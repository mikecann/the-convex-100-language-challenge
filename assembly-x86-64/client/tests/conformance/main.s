; ---------------------------------------------------------------------------
; main.s -- the NDJSON adapter protocol v1 conformance executable.
;
; This is test infrastructure, not public client code (see AGENTS.md's
; "Conformance executable" section): it implements the shared adapter
; protocol over stdin/stdout, or over one TCP connection when
; ADAPTER_LISTEN is set, and calls the real client (convex_new/convex_call/
; convex_set_auth/convex_live_*) for every operation.
;
; serve()'s main loop is poll()-driven rather than a blocking line read:
; once any subscription exists it must service the command channel and the
; Live WebSocket without either one starving the other, and it must never
; block indefinitely on a peer that stops sending. adapter_try_line is the
; non-blocking-safe line reader that makes this possible -- it performs at
; most one `read` per call (only ever invoked after poll() said progress
; was possible), unlike adapter_next_line's retry loop below it.
;
; Live delivery itself has no adapter-level queue: convex_live.s already
; owns a bounded per-subscription queue (see convex.inc's
; LIVE_QUEUE_DEPTH), and drain_subscriptions below just empties it into
; NDJSON events once per event-loop tick. Nothing here buffers a second
; time on top of that.
;
; Same fixed-frame stack discipline as the rest of this client.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

extern buf_init
extern buf_free
extern buf_reserve
extern buf_append
extern buf_append_byte
extern buf_append_cstr
extern json_new_object
extern json_new_string
extern json_new_int
extern json_object_set
extern json_object_get
extern json_free
extern json_parse
extern json_serialize
extern find_bytes
extern find_and_null_entry
extern convex_new
extern convex_free
extern convex_set_auth
extern convex_call
extern convex_live_init
extern convex_live_close
extern convex_live_subscribe
extern convex_live_unsubscribe
extern convex_live_debug_disconnect
extern convex_live_maintain
extern convex_live_service_socket
extern convex_live_dequeue
extern convex_live_poll_fd
extern dbg_str    ; DEBUG ONLY

; adapter_sub: the adapter's own map from the NDJSON protocol's
; subscriptionId string to the convex_sub* convex_live_subscribe returned.
; convex_live.s deliberately knows nothing about this string -- see
; convex.inc's convex_sub comment -- so this bookkeeping lives here.
struc adapter_sub
    .subid_ptr: resq 1
    .subid_len: resq 1
    .sub:       resq 1
    .next:      resq 1
endstruc

section .bss
    g_client:   resq 1
    g_in_fd:    resd 1
    g_out_fd:   resd 1
    g_read_buf: resb buf_size
    g_pending_consume: resq 1
    g_runtime_text: resb 64
    g_runtime_len: resq 1
    g_live:     resb convex_live_size
    g_live_ready: resb 1
    g_adapter_subs: resq 1

section .text

global main

; --- raw line reader over a plain fd (never TLS -- this is always a local
; loopback connection to the shared harness or the test's own stdio) ------

; int raw_read_more(int fd, buf *b) -- 1 progress, 0 EOF, -1 error.
raw_read_more:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], edi
    mov [rbp-16], rsi
    mov rdi, rsi
    mov esi, 4096
    call buf_reserve
    test eax, eax
    jz .fail
    mov rcx, [rbp-16]
    mov rax, [rcx + buf.data]
    add rax, [rcx + buf.len]
    mov edi, [rbp-8]
    mov rsi, rax
    mov edx, 4096
    call read
    cmp rax, 0
    jl .fail
    jz .eof
    mov rcx, [rbp-16]
    add [rcx + buf.len], rax
    mov eax, 1
    jmp .done
.eof:
    xor eax, eax
    jmp .done
.fail:
    mov eax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; int adapter_next_line(int fd, char **out_ptr, u64 *out_len)
; 1 = a line is available (CRLF- or LF-terminated, or the final unterminated
; tail at EOF), 0 = clean EOF with nothing left, -1 = read error. The
; returned pointer aliases g_read_buf and is only valid until the next call.
;
; g_pending_consume defers compacting the previous line out of the buffer
; until the START of the call that follows, rather than doing it before
; returning. An earlier draft compacted immediately after locating a line
; -- which starts with a memmove(dest=buf.data, ...) -- while *out_ptr had
; already been set to that very same buf.data address a few instructions
; earlier: the memmove overwrote the line's bytes with the *next* line's
; bytes before the caller ever read them. The line still looked like valid
; adapter input often enough (or coincidentally still invalid JSON) that
; only the second of three lines in a batch visibly broke, which is what
; actually surfaced this in testing.
adapter_next_line:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], edi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rax, [g_pending_consume]
    test rax, rax
    jz .scan
    lea rcx, [g_read_buf]
    mov rdx, [rcx + buf.len]
    cmp rax, rdx
    jae .pending_consume_all
    mov r9, rax
    mov r10, rdx
    sub r10, r9
    mov rdi, [rcx + buf.data]
    mov rsi, rdi
    add rsi, r9
    mov rdx, r10
    call memmove
    lea rcx, [g_read_buf]
    mov rdx, [g_pending_consume]
    mov rax, [rcx + buf.len]
    sub rax, rdx
    mov [rcx + buf.len], rax
    jmp .pending_done
.pending_consume_all:
    lea rcx, [g_read_buf]
    mov qword [rcx + buf.len], 0
.pending_done:
    mov qword [g_pending_consume], 0
.scan:
    lea rax, [g_read_buf]
    mov rdi, [rax + buf.data]
    mov rsi, [rax + buf.len]
    lea rdx, [rel nl_byte]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    jne .have_line
    mov edi, [rbp-8]
    lea rsi, [g_read_buf]
    call raw_read_more
    cmp eax, 1
    je .scan
    cmp eax, 0
    je .try_final_line
    mov eax, -1
    jmp .done
.try_final_line:
    lea rax, [g_read_buf]
    mov rcx, [rax + buf.len]
    test rcx, rcx
    jz .no_more
    mov rax, rcx
.have_line:
    mov [rbp-32], rax           ; nl_index (or buf.len for the synthetic tail)
    lea rcx, [g_read_buf]
    mov rdx, [rcx + buf.data]
    mov r8, [rbp-32]
    test r8, r8
    jz .no_cr
    mov r9, rdx
    add r9, r8
    dec r9
    cmp byte [r9], 13
    jne .no_cr
    dec r8
.no_cr:
    mov [rbp-40], r8
    mov rcx, [rbp-16]
    mov [rcx], rdx
    mov rax, [rbp-40]
    mov rcx, [rbp-24]
    mov [rcx], rax
    ; record how much to drop from the front on the *next* call; the
    ; buffer itself is untouched here, so the pointer just returned stays
    ; valid until this function is entered again.
    lea rcx, [g_read_buf]
    mov rax, [rbp-32]
    mov rdx, [rcx + buf.len]
    cmp rax, rdx
    jae .mark_consume_all
    lea r9, [rax + 1]
    mov [g_pending_consume], r9
    jmp .have_line_done
.mark_consume_all:
    mov [g_pending_consume], rdx
.have_line_done:
    mov eax, 1
    jmp .done
.no_more:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; int adapter_try_line(int fd, char **out_ptr, u64 *out_len)
; Same line-framing contract as adapter_next_line (a line already buffered
; is returned with no I/O at all), but never loops on raw_read_more: it
; performs at most one read attempt, then reports "not ready yet" (0)
; rather than trying again. Only serve()'s poll()-driven loop calls this,
; and only after poll() (or a nonempty leftover buffer) said the fd could
; make progress, so one attempt is always enough to either produce a line,
; observe EOF, or legitimately have nothing more to give right now.
; Returns 1 = line ready, 0 = not ready (no error), -1 = read error,
; 2 = clean EOF with nothing left.
adapter_try_line:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], edi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rax, [g_pending_consume]
    test rax, rax
    jz .scan
    lea rcx, [g_read_buf]
    mov rdx, [rcx + buf.len]
    cmp rax, rdx
    jae .pending_consume_all
    mov r9, rax
    mov r10, rdx
    sub r10, r9
    mov rdi, [rcx + buf.data]
    mov rsi, rdi
    add rsi, r9
    mov rdx, r10
    call memmove
    lea rcx, [g_read_buf]
    mov rdx, [g_pending_consume]
    mov rax, [rcx + buf.len]
    sub rax, rdx
    mov [rcx + buf.len], rax
    jmp .pending_done
.pending_consume_all:
    lea rcx, [g_read_buf]
    mov qword [rcx + buf.len], 0
.pending_done:
    mov qword [g_pending_consume], 0
.scan:
    lea rax, [g_read_buf]
    mov rdi, [rax + buf.data]
    mov rsi, [rax + buf.len]
    lea rdx, [rel nl_byte]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    jne .have_line
    mov edi, [rbp-8]
    lea rsi, [g_read_buf]
    call raw_read_more
    cmp eax, 1
    je .rescan
    cmp eax, 0
    je .try_final
    mov eax, -1
    jmp .done
.rescan:
    lea rax, [g_read_buf]
    mov rdi, [rax + buf.data]
    mov rsi, [rax + buf.len]
    lea rdx, [rel nl_byte]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    jne .have_line
    xor eax, eax
    jmp .done
.try_final:
    lea rax, [g_read_buf]
    mov rcx, [rax + buf.len]
    test rcx, rcx
    jz .eof
    mov rax, rcx
    jmp .have_line
.eof:
    mov eax, 2
    jmp .done
.have_line:
    mov [rbp-32], rax           ; nl_index (or buf.len for the synthetic tail)
    lea rcx, [g_read_buf]
    mov rdx, [rcx + buf.data]
    mov r8, [rbp-32]
    test r8, r8
    jz .no_cr
    mov r9, rdx
    add r9, r8
    dec r9
    cmp byte [r9], 13
    jne .no_cr
    dec r8
.no_cr:
    mov [rbp-40], r8
    mov rcx, [rbp-16]
    mov [rcx], rdx
    mov rax, [rbp-40]
    mov rcx, [rbp-24]
    mov [rcx], rax
    lea rcx, [g_read_buf]
    mov rax, [rbp-32]
    mov rdx, [rcx + buf.len]
    cmp rax, rdx
    jae .mark_consume_all
    lea r9, [rax + 1]
    mov [g_pending_consume], r9
    jmp .have_line_done
.mark_consume_all:
    mov [g_pending_consume], rdx
.have_line_done:
    mov eax, 1
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- event emission --------------------------------------------------------

; void emit_event(json_value *event) -- serializes, writes one NDJSON line
; to g_out_fd, and frees the tree.
; A struct-offset mistake lived here: the local `buf` (24 bytes: .data at
; +0, .len at +8, .cap at +16) was based at rbp-24, which puts .cap at
; rbp-24+16 = rbp-8 -- exactly the slot the event pointer was saved in.
; buf_init zeroing .cap silently zeroed the event pointer too. The buf is
; now based far enough below rbp-8 that its 24 bytes cannot reach it.
emit_event:
    push rbp
    mov rbp, rsp
    sub rsp, 64       ; event ptr at rbp-8; local buf at rbp-56 (.data=-56,
                       ; .len=-48, .cap=-40 -- ends at rbp-32, clear of rbp-8)
    mov [rbp-8], rdi
    lea rdi, [rbp-56]
    call buf_init
    mov rdi, [rbp-8]
    lea rsi, [rbp-56]
    call json_serialize
    lea rdi, [rbp-56]
    mov esi, 10
    call buf_append_byte
    mov edi, [g_out_fd]
    mov rax, [rbp-56]           ; buf.data
    mov rsi, rax
    mov rdx, [rbp-48]           ; buf.len
    call write
    lea rdi, [rbp-56]
    call buf_free
    mov rdi, [rbp-8]
    call json_free
    mov rsp, rbp
    pop rbp
    ret


; void emit_simple(const char *id, u64 id_len, const char *type, u64 type_len)
emit_simple:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    call json_new_object
    mov [rbp-40], rax           ; event
    mov rax, [rbp-16]
    test rax, rax
    jz .no_id
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-40]
    lea rsi, [rel k_id]
    mov edx, k_id_len
    call json_object_set
.no_id:
    mov rdi, [rbp-24]
    mov rsi, [rbp-32]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-40]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    mov rdi, [rbp-40]
    call emit_event
    mov rsp, rbp
    pop rbp
    ret

; void emit_error(const char *id, u64 id_len, const char *name, u64 name_len,
;                  const char *msg, u64 msg_len, json_value *data)
;                  [data arrives on the stack: the 7th argument]
emit_error:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov [rbp-40], r8
    mov [rbp-48], r9
    mov rax, [rbp + 16]
    mov [rbp-56], rax           ; data
    call json_new_object
    mov [rbp-64], rax           ; event
    lea rdi, [rel v_error]
    mov esi, v_error_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-64]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    mov rax, [rbp-16]
    test rax, rax
    jz .no_id
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-64]
    lea rsi, [rel k_id]
    mov edx, k_id_len
    call json_object_set
.no_id:
    call json_new_object
    mov [rbp-72], rax           ; error object
    mov rdi, [rbp-24]
    mov rsi, [rbp-32]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-72]
    lea rsi, [rel k_name]
    mov edx, k_name_len
    call json_object_set
    mov rdi, [rbp-40]
    mov rsi, [rbp-48]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-72]
    lea rsi, [rel k_message]
    mov edx, k_message_len
    call json_object_set
    mov rax, [rbp-56]
    test rax, rax
    jz .no_data
    mov rdi, [rbp-72]
    lea rsi, [rel k_data]
    mov edx, k_data_len
    mov rcx, rax
    call json_object_set
.no_data:
    mov rdi, [rbp-64]
    lea rsi, [rel k_error]
    mov edx, k_error_len
    mov rcx, [rbp-72]
    call json_object_set
    mov rdi, [rbp-64]
    call emit_event
    mov rsp, rbp
    pop rbp
    ret

; void emit_subscription_value(const char *subid, u64 subid_len,
;                               json_value *value, json_value *logs)
; Takes ownership of value/logs -- emit_event frees the whole event tree
; they become part of once serialized and written.
emit_subscription_value:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    call json_new_object
    mov [rbp-40], rax
    lea rdi, [rel v_subscription]
    mov esi, v_subscription_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-40]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-40]
    lea rsi, [rel k_subscription_id]
    mov edx, k_subscription_id_len
    call json_object_set
    mov rdi, [rbp-40]
    lea rsi, [rel k_value]
    mov edx, k_value_len
    mov rcx, [rbp-24]
    call json_object_set
    mov rax, [rbp-32]
    test rax, rax
    jz .no_logs
    mov rdi, [rbp-40]
    lea rsi, [rel k_log_lines]
    mov edx, k_log_lines_len
    mov rcx, rax
    call json_object_set
.no_logs:
    mov rdi, [rbp-40]
    call emit_event
    mov rsp, rbp
    pop rbp
    ret

; void emit_subscription_error(const char *subid, u64 subid_len,
;                               const char *ename, u64 enlen,
;                               const char *emsg, u64 emlen,
;                               json_value *edata)
; [edata arrives on the stack: the 7th argument, at [rbp+16]]
; Reads (does not take ownership of) ename/emsg -- both are copied into a
; fresh JSON string. edata IS taken, freed as part of the event tree.
emit_subscription_error:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov [rbp-40], r8
    mov [rbp-48], r9
    mov rax, [rbp + 16]
    mov [rbp-56], rax
    call json_new_object
    mov [rbp-64], rax
    lea rdi, [rel v_subscription]
    mov esi, v_subscription_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-64]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-64]
    lea rsi, [rel k_subscription_id]
    mov edx, k_subscription_id_len
    call json_object_set
    call json_new_object
    mov [rbp-72], rax
    mov rdi, [rbp-24]
    mov rsi, [rbp-32]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-72]
    lea rsi, [rel k_name]
    mov edx, k_name_len
    call json_object_set
    mov rdi, [rbp-40]
    mov rsi, [rbp-48]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-72]
    lea rsi, [rel k_message]
    mov edx, k_message_len
    call json_object_set
    mov rax, [rbp-56]
    test rax, rax
    jz .no_data
    mov rdi, [rbp-72]
    lea rsi, [rel k_data]
    mov edx, k_data_len
    mov rcx, rax
    call json_object_set
.no_data:
    mov rdi, [rbp-64]
    lea rsi, [rel k_error]
    mov edx, k_error_len
    mov rcx, [rbp-72]
    call json_object_set
    mov rdi, [rbp-64]
    call emit_event
    mov rsp, rbp
    pop rbp
    ret

; --- Convex client lifecycle -----------------------------------------------

; void set_error_full_local(convex_error *err, const char *name, u64 name_len,
;                            const char *msg, u64 msg_len, json_value *data)
; Leaf; no calls, so no frame needed.
set_error_full_local:
    test rdi, rdi
    jz .done
    mov [rdi + convex_error.name_ptr], rsi
    mov [rdi + convex_error.name_len], rdx
    mov [rdi + convex_error.msg_ptr], rcx
    mov [rdi + convex_error.msg_len], r8
    mov [rdi + convex_error.data], r9
.done:
    ret

; convex_client *ensure_client(convex_error *err) -- creates the client on
; first use from CONVEX_URL/CONVEX_AUTH_TOKEN, matching the reference C
; adapter's ensure_client exactly.
ensure_client:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi            ; err
    mov rax, [g_client]
    test rax, rax
    jnz .have_client
    lea rdi, [rel env_convex_url]
    call getenv
    test rax, rax
    jz .missing_url
    mov [rbp-16], rax           ; url ptr
    mov rdi, rax
    call strlen
    test rax, rax
    jz .missing_url
    mov [rbp-24], rax           ; url len
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    xor edx, edx
    xor ecx, ecx
    mov r8, [rbp-8]
    call convex_new
    test rax, rax
    jz .new_failed
    mov [g_client], rax
    lea rdi, [rel env_auth_token]
    call getenv
    test rax, rax
    jz .have_client
    mov [rbp-16], rax           ; token ptr
    mov rdi, rax
    call strlen
    mov [rbp-24], rax           ; token len
    mov rdi, [g_client]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, [rbp-8]
    call convex_set_auth
.have_client:
    mov rax, [g_client]
    jmp .done
.missing_url:
    mov rdi, [rbp-8]
    lea rsi, [rel err_name_protocol_ref]
    mov edx, err_name_protocol_ref_len
    lea rcx, [rel err_msg_missing_url]
    mov r8, err_msg_missing_url_len
    xor r9, r9
    call set_error_full_local
    xor eax, eax
    jmp .done
.new_failed:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; convex_live *ensure_live(convex_error *err) -- lazily creates the client
; (via ensure_client) and, on first use, initializes the one Live state
; machine this process owns.
%define EL_ERR -8
ensure_live:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+EL_ERR], rdi
    movzx eax, byte [g_live_ready]
    test eax, eax
    jnz .have_live
    mov rdi, [rbp+EL_ERR]
    call ensure_client
    test rax, rax
    jz .fail
    mov rsi, rax          ; client (2nd arg)
    lea rdi, [g_live]     ; live (1st arg)
    call convex_live_init
    test eax, eax
    jz .oom
    mov byte [g_live_ready], 1
.have_live:
    lea rax, [g_live]
    jmp .done
.oom:
    mov rdi, [rbp+EL_ERR]
    call set_error_oom_local
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef EL_ERR

; void set_error_oom_local(convex_error *err) -- mirrors convex_client.s's
; own private set_error_oom (not exported), for the one failure path in
; this file that needs it (ensure_live's convex_live_init OOM case).
set_error_oom_local:
    test rdi, rdi
    jz .done
    lea rax, [rel err_name_protocol_ref]
    mov [rdi + convex_error.name_ptr], rax
    mov qword [rdi + convex_error.name_len], err_name_protocol_ref_len
    lea rax, [rel err_msg_oom_local]
    mov [rdi + convex_error.msg_ptr], rax
    mov qword [rdi + convex_error.msg_len], err_msg_oom_local_len
    mov qword [rdi + convex_error.data], 0
.done:
    ret

; adapter_sub *find_adapter_sub(const char *subid, u64 subid_len)
find_adapter_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov rax, [g_adapter_subs]
.loop:
    test rax, rax
    jz .notfound
    mov rcx, [rax + adapter_sub.subid_len]
    cmp rcx, [rbp-16]
    jne .next
    mov [rbp-24], rax
    mov rdi, [rax + adapter_sub.subid_ptr]
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call memcmp
    test eax, eax
    jnz .next
    mov rax, [rbp-24]
    jmp .done
.next:
    mov rax, [rax + adapter_sub.next]
    jmp .loop
.notfound:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; adapter_sub *add_adapter_sub(const char *subid, u64 subid_len,
;                               convex_sub *sub) -- copies subid (the
; wrapper must outlive the NDJSON command tree it was parsed from).
add_adapter_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov edi, adapter_sub_size
    call malloc
    test rax, rax
    jz .oom_bare
    mov [rbp-32], rax
    mov rax, [rbp-16]
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .oom_free_node
    mov rcx, [rbp-32]
    mov [rcx + adapter_sub.subid_ptr], rax
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call memcpy
    mov rcx, [rbp-32]
    mov rax, [rcx + adapter_sub.subid_ptr]
    mov rdx, [rbp-16]
    mov byte [rax + rdx], 0
    mov [rcx + adapter_sub.subid_len], rdx
    mov rax, [rbp-24]
    mov [rcx + adapter_sub.sub], rax
    mov rax, [g_adapter_subs]
    mov [rcx + adapter_sub.next], rax
    mov [g_adapter_subs], rcx
    mov rax, rcx
    jmp .done
.oom_free_node:
    mov rdi, [rbp-32]
    call free
.oom_bare:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; void remove_adapter_sub(const char *subid, u64 subid_len) -- unlinks and
; frees the wrapper node only; the caller is responsible for the
; convex_sub* itself (via convex_live_unsubscribe).
%define RAS_SUBID -8
%define RAS_LEN   -16
%define RAS_PREV  -24
%define RAS_MATCH -32
remove_adapter_sub:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp+RAS_SUBID], rdi
    mov [rbp+RAS_LEN], rsi
    mov rax, [g_adapter_subs]
    test rax, rax
    jz .done
    mov rcx, [rax + adapter_sub.subid_len]
    cmp rcx, [rbp+RAS_LEN]
    jne .search
    mov rdi, [rax + adapter_sub.subid_ptr]
    mov rsi, [rbp+RAS_SUBID]
    mov rdx, [rbp+RAS_LEN]
    call memcmp
    test eax, eax
    jnz .search
    mov rax, [g_adapter_subs]
    mov [rbp+RAS_MATCH], rax
    mov rcx, [rax + adapter_sub.next]
    mov [g_adapter_subs], rcx
    mov rdi, [rax + adapter_sub.subid_ptr]
    call free
    mov rdi, [rbp+RAS_MATCH]
    call free
    jmp .done
.search:
    mov rax, [g_adapter_subs]
    mov [rbp+RAS_PREV], rax
.search_loop:
    mov rax, [rbp+RAS_PREV]
    mov rcx, [rax + adapter_sub.next]
    test rcx, rcx
    jz .done
    mov rdx, [rcx + adapter_sub.subid_len]
    cmp rdx, [rbp+RAS_LEN]
    jne .search_next
    mov rdi, [rcx + adapter_sub.subid_ptr]
    mov rsi, [rbp+RAS_SUBID]
    mov rdx, [rbp+RAS_LEN]
    call memcmp
    test eax, eax
    jnz .search_next
    mov [rbp+RAS_MATCH], rcx
    mov rax, [rbp+RAS_PREV]
    mov rdx, [rcx + adapter_sub.next]
    mov [rax + adapter_sub.next], rdx
    mov rdi, [rcx + adapter_sub.subid_ptr]
    call free
    mov rdi, [rbp+RAS_MATCH]
    call free
    jmp .done
.search_next:
    mov [rbp+RAS_PREV], rcx
    jmp .search_loop
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef RAS_SUBID
%undef RAS_LEN
%undef RAS_PREV
%undef RAS_MATCH

; void drain_subscriptions(void) -- empties every subscription's bounded
; queue into NDJSON "subscription" events. Called once per event-loop
; tick; never itself grows a buffer, so it can never be the thing that
; makes memory unbounded under a slow reader (see the file header).
%define DS_CUR -8
%define DS_UPDATE -72        ; convex_update, 64 bytes: rbp-72..rbp-9
drain_subscriptions:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov rax, [g_adapter_subs]
    mov [rbp+DS_CUR], rax
.outer:
    mov rax, [rbp+DS_CUR]
    test rax, rax
    jz .done
.drain_one:
    mov rax, [rbp+DS_CUR]
    mov rdi, [rax + adapter_sub.sub]
    lea rsi, [rbp+DS_UPDATE]
    call convex_live_dequeue
    test eax, eax
    jz .next_sub

    mov rax, [rbp+DS_UPDATE + convex_update.has_error]
    test rax, rax
    jnz .emit_error_update

    mov rax, [rbp+DS_CUR]
    mov rdi, [rax + adapter_sub.subid_ptr]
    mov rsi, [rax + adapter_sub.subid_len]
    mov rdx, [rbp+DS_UPDATE + convex_update.value]
    mov rcx, [rbp+DS_UPDATE + convex_update.logs]
    call emit_subscription_value
    jmp .drain_one
.emit_error_update:
    mov rax, [rbp+DS_CUR]
    mov rdi, [rax + adapter_sub.subid_ptr]
    mov rsi, [rax + adapter_sub.subid_len]
    mov rdx, [rbp+DS_UPDATE + convex_update.err_name_ptr]
    mov rcx, [rbp+DS_UPDATE + convex_update.err_name_len]
    mov r8, [rbp+DS_UPDATE + convex_update.err_msg_ptr]
    mov r9, [rbp+DS_UPDATE + convex_update.err_msg_len]
    sub rsp, 16
    mov rax, [rbp+DS_UPDATE + convex_update.err_data]
    mov [rsp], rax
    call emit_subscription_error
    add rsp, 16
    mov rdi, [rbp+DS_UPDATE + convex_update.err_msg_ptr]
    call free
    jmp .drain_one
.next_sub:
    mov rax, [rbp+DS_CUR]
    mov rax, [rax + adapter_sub.next]
    mov [rbp+DS_CUR], rax
    jmp .outer
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef DS_CUR
%undef DS_UPDATE

; const char *gnu_get_libc_version(void), cached into g_runtime_text.
build_runtime_string:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov rax, [g_runtime_len]
    test rax, rax
    jnz .done
    call gnu_get_libc_version
    mov [rbp-8], rax
    lea rdi, [g_runtime_text]
    lea rsi, [rel glibc_prefix]
    mov edx, glibc_prefix_len
    call memcpy
    mov rdi, [rbp-8]
    call strlen
    mov r8, rax
    cmp r8, 32
    jbe .len_ok
    mov r8, 32
.len_ok:
    lea rdi, [g_runtime_text + glibc_prefix_len]
    mov rsi, [rbp-8]
    mov rdx, r8
    call memcpy
    mov rax, glibc_prefix_len
    add rax, r8
    mov [g_runtime_len], rax
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- command handlers -------------------------------------------------

; void handle_hello(const char *id, u64 id_len, json_value *cmd)
handle_hello:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rdi, rdx
    lea rsi, [rel k_protocol_version]
    mov edx, k_protocol_version_len
    call json_object_get
    test rax, rax
    jz .bad_version
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_INT
    jne .bad_version
    mov rcx, [rax + json_value.ival]
    cmp rcx, 1
    jne .bad_version
    call json_new_object
    mov [rbp-32], rax
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_id]
    mov edx, k_id_len
    call json_object_set
    mov edi, 1
    call json_new_int
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_protocol_version]
    mov edx, k_protocol_version_len
    call json_object_set
    lea rdi, [rel v_ready]
    mov esi, v_ready_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    lea rdi, [rel v_language]
    mov esi, v_language_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_language]
    mov edx, k_language_len
    call json_object_set
    lea rdi, [rel v_implementation]
    mov esi, v_implementation_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_implementation]
    mov edx, k_implementation_len
    call json_object_set
    call build_runtime_string
    lea rdi, [g_runtime_text]
    mov rsi, [g_runtime_len]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-32]
    lea rsi, [rel k_runtime]
    mov edx, k_runtime_len
    call json_object_set
    mov rdi, [rbp-32]
    call emit_event
    jmp .done
.bad_version:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_bad_version]
    mov r9, err_msg_bad_version_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
.done:
    mov rsp, rbp
    pop rbp
    ret

; void handle_call(const char *id, u64 id_len, int op, json_value *cmd)
; Frees `cmd` on every path (it owns it once dispatched here).
handle_call:
    push rbp
    mov rbp, rsp
    sub rsp, 160
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    lea rdi, [rbp-72]           ; err (40 bytes: rbp-72..rbp-33)
    call ensure_client
    test rax, rax
    jz .from_ensure_fail
    mov [rbp-128], rax          ; client
    mov rdi, [rbp-32]
    lea rsi, [rel k_path]
    mov edx, k_path_len
    call json_object_get
    mov [rbp-112], rax          ; path node
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad_args
    mov rdi, [rbp-32]
    lea rsi, [rel k_args]
    mov edx, k_args_len
    call json_object_get
    mov [rbp-120], rax          ; args node
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad_args
    mov rdi, [rbp-32]
    lea rsi, [rel k_args]
    mov edx, k_args_len
    call find_and_null_entry
    mov rdi, [rbp-128]
    mov esi, [rbp-24]
    mov rax, [rbp-112]
    mov rdx, [rax + json_value.ptr]
    mov rcx, [rax + json_value.len]
    mov r8, [rbp-120]
    lea r9, [rbp-104]           ; result (16 bytes: rbp-104..rbp-89)
    sub rsp, 16
    lea rax, [rbp-72]
    mov [rsp], rax
    call convex_call
    add rsp, 16
    test eax, eax
    jz .transport_failed
    call json_new_object
    mov [rbp-136], rax          ; response event
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-136]
    lea rsi, [rel k_id]
    mov edx, k_id_len
    call json_object_set
    lea rdi, [rel v_result]
    mov esi, v_result_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-136]
    lea rsi, [rel k_type]
    mov edx, k_type_len
    call json_object_set
    mov rdi, [rbp-136]
    lea rsi, [rel k_value]
    mov edx, k_value_len
    mov rcx, [rbp-104]
    call json_object_set
    mov rax, [rbp-96]
    test rax, rax
    jz .no_logs
    mov rdi, [rbp-136]
    lea rsi, [rel k_log_lines]
    mov edx, k_log_lines_len
    mov rcx, rax
    call json_object_set
.no_logs:
    mov rdi, [rbp-136]
    call emit_event
    jmp .free_cmd
.transport_failed:
.from_ensure_fail:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-72 + convex_error.name_ptr]
    mov rcx, [rbp-72 + convex_error.name_len]
    mov r8, [rbp-72 + convex_error.msg_ptr]
    mov r9, [rbp-72 + convex_error.msg_len]
    sub rsp, 16
    mov rax, [rbp-72 + convex_error.data]
    mov [rsp], rax
    call emit_error
    add rsp, 16
    jmp .free_cmd
.bad_args:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_bad_call_args]
    mov r9, err_msg_bad_call_args_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
.free_cmd:
    mov rdi, [rbp-32]
    call json_free
    mov rsp, rbp
    pop rbp
    ret

; void handle_set_auth(const char *id, u64 id_len, json_value *cmd)
handle_set_auth:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    lea rdi, [rbp-64]            ; err (40 bytes: rbp-64..rbp-25)
    call ensure_client
    test rax, rax
    jz .fail
    mov [rbp-72], rax            ; client
    mov rdi, [rbp-24]
    lea rsi, [rel k_token]
    mov edx, k_token_len
    call json_object_get
    mov [rbp-80], rax
    xor r8, r8
    xor r9, r9
    mov rax, [rbp-80]
    test rax, rax
    jz .no_token
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad_token
    mov r8, [rax + json_value.ptr]
    mov r9, [rax + json_value.len]
.no_token:
    mov rdi, [rbp-72]
    mov rsi, r8
    mov rdx, r9
    lea rcx, [rbp-64]
    call convex_set_auth
    test eax, eax
    jz .fail
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel v_ack]
    mov ecx, v_ack_len
    call emit_simple
    jmp .done
.bad_token:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_bad_token]
    mov r9, err_msg_bad_token_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    jmp .done
.fail:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-64 + convex_error.name_ptr]
    mov rcx, [rbp-64 + convex_error.name_len]
    mov r8, [rbp-64 + convex_error.msg_ptr]
    mov r9, [rbp-64 + convex_error.msg_len]
    sub rsp, 16
    mov rax, [rbp-64 + convex_error.data]
    mov [rsp], rax
    call emit_error
    add rsp, 16
.done:
    mov rdi, [rbp-24]
    call json_free
    mov rsp, rbp
    pop rbp
    ret

; void handle_subscribe(const char *id, u64 id_len, json_value *cmd)
; Frees `cmd` on every path. A subscribe for a subscriptionId that is
; already active replaces it: the old subscription is fully unsubscribed
; (invalidating its relay) before the new one's ack is published, per
; AGENTS.md's same-ID-replacement rule.
%define HS_ID        -8
%define HS_IDLEN     -16
%define HS_CMD       -24
%define HS_SUBIDNODE -32
%define HS_PATHNODE  -40
%define HS_ARGSNODE  -48
%define HS_LIVE      -56
%define HS_SUB       -64
%define HS_EXISTING  -72
%define HS_ERR       -112    ; convex_error, 40 bytes: rbp-112..rbp-73
handle_subscribe:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp+HS_ID], rdi
    mov [rbp+HS_IDLEN], rsi
    mov [rbp+HS_CMD], rdx

    mov rdi, rdx
    lea rsi, [rel k_subscription_id]
    mov edx, k_subscription_id_len
    call json_object_get
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad_args
    mov [rbp+HS_SUBIDNODE], rax

    mov rdi, [rbp+HS_CMD]
    lea rsi, [rel k_path]
    mov edx, k_path_len
    call json_object_get
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad_args
    mov [rbp+HS_PATHNODE], rax

    mov rdi, [rbp+HS_CMD]
    lea rsi, [rel k_args]
    mov edx, k_args_len
    call json_object_get
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad_args
    mov [rbp+HS_ARGSNODE], rax

    lea rdi, [rbp+HS_ERR]
    call ensure_live
    test rax, rax
    jz .from_ensure_fail
    mov [rbp+HS_LIVE], rax

    mov rax, [rbp+HS_SUBIDNODE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    call find_adapter_sub
    test rax, rax
    jz .no_existing
    mov rcx, [rax + adapter_sub.sub]
    mov [rbp+HS_EXISTING], rcx
    mov rdi, [rbp+HS_EXISTING]
    call convex_live_unsubscribe
    mov rax, [rbp+HS_SUBIDNODE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    call remove_adapter_sub
.no_existing:
    ; detach args from cmd before freeing cmd below -- convex_live_
    ; subscribe takes ownership of it.
    mov rdi, [rbp+HS_CMD]
    lea rsi, [rel k_args]
    mov edx, k_args_len
    call find_and_null_entry

    mov rdi, [rbp+HS_LIVE]
    mov rax, [rbp+HS_PATHNODE]
    mov rsi, [rax + json_value.ptr]
    mov rdx, [rax + json_value.len]
    mov rcx, [rbp+HS_ARGSNODE]
    call convex_live_subscribe
    test rax, rax
    jz .oom_after_detach
    mov [rbp+HS_SUB], rax

    mov rax, [rbp+HS_SUBIDNODE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    mov rdx, [rbp+HS_SUB]
    call add_adapter_sub
    test rax, rax
    jz .oom_wrapper

    mov rdi, [rbp+HS_ID]
    mov rsi, [rbp+HS_IDLEN]
    lea rdx, [rel v_ack]
    mov ecx, v_ack_len
    call emit_simple
    jmp .free_cmd

.oom_wrapper:
    mov rdi, [rbp+HS_SUB]
    call convex_live_unsubscribe
    mov rdi, [rbp+HS_ID]
    mov rsi, [rbp+HS_IDLEN]
    lea rdx, [rel err_name_error]
    mov ecx, err_name_error_len
    lea r8, [rel err_msg_oom_local]
    mov r9, err_msg_oom_local_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    jmp .free_cmd
.oom_after_detach:
    mov rdi, [rbp+HS_ARGSNODE]
    call json_free
    mov rdi, [rbp+HS_ID]
    mov rsi, [rbp+HS_IDLEN]
    lea rdx, [rel err_name_error]
    mov ecx, err_name_error_len
    lea r8, [rel err_msg_oom_local]
    mov r9, err_msg_oom_local_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    jmp .free_cmd
.from_ensure_fail:
    mov rdi, [rbp+HS_ID]
    mov rsi, [rbp+HS_IDLEN]
    mov rdx, [rbp+HS_ERR + convex_error.name_ptr]
    mov rcx, [rbp+HS_ERR + convex_error.name_len]
    mov r8, [rbp+HS_ERR + convex_error.msg_ptr]
    mov r9, [rbp+HS_ERR + convex_error.msg_len]
    sub rsp, 16
    mov rax, [rbp+HS_ERR + convex_error.data]
    mov [rsp], rax
    call emit_error
    add rsp, 16
    jmp .free_cmd
.bad_args:
    mov rdi, [rbp+HS_ID]
    mov rsi, [rbp+HS_IDLEN]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_bad_subscribe_args]
    mov r9, err_msg_bad_subscribe_args_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
.free_cmd:
    mov rdi, [rbp+HS_CMD]
    call json_free
    mov rsp, rbp
    pop rbp
    ret
%undef HS_ID
%undef HS_IDLEN
%undef HS_CMD
%undef HS_SUBIDNODE
%undef HS_PATHNODE
%undef HS_ARGSNODE
%undef HS_LIVE
%undef HS_SUB
%undef HS_EXISTING
%undef HS_ERR

; void handle_unsubscribe(const char *id, u64 id_len, json_value *cmd)
; Frees `cmd` on every path. Silently acks an unknown subscriptionId
; (matching the reference JS adapter's own leniency there) rather than
; treating it as a protocol error.
%define HU_ID    -8
%define HU_IDLEN -16
%define HU_CMD   -24
%define HU_NODE  -32
handle_unsubscribe:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp+HU_ID], rdi
    mov [rbp+HU_IDLEN], rsi
    mov [rbp+HU_CMD], rdx

    mov rdi, rdx
    lea rsi, [rel k_subscription_id]
    mov edx, k_subscription_id_len
    call json_object_get
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .bad_args
    mov [rbp+HU_NODE], rax

    mov rax, [rbp+HU_NODE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    call find_adapter_sub
    test rax, rax
    jz .ack
    mov rcx, [rax + adapter_sub.sub]
    mov rdi, rcx
    call convex_live_unsubscribe
    mov rax, [rbp+HU_NODE]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    call remove_adapter_sub
.ack:
    mov rdi, [rbp+HU_ID]
    mov rsi, [rbp+HU_IDLEN]
    lea rdx, [rel v_ack]
    mov ecx, v_ack_len
    call emit_simple
    jmp .free_cmd
.bad_args:
    mov rdi, [rbp+HU_ID]
    mov rsi, [rbp+HU_IDLEN]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_bad_unsubscribe_args]
    mov r9, err_msg_bad_unsubscribe_args_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
.free_cmd:
    mov rdi, [rbp+HU_CMD]
    call json_free
    mov rsp, rbp
    pop rbp
    ret
%undef HU_ID
%undef HU_IDLEN
%undef HU_CMD
%undef HU_NODE

; void handle_debug_disconnect(const char *id, u64 id_len) -- adapter-only
; fault injection; see manifest.yaml's adapter.adapterOnlyCommands.
handle_debug_disconnect:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .not_connected
    lea rdi, [g_live]
    call convex_live_debug_disconnect
    test eax, eax
    jz .not_connected
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel v_ack]
    mov ecx, v_ack_len
    call emit_simple
    jmp .done
.not_connected:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel err_name_transport]
    mov ecx, err_name_transport_len
    lea r8, [rel err_msg_not_connected]
    mov r9, err_msg_not_connected_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
.done:
    mov rsp, rbp
    pop rbp
    ret

; void handle_close(const char *id, u64 id_len)
handle_close:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .no_live
    lea rdi, [g_live]
    call convex_live_close
    mov byte [g_live_ready], 0
.no_live:
    mov rax, [g_client]
    test rax, rax
    jz .no_client
    mov rdi, rax
    call convex_free
    mov qword [g_client], 0
.no_client:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel v_closed]
    mov ecx, v_closed_len
    call emit_simple
    mov byte [g_should_close], 1
    mov rsp, rbp
    pop rbp
    ret

; int str_is(const char *s, u64 s_len, const char *lit, u64 lit_len)
str_is:
    push rbp
    mov rbp, rsp
    sub rsp, 16
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

; void dispatch(json_value *cmd)
dispatch:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi            ; cmd
    lea rsi, [rel k_id]
    mov edx, k_id_len
    call json_object_get
    xor r8, r8
    xor r9, r9
    test rax, rax
    jz .no_cmd_id
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .no_cmd_id
    mov r8, [rax + json_value.ptr]
    mov r9, [rax + json_value.len]
.no_cmd_id:
    mov [rbp-16], r8            ; id ptr
    mov [rbp-24], r9            ; id len
    mov rdi, [rbp-8]
    lea rsi, [rel k_op]
    mov edx, k_op_len
    call json_object_get
    test rax, rax
    jz .unknown_op
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .unknown_op
    mov [rbp-32], rax           ; op node

    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_hello]
    mov ecx, op_hello_len
    call str_is
    test eax, eax
    jz .try_query
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rdx, [rbp-8]
    call handle_hello
    mov rdi, [rbp-8]
    call json_free
    jmp .done
.try_query:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_query]
    mov ecx, op_query_len
    call str_is
    test eax, eax
    jz .try_mutation
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov edx, CONVEX_OP_QUERY
    mov rcx, [rbp-8]
    call handle_call
    jmp .done
.try_mutation:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_mutation]
    mov ecx, op_mutation_len
    call str_is
    test eax, eax
    jz .try_action
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov edx, CONVEX_OP_MUTATION
    mov rcx, [rbp-8]
    call handle_call
    jmp .done
.try_action:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_action]
    mov ecx, op_action_len
    call str_is
    test eax, eax
    jz .try_set_auth
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov edx, CONVEX_OP_ACTION
    mov rcx, [rbp-8]
    call handle_call
    jmp .done
.try_set_auth:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_set_auth]
    mov ecx, op_set_auth_len
    call str_is
    test eax, eax
    jz .try_close
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rdx, [rbp-8]
    call handle_set_auth
    jmp .done
.try_close:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_close]
    mov ecx, op_close_len
    call str_is
    test eax, eax
    jz .try_subscribe
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    call handle_close
    mov rdi, [rbp-8]
    call json_free
    jmp .done
.try_subscribe:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_subscribe]
    mov ecx, op_subscribe_len
    call str_is
    test eax, eax
    jz .try_unsubscribe
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rdx, [rbp-8]
    call handle_subscribe
    jmp .done
.try_unsubscribe:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_unsubscribe]
    mov ecx, op_unsubscribe_len
    call str_is
    test eax, eax
    jz .try_debug_disconnect
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rdx, [rbp-8]
    call handle_unsubscribe
    jmp .done
.try_debug_disconnect:
    mov rax, [rbp-32]
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel op_debug_disconnect]
    mov ecx, op_debug_disconnect_len
    call str_is
    test eax, eax
    jz .unknown_op_free
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    call handle_debug_disconnect
    mov rdi, [rbp-8]
    call json_free
    jmp .done
.unknown_op_free:
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_unknown_op]
    mov r9, err_msg_unknown_op_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    mov rdi, [rbp-8]
    call json_free
    jmp .done
.unknown_op:
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_unknown_op]
    mov r9, err_msg_unknown_op_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    mov rdi, [rbp-8]
    call json_free
.done:
    mov rsp, rbp
    pop rbp
    ret

; void serve(int in_fd, int out_fd)
; serve()'s loop is the one place in this file that owns the WebSocket:
; convex_live_maintain, convex_live_service_socket and drain_subscriptions
; are only ever called from here, on this one thread, satisfying AGENTS.md's
; "one worker owns WebSocket reads, writes, reconnects and query-set
; version changes" requirement by construction rather than with a lock.
%define SV_PFDS    -32       ; pollfd[2], 16 bytes: rbp-32..rbp-17
%define SV_NFDS    -40
%define SV_LINEPTR -48
%define SV_LINELEN -56
%define SV_CMDVAL  -64
serve:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [g_in_fd], edi
    mov [g_out_fd], esi
    lea rdi, [g_read_buf]
    call buf_init
.loop:
    mov al, [g_should_close]
    test al, al
    jnz .stop

    movzx edi, byte [g_live_ready]
    add dil, '0'
    mov [dbg_live_ready_byte], dil
    mov edi, 'l'
    lea rsi, [rel dbg_live_ready_byte]
    mov edx, 1
    call dbg_str

    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .no_maintain
    lea rdi, [g_live]
    call convex_live_maintain
.no_maintain:
    mov eax, [g_in_fd]
    mov [rbp+SV_PFDS + pollfd.fd], eax
    mov word [rbp+SV_PFDS + pollfd.events], POLLIN
    mov word [rbp+SV_PFDS + pollfd.revents], 0
    mov dword [rbp+SV_NFDS], 1

    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .have_pfds
    lea rdi, [g_live]
    call convex_live_poll_fd
    cmp rax, 0
    jl .have_pfds
    mov [rbp+SV_PFDS + 8 + pollfd.fd], eax
    mov word [rbp+SV_PFDS + 8 + pollfd.events], POLLIN
    mov word [rbp+SV_PFDS + 8 + pollfd.revents], 0
    mov dword [rbp+SV_NFDS], 2
.have_pfds:
    ; a bounded 100ms tick: short enough to keep reconnect backoff and
    ; queue draining timely, long enough not to spin the CPU.
    lea rdi, [rbp+SV_PFDS]
    mov esi, [rbp+SV_NFDS]
    mov edx, 100
    call poll

    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .no_service
    cmp dword [rbp+SV_NFDS], 2
    jl .no_service
    movzx eax, word [rbp+SV_PFDS + 8 + pollfd.revents]
    test eax, POLLIN
    jz .no_service
    lea rdi, [g_live]
    call convex_live_service_socket
.no_service:
    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .no_drain
    call drain_subscriptions
.no_drain:
    movzx eax, word [rbp+SV_PFDS + pollfd.revents]
    test eax, POLLIN
    jz .loop
.cmd_loop:
    mov edi, [g_in_fd]
    lea rsi, [rbp+SV_LINEPTR]
    lea rdx, [rbp+SV_LINELEN]
    call adapter_try_line
    cmp eax, 1
    jne .cmd_loop_done
    mov rdi, [rbp+SV_LINEPTR]
    mov rsi, [rbp+SV_LINELEN]
    test rsi, rsi
    jnz .have_content
    jmp .cmd_loop                ; a blank line is not a command; skip it
.have_content:
    lea rdx, [rbp+SV_CMDVAL]
    call json_parse
    test eax, eax
    jz .malformed
    mov rdi, [rbp+SV_CMDVAL]
    call dispatch
    jmp .cmd_loop
.malformed:
    lea rdi, [empty_str]
    xor esi, esi
    lea rdx, [rel err_name_protocol_ref]
    mov ecx, err_name_protocol_ref_len
    lea r8, [rel err_msg_malformed]
    mov r9, err_msg_malformed_len
    sub rsp, 16
    mov qword [rsp], 0
    call emit_error
    add rsp, 16
    jmp .cmd_loop
.cmd_loop_done:
    ; 0 = nothing more buffered right now; go back to poll(). -1 (error)
    ; or 2 (EOF) both mean the command channel is gone.
    test eax, eax
    jz .loop
    mov byte [g_should_close], 1
    jmp .loop
.stop:
    movzx eax, byte [g_live_ready]
    test eax, eax
    jz .no_live_stop
    lea rdi, [g_live]
    call convex_live_close
    mov byte [g_live_ready], 0
.no_live_stop:
    lea rdi, [g_read_buf]
    call buf_free
    mov rsp, rbp
    pop rbp
    ret
%undef SV_PFDS
%undef SV_NFDS
%undef SV_LINEPTR
%undef SV_LINELEN
%undef SV_CMDVAL

; --- entry point --------------------------------------------------------

; Parses "ADAPTER_LISTEN=host:port" (IPv4 dotted-quad host only, matching
; the reference C adapter's own documented restriction), binds, listens,
; accepts exactly one controller connection, and serves the NDJSON
; protocol over that connection instead of stdio.
main:
    push rbp
    mov rbp, rsp
    sub rsp, 160
    lea rdi, [rel env_adapter_listen]
    call getenv
    test rax, rax
    jz .use_stdio
    mov [rbp-8], rax            ; ADAPTER_LISTEN value
    mov rdi, rax
    call strlen
    mov [rbp-16], rax
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    lea rdx, [rel colon_byte]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    je .listen_bad
    mov [rbp-24], rax           ; colon index
    ; host copy (NUL-terminated) for inet_pton
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .listen_bad
    mov [rbp-32], rax           ; host cstr
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-24]
    call memcpy
    mov rax, [rbp-32]
    mov rcx, [rbp-24]
    mov byte [rax + rcx], 0
    ; port substring -> int (a NUL-terminated copy keeps atoi honest)
    mov rax, [rbp-16]
    sub rax, [rbp-24]
    dec rax
    mov [rbp-40], rax           ; port text length
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .listen_bad_free_host
    mov [rbp-48], rax           ; port cstr
    mov rdi, rax
    mov rax, [rbp-8]
    add rax, [rbp-24]
    inc rax
    mov rsi, rax
    mov rdx, [rbp-40]
    call memcpy
    mov rax, [rbp-48]
    mov rcx, [rbp-40]
    mov byte [rax + rcx], 0
    mov rdi, [rbp-48]
    call atoi
    mov [rbp-56], rax           ; port (int, sign-extended into a qword slot)

    mov edi, AF_INET
    mov esi, SOCK_STREAM
    xor edx, edx
    call socket
    cmp eax, 0
    jl .listen_bad_free_both
    mov [rbp-64], eax           ; listen fd

    lea rdi, [rbp-96]           ; sockaddr_in (16 bytes)
    xor esi, esi
    mov edx, sockaddr_in_size
    call memset
    mov word [rbp-96 + sockaddr_in.sin_family], AF_INET
    mov rax, [rbp-56]
    mov rdx, rax
    shr rdx, 8
    mov byte [rbp-96 + sockaddr_in.sin_port + 0], dl
    mov byte [rbp-96 + sockaddr_in.sin_port + 1], al
    ; inet_pton(AF_INET, host_cstr, &sin_addr) -- args are (family, src, dst)
    mov edi, AF_INET
    mov rsi, [rbp-32]
    lea rdx, [rbp-96 + sockaddr_in.sin_addr]
    call inet_pton
    cmp eax, 1
    jne .listen_bad_free_both

    mov edi, [rbp-64]
    lea rsi, [rbp-96]
    mov edx, sockaddr_in_size
    call bind
    test eax, eax
    jnz .listen_bad_free_both

    mov edi, [rbp-64]
    mov esi, 1
    call listen
    test eax, eax
    jnz .listen_bad_free_both

    mov edi, [rbp-64]
    xor esi, esi
    xor edx, edx
    call accept
    cmp eax, 0
    jl .listen_bad_free_both
    mov [rbp-72], eax           ; accepted fd

    mov rdi, [rbp-32]
    call free
    mov rdi, [rbp-48]
    call free
    mov edi, [rbp-64]
    call close

    mov edi, [rbp-72]
    mov esi, [rbp-72]
    call serve
    xor edi, edi
    call exit

.listen_bad_free_both:
    mov rdi, [rbp-48]
    call free
.listen_bad_free_host:
    mov rdi, [rbp-32]
    call free
.listen_bad:
    lea rsi, [rel err_msg_bad_listen]
    mov edx, err_msg_bad_listen_len
    mov edi, 2
    call write
    mov edi, 1
    call exit

.use_stdio:
    xor edi, edi
    mov esi, 1
    call serve
    xor edi, edi
    call exit

section .bss
    g_should_close: resb 1
    dbg_live_ready_byte: resb 1    ; DEBUG ONLY

section .rodata
    nl_byte: db 10
    colon_byte: db ':'
    empty_str: db 0
    env_convex_url: db "CONVEX_URL", 0
    env_auth_token: db "CONVEX_AUTH_TOKEN", 0
    env_adapter_listen: db "ADAPTER_LISTEN", 0
    glibc_prefix: db "glibc "
    glibc_prefix_len equ $ - glibc_prefix
    op_hello: db "hello"
    op_hello_len equ $ - op_hello
    op_query: db "query"
    op_query_len equ $ - op_query
    op_mutation: db "mutation"
    op_mutation_len equ $ - op_mutation
    op_action: db "action"
    op_action_len equ $ - op_action
    op_set_auth: db "setAuth"
    op_set_auth_len equ $ - op_set_auth
    op_close: db "close"
    op_close_len equ $ - op_close
    op_subscribe: db "subscribe"
    op_subscribe_len equ $ - op_subscribe
    op_unsubscribe: db "unsubscribe"
    op_unsubscribe_len equ $ - op_unsubscribe
    op_debug_disconnect: db "debugDisconnect"
    op_debug_disconnect_len equ $ - op_debug_disconnect
    k_id: db "id"
    k_id_len equ $ - k_id
    k_op: db "op"
    k_op_len equ $ - k_op
    k_type: db "type"
    k_type_len equ $ - k_type
    k_path: db "path"
    k_path_len equ $ - k_path
    k_args: db "args"
    k_args_len equ $ - k_args
    k_token: db "token"
    k_token_len equ $ - k_token
    k_value: db "value"
    k_value_len equ $ - k_value
    k_log_lines: db "logLines"
    k_log_lines_len equ $ - k_log_lines
    k_name: db "name"
    k_name_len equ $ - k_name
    k_message: db "message"
    k_message_len equ $ - k_message
    k_data: db "data"
    k_data_len equ $ - k_data
    k_error: db "error"
    k_error_len equ $ - k_error
    k_subscription_id: db "subscriptionId"
    k_subscription_id_len equ $ - k_subscription_id
    k_protocol_version: db "protocolVersion"
    k_protocol_version_len equ $ - k_protocol_version
    k_runtime: db "runtime"
    k_runtime_len equ $ - k_runtime
    k_language: db "language"
    k_language_len equ $ - k_language
    k_implementation: db "implementation"
    k_implementation_len equ $ - k_implementation
    v_ready: db "ready"
    v_ready_len equ $ - v_ready
    v_result: db "result"
    v_result_len equ $ - v_result
    v_error: db "error"
    v_error_len equ $ - v_error
    v_ack: db "ack"
    v_ack_len equ $ - v_ack
    v_closed: db "closed"
    v_closed_len equ $ - v_closed
    v_subscription: db "subscription"
    v_subscription_len equ $ - v_subscription
    v_language: db "assembly-x86-64"
    v_language_len equ $ - v_language
    v_implementation: db "native-nasm-libssl-libc"
    v_implementation_len equ $ - v_implementation
    err_name_protocol_ref: db "ProtocolError"
    err_name_protocol_ref_len equ $ - err_name_protocol_ref
    err_name_error: db "Error"
    err_name_error_len equ $ - err_name_error
    err_name_transport: db "TransportError"
    err_name_transport_len equ $ - err_name_transport
    err_msg_missing_url: db "CONVEX_URL is required"
    err_msg_missing_url_len equ $ - err_msg_missing_url
    err_msg_bad_version: db "unsupported adapter protocol version"
    err_msg_bad_version_len equ $ - err_msg_bad_version
    err_msg_bad_call_args: db "Convex arguments must be a JSON object"
    err_msg_bad_call_args_len equ $ - err_msg_bad_call_args
    err_msg_bad_token: db "token must be a string"
    err_msg_bad_token_len equ $ - err_msg_bad_token
    err_msg_bad_subscribe_args: db "subscribe requires subscriptionId, path and object args"
    err_msg_bad_subscribe_args_len equ $ - err_msg_bad_subscribe_args
    err_msg_bad_unsubscribe_args: db "unsubscribe requires subscriptionId"
    err_msg_bad_unsubscribe_args_len equ $ - err_msg_bad_unsubscribe_args
    err_msg_not_connected: db "Live WebSocket is not connected"
    err_msg_not_connected_len equ $ - err_msg_not_connected
    err_msg_oom_local: db "out of memory"
    err_msg_oom_local_len equ $ - err_msg_oom_local
    err_msg_unknown_op: db "unknown adapter operation"
    err_msg_unknown_op_len equ $ - err_msg_unknown_op
    err_msg_malformed: db "malformed adapter command"
    err_msg_malformed_len equ $ - err_msg_malformed
    err_msg_bad_listen: db "ADAPTER_LISTEN must be host:port with an IPv4 host", 10
    err_msg_bad_listen_len equ $ - err_msg_bad_listen
