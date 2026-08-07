; ---------------------------------------------------------------------------
; convex_live.s -- the Convex sync (Live) protocol state machine, built on
; convex_ws.s's RFC 6455 primitives. This file owns everything protocol-
; specific: the Connect/ModifyQuerySet/Transition JSON message shapes, query
; IDs, reconnect-with-backoff, resending the active Add set after every
; reconnect, and rehydration suppression (a fresh session always replays a
; QueryUpdated for every query it re-Adds, even when nothing changed --
; without suppressing an unchanged replay, a client-visible reconnect would
; look like a spurious update).
;
; Single-owner by construction: every function here that touches the socket,
; the query-set version, or the subscription list is only ever called from
; whichever single control thread the embedding program (the conformance
; adapter's poll() event loop, or the canonical example's blocking wait
; helper) runs on. There is no lock because there is only ever one caller.
;
; Same fixed-frame stack discipline as the rest of this client; the trickier
; functions below use %define'd names for their frame slots instead of bare
; rbp-N arithmetic, undefining each name once the function is done, so nothing
; here reaches into a slot that belongs to a different function's frame.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

extern buf_init
extern buf_free
extern buf_append
extern json_new_null
extern json_new_bool
extern json_new_int
extern json_new_string
extern json_new_array
extern json_new_object
extern json_array_push
extern json_object_set
extern json_object_get
extern json_free
extern json_parse
extern json_serialize
extern json_clone
extern ws_open
extern ws_close
extern ws_send_frame
extern ws_recv_more
extern ws_pump_message
extern poll

section .text

global convex_live_init
global convex_live_close
global convex_live_subscribe
global convex_live_unsubscribe
global convex_live_debug_disconnect
global convex_live_maintain
global convex_live_service_socket
global convex_live_dequeue
global convex_live_poll_fd
global convex_live_next

LIVE_BACKOFF_BASE_MS equ 200
LIVE_BACKOFF_MAX_MS  equ 10000

; --- small leaf helpers -----------------------------------------------

; void dbg_mark(int code) [edi] -- DEBUG ONLY: writes one marker digit +
; newline to stderr. Used to bisect a crash by call-site sequence.
dbg_mark:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], edi
    add byte [rbp-8], '0'
    mov edi, 2
    lea rsi, [rbp-8]
    mov edx, 1
    call write
    mov edi, 2
    lea rsi, [rel dbg_nl_live]
    mov edx, 1
    call write
    mov rsp, rbp
    pop rbp
    ret

; char hex_nibble_char(int nibble) [edi, 0-15] -- leaf, no frame needed.
hex_nibble_char:
    mov al, dil
    cmp al, 10
    jb .digit
    add al, 'a' - 10
    ret
.digit:
    add al, '0'
    ret

; int bytes_eq(const char *a, u64 alen, const char *b, u64 blen) -- leaf
; aside from one memcmp call, matching the same small helper every other
; file in this client keeps privately rather than sharing across
; translation units. memcmp itself is already declared extern by
; convex.inc, included above.
%define BE_ALEN -8
%define BE_BLEN -16
bytes_eq:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+BE_ALEN], rsi
    mov [rbp+BE_BLEN], rcx
    cmp rsi, rcx
    jne .no
    test rsi, rsi
    jz .yes
    mov r8, rdx
    mov rdx, rsi
    mov rsi, r8
    call memcmp
    test eax, eax
    jnz .no
.yes:
    mov eax, 1
    jmp .done
.no:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef BE_ALEN
%undef BE_BLEN

; i64 monotonic_ms(void)
%define MM_TS     -16     ; timespec, 16 bytes: rbp-16..rbp-1
%define MM_RESULT -24
monotonic_ms:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rbp+MM_TS]
    call clock_gettime
    mov rax, [rbp+MM_TS + timespec.tv_sec]
    imul rax, rax, 1000
    mov [rbp+MM_RESULT], rax
    mov rax, [rbp+MM_TS + timespec.tv_nsec]
    xor rdx, rdx
    mov rcx, 1000000
    div rcx
    add rax, [rbp+MM_RESULT]
    mov rsp, rbp
    pop rbp
    ret
%undef MM_TS
%undef MM_RESULT

; void gen_session_id(char *out) -- writes a 36-character (plus NUL)
; RFC 4122-shaped v4 UUID text. Only ever used as an opaque per-connection
; identifier the server echoes back in protocol traffic, so a best-effort
; fallback on RAND_bytes failure (still formatted correctly, just less
; random) is an acceptable simplification rather than a hard error.
%define GS_OUT -8
%define GS_RAW -24        ; 16 bytes: rbp-24..rbp-9
%define GS_I   -32
%define GS_J   -40
gen_session_id:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp+GS_OUT], rdi
    lea rdi, [rbp+GS_RAW]
    mov esi, 16
    call RAND_bytes

    movzx eax, byte [rbp+GS_RAW+6]
    and al, 0x0F
    or al, 0x40
    mov [rbp+GS_RAW+6], al
    movzx eax, byte [rbp+GS_RAW+8]
    and al, 0x3F
    or al, 0x80
    mov [rbp+GS_RAW+8], al

    mov qword [rbp+GS_I], 0
    mov qword [rbp+GS_J], 0
.byte_loop:
    mov rax, [rbp+GS_I]
    cmp rax, 16
    jae .terminate
    movzx ecx, byte [rbp+GS_RAW + rax]
    mov edx, ecx
    shr dl, 4
    movzx edi, dl
    call hex_nibble_char
    mov rcx, [rbp+GS_OUT]
    mov rdx, [rbp+GS_J]
    mov [rcx+rdx], al
    inc qword [rbp+GS_J]

    mov rax, [rbp+GS_I]
    movzx ecx, byte [rbp+GS_RAW + rax]
    and ecx, 0x0F
    mov edi, ecx
    call hex_nibble_char
    mov rcx, [rbp+GS_OUT]
    mov rdx, [rbp+GS_J]
    mov [rcx+rdx], al
    inc qword [rbp+GS_J]

    mov rax, [rbp+GS_I]
    cmp rax, 3
    je .dash
    cmp rax, 5
    je .dash
    cmp rax, 7
    je .dash
    cmp rax, 9
    je .dash
    jmp .next_byte
.dash:
    mov rcx, [rbp+GS_OUT]
    mov rdx, [rbp+GS_J]
    mov byte [rcx+rdx], '-'
    inc qword [rbp+GS_J]
.next_byte:
    mov rax, [rbp+GS_I]
    inc rax
    mov [rbp+GS_I], rax
    jmp .byte_loop
.terminate:
    mov rcx, [rbp+GS_OUT]
    mov rdx, [rbp+GS_J]
    mov byte [rcx+rdx], 0
    mov rsp, rbp
    pop rbp
    ret
%undef GS_OUT
%undef GS_RAW
%undef GS_I
%undef GS_J

; --- small JSON-building helpers ---------------------------------------

; void obj_set_int(json_value *obj, const char *key, u64 keylen, i64 val)
%define OSI_OBJ -8
%define OSI_KEY -16
%define OSI_KEYLEN -24
obj_set_int:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+OSI_OBJ], rdi
    mov [rbp+OSI_KEY], rsi
    mov [rbp+OSI_KEYLEN], rdx
    mov rdi, rcx
    call json_new_int
    mov rcx, rax
    mov rdi, [rbp+OSI_OBJ]
    mov rsi, [rbp+OSI_KEY]
    mov rdx, [rbp+OSI_KEYLEN]
    call json_object_set
    mov rsp, rbp
    pop rbp
    ret
%undef OSI_OBJ
%undef OSI_KEY
%undef OSI_KEYLEN

; void obj_set_str(json_value *obj, const char *key, u64 keylen,
;                   const char *val, u64 vallen)
%define OSS_OBJ -8
%define OSS_KEY -16
%define OSS_KEYLEN -24
obj_set_str:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+OSS_OBJ], rdi
    mov [rbp+OSS_KEY], rsi
    mov [rbp+OSS_KEYLEN], rdx
    mov rdi, rcx
    mov rsi, r8
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp+OSS_OBJ]
    mov rsi, [rbp+OSS_KEY]
    mov rdx, [rbp+OSS_KEYLEN]
    call json_object_set
    mov rsp, rbp
    pop rbp
    ret
%undef OSS_OBJ
%undef OSS_KEY
%undef OSS_KEYLEN

; --- subscription list ---------------------------------------------------

; convex_sub *find_sub_by_query_id(convex_live *live, u64 qid)
%define FQ_QID -8
find_sub_by_query_id:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+FQ_QID], rsi
    mov rax, [rdi + convex_live.subs]
.loop:
    test rax, rax
    jz .notfound
    mov rcx, [rax + convex_sub.query_id]
    cmp rcx, [rbp+FQ_QID]
    je .done
    mov rax, [rax + convex_sub.next]
    jmp .loop
.notfound:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef FQ_QID

; void free_update_contents(convex_update *u) -- frees everything a queued
; update owns, without freeing the (caller-owned) convex_update slot itself.
free_update_contents:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rax, [rdi + convex_update.value]
    test rax, rax
    jz .no_value
    mov rdi, rax
    call json_free
.no_value:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_update.logs]
    test rax, rax
    jz .no_logs
    mov rdi, rax
    call json_free
.no_logs:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_update.err_msg_ptr]
    test rax, rax
    jz .no_msg
    mov rdi, rax
    call free
.no_msg:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_update.err_data]
    test rax, rax
    jz .no_data
    mov rdi, rax
    call json_free
.no_data:
    mov rsp, rbp
    pop rbp
    ret

; void live_enqueue(convex_sub *sub, json_value *value, json_value *logs,
;                    int has_error, const char *err_name_ptr, u64 err_name_len,
;                    char *err_msg_ptr, u64 err_msg_len, json_value *err_data)
; [err_msg_ptr, err_msg_len, err_data arrive on the stack at rbp+16/24/32]
; Takes ownership of value/logs/err_msg_ptr/err_data. Drops the oldest
; queued update (freeing it) when the bounded queue is already full --
; AGENTS.md's required "bound it and test its overflow behaviour" choice;
; see the README for why drop-oldest rather than a general backpressure
; scheme.
%define EQ_SUB      -8
%define EQ_VALUE    -16
%define EQ_LOGS     -24
%define EQ_HASERR   -32
%define EQ_ENAMEP   -40
%define EQ_ENAMEL   -48
%define EQ_EMSGP    -56
%define EQ_EMSGL    -64
%define EQ_EDATA    -72
%define EQ_IDX      -80
live_enqueue:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+EQ_SUB], rdi
    mov [rbp+EQ_VALUE], rsi
    mov [rbp+EQ_LOGS], rdx
    mov [rbp+EQ_HASERR], rcx
    mov [rbp+EQ_ENAMEP], r8
    mov [rbp+EQ_ENAMEL], r9
    mov rax, [rbp + 16]
    mov [rbp+EQ_EMSGP], rax
    mov rax, [rbp + 24]
    mov [rbp+EQ_EMSGL], rax
    mov rax, [rbp + 32]
    mov [rbp+EQ_EDATA], rax

    mov rax, [rbp+EQ_SUB]
    mov rcx, [rax + convex_sub.queue_count]
    cmp rcx, LIVE_QUEUE_DEPTH
    jb .have_room
    ; drop the oldest
    mov rax, [rbp+EQ_SUB]
    mov rcx, [rax + convex_sub.queue_head]
    lea rdi, [rax + convex_sub.queue]
    imul rcx, rcx, convex_update_size
    add rdi, rcx
    call free_update_contents
    mov rax, [rbp+EQ_SUB]
    mov rcx, [rax + convex_sub.queue_head]
    inc rcx
    and rcx, (LIVE_QUEUE_DEPTH - 1)
    mov [rax + convex_sub.queue_head], rcx
    dec qword [rax + convex_sub.queue_count]
.have_room:
    mov rax, [rbp+EQ_SUB]
    mov rcx, [rax + convex_sub.queue_head]
    add rcx, [rax + convex_sub.queue_count]
    and rcx, (LIVE_QUEUE_DEPTH - 1)
    mov [rbp+EQ_IDX], rcx
    lea rdx, [rax + convex_sub.queue]
    imul rcx, rcx, convex_update_size
    add rdx, rcx
    mov rax, [rbp+EQ_VALUE]
    mov [rdx + convex_update.value], rax
    mov rax, [rbp+EQ_LOGS]
    mov [rdx + convex_update.logs], rax
    mov rax, [rbp+EQ_HASERR]
    mov [rdx + convex_update.has_error], rax
    mov rax, [rbp+EQ_ENAMEP]
    mov [rdx + convex_update.err_name_ptr], rax
    mov rax, [rbp+EQ_ENAMEL]
    mov [rdx + convex_update.err_name_len], rax
    mov rax, [rbp+EQ_EMSGP]
    mov [rdx + convex_update.err_msg_ptr], rax
    mov rax, [rbp+EQ_EMSGL]
    mov [rdx + convex_update.err_msg_len], rax
    mov rax, [rbp+EQ_EDATA]
    mov [rdx + convex_update.err_data], rax
    mov rax, [rbp+EQ_SUB]
    inc qword [rax + convex_sub.queue_count]

    mov rsp, rbp
    pop rbp
    ret
%undef EQ_SUB
%undef EQ_VALUE
%undef EQ_LOGS
%undef EQ_HASERR
%undef EQ_ENAMEP
%undef EQ_ENAMEL
%undef EQ_EMSGP
%undef EQ_EMSGL
%undef EQ_EDATA
%undef EQ_IDX

; int convex_live_dequeue(convex_sub *sub, convex_update *out)
convex_live_dequeue:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov rax, [rdi + convex_sub.queue_count]
    test rax, rax
    jz .empty
    mov rcx, [rdi + convex_sub.queue_head]
    lea rdx, [rdi + convex_sub.queue]
    imul rcx, rcx, convex_update_size
    add rdx, rcx
    mov [rbp-24], rdx           ; source slot address
    ; copy the 8-field (64-byte) convex_update struct
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rcx, [rsi + convex_update.value]
    mov [rdi + convex_update.value], rcx
    mov rcx, [rsi + convex_update.logs]
    mov [rdi + convex_update.logs], rcx
    mov rcx, [rsi + convex_update.has_error]
    mov [rdi + convex_update.has_error], rcx
    mov rcx, [rsi + convex_update.err_name_ptr]
    mov [rdi + convex_update.err_name_ptr], rcx
    mov rcx, [rsi + convex_update.err_name_len]
    mov [rdi + convex_update.err_name_len], rcx
    mov rcx, [rsi + convex_update.err_msg_ptr]
    mov [rdi + convex_update.err_msg_ptr], rcx
    mov rcx, [rsi + convex_update.err_msg_len]
    mov [rdi + convex_update.err_msg_len], rcx
    mov rcx, [rsi + convex_update.err_data]
    mov [rdi + convex_update.err_data], rcx

    mov rdi, [rbp-8]
    mov rax, [rdi + convex_sub.queue_head]
    inc rax
    and rax, (LIVE_QUEUE_DEPTH - 1)
    mov [rdi + convex_sub.queue_head], rax
    dec qword [rdi + convex_sub.queue_count]
    mov eax, 1
    jmp .done
.empty:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; void deliver_update(convex_sub *sub, json_value *value, json_value *logs,
;                      int has_error, const char *err_name_ptr, u64 err_name_len,
;                      char *err_msg_ptr, u64 err_msg_len, json_value *err_data)
; [err_msg_ptr/err_msg_len/err_data on the stack, same layout as live_enqueue]
; Applies the reconnect rehydration-suppression rule (see the file header)
; before handing off to live_enqueue.
%define DU_SUB    -8
%define DU_VALUE  -16
%define DU_LOGS   -24
%define DU_HASERR -32
%define DU_ENAMEP -40
%define DU_ENAMEL -48
%define DU_EMSGP  -56
%define DU_EMSGL  -64
%define DU_EDATA  -72
%define DU_WASREC -80
%define DU_SUPPRESS -88
%define DU_TMPBUF -112       ; buf, 24 bytes: rbp-112..rbp-89
deliver_update:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp+DU_SUB], rdi
    mov [rbp+DU_VALUE], rsi
    mov [rbp+DU_LOGS], rdx
    mov [rbp+DU_HASERR], rcx
    mov [rbp+DU_ENAMEP], r8
    mov [rbp+DU_ENAMEL], r9
    mov rax, [rbp + 16]
    mov [rbp+DU_EMSGP], rax
    mov rax, [rbp + 24]
    mov [rbp+DU_EMSGL], rax
    mov rax, [rbp + 32]
    mov [rbp+DU_EDATA], rax

    mov rax, [rdi + convex_sub.just_reconnected]
    mov [rbp+DU_WASREC], rax
    mov qword [rdi + convex_sub.just_reconnected], 0
    mov qword [rbp+DU_SUPPRESS], 0

    mov rax, [rbp+DU_HASERR]
    test rax, rax
    jnz .skip_value_bookkeeping

    mov rax, [rbp+DU_WASREC]
    test rax, rax
    jz .fresh_value
    mov rax, [rbp+DU_SUB]
    mov rax, [rax + convex_sub.has_last_value]
    test rax, rax
    jz .fresh_value

    ; compare a fresh serialization of the new value against the last one
    ; delivered, and suppress this delivery if they are byte-identical.
    lea rdi, [rbp+DU_TMPBUF]
    call buf_init
    mov rdi, [rbp+DU_VALUE]
    lea rsi, [rbp+DU_TMPBUF]
    call json_serialize
    mov rax, [rbp+DU_SUB]
    lea rax, [rax + convex_sub.last_value_text]
    mov rdi, [rbp+DU_TMPBUF + buf.data]
    mov rsi, [rbp+DU_TMPBUF + buf.len]
    mov rdx, [rax + buf.data]
    mov rcx, [rax + buf.len]
    call bytes_eq
    test eax, eax
    jz .not_equal
    mov qword [rbp+DU_SUPPRESS], 1
    lea rdi, [rbp+DU_TMPBUF]
    call buf_free
    jmp .skip_value_bookkeeping
.not_equal:
    mov rax, [rbp+DU_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_free
    mov rax, [rbp+DU_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    mov rsi, [rbp+DU_TMPBUF + buf.data]
    mov [rdi + buf.data], rsi
    mov rsi, [rbp+DU_TMPBUF + buf.len]
    mov [rdi + buf.len], rsi
    mov rsi, [rbp+DU_TMPBUF + buf.cap]
    mov [rdi + buf.cap], rsi
    mov qword [rax + convex_sub.has_last_value], 1
    jmp .skip_value_bookkeeping
.fresh_value:
    mov rax, [rbp+DU_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_free
    mov rax, [rbp+DU_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_init
    mov rdi, [rbp+DU_VALUE]
    mov rax, [rbp+DU_SUB]
    lea rsi, [rax + convex_sub.last_value_text]
    call json_serialize
    mov rax, [rbp+DU_SUB]
    mov qword [rax + convex_sub.has_last_value], 1
.skip_value_bookkeeping:
    mov rax, [rbp+DU_SUPPRESS]
    test rax, rax
    jz .enqueue
    mov rdi, [rbp+DU_VALUE]
    call json_free
    mov rdi, [rbp+DU_LOGS]
    call json_free
    jmp .done
.enqueue:
    mov rdi, [rbp+DU_SUB]
    mov rsi, [rbp+DU_VALUE]
    mov rdx, [rbp+DU_LOGS]
    mov rcx, [rbp+DU_HASERR]
    mov r8, [rbp+DU_ENAMEP]
    mov r9, [rbp+DU_ENAMEL]
    sub rsp, 32
    mov rax, [rbp+DU_EMSGP]
    mov [rsp], rax
    mov rax, [rbp+DU_EMSGL]
    mov [rsp+8], rax
    mov rax, [rbp+DU_EDATA]
    mov [rsp+16], rax
    call live_enqueue
    add rsp, 32
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef DU_SUB
%undef DU_VALUE
%undef DU_LOGS
%undef DU_HASERR
%undef DU_ENAMEP
%undef DU_ENAMEL
%undef DU_EMSGP
%undef DU_EMSGL
%undef DU_EDATA
%undef DU_WASREC
%undef DU_SUPPRESS
%undef DU_TMPBUF

; char *dup_bytes(const char *p, u64 len) -- NUL-terminated malloc'd copy,
; or 0 on OOM. Every owned string this file keeps (remote_ts,
; max_observed_ts, a QueryFailed errorMessage) goes through this so freeing
; them is always the same one-line `call free`, never a mix of static
; literals and heap pointers.
%define DB_P -8
%define DB_LEN -16
%define DB_RESULT -24
dup_bytes:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+DB_P], rdi
    mov [rbp+DB_LEN], rsi
    lea rdi, [rsi + 1]
    call malloc
    test rax, rax
    jz .done
    mov [rbp+DB_RESULT], rax
    mov rdi, rax
    mov rsi, [rbp+DB_P]
    mov rdx, [rbp+DB_LEN]
    call memcpy
    mov rax, [rbp+DB_RESULT]
    mov rcx, [rbp+DB_LEN]
    mov byte [rax + rcx], 0
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef DB_P
%undef DB_LEN
%undef DB_RESULT

; --- outgoing message builders -----------------------------------------

; int send_connect_message(convex_live *live)
%define SC_LIVE -8
%define SC_OBJ  -16
%define SC_TMP  -48        ; buf, 24 bytes: rbp-48..rbp-25
%define SC_RESULT -56
send_connect_message:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp+SC_LIVE], rdi
    call json_new_object
    mov [rbp+SC_OBJ], rax

    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    lea rcx, [rel v_connect]
    mov r8, v_connect_len
    call obj_set_str

    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rel k_session_id]
    mov edx, k_session_id_len
    mov rax, [rbp+SC_LIVE]
    lea rcx, [rax + convex_live.session_id]
    mov r8, 36
    call obj_set_str

    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rel k_connection_count]
    mov edx, k_connection_count_len
    mov rax, [rbp+SC_LIVE]
    mov rcx, [rax + convex_live.connection_count]
    call obj_set_int

    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rel k_last_close_reason]
    mov edx, k_last_close_reason_len
    mov rax, [rbp+SC_LIVE]
    mov rcx, [rax + convex_live.last_close_reason_ptr]
    mov r8, [rax + convex_live.last_close_reason_len]
    call obj_set_str

    mov rax, [rbp+SC_LIVE]
    mov rcx, [rax + convex_live.max_observed_ts_len]
    test rcx, rcx
    jz .no_max_ts
    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rel k_max_observed_ts]
    mov edx, k_max_observed_ts_len
    mov rax, [rbp+SC_LIVE]
    mov rcx, [rax + convex_live.max_observed_ts_ptr]
    mov r8, [rax + convex_live.max_observed_ts_len]
    call obj_set_str
.no_max_ts:
    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rel k_client_ts]
    mov edx, k_client_ts_len
    xor ecx, ecx
    call obj_set_int

    lea rdi, [rbp+SC_TMP]
    call buf_init
    mov rdi, [rbp+SC_OBJ]
    lea rsi, [rbp+SC_TMP]
    call json_serialize

    mov rax, [rbp+SC_LIVE]
    lea rdi, [rax + convex_live.ws]
    mov esi, WS_OP_TEXT
    mov rdx, [rbp+SC_TMP + buf.data]
    mov rcx, [rbp+SC_TMP + buf.len]
    call ws_send_frame
    mov [rbp+SC_RESULT], rax
    lea rdi, [rbp+SC_TMP]
    call buf_free
    mov rdi, [rbp+SC_OBJ]
    call json_free
    mov rax, [rbp+SC_RESULT]
    mov rsp, rbp
    pop rbp
    ret
%undef SC_LIVE
%undef SC_OBJ
%undef SC_TMP
%undef SC_RESULT

; int send_add_batch(convex_live *live) -- batches every PENDING_ADD
; subscription into one ModifyQuerySet/Add message. The same code path
; serves a subscribe issued while already connected and the full resend a
; reconnect requires (try_connect marks every previously-ACTIVE
; subscription back to PENDING_ADD before this ever runs). Cloning each
; sub's args (rather than handing over the sub's own copy) matters: the
; args tree must survive to be resent again after a *later* reconnect, so
; the copy that becomes part of this outgoing message -- and gets freed
; with it -- must not be the subscription's only copy.
%define AB_LIVE   -8
%define AB_OBJ    -16
%define AB_MODS   -24
%define AB_SUB    -32
%define AB_ANY    -40
%define AB_MOD    -48
%define AB_ARGS   -56
%define AB_RESULT -64
%define AB_TMP    -96      ; buf, 24 bytes: rbp-96..rbp-73
send_add_batch:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp+AB_LIVE], rdi

    mov qword [rbp+AB_ANY], 0
    mov rax, [rdi + convex_live.subs]
.scan:
    test rax, rax
    jz .scan_done
    cmp qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    jne .scan_next
    mov qword [rbp+AB_ANY], 1
.scan_next:
    mov rax, [rax + convex_sub.next]
    jmp .scan
.scan_done:
    cmp qword [rbp+AB_ANY], 0
    jnz .build
    mov eax, 1
    jmp .done
.build:
    call json_new_object
    mov [rbp+AB_OBJ], rax

    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    lea rcx, [rel v_modify_query_set]
    mov r8, v_modify_query_set_len
    call obj_set_str

    mov rdi, [rbp+AB_OBJ]
    lea rsi, [rel k_base_version]
    mov edx, k_base_version_len
    mov rax, [rbp+AB_LIVE]
    mov rcx, [rax + convex_live.base_version]
    call obj_set_int

    mov rdi, [rbp+AB_OBJ]
    lea rsi, [rel k_new_version]
    mov edx, k_new_version_len
    mov rax, [rbp+AB_LIVE]
    mov rcx, [rax + convex_live.base_version]
    inc rcx
    call obj_set_int

    call json_new_array
    mov [rbp+AB_MODS], rax

    mov rax, [rbp+AB_LIVE]
    mov rax, [rax + convex_live.subs]
    mov [rbp+AB_SUB], rax
.mods_loop:
    mov rax, [rbp+AB_SUB]
    test rax, rax
    jz .mods_done
    cmp qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    jne .mods_next

    call json_new_object
    mov [rbp+AB_MOD], rax
    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    lea rcx, [rel v_add]
    mov r8, v_add_len
    call obj_set_str

    mov rdi, [rbp+AB_MOD]
    lea rsi, [rel k_query_id]
    mov edx, k_query_id_len
    mov rax, [rbp+AB_SUB]
    mov rcx, [rax + convex_sub.query_id]
    call obj_set_int

    mov rdi, [rbp+AB_MOD]
    lea rsi, [rel k_udf_path]
    mov edx, k_udf_path_len
    mov rax, [rbp+AB_SUB]
    mov rcx, [rax + convex_sub.path_ptr]
    mov r8, [rax + convex_sub.path_len]
    call obj_set_str

    call json_new_array
    mov [rbp+AB_ARGS], rax
    mov rax, [rbp+AB_SUB]
    mov rdi, [rax + convex_sub.args]
    call json_clone
    mov rdi, [rbp+AB_ARGS]
    mov rsi, rax
    call json_array_push
    mov rdi, [rbp+AB_MOD]
    lea rsi, [rel k_args]
    mov edx, k_args_len
    mov rcx, [rbp+AB_ARGS]
    call json_object_set

    mov rdi, [rbp+AB_MODS]
    mov rsi, [rbp+AB_MOD]
    call json_array_push

.mods_next:
    mov rax, [rbp+AB_SUB]
    mov rax, [rax + convex_sub.next]
    mov [rbp+AB_SUB], rax
    jmp .mods_loop
.mods_done:
    mov rdi, [rbp+AB_OBJ]
    lea rsi, [rel k_modifications]
    mov edx, k_modifications_len
    mov rcx, [rbp+AB_MODS]
    call json_object_set

    lea rdi, [rbp+AB_TMP]
    call buf_init
    mov rdi, [rbp+AB_OBJ]
    lea rsi, [rbp+AB_TMP]
    call json_serialize

    mov rax, [rbp+AB_LIVE]
    lea rdi, [rax + convex_live.ws]
    mov esi, WS_OP_TEXT
    mov rdx, [rbp+AB_TMP + buf.data]
    mov rcx, [rbp+AB_TMP + buf.len]
    call ws_send_frame
    mov [rbp+AB_RESULT], rax
    lea rdi, [rbp+AB_TMP]
    call buf_free
    mov rdi, [rbp+AB_OBJ]
    call json_free

    cmp qword [rbp+AB_RESULT], 0
    jz .mark_done
    mov rax, [rbp+AB_LIVE]
    inc qword [rax + convex_live.base_version]
    mov rax, [rax + convex_live.subs]
.mark_loop:
    test rax, rax
    jz .mark_done
    cmp qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    jne .mark_next
    mov qword [rax + convex_sub.state], CONVEX_SUB_ACTIVE
.mark_next:
    mov rax, [rax + convex_sub.next]
    jmp .mark_loop
.mark_done:
    mov rax, [rbp+AB_RESULT]
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef AB_LIVE
%undef AB_OBJ
%undef AB_MODS
%undef AB_SUB
%undef AB_ANY
%undef AB_MOD
%undef AB_ARGS
%undef AB_RESULT
%undef AB_TMP

; int send_remove(convex_live *live, convex_sub *sub)
%define SR2_LIVE -8
%define SR2_SUB  -16
%define SR2_OBJ  -24
%define SR2_MODS -32
%define SR2_MOD  -40
%define SR2_RESULT -48
%define SR2_TMP  -80       ; buf, 24 bytes: rbp-80..rbp-57
send_remove:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+SR2_LIVE], rdi
    mov [rbp+SR2_SUB], rsi

    call json_new_object
    mov [rbp+SR2_OBJ], rax
    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    lea rcx, [rel v_modify_query_set]
    mov r8, v_modify_query_set_len
    call obj_set_str

    mov rdi, [rbp+SR2_OBJ]
    lea rsi, [rel k_base_version]
    mov edx, k_base_version_len
    mov rax, [rbp+SR2_LIVE]
    mov rcx, [rax + convex_live.base_version]
    call obj_set_int

    mov rdi, [rbp+SR2_OBJ]
    lea rsi, [rel k_new_version]
    mov edx, k_new_version_len
    mov rax, [rbp+SR2_LIVE]
    mov rcx, [rax + convex_live.base_version]
    inc rcx
    call obj_set_int

    call json_new_array
    mov [rbp+SR2_MODS], rax
    call json_new_object
    mov [rbp+SR2_MOD], rax
    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    lea rcx, [rel v_remove]
    mov r8, v_remove_len
    call obj_set_str
    mov rdi, [rbp+SR2_MOD]
    lea rsi, [rel k_query_id]
    mov edx, k_query_id_len
    mov rax, [rbp+SR2_SUB]
    mov rcx, [rax + convex_sub.query_id]
    call obj_set_int
    mov rdi, [rbp+SR2_MODS]
    mov rsi, [rbp+SR2_MOD]
    call json_array_push

    mov rdi, [rbp+SR2_OBJ]
    lea rsi, [rel k_modifications]
    mov edx, k_modifications_len
    mov rcx, [rbp+SR2_MODS]
    call json_object_set

    lea rdi, [rbp+SR2_TMP]
    call buf_init
    mov rdi, [rbp+SR2_OBJ]
    lea rsi, [rbp+SR2_TMP]
    call json_serialize

    mov rax, [rbp+SR2_LIVE]
    lea rdi, [rax + convex_live.ws]
    mov esi, WS_OP_TEXT
    mov rdx, [rbp+SR2_TMP + buf.data]
    mov rcx, [rbp+SR2_TMP + buf.len]
    call ws_send_frame
    mov [rbp+SR2_RESULT], rax
    lea rdi, [rbp+SR2_TMP]
    call buf_free
    mov rdi, [rbp+SR2_OBJ]
    call json_free

    cmp qword [rbp+SR2_RESULT], 0
    jz .done
    mov rax, [rbp+SR2_LIVE]
    inc qword [rax + convex_live.base_version]
.done:
    mov rax, [rbp+SR2_RESULT]
    mov rsp, rbp
    pop rbp
    ret
%undef SR2_LIVE
%undef SR2_SUB
%undef SR2_OBJ
%undef SR2_MODS
%undef SR2_MOD
%undef SR2_RESULT
%undef SR2_TMP

; --- connection lifecycle -----------------------------------------------

; void teardown_and_schedule(convex_live *live, const char *reason_ptr,
;                             u64 reason_len, int immediate)
; `immediate` is true only for a deliberate debugDisconnect: it resets
; backoff to the base delay and schedules the next attempt right now,
; instead of growing the exponential delay the way a real failure does.
; Every previously-ACTIVE subscription goes back to PENDING_ADD with
; just_reconnected set, so the next successful connection resends its Add
; and (per deliver_update) suppresses the resulting unchanged rehydration.
%define TS_LIVE -8
%define TS_REASONP -16
%define TS_REASONL -24
%define TS_IMM -32
teardown_and_schedule:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+TS_LIVE], rdi
    mov [rbp+TS_REASONP], rsi
    mov [rbp+TS_REASONL], rdx
    mov [rbp+TS_IMM], rcx

    lea rdi, [rdi + convex_live.ws]
    call ws_close

    mov rax, [rbp+TS_LIVE]
    mov qword [rax + convex_live.connected], 0
    inc qword [rax + convex_live.connection_count]
    mov rcx, [rbp+TS_REASONP]
    mov [rax + convex_live.last_close_reason_ptr], rcx
    mov rcx, [rbp+TS_REASONL]
    mov [rax + convex_live.last_close_reason_len], rcx

    mov rax, [rax + convex_live.subs]
.mark_loop:
    test rax, rax
    jz .mark_done
    cmp qword [rax + convex_sub.state], CONVEX_SUB_ACTIVE
    jne .mark_next
    mov qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    mov qword [rax + convex_sub.just_reconnected], 1
.mark_next:
    mov rax, [rax + convex_sub.next]
    jmp .mark_loop
.mark_done:
    call monotonic_ms
    mov rcx, [rbp+TS_LIVE]
    cmp qword [rbp+TS_IMM], 0
    jz .backoff
    mov qword [rcx + convex_live.backoff_ms], LIVE_BACKOFF_BASE_MS
    mov [rcx + convex_live.next_attempt_ms], rax
    jmp .done
.backoff:
    mov rdx, [rcx + convex_live.backoff_ms]
    add rax, rdx
    mov [rcx + convex_live.next_attempt_ms], rax
    mov rax, rdx
    shl rax, 1
    cmp rax, LIVE_BACKOFF_MAX_MS
    jbe .store_backoff
    mov rax, LIVE_BACKOFF_MAX_MS
.store_backoff:
    mov [rcx + convex_live.backoff_ms], rax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef TS_LIVE
%undef TS_REASONP
%undef TS_REASONL
%undef TS_IMM

; int try_connect(convex_live *live) -- opens the WebSocket, sends Connect,
; and resets every piece of per-connection state a fresh sync session
; starts over: the server's confirmed query-set version, the query-set
; version we send, and (via marking every ACTIVE subscription back to
; PENDING_ADD) the Add resend the caller's next send_add_batch will do.
%define TC_LIVE -8
%define TC_TMP  -16
try_connect:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+TC_LIVE], rdi

    mov edi, 3
    call dbg_mark

    mov rax, [rbp+TC_LIVE]
    mov rax, [rax + convex_live.client]
    lea rdi, [rax + convex_client.url]
    mov rsi, [rax + convex_client.user_agent_ptr]
    mov rdx, [rax + convex_client.user_agent_len]
    mov rcx, [rbp+TC_LIVE]
    lea rcx, [rcx + convex_live.ws]
    call ws_open
    mov [rbp+TC_TMP], rax
    mov edi, 4
    call dbg_mark
    mov rax, [rbp+TC_TMP]
    test eax, eax
    jz .fail

    mov edi, 7
    call dbg_mark
    mov rdi, [rbp+TC_LIVE]
    call send_connect_message
    mov [rbp+TC_TMP], rax
    mov edi, 8
    call dbg_mark
    mov rax, [rbp+TC_TMP]
    test eax, eax
    jz .fail

    mov rax, [rbp+TC_LIVE]
    mov qword [rax + convex_live.connected], 1
    mov qword [rax + convex_live.remote_query_set], 0
    mov qword [rax + convex_live.remote_identity], 0
    mov qword [rax + convex_live.base_version], 0

    mov rcx, [rax + convex_live.remote_ts_ptr]
    test rcx, rcx
    jz .no_free_ts
    mov rdi, rcx
    call free
.no_free_ts:
    lea rdi, [rel initial_ts]
    mov esi, initial_ts_len
    call dup_bytes
    mov rcx, [rbp+TC_LIVE]
    mov [rcx + convex_live.remote_ts_ptr], rax
    mov qword [rcx + convex_live.remote_ts_len], initial_ts_len

    mov rax, [rcx + convex_live.subs]
.mark_loop:
    test rax, rax
    jz .mark_done
    cmp qword [rax + convex_sub.state], CONVEX_SUB_ACTIVE
    jne .mark_next
    mov qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    mov qword [rax + convex_sub.just_reconnected], 1
.mark_next:
    mov rax, [rax + convex_sub.next]
    jmp .mark_loop
.mark_done:
    mov rax, [rbp+TC_LIVE]
    mov qword [rax + convex_live.backoff_ms], LIVE_BACKOFF_BASE_MS
    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef TC_LIVE
%undef TC_TMP

; void convex_live_maintain(convex_live *live) -- called every event-loop
; tick regardless of socket readiness: (re)connects on schedule and flushes
; any pending Add work. Never blocks -- ws_open's own connect/handshake
; calls are the only place this can take real wall-clock time, bounded the
; same way every other blocking call in this client is.
%define LM_LIVE -8
convex_live_maintain:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+LM_LIVE], rdi

    mov edi, 2
    call dbg_mark
    mov rdi, [rbp+LM_LIVE]

    mov rax, [rdi + convex_live.connected]
    test rax, rax
    jnz .connected

    mov rax, [rdi + convex_live.subs]
    test rax, rax
    jz .done

    call monotonic_ms
    mov rcx, [rbp+LM_LIVE]
    cmp rax, [rcx + convex_live.next_attempt_ms]
    jl .done

    mov rdi, [rbp+LM_LIVE]
    call try_connect
    test eax, eax
    jnz .connected
    mov rdi, [rbp+LM_LIVE]
    lea rsi, [rel reason_transport_error]
    mov edx, reason_transport_error_len
    xor ecx, ecx
    call teardown_and_schedule
    jmp .done
.connected:
    mov rax, [rbp+LM_LIVE]
    mov rax, [rax + convex_live.connected]
    test rax, rax
    jz .done
    mov rdi, [rbp+LM_LIVE]
    call send_add_batch
    test eax, eax
    jnz .done
    mov rdi, [rbp+LM_LIVE]
    lea rsi, [rel reason_transport_error]
    mov edx, reason_transport_error_len
    xor ecx, ecx
    call teardown_and_schedule
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef LM_LIVE

; --- incoming message handling ------------------------------------------

; int parse_sv(json_value *sv, u64 *qs_out, u64 *id_out, char **ts_ptr_out,
;              u64 *ts_len_out) -- extracts a StateVersion's querySet,
; identity and ts fields.
%define PV_QSOUT  -8
%define PV_IDOUT  -16
%define PV_TSPOUT -24
%define PV_TSLOUT -32
%define PV_SV     -40
parse_sv:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp+PV_SV], rdi
    mov [rbp+PV_QSOUT], rsi
    mov [rbp+PV_IDOUT], rdx
    mov [rbp+PV_TSPOUT], rcx
    mov [rbp+PV_TSLOUT], r8

    mov rdi, [rbp+PV_SV]
    lea rsi, [rel k_query_set]
    mov edx, k_query_set_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_INT
    jne .bad
    mov rcx, [rax + json_value.ival]
    mov rdx, [rbp+PV_QSOUT]
    mov [rdx], rcx

    mov rdi, [rbp+PV_SV]
    lea rsi, [rel k_identity]
    mov edx, k_identity_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_INT
    jne .bad
    mov rcx, [rax + json_value.ival]
    mov rdx, [rbp+PV_IDOUT]
    mov [rdx], rcx

    mov rdi, [rbp+PV_SV]
    lea rsi, [rel k_ts]
    mov edx, k_ts_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad
    mov rcx, [rax + json_value.ptr]
    mov rdx, [rbp+PV_TSPOUT]
    mov [rdx], rcx
    mov rcx, [rax + json_value.len]
    mov rdx, [rbp+PV_TSLOUT]
    mov [rdx], rcx

    mov eax, 1
    jmp .done
.bad:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef PV_QSOUT
%undef PV_IDOUT
%undef PV_TSPOUT
%undef PV_TSLOUT
%undef PV_SV

; int handle_transition(convex_live *live, json_value *msg)
%define HT_LIVE  -8
%define HT_MSG   -16
%define HT_SQS   -24
%define HT_SID   -32
%define HT_STSP  -40
%define HT_STSL  -48
%define HT_EQS   -56
%define HT_EID   -64
%define HT_ETSP  -72
%define HT_ETSL  -80
%define HT_MODS  -88
%define HT_I     -96
%define HT_MOD   -104
%define HT_TYPE  -112
%define HT_QID   -120
%define HT_SUB   -128
%define HT_CLONE -136
%define HT_LOGS  -144
%define HT_ERRMSG -152
%define HT_ERRMSGLEN -160
%define HT_ERRDATA -168
handle_transition:
    push rbp
    mov rbp, rsp
    sub rsp, 176
    mov [rbp+HT_LIVE], rdi
    mov [rbp+HT_MSG], rsi

    mov rdi, rsi
    lea rsi, [rel k_start_version]
    mov edx, k_start_version_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad
    mov rdi, rax
    lea rsi, [rbp+HT_SQS]
    lea rdx, [rbp+HT_SID]
    lea rcx, [rbp+HT_STSP]
    lea r8, [rbp+HT_STSL]
    call parse_sv
    test eax, eax
    jz .bad

    mov rdi, [rbp+HT_MSG]
    lea rsi, [rel k_end_version]
    mov edx, k_end_version_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad
    mov rdi, rax
    lea rsi, [rbp+HT_EQS]
    lea rdx, [rbp+HT_EID]
    lea rcx, [rbp+HT_ETSP]
    lea r8, [rbp+HT_ETSL]
    call parse_sv
    test eax, eax
    jz .bad

    mov rdi, [rbp+HT_MSG]
    lea rsi, [rel k_modifications]
    mov edx, k_modifications_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_ARRAY
    jne .bad
    mov [rbp+HT_MODS], rax

    mov rax, [rbp+HT_LIVE]
    mov rcx, [rax + convex_live.remote_query_set]
    cmp rcx, [rbp+HT_SQS]
    jne .bad
    mov rcx, [rax + convex_live.remote_identity]
    cmp rcx, [rbp+HT_SID]
    jne .bad
    mov rdi, [rbp+HT_STSP]
    mov rsi, [rbp+HT_STSL]
    mov rdx, [rax + convex_live.remote_ts_ptr]
    mov rcx, [rax + convex_live.remote_ts_len]
    call bytes_eq
    test eax, eax
    jz .bad

    mov qword [rbp+HT_I], 0
.mod_loop:
    mov rax, [rbp+HT_I]
    mov rcx, [rbp+HT_MODS]
    cmp rax, [rcx + json_value.len]
    jae .mods_done
    mov rcx, [rbp+HT_MODS]
    mov rdx, [rcx + json_value.ptr]
    mov rax, [rdx + rax*8]
    mov [rbp+HT_MOD], rax
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad

    mov rdi, rax
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad
    mov [rbp+HT_TYPE], rax

    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_query_id]
    mov edx, k_query_id_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_INT
    jne .bad
    mov rcx, [rax + json_value.ival]
    mov [rbp+HT_QID], rcx

    mov rax, [rbp+HT_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_query_removed]
    mov ecx, v_query_removed_len
    call bytes_eq
    test eax, eax
    jnz .mod_next

    mov rax, [rbp+HT_LIVE]
    mov rdi, rax
    mov rsi, [rbp+HT_QID]
    call find_sub_by_query_id
    mov [rbp+HT_SUB], rax

    mov rax, [rbp+HT_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_query_updated]
    mov ecx, v_query_updated_len
    call bytes_eq
    test eax, eax
    jz .try_failed

    ; QueryUpdated
    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_value]
    mov edx, k_value_len
    call json_object_get
    test rax, rax
    jz .bad
    mov [rbp+HT_CLONE], rax
    cmp qword [rbp+HT_SUB], 0
    jz .mod_next

    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_log_lines]
    mov edx, k_log_lines_len
    call json_object_get
    mov [rbp+HT_LOGS], rax

    mov rdi, [rbp+HT_CLONE]
    call json_clone
    mov [rbp+HT_CLONE], rax
    mov rdi, [rbp+HT_LOGS]
    call json_clone
    mov [rbp+HT_LOGS], rax

    mov rdi, [rbp+HT_SUB]
    mov rsi, [rbp+HT_CLONE]
    mov rdx, [rbp+HT_LOGS]
    xor ecx, ecx
    xor r8, r8
    xor r9, r9
    sub rsp, 32
    mov qword [rsp], 0
    mov qword [rsp+8], 0
    mov qword [rsp+16], 0
    call deliver_update
    add rsp, 32
    jmp .mod_next

.try_failed:
    mov rax, [rbp+HT_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_query_failed]
    mov ecx, v_query_failed_len
    call bytes_eq
    test eax, eax
    jz .bad

    cmp qword [rbp+HT_SUB], 0
    jz .mod_next

    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_error_message]
    mov edx, k_error_message_len
    call json_object_get
    test rax, rax
    jz .use_default_msg
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .use_default_msg
    mov rcx, [rax + json_value.len]
    mov [rbp+HT_ERRMSGLEN], rcx
    mov rdi, [rax + json_value.ptr]
    mov rsi, rcx
    call dup_bytes
    test rax, rax
    jz .bad
    mov [rbp+HT_ERRMSG], rax
    jmp .have_msg
.use_default_msg:
    lea rdi, [rel err_msg_live_default]
    mov esi, err_msg_live_default_len
    call dup_bytes
    test rax, rax
    jz .bad
    mov [rbp+HT_ERRMSG], rax
    mov qword [rbp+HT_ERRMSGLEN], err_msg_live_default_len
.have_msg:
    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_error_data]
    mov edx, k_error_data_len
    call json_object_get
    mov rdi, rax
    call json_clone
    mov [rbp+HT_ERRDATA], rax

    mov rdi, [rbp+HT_MOD]
    lea rsi, [rel k_log_lines]
    mov edx, k_log_lines_len
    call json_object_get
    mov rdi, rax
    call json_clone
    mov [rbp+HT_LOGS], rax

    mov rdi, [rbp+HT_SUB]
    xor esi, esi
    mov rdx, [rbp+HT_LOGS]
    mov ecx, 1
    lea r8, [rel err_name_function]
    mov r9, err_name_function_len
    sub rsp, 32
    mov rax, [rbp+HT_ERRMSG]
    mov [rsp], rax
    mov rax, [rbp+HT_ERRMSGLEN]
    mov [rsp+8], rax
    mov rax, [rbp+HT_ERRDATA]
    mov [rsp+16], rax
    call deliver_update
    add rsp, 32

.mod_next:
    mov rax, [rbp+HT_I]
    inc rax
    mov [rbp+HT_I], rax
    jmp .mod_loop
.mods_done:
    mov rax, [rbp+HT_LIVE]
    mov rcx, [rbp+HT_EQS]
    mov [rax + convex_live.remote_query_set], rcx
    mov rcx, [rbp+HT_EID]
    mov [rax + convex_live.remote_identity], rcx

    mov rcx, [rax + convex_live.remote_ts_ptr]
    test rcx, rcx
    jz .no_free_remote_ts
    mov rdi, rcx
    call free
.no_free_remote_ts:
    mov rdi, [rbp+HT_ETSP]
    mov rsi, [rbp+HT_ETSL]
    call dup_bytes
    mov rcx, [rbp+HT_LIVE]
    mov [rcx + convex_live.remote_ts_ptr], rax
    mov rsi, [rbp+HT_ETSL]
    mov [rcx + convex_live.remote_ts_len], rsi

    mov rcx, [rcx + convex_live.max_observed_ts_ptr]
    test rcx, rcx
    jz .no_free_max_ts
    mov rdi, rcx
    call free
.no_free_max_ts:
    mov rdi, [rbp+HT_ETSP]
    mov rsi, [rbp+HT_ETSL]
    call dup_bytes
    mov rcx, [rbp+HT_LIVE]
    mov [rcx + convex_live.max_observed_ts_ptr], rax
    mov rsi, [rbp+HT_ETSL]
    mov [rcx + convex_live.max_observed_ts_len], rsi

    mov qword [rcx + convex_live.backoff_ms], LIVE_BACKOFF_BASE_MS

    mov eax, 1
    jmp .done
.bad:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef HT_LIVE
%undef HT_MSG
%undef HT_SQS
%undef HT_SID
%undef HT_STSP
%undef HT_STSL
%undef HT_EQS
%undef HT_EID
%undef HT_ETSP
%undef HT_ETSL
%undef HT_MODS
%undef HT_I
%undef HT_MOD
%undef HT_TYPE
%undef HT_QID
%undef HT_SUB
%undef HT_CLONE
%undef HT_LOGS
%undef HT_ERRMSG
%undef HT_ERRMSGLEN
%undef HT_ERRDATA

; int handle_message(convex_live *live, json_value *msg) -- dispatches by
; "type". Ping/MutationResponse/ActionResponse are tolerated no-ops (this
; build never sends a Mutation/Action over the WebSocket -- see the
; README's limitations -- so the latter two are never actually expected,
; but accepting them costs nothing and matches the reference protocol
; client's tolerance). Anything else is protocol drift.
%define HM_LIVE -8
%define HM_MSG  -16
%define HM_TYPE -24
handle_message:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+HM_LIVE], rdi
    mov [rbp+HM_MSG], rsi

    mov rdi, rsi
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad
    mov [rbp+HM_TYPE], rax

    mov rax, [rbp+HM_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_transition]
    mov ecx, v_transition_len
    call bytes_eq
    test eax, eax
    jz .try_ping
    mov rdi, [rbp+HM_LIVE]
    mov rsi, [rbp+HM_MSG]
    call handle_transition
    jmp .done
.try_ping:
    mov rax, [rbp+HM_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_ping]
    mov ecx, v_ping_len
    call bytes_eq
    test eax, eax
    jnz .noop
    mov rax, [rbp+HM_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_mutation_response]
    mov ecx, v_mutation_response_len
    call bytes_eq
    test eax, eax
    jnz .noop
    mov rax, [rbp+HM_TYPE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel v_action_response]
    mov ecx, v_action_response_len
    call bytes_eq
    test eax, eax
    jnz .noop
.bad:
    xor eax, eax
    jmp .done
.noop:
    mov eax, 1
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef HM_LIVE
%undef HM_MSG
%undef HM_TYPE

; void convex_live_service_socket(convex_live *live) -- called once per
; event-loop tick when the WebSocket fd was reported readable (or has
; buffered TLS application data already decrypted; see main.s). Reads
; whatever is available exactly once, then drains every complete message
; ws_pump_message can already assemble from that -- never more than one
; `read` per call, so this can never itself block waiting on the network.
%define SS_LIVE -8
%define SS_KIND  -16
%define SS_DATA  -24
%define SS_LEN   -32
%define SS_MSG   -40
%define SS_HMRESULT -48
convex_live_service_socket:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp+SS_LIVE], rdi

    mov rax, [rdi + convex_live.connected]
    test rax, rax
    jz .done

    lea rdi, [rdi + convex_live.ws]
    call ws_recv_more
    cmp eax, 1
    je .pump
    mov rdi, [rbp+SS_LIVE]
    lea rsi, [rel reason_transport_error]
    mov edx, reason_transport_error_len
    xor ecx, ecx
    call teardown_and_schedule
    jmp .done
.pump:
    mov rax, [rbp+SS_LIVE]
    lea rdi, [rax + convex_live.ws]
    lea rsi, [rbp+SS_KIND]
    lea rdx, [rbp+SS_DATA]
    lea rcx, [rbp+SS_LEN]
    call ws_pump_message
    cmp eax, 0
    je .done
    cmp eax, -1
    je .protocol_error
    cmp eax, 2
    je .peer_closed

    mov rax, [rbp+SS_KIND]
    cmp rax, WS_OP_TEXT
    jne .free_and_protocol_error

    mov rdi, [rbp+SS_DATA]
    mov rsi, [rbp+SS_LEN]
    lea rdx, [rbp+SS_MSG]
    call json_parse
    mov rcx, [rbp+SS_DATA]
    test rcx, rcx
    jz .no_free_data
    mov rdi, rcx
    call free
.no_free_data:
    test eax, eax
    jz .protocol_error

    mov rdi, [rbp+SS_LIVE]
    mov rsi, [rbp+SS_MSG]
    call handle_message
    mov [rbp+SS_HMRESULT], rax
    mov rdi, [rbp+SS_MSG]
    call json_free
    mov rax, [rbp+SS_HMRESULT]
    test eax, eax
    jz .protocol_error
    jmp .pump

.free_and_protocol_error:
    mov rax, [rbp+SS_DATA]
    test rax, rax
    jz .protocol_error
    mov rdi, rax
    call free
.protocol_error:
    mov rdi, [rbp+SS_LIVE]
    lea rsi, [rel reason_protocol_error]
    mov edx, reason_protocol_error_len
    xor ecx, ecx
    call teardown_and_schedule
    jmp .done
.peer_closed:
    mov rdi, [rbp+SS_LIVE]
    lea rsi, [rel reason_server_closed]
    mov edx, reason_server_closed_len
    xor ecx, ecx
    call teardown_and_schedule
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef SS_LIVE
%undef SS_KIND
%undef SS_DATA
%undef SS_LEN
%undef SS_MSG
%undef SS_HMRESULT

; --- public lifecycle API ------------------------------------------------

; int convex_live_init(convex_live *live, convex_client *client)
%define LI_LIVE -8
%define LI_CLIENT -16
convex_live_init:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+LI_LIVE], rdi
    mov [rbp+LI_CLIENT], rsi
    mov rdx, convex_live_size
    xor esi, esi
    call memset

    mov rax, [rbp+LI_LIVE]
    mov rcx, [rbp+LI_CLIENT]
    mov [rax + convex_live.client], rcx
    lea rdi, [rax + convex_live.session_id]
    call gen_session_id

    mov rax, [rbp+LI_LIVE]
    lea rcx, [rel reason_initial_connect]
    mov [rax + convex_live.last_close_reason_ptr], rcx
    mov qword [rax + convex_live.last_close_reason_len], reason_initial_connect_len

    lea rdi, [rel initial_ts]
    mov esi, initial_ts_len
    call dup_bytes
    test rax, rax
    jz .oom
    mov rcx, [rbp+LI_LIVE]
    mov [rcx + convex_live.remote_ts_ptr], rax
    mov qword [rcx + convex_live.remote_ts_len], initial_ts_len
    mov qword [rcx + convex_live.backoff_ms], LIVE_BACKOFF_BASE_MS
    mov qword [rcx + convex_live.next_attempt_ms], 0
    mov eax, 1
    jmp .done
.oom:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef LI_LIVE
%undef LI_CLIENT

; void convex_live_close(convex_live *live) -- tears down the socket and
; every subscription's owned state. Bounded the same way ws_close is
; (never waits on the peer's close_notify) so the adapter's "close" and
; the example's cleanup can never hang on a stalled or hostile server.
%define LC_LIVE -8
%define LC_SUB  -16
%define LC_NEXT -24
convex_live_close:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+LC_LIVE], rdi

    lea rdi, [rdi + convex_live.ws]
    call ws_close

    mov rax, [rbp+LC_LIVE]
    mov rax, [rax + convex_live.subs]
    mov [rbp+LC_SUB], rax
.loop:
    mov rax, [rbp+LC_SUB]
    test rax, rax
    jz .subs_done
    mov rcx, [rax + convex_sub.next]
    mov [rbp+LC_NEXT], rcx

    mov rdi, [rax + convex_sub.path_ptr]
    test rdi, rdi
    jz .no_path
    call free
.no_path:
    mov rax, [rbp+LC_SUB]
    mov rdi, [rax + convex_sub.args]
    call json_free
    mov rax, [rbp+LC_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_free
.drain_queue:
    mov rax, [rbp+LC_SUB]
    mov rcx, [rax + convex_sub.queue_count]
    test rcx, rcx
    jz .queue_drained
    mov rcx, [rax + convex_sub.queue_head]
    lea rdi, [rax + convex_sub.queue]
    imul rcx, rcx, convex_update_size
    add rdi, rcx
    call free_update_contents
    mov rax, [rbp+LC_SUB]
    mov rcx, [rax + convex_sub.queue_head]
    inc rcx
    and rcx, (LIVE_QUEUE_DEPTH - 1)
    mov [rax + convex_sub.queue_head], rcx
    dec qword [rax + convex_sub.queue_count]
    jmp .drain_queue
.queue_drained:
    mov rdi, [rbp+LC_SUB]
    call free
    mov rax, [rbp+LC_NEXT]
    mov [rbp+LC_SUB], rax
    jmp .loop
.subs_done:
    mov rax, [rbp+LC_LIVE]
    mov qword [rax + convex_live.subs], 0

    mov rcx, [rax + convex_live.remote_ts_ptr]
    test rcx, rcx
    jz .no_remote_ts
    mov rdi, rcx
    call free
.no_remote_ts:
    mov rax, [rbp+LC_LIVE]
    mov rcx, [rax + convex_live.max_observed_ts_ptr]
    test rcx, rcx
    jz .no_max_ts
    mov rdi, rcx
    call free
.no_max_ts:
    mov rsp, rbp
    pop rbp
    ret
%undef LC_LIVE
%undef LC_SUB
%undef LC_NEXT

; convex_sub *convex_live_subscribe(convex_live *live, const char *path,
;                                    u64 path_len, json_value *args)
; Takes ownership of `args`, matching convex_call's own ownership contract
; elsewhere in this client.
%define LS_LIVE -8
%define LS_PATH -16
%define LS_PATHLEN -24
%define LS_ARGS -32
%define LS_SUB -40
convex_live_subscribe:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp+LS_LIVE], rdi
    mov [rbp+LS_PATH], rsi
    mov [rbp+LS_PATHLEN], rdx
    mov [rbp+LS_ARGS], rcx

    mov edi, 1
    call dbg_mark

    mov edi, convex_sub_size
    call malloc
    test rax, rax
    jz .oom_bare
    mov [rbp+LS_SUB], rax
    mov rdi, rax
    xor esi, esi
    mov edx, convex_sub_size
    call memset

    mov rdi, [rbp+LS_PATHLEN]
    lea rdi, [rdi + 1]
    call malloc
    test rax, rax
    jz .oom_free_sub
    mov rcx, [rbp+LS_SUB]
    mov [rcx + convex_sub.path_ptr], rax
    mov rdi, rax
    mov rsi, [rbp+LS_PATH]
    mov rdx, [rbp+LS_PATHLEN]
    call memcpy
    mov rax, [rbp+LS_SUB]
    mov rcx, [rax + convex_sub.path_ptr]
    mov rdx, [rbp+LS_PATHLEN]
    mov byte [rcx + rdx], 0
    mov [rax + convex_sub.path_len], rdx

    mov rcx, [rbp+LS_ARGS]
    mov [rax + convex_sub.args], rcx
    mov rcx, [rbp+LS_LIVE]
    mov rdx, [rcx + convex_live.next_query_id]
    mov [rax + convex_sub.query_id], rdx
    inc rdx
    mov [rcx + convex_live.next_query_id], rdx
    mov qword [rax + convex_sub.state], CONVEX_SUB_PENDING_ADD
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_init

    mov rax, [rbp+LS_SUB]
    mov rcx, [rbp+LS_LIVE]
    mov rdx, [rcx + convex_live.subs]
    mov [rax + convex_sub.next], rdx
    mov [rcx + convex_live.subs], rax

    mov rax, [rbp+LS_SUB]
    jmp .done
.oom_free_sub:
    mov rdi, [rbp+LS_SUB]
    call free
.oom_bare:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef LS_LIVE
%undef LS_PATH
%undef LS_PATHLEN
%undef LS_ARGS
%undef LS_SUB

; void convex_live_unsubscribe(convex_sub *sub) -- unlinks and frees the
; subscription's state before returning, so any Transition that names its
; queryId after this point simply finds no match (see handle_transition's
; find_sub_by_query_id) rather than needing a separate tombstone state.
; Best-effort sends a Remove first when connected; a failure there is
; indistinguishable from a connection that is about to be noticed as dead
; on the next read, so it is not treated specially here.
%define LU_SUB -8
%define LU_LIVE -16
%define LU_PREV -24
convex_live_unsubscribe:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+LU_SUB], rdi
    mov rax, [rdi + convex_sub.manager]
    mov [rbp+LU_LIVE], rax

    mov rcx, [rax + convex_live.connected]
    test rcx, rcx
    jz .no_send
    mov rdi, rax
    mov rsi, [rbp+LU_SUB]
    call send_remove
.no_send:
    mov rax, [rbp+LU_LIVE]
    mov rcx, [rax + convex_live.subs]
    cmp rcx, [rbp+LU_SUB]
    jne .search
    mov rcx, [rbp+LU_SUB]
    mov rcx, [rcx + convex_sub.next]
    mov [rax + convex_live.subs], rcx
    jmp .unlinked
.search:
    mov [rbp+LU_PREV], rcx
.search_loop:
    mov rax, [rbp+LU_PREV]
    mov rcx, [rax + convex_sub.next]
    cmp rcx, [rbp+LU_SUB]
    je .found_prev
    mov [rbp+LU_PREV], rcx
    jmp .search_loop
.found_prev:
    mov rax, [rbp+LU_PREV]
    mov rcx, [rbp+LU_SUB]
    mov rcx, [rcx + convex_sub.next]
    mov [rax + convex_sub.next], rcx
.unlinked:
    mov rax, [rbp+LU_SUB]
    mov rdi, [rax + convex_sub.path_ptr]
    test rdi, rdi
    jz .no_path
    call free
.no_path:
    mov rax, [rbp+LU_SUB]
    mov rdi, [rax + convex_sub.args]
    call json_free
    mov rax, [rbp+LU_SUB]
    lea rdi, [rax + convex_sub.last_value_text]
    call buf_free
.drain:
    mov rax, [rbp+LU_SUB]
    mov rcx, [rax + convex_sub.queue_count]
    test rcx, rcx
    jz .drained
    mov rcx, [rax + convex_sub.queue_head]
    lea rdi, [rax + convex_sub.queue]
    imul rcx, rcx, convex_update_size
    add rdi, rcx
    call free_update_contents
    mov rax, [rbp+LU_SUB]
    mov rcx, [rax + convex_sub.queue_head]
    inc rcx
    and rcx, (LIVE_QUEUE_DEPTH - 1)
    mov [rax + convex_sub.queue_head], rcx
    dec qword [rax + convex_sub.queue_count]
    jmp .drain
.drained:
    mov rdi, [rbp+LU_SUB]
    call free
    mov rsp, rbp
    pop rbp
    ret
%undef LU_SUB
%undef LU_LIVE
%undef LU_PREV

; int convex_live_debug_disconnect(convex_live *live) -- adapter-only
; fault injection (see manifest.yaml's adapter.adapterOnlyCommands). Only
; acknowledges once the old connection is fully retired and a fresh
; connection attempt is scheduled for the very next convex_live_maintain
; tick -- teardown_and_schedule's `immediate` flag is exactly that.
convex_live_debug_disconnect:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rax, [rdi + convex_live.connected]
    test rax, rax
    jz .not_connected
    mov rdi, [rbp-8]
    lea rsi, [rel reason_debug_disconnect]
    mov edx, reason_debug_disconnect_len
    mov ecx, 1
    call teardown_and_schedule
    mov eax, 1
    jmp .done
.not_connected:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; i64 convex_live_poll_fd(convex_live *live) -- the socket fd to include in
; a poll() set, or -1 when there is no live connection to watch. Leaf: it
; makes no calls, so it needs no frame.
convex_live_poll_fd:
    mov rax, [rdi + convex_live.connected]
    test rax, rax
    jz .not_connected
    mov eax, [rdi + convex_live.ws + ws_conn.conn + convex_conn.fd]
    cdqe
    ret
.not_connected:
    mov rax, -1
    ret

; int convex_live_next(convex_sub *sub, convex_update *out, i64 timeout_ms)
; The canonical example's blocking wait primitive, mirroring the C
; reference client's convex_subscription_next: pumps connect/reconnect and
; socket I/O internally, using a bounded poll() (capped at 200ms per
; iteration even when more time remains) so it keeps reassessing reconnect
; backoff instead of sleeping through it. 1 = *out filled (caller now owns
; its value/logs/err_msg_ptr/err_data), 0 = timed out with nothing ready.
%define LN_SUB -8
%define LN_OUT -16
%define LN_TIMEOUT -24
%define LN_DEADLINE -32
%define LN_LIVE -40
%define LN_WAIT -48
%define LN_PFD -56          ; pollfd, 8 bytes: rbp-56..rbp-49
convex_live_next:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp+LN_SUB], rdi
    mov [rbp+LN_OUT], rsi
    mov [rbp+LN_TIMEOUT], rdx
    mov rax, [rdi + convex_sub.manager]
    mov [rbp+LN_LIVE], rax

    call monotonic_ms
    add rax, [rbp+LN_TIMEOUT]
    mov [rbp+LN_DEADLINE], rax
.loop:
    mov rdi, [rbp+LN_SUB]
    mov rsi, [rbp+LN_OUT]
    call convex_live_dequeue
    test eax, eax
    jnz .got

    mov rdi, [rbp+LN_LIVE]
    call convex_live_maintain

    call monotonic_ms
    cmp rax, [rbp+LN_DEADLINE]
    jge .timed_out
    mov rcx, [rbp+LN_DEADLINE]
    sub rcx, rax
    cmp rcx, 200
    jbe .wait_ok
    mov rcx, 200
.wait_ok:
    mov [rbp+LN_WAIT], rcx

    mov rdi, [rbp+LN_LIVE]
    call convex_live_poll_fd
    cmp rax, 0
    jl .no_fd

    mov dword [rbp+LN_PFD + pollfd.fd], eax
    mov word [rbp+LN_PFD + pollfd.events], POLLIN
    mov word [rbp+LN_PFD + pollfd.revents], 0
    lea rdi, [rbp+LN_PFD]
    mov esi, 1
    mov edx, [rbp+LN_WAIT]
    call poll
    cmp eax, 0
    jle .loop
    movzx eax, word [rbp+LN_PFD + pollfd.revents]
    test eax, POLLIN
    jz .loop
    mov rdi, [rbp+LN_LIVE]
    call convex_live_service_socket
    jmp .loop
.no_fd:
    xor edi, edi
    xor esi, esi
    mov edx, [rbp+LN_WAIT]
    call poll
    jmp .loop
.got:
    mov eax, 1
    jmp .done
.timed_out:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef LN_SUB
%undef LN_OUT
%undef LN_TIMEOUT
%undef LN_DEADLINE
%undef LN_LIVE
%undef LN_WAIT
%undef LN_PFD

section .rodata
    dbg_nl_live: db 10
    initial_ts: db "AAAAAAAAAAA="
    initial_ts_len equ $ - initial_ts

    reason_initial_connect: db "InitialConnect"
    reason_initial_connect_len equ $ - reason_initial_connect
    reason_transport_error: db "TransportError"
    reason_transport_error_len equ $ - reason_transport_error
    reason_protocol_error: db "ProtocolError"
    reason_protocol_error_len equ $ - reason_protocol_error
    reason_server_closed: db "server closed the WebSocket"
    reason_server_closed_len equ $ - reason_server_closed
    reason_debug_disconnect: db "DebugDisconnect"
    reason_debug_disconnect_len equ $ - reason_debug_disconnect

    err_name_function: db "FunctionError"
    err_name_function_len equ $ - err_name_function
    err_msg_live_default: db "Convex Live query failed"
    err_msg_live_default_len equ $ - err_msg_live_default

    k_type: db "type"
    k_type_len equ $ - k_type
    k_session_id: db "sessionId"
    k_session_id_len equ $ - k_session_id
    k_connection_count: db "connectionCount"
    k_connection_count_len equ $ - k_connection_count
    k_last_close_reason: db "lastCloseReason"
    k_last_close_reason_len equ $ - k_last_close_reason
    k_max_observed_ts: db "maxObservedTimestamp"
    k_max_observed_ts_len equ $ - k_max_observed_ts
    k_client_ts: db "clientTs"
    k_client_ts_len equ $ - k_client_ts
    k_base_version: db "baseVersion"
    k_base_version_len equ $ - k_base_version
    k_new_version: db "newVersion"
    k_new_version_len equ $ - k_new_version
    k_modifications: db "modifications"
    k_modifications_len equ $ - k_modifications
    k_query_id: db "queryId"
    k_query_id_len equ $ - k_query_id
    k_udf_path: db "udfPath"
    k_udf_path_len equ $ - k_udf_path
    k_args: db "args"
    k_args_len equ $ - k_args
    k_start_version: db "startVersion"
    k_start_version_len equ $ - k_start_version
    k_end_version: db "endVersion"
    k_end_version_len equ $ - k_end_version
    k_query_set: db "querySet"
    k_query_set_len equ $ - k_query_set
    k_identity: db "identity"
    k_identity_len equ $ - k_identity
    k_ts: db "ts"
    k_ts_len equ $ - k_ts
    k_value: db "value"
    k_value_len equ $ - k_value
    k_log_lines: db "logLines"
    k_log_lines_len equ $ - k_log_lines
    k_error_message: db "errorMessage"
    k_error_message_len equ $ - k_error_message
    k_error_data: db "errorData"
    k_error_data_len equ $ - k_error_data

    v_connect: db "Connect"
    v_connect_len equ $ - v_connect
    v_modify_query_set: db "ModifyQuerySet"
    v_modify_query_set_len equ $ - v_modify_query_set
    v_add: db "Add"
    v_add_len equ $ - v_add
    v_remove: db "Remove"
    v_remove_len equ $ - v_remove
    v_transition: db "Transition"
    v_transition_len equ $ - v_transition
    v_ping: db "Ping"
    v_ping_len equ $ - v_ping
    v_mutation_response: db "MutationResponse"
    v_mutation_response_len equ $ - v_mutation_response
    v_action_response: db "ActionResponse"
    v_action_response_len equ $ - v_action_response
    v_query_removed: db "QueryRemoved"
    v_query_removed_len equ $ - v_query_removed
    v_query_updated: db "QueryUpdated"
    v_query_updated_len equ $ - v_query_updated
    v_query_failed: db "QueryFailed"
    v_query_failed_len equ $ - v_query_failed
