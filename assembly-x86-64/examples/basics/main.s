; ---------------------------------------------------------------------------
; main.s -- the canonical Convex example: query the shared counter, start
; Live before mutating it, apply an idempotent mutation, and report the
; resulting Live update -- the full 0 -> 1 journey.
;
; It fails loudly on any unexpected value; nothing here is a smoke test
; that can only pass.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

extern write
extern exit
extern getenv
extern strlen
extern memcpy
extern convex_new
extern convex_free
extern convex_call
extern convex_live_init
extern convex_live_close
extern convex_live_subscribe
extern convex_live_unsubscribe
extern convex_live_next
extern json_new_object
extern json_new_string
extern json_object_set
extern json_object_get
extern json_free

section .bss
    client:  resq 1
    err:     resb convex_error_size
    result1: resb convex_result_size
    result2: resb convex_result_size
    room_arg: resb 64
    room_len: resq 1
    g_live:  resb convex_live_size
    g_sub:   resq 1
    g_update: resb convex_update_size

section .text
global main

; void die(const char *message, u64 len) -- prints to stderr and exits 1.
die:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    ; write's argument order (fd, buf, count) differs from ours (buf,
    ; count), so the incoming rdi/rsi must be saved before rdi is
    ; overwritten with the fd -- an earlier draft clobbered rdi with the fd
    ; number first and called write with whatever rsi/rdx happened to
    ; already hold, silently printing nothing.
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov edi, 2
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call write
    mov edi, 2
    lea rsi, [nl]
    mov edx, 1
    call write
    mov edi, 1
    call exit

; void print_line(const char *ptr, u64 len)
print_line:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov edi, 1
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call write
    mov edi, 1
    lea rsi, [nl]
    mov edx, 1
    call write
    mov rsp, rbp
    pop rbp
    ret

; int count_of(json_value *state) -- pulls the "count" field and requires it
; to be a mathematically integral, in-range number. Convex may encode a
; whole count as either a plain integer or a decimal like "0.0"; this client
; already keeps a decimal literal's exact value as a double, so accepting
; both here just means checking the tag rather than reparsing text.
count_of:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    test rdi, rdi
    jz .bad
    lea rsi, [rel k_count]
    mov edx, 5
    call json_object_get
    test rax, rax
    jz .bad
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_INT
    je .is_int
    cmp rcx, JV_DOUBLE
    jne .bad
    ; integral double check: truncating to an int64 and back must round-trip
    movq xmm0, [rax + json_value.dval]
    cvttsd2si rcx, xmm0
    cvtsi2sd xmm1, rcx
    ucomisd xmm0, xmm1
    jne .bad
    mov eax, ecx
    jmp .done
.is_int:
    mov rax, [rax + json_value.ival]
    cmp rax, 0x7FFFFFFF
    jg .bad
    cmp rax, -1
    jl .bad
    jmp .done
.bad:
    mov eax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; void free_update(void) -- frees g_update's owned value/logs once this
; example is done reading them, so the second convex_live_next call (which
; reuses the same scratch struct) never leaks the first one's payload.
free_update:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov rdi, [g_update + convex_update.value]
    test rdi, rdi
    jz .no_value
    call json_free
.no_value:
    mov rax, [g_update + convex_update.logs]
    test rax, rax
    jz .no_logs
    mov rdi, rax
    call json_free
.no_logs:
    mov rsp, rbp
    pop rbp
    ret

; int main(int argc, char **argv) -- the standard C entry point, supplied
; by the C runtime this executable links against (see the Dockerfile). argc
; and argv arrive in rdi/rsi exactly as they would for a C program.
main:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi            ; argc
    mov [rbp-16], rsi           ; argv

    ; Configure the deployment from the environment and create the client.
    lea rdi, [rel env_convex_url]
    call getenv
    test rax, rax
    jz .no_url
    mov [rbp-24], rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, [rbp-24]
    lea rdx, [rel version_text]
    mov ecx, version_len
    lea r8, [err]
    call convex_new
    test rax, rax
    jz .new_failed
    mov [client], rax

    ; Initialize the Live sync state machine for this client.
    lea rdi, [g_live]
    mov rsi, [client]
    call convex_live_init
    test eax, eax
    jz .live_init_failed

    ; The room argument selects a unique shared counter: the verifier
    ; passes one on argv[1]; running the image by hand without an argument
    ; falls back to a friendly default.
    mov rax, [rbp-8]
    cmp rax, 2
    jl .default_room
    mov rax, [rbp-16]
    mov rax, [rax + 8]           ; argv[1]
    mov [rbp-24], rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    cmp rsi, 63
    jbe .room_len_ok
    mov rsi, 63                  ; clamp defensively; room_arg is 64 bytes
.room_len_ok:
    lea rdi, [room_arg]
    mov rdx, rsi
    mov [room_len], rsi
    mov rsi, [rbp-24]
    call memcpy
    jmp .have_room
.default_room:
    lea rdi, [room_arg]
    lea rsi, [rel default_room]
    mov edx, default_room_len
    call memcpy
    mov qword [room_len], default_room_len
.have_room:

    ; Query the current counter over HTTP and decode its JSON object.
    call json_new_object
    mov [rbp-8], rax
    lea rdi, [room_arg]
    mov rsi, [room_len]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-8]
    lea rsi, [rel k_room]
    mov edx, 4
    call json_object_set

    mov rdi, [client]
    mov esi, CONVEX_OP_QUERY
    lea rdx, [rel path_state]
    mov ecx, path_state_len
    mov r8, [rbp-8]
    lea r9, [result1]
    sub rsp, 16
    lea rax, [err]
    mov [rsp], rax
    call convex_call
    add rsp, 16
    test eax, eax
    jz .query_failed

    mov rdi, [result1 + convex_result.value]
    call count_of
    cmp eax, 0
    jne .unexpected_query
    lea rdi, [rel msg_current]
    mov esi, msg_current_len
    call print_line

    ; Start Live before the mutation so no reactive update can be missed --
    ; a fresh args object, since convex_call above already consumed the
    ; first one as part of its request.
    call json_new_object
    mov [rbp-8], rax
    lea rdi, [room_arg]
    mov rsi, [room_len]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-8]
    lea rsi, [rel k_room]
    mov edx, 4
    call json_object_set

    lea rdi, [g_live]
    lea rsi, [rel path_state]
    mov edx, path_state_len
    mov rcx, [rbp-8]
    call convex_live_subscribe
    test rax, rax
    jz .subscribe_failed
    mov [g_sub], rax

    mov rdi, [g_sub]
    lea rsi, [g_update]
    mov edx, 10000
    call convex_live_next
    test eax, eax
    jz .live_initial_timeout
    mov rax, [g_update + convex_update.has_error]
    test rax, rax
    jnz .live_initial_error
    mov rdi, [g_update + convex_update.value]
    call count_of
    cmp eax, 0
    jne .unexpected_live_initial
    lea rdi, [rel msg_live_initial]
    mov esi, msg_live_initial_len
    call print_line
    call free_update

    ; The run ID makes the mutation safe to retry without incrementing
    ; twice: the server treats a repeated runId for the same room as a
    ; no-op rather than a second increment.
    call json_new_object
    mov [rbp-8], rax
    lea rdi, [room_arg]
    mov rsi, [room_len]
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-8]
    lea rsi, [rel k_room]
    mov edx, 4
    call json_object_set
    lea rdi, [rel lang_text]
    mov esi, lang_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-8]
    lea rsi, [rel k_language]
    mov edx, 8
    call json_object_set
    lea rdi, [rel run_id_text]
    mov esi, run_id_len
    call json_new_string
    mov rcx, rax
    mov rdi, [rbp-8]
    lea rsi, [rel k_run_id]
    mov edx, 5
    call json_object_set

    mov rdi, [client]
    mov esi, CONVEX_OP_MUTATION
    lea rdx, [rel path_increment]
    mov ecx, path_increment_len
    mov r8, [rbp-8]
    lea r9, [result2]
    sub rsp, 16
    lea rax, [err]
    mov [rsp], rax
    call convex_call
    add rsp, 16
    test eax, eax
    jz .mutation_failed

    mov rdi, [result2 + convex_result.value]
    lea rsi, [rel k_applied]
    mov edx, 7
    call json_object_get
    test rax, rax
    jz .unexpected_mutation
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_TRUE
    jne .unexpected_mutation
    lea rdi, [rel msg_applied]
    mov esi, msg_applied_len
    call print_line

    mov rdi, [result2 + convex_result.value]
    lea rsi, [rel k_state]
    mov edx, 5
    call json_object_get
    test rax, rax
    jz .unexpected_mutation
    mov rdi, rax
    call count_of
    cmp eax, 1
    jne .unexpected_mutation
    lea rdi, [rel msg_mutation_count]
    mov esi, msg_mutation_count_len
    call print_line

    ; Decode the resulting Live update, then cleanly remove the
    ; subscription.
    mov rdi, [g_sub]
    lea rsi, [g_update]
    mov edx, 10000
    call convex_live_next
    test eax, eax
    jz .live_updated_timeout
    mov rax, [g_update + convex_update.has_error]
    test rax, rax
    jnz .live_updated_error
    mov rdi, [g_update + convex_update.value]
    call count_of
    cmp eax, 1
    jne .unexpected_live_updated
    lea rdi, [rel msg_live_updated]
    mov esi, msg_live_updated_len
    call print_line
    call free_update

    mov rdi, [g_sub]
    call convex_live_unsubscribe

    ; Print verification only after HTTP and Live agree on the 0 -> 1
    ; journey.
    lea rdi, [rel msg_verified]
    mov esi, msg_verified_len
    call print_line

    mov rdi, [result1 + convex_result.value]
    call json_free
    mov rdi, [result2 + convex_result.value]
    call json_free
    mov rax, [result1 + convex_result.logs]
    test rax, rax
    jz .no_logs1
    call json_free
.no_logs1:
    mov rax, [result2 + convex_result.logs]
    test rax, rax
    jz .no_logs2
    mov rdi, rax
    call json_free
.no_logs2:
    lea rdi, [g_live]
    call convex_live_close
    mov rdi, [client]
    call convex_free
    xor edi, edi
    call exit

.no_url:
    lea rdi, [rel msg_no_url]
    mov esi, msg_no_url_len
    call die
.new_failed:
    mov rdi, [err + convex_error.msg_ptr]
    mov rsi, [err + convex_error.msg_len]
    call die
.live_init_failed:
    lea rdi, [rel msg_live_init_failed]
    mov esi, msg_live_init_failed_len
    call die
.query_failed:
    mov rdi, [err + convex_error.msg_ptr]
    mov rsi, [err + convex_error.msg_len]
    call die
.unexpected_query:
    lea rdi, [rel msg_unexpected_query]
    mov esi, msg_unexpected_query_len
    call die
.subscribe_failed:
    lea rdi, [rel msg_subscribe_failed]
    mov esi, msg_subscribe_failed_len
    call die
.live_initial_timeout:
    lea rdi, [rel msg_live_initial_timeout]
    mov esi, msg_live_initial_timeout_len
    call die
.live_initial_error:
    mov rdi, [g_update + convex_update.err_msg_ptr]
    mov rsi, [g_update + convex_update.err_msg_len]
    call die
.unexpected_live_initial:
    lea rdi, [rel msg_unexpected_live_initial]
    mov esi, msg_unexpected_live_initial_len
    call die
.mutation_failed:
    mov rdi, [err + convex_error.msg_ptr]
    mov rsi, [err + convex_error.msg_len]
    call die
.unexpected_mutation:
    lea rdi, [rel msg_unexpected_mutation]
    mov esi, msg_unexpected_mutation_len
    call die
.live_updated_timeout:
    lea rdi, [rel msg_live_updated_timeout]
    mov esi, msg_live_updated_timeout_len
    call die
.live_updated_error:
    mov rdi, [g_update + convex_update.err_msg_ptr]
    mov rsi, [g_update + convex_update.err_msg_len]
    call die
.unexpected_live_updated:
    lea rdi, [rel msg_unexpected_live_updated]
    mov esi, msg_unexpected_live_updated_len
    call die

section .rodata
    env_convex_url: db "CONVEX_URL", 0
    version_text: db "assembly-x86-64-0.1.0"
    version_len equ $ - version_text
    default_room: db "assembly-x86-64-basic-example"
    default_room_len equ $ - default_room
    lang_text: db "Assembly"
    lang_len equ $ - lang_text
    run_id_text: db "assembly-x86-64-basic-example-once"
    run_id_len equ $ - run_id_text
    path_state: db "demo:state"
    path_state_len equ $ - path_state
    path_increment: db "demo:increment"
    path_increment_len equ $ - path_increment
    k_room: db "room"
    k_count: db "count"
    k_language: db "language"
    k_run_id: db "runId"
    k_applied: db "applied"
    k_state: db "state"
    nl: db 10
    msg_current: db "current count: 0"
    msg_current_len equ $ - msg_current
    msg_live_initial: db "live initial count: 0"
    msg_live_initial_len equ $ - msg_live_initial
    msg_applied: db "mutation applied: true"
    msg_applied_len equ $ - msg_applied
    msg_mutation_count: db "mutation count: 1"
    msg_mutation_count_len equ $ - msg_mutation_count
    msg_live_updated: db "live updated count: 1"
    msg_live_updated_len equ $ - msg_live_updated
    msg_verified: db "verified count: 0 -> 1"
    msg_verified_len equ $ - msg_verified
    msg_no_url: db "CONVEX_URL is required"
    msg_no_url_len equ $ - msg_no_url
    msg_live_init_failed: db "could not initialize Live"
    msg_live_init_failed_len equ $ - msg_live_init_failed
    msg_unexpected_query: db "unexpected initial query value"
    msg_unexpected_query_len equ $ - msg_unexpected_query
    msg_subscribe_failed: db "could not start Live subscription"
    msg_subscribe_failed_len equ $ - msg_subscribe_failed
    msg_live_initial_timeout: db "timed out waiting for the initial Live value"
    msg_live_initial_timeout_len equ $ - msg_live_initial_timeout
    msg_unexpected_live_initial: db "unexpected initial Live value"
    msg_unexpected_live_initial_len equ $ - msg_unexpected_live_initial
    msg_unexpected_mutation: db "unexpected mutation result"
    msg_unexpected_mutation_len equ $ - msg_unexpected_mutation
    msg_live_updated_timeout: db "timed out waiting for the updated Live value"
    msg_live_updated_timeout_len equ $ - msg_live_updated_timeout
    msg_unexpected_live_updated: db "unexpected updated Live value"
    msg_unexpected_live_updated_len equ $ - msg_unexpected_live_updated
