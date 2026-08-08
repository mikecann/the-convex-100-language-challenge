; ---------------------------------------------------------------------------
; convex_buf.s -- a growable byte buffer.
;
; Every HTTP request, every WebSocket frame and every serialized JSON value
; this client produces is assembled into one of these before it touches the
; network. malloc/realloc/free/memcpy are the only external calls; growth,
; capacity doubling and append logic are all written here.
;
; Stack discipline used by every non-trivial function in this codebase:
;     push rbp
;     mov  rbp, rsp
;     sub  rsp, FRAME          ; FRAME is always a compile-time multiple of 16
;     mov  [rbp-8], rdi        ; spill whichever arguments/locals are needed
;     ...
;     mov  rsp, rbp
;     pop  rbp
;     ret
; `call`ing this function leaves %rsp % 16 == 8 at entry per the SysV AMD64
; ABI, so one `push rbp` plus any multiple-of-16 `sub rsp` always leaves
; %rsp % 16 == 0 at every `call` this function makes, with %rsp otherwise
; held constant for the whole function body. Reasoning about odd/even push
; counts by hand is exactly how an earlier draft of this file mis-aligned
; the stack and crashed inside libc; the fixed frame removes that whole
; class of mistake by construction.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

section .text

global buf_init
global buf_free
global buf_reserve
global buf_append
global buf_append_byte
global buf_append_cstr
global buf_append_u64
global buf_append_i64

; void buf_init(buf *b) -- leaf, no calls, no frame needed.
buf_init:
    mov qword [rdi + buf.data], 0
    mov qword [rdi + buf.len], 0
    mov qword [rdi + buf.cap], 0
    ret

; void buf_free(buf *b)
buf_free:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rdi, [rdi + buf.data]
    test rdi, rdi
    jz .done
    call free
.done:
    mov rax, [rbp-8]
    mov qword [rax + buf.data], 0
    mov qword [rax + buf.len], 0
    mov qword [rax + buf.cap], 0
    mov rsp, rbp
    pop rbp
    ret

; int buf_reserve(buf *b, u64 extra) -- ensures room for `extra` more bytes
; beyond the current length, doubling capacity (or growing exactly, if
; doubling would overflow) as needed. Returns 1 on success, 0 on OOM.
buf_reserve:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi            ; b
    mov [rbp-16], rsi           ; extra (reused below once it is consumed)
    mov rax, [rdi + buf.len]
    add rax, rsi
    jc .fail                    ; length + extra overflowed u64
    cmp rax, [rdi + buf.cap]
    jbe .ok                     ; already large enough
    mov [rbp-24], rax           ; needed total length
    mov rcx, [rdi + buf.cap]
    test rcx, rcx
    jnz .have_cap
    mov rcx, 256                ; initial capacity for a fresh buffer
.have_cap:
.grow:
    cmp rcx, [rbp-24]
    jae .do_realloc
    shl rcx, 1                  ; double until it is big enough
    jnc .grow
    mov rcx, [rbp-24]           ; doubling overflowed; take the exact size
.do_realloc:
    mov [rbp-16], rcx           ; new capacity, replacing the spent `extra`
    mov rdi, [rbp-8]
    mov rdi, [rdi + buf.data]
    mov rsi, rcx
    call realloc
    test rax, rax
    jz .fail
    mov rcx, [rbp-8]
    mov [rcx + buf.data], rax
    mov rdx, [rbp-16]
    mov [rcx + buf.cap], rdx
.ok:
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret
.fail:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret

; int buf_append(buf *b, const void *bytes, u64 len)
buf_append:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi             ; b
    mov [rbp-16], rsi            ; bytes
    mov [rbp-24], rdx            ; len
    test rdx, rdx
    jz .ok_noop
    mov rsi, rdx                 ; buf_reserve(b, len)
    call buf_reserve
    test eax, eax
    jz .fail
    mov rdi, [rbp-8]
    mov rax, [rdi + buf.data]
    add rax, [rdi + buf.len]
    mov rdi, rax                 ; dest = b->data + b->len
    mov rsi, [rbp-16]            ; src
    mov rdx, [rbp-24]            ; n
    call memcpy
    mov rdi, [rbp-8]
    mov rax, [rbp-24]
    add [rdi + buf.len], rax
.ok_noop:
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret
.fail:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret

; int buf_append_byte(buf *b, u8 byte)
buf_append_byte:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov al, sil
    mov [rbp-16], al              ; one-byte scratch buffer to point at
    mov rdi, [rbp-8]
    lea rsi, [rbp-16]
    mov edx, 1
    call buf_append
    mov rsp, rbp
    pop rbp
    ret

; int buf_append_cstr(buf *b, const char *s) -- appends a NUL-terminated
; literal; used only for our own fixed string constants.
buf_append_cstr:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov rdi, rsi
    call strlen
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, rax
    call buf_append
    mov rsp, rbp
    pop rbp
    ret

; int buf_append_u64(buf *b, u64 value) -- decimal, unsigned, no sign.
buf_append_u64:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi              ; b
    mov [rbp-16], rsi             ; value
    ; Digits are built backwards into a 32-byte scratch region
    ; [rbp-64 .. rbp-33], terminated by a NUL at [rbp-33]; u64 max is 20
    ; digits, so 31 usable bytes below the terminator is ample room.
    mov byte [rbp-33], 0
    lea rcx, [rbp-33]             ; write cursor
    mov rax, [rbp-16]
    mov r10, 10                   ; divisor; caller-saved, nothing to restore
    test rax, rax
    jnz .loop
    dec rcx
    mov byte [rcx], '0'
    jmp .emit
.loop:
    test rax, rax
    jz .emit
    xor rdx, rdx
    div r10
    add dl, '0'
    dec rcx
    mov [rcx], dl
    jmp .loop
.emit:
    mov rdi, [rbp-8]
    mov rsi, rcx
    call buf_append_cstr
    mov rsp, rbp
    pop rbp
    ret

; int buf_append_i64(buf *b, i64 value) -- decimal, signed.
buf_append_i64:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    test rsi, rsi
    jns .positive
    mov rdi, [rbp-8]
    mov esi, '-'
    call buf_append_byte
    mov rsi, [rbp-16]
    neg rsi
    mov [rbp-16], rsi
.positive:
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    call buf_append_u64
    mov rsp, rbp
    pop rbp
    ret
