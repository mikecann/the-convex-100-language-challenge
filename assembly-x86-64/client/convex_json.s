; ---------------------------------------------------------------------------
; convex_json.s -- JSON value model, parser and serializer.
;
; This is the one piece of "JSON handling" AGENTS.md calls out by name as
; required to be hand-written assembly, so nothing here delegates to a
; library: recursive-descent parsing, string escape/unescape, integer and
; floating-point number parsing, and text serialization are all implemented
; below. malloc/realloc/free/memcpy supply memory only.
;
; Same fixed-frame stack discipline as convex_buf.s throughout: push rbp;
; mov rbp,rsp; sub rsp,FRAME (FRAME a multiple of 16); restore and leave at
; every return path. See convex_buf.s for why.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

extern buf_init
extern buf_free
extern buf_reserve
extern buf_append
extern buf_append_byte
extern buf_append_cstr
extern buf_append_u64
extern buf_append_i64

section .text

global json_new_null
global json_new_bool
global json_new_int
global json_new_string
global json_new_array
global json_new_object
global json_array_push
global json_object_set
global json_object_get
global json_free
global json_parse
global json_serialize

; --- node allocation --------------------------------------------------------

; json_value *alloc_node(void) -- zeroed 48-byte node, or 0 on OOM.
alloc_node:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov edi, json_value_size
    call malloc
    test rax, rax
    jz .done
    mov [rbp-8], rax
    mov rdi, rax
    xor esi, esi
    mov edx, json_value_size
    call memset
    mov rax, [rbp-8]
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_null(void)
json_new_null:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    call alloc_node
    test rax, rax
    jz .done
    mov qword [rax + json_value.tag], JV_NULL
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_bool(int v)
json_new_bool:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    call alloc_node
    test rax, rax
    jz .done
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .false
    mov qword [rax + json_value.tag], JV_TRUE
    jmp .done
.false:
    mov qword [rax + json_value.tag], JV_FALSE
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_int(i64 v)
json_new_int:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    call alloc_node
    test rax, rax
    jz .done
    mov qword [rax + json_value.tag], JV_INT
    mov rcx, [rbp-8]
    mov [rax + json_value.ival], rcx
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_string(const char *p, u64 len) -- copies the bytes.
json_new_string:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi   ; p
    mov [rbp-16], rsi  ; len
    call alloc_node
    test rax, rax
    jz .fail
    mov [rbp-24], rax
    mov qword [rax + json_value.tag], JV_STRING
    mov rsi, [rbp-16]
    mov [rax + json_value.len], rsi
    test rsi, rsi
    jz .empty
    mov rdi, rsi
    call malloc
    test rax, rax
    jz .oom
    mov rcx, [rbp-24]
    mov [rcx + json_value.ptr], rax
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call memcpy
    mov rax, [rbp-24]
    jmp .done
.empty:
    mov rax, [rbp-24]
    jmp .done
.oom:
    mov rdi, [rbp-24]
    call free
    xor eax, eax
    jmp .done
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_array(void)
json_new_array:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    call alloc_node
    test rax, rax
    jz .done
    mov qword [rax + json_value.tag], JV_ARRAY
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_new_object(void)
json_new_object:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    call alloc_node
    test rax, rax
    jz .done
    mov qword [rax + json_value.tag], JV_OBJECT
.done:
    mov rsp, rbp
    pop rbp
    ret

; int json_array_push(json_value *arr, json_value *item) -- grows arr's
; element vector (json_value* per slot) by doubling, like buf_reserve.
json_array_push:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi    ; arr
    mov [rbp-16], rsi   ; item
    mov rax, [rdi + json_value.len]
    cmp rax, [rdi + json_value.cap]
    jb .have_room
    mov rcx, [rdi + json_value.cap]
    test rcx, rcx
    jnz .double
    mov rcx, 8
    jmp .realloc
.double:
    shl rcx, 1
.realloc:
    mov [rbp-24], rcx
    mov rdi, [rdi + json_value.ptr]
    mov rsi, rcx
    shl rsi, 3          ; capacity * sizeof(json_value*)
    call realloc
    test rax, rax
    jz .fail
    mov rcx, [rbp-8]
    mov [rcx + json_value.ptr], rax
    mov rdx, [rbp-24]
    mov [rcx + json_value.cap], rdx
.have_room:
    mov rcx, [rbp-8]
    mov rax, [rcx + json_value.ptr]
    mov rdx, [rcx + json_value.len]
    mov rsi, [rbp-16]
    mov [rax + rdx*8], rsi
    inc qword [rcx + json_value.len]
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret
.fail:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret

; int json_object_set(json_value *obj, const char *key, u64 key_len,
;                      json_value *value)
; Replaces the value (freeing the old one) if key already exists, otherwise
; appends a new entry, growing the entries vector (json_entry, 24 bytes each)
; by doubling. Every value that must outlive a `call` -- including the loop
; index -- lives in a frame slot and is reloaded afterward; nothing is
; trusted to survive a call in a register (r8-r11 are caller-saved, and an
; earlier draft of this file wrongly assumed memcmp would not touch them).
json_object_set:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [rbp-8], rdi     ; obj
    mov [rbp-16], rsi    ; key
    mov [rbp-24], rdx    ; key_len
    mov [rbp-32], rcx    ; value
    mov rax, [rdi + json_value.ptr]
    mov [rbp-40], rax    ; entries
    mov rax, [rdi + json_value.len]
    mov [rbp-48], rax    ; count
    mov qword [rbp-56], 0 ; index
.scan:
    mov rax, [rbp-56]
    cmp rax, [rbp-48]
    jae .not_found
    imul rax, rax, json_entry_size
    add rax, [rbp-40]
    mov r11, [rax + json_entry.key_len]
    cmp r11, [rbp-24]
    jne .next
    mov rdi, [rax + json_entry.key_ptr]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call memcmp
    test eax, eax
    jnz .next
    ; found: recompute the entry address (nothing survives the call above)
    mov rax, [rbp-56]
    imul rax, rax, json_entry_size
    add rax, [rbp-40]
    mov rdi, [rax + json_entry.value]
    call json_free
    mov rax, [rbp-56]
    imul rax, rax, json_entry_size
    add rax, [rbp-40]
    mov rcx, [rbp-32]
    mov [rax + json_entry.value], rcx
    mov eax, 1
    jmp .done
.next:
    mov rax, [rbp-56]
    inc rax
    mov [rbp-56], rax
    jmp .scan
.not_found:
    mov rdi, [rbp-8]
    mov rax, [rdi + json_value.len]
    cmp rax, [rdi + json_value.cap]
    jb .have_room
    mov rcx, [rdi + json_value.cap]
    test rcx, rcx
    jnz .double
    mov rcx, 8
    jmp .grow_realloc
.double:
    shl rcx, 1
.grow_realloc:
    mov [rbp-64], rcx           ; new capacity
    mov rdi, [rdi + json_value.ptr]
    imul rsi, rcx, json_entry_size
    call realloc
    test rax, rax
    jz .fail
    mov rcx, [rbp-8]
    mov [rcx + json_value.ptr], rax
    mov rdx, [rbp-64]
    mov [rcx + json_value.cap], rdx
.have_room:
    ; copy the key bytes so the caller can free/reuse their buffer
    mov rdi, [rbp-24]
    call malloc
    test rax, rax
    jz .fail
    mov [rbp-72], rax            ; key copy
    mov rdi, rax
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call memcpy
    mov rcx, [rbp-8]
    mov rax, [rcx + json_value.ptr]
    mov rdx, [rcx + json_value.len]
    imul rdx, rdx, json_entry_size
    add rax, rdx
    mov r11, [rbp-72]
    mov [rax + json_entry.key_ptr], r11
    mov r11, [rbp-24]
    mov [rax + json_entry.key_len], r11
    mov r11, [rbp-32]
    mov [rax + json_entry.value], r11
    inc qword [rcx + json_value.len]
    mov eax, 1
.done:
    mov rsp, rbp
    pop rbp
    ret
.fail:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret

; json_value *json_object_get(json_value *obj, const char *key, u64 key_len)
json_object_get:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rax, [rdi + json_value.ptr]
    mov [rbp-32], rax    ; entries
    mov rax, [rdi + json_value.len]
    mov [rbp-40], rax    ; count
    mov qword [rbp-48], 0 ; index
.scan:
    mov rax, [rbp-48]
    cmp rax, [rbp-40]
    jae .not_found
    imul rax, rax, json_entry_size
    add rax, [rbp-32]
    mov r11, [rax + json_entry.key_len]
    cmp r11, [rbp-24]
    jne .next
    mov rdi, [rax + json_entry.key_ptr]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call memcmp
    test eax, eax
    jnz .next
    mov rax, [rbp-48]
    imul rax, rax, json_entry_size
    add rax, [rbp-32]
    mov rax, [rax + json_entry.value]
    jmp .done
.next:
    mov rax, [rbp-48]
    inc rax
    mov [rbp-48], rax
    jmp .scan
.not_found:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; void json_free(json_value *v) -- recursively frees a value tree. Safe to
; call with NULL. Every piece of state that must survive the recursive call
; to json_free lives in a frame slot, never in a callee-saved register --
; this function clobbers no registers it would owe its own caller a restore
; for, and the fixed frame means no push/pop bookkeeping around the loops.
json_free:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    test rdi, rdi
    jz .noop
    mov [rbp-8], rdi          ; v
    mov rax, [rdi + json_value.tag]
    cmp rax, JV_STRING
    je .free_string
    cmp rax, JV_ARRAY
    je .free_array
    cmp rax, JV_OBJECT
    je .free_object
    jmp .free_self
.free_string:
    mov rdi, [rbp-8]
    mov rdi, [rdi + json_value.ptr]
    test rdi, rdi
    jz .free_self
    call free
    jmp .free_self
.free_array:
    mov rdi, [rbp-8]
    mov rax, [rdi + json_value.ptr]
    mov [rbp-24], rax          ; items vector
    mov rax, [rdi + json_value.len]
    mov [rbp-32], rax          ; count
    mov qword [rbp-40], 0      ; index
.arr_loop:
    mov rax, [rbp-40]
    cmp rax, [rbp-32]
    jae .free_array_vec
    mov rcx, [rbp-24]
    mov rdi, [rcx + rax*8]
    call json_free
    mov rax, [rbp-40]
    inc rax
    mov [rbp-40], rax
    jmp .arr_loop
.free_array_vec:
    mov rdi, [rbp-24]
    test rdi, rdi
    jz .free_self
    call free
    jmp .free_self
.free_object:
    mov rdi, [rbp-8]
    mov rax, [rdi + json_value.ptr]
    mov [rbp-24], rax          ; entries vector
    mov rax, [rdi + json_value.len]
    mov [rbp-32], rax          ; count
    mov qword [rbp-40], 0      ; index
.obj_loop:
    mov rax, [rbp-40]
    cmp rax, [rbp-32]
    jae .free_object_vec
    mov rcx, [rbp-24]
    imul rax, rax, json_entry_size
    add rax, rcx
    mov [rbp-16], rax          ; this entry's address, across two calls below
    mov rdi, [rax + json_entry.key_ptr]
    call free
    mov rax, [rbp-16]
    mov rdi, [rax + json_entry.value]
    call json_free
    mov rax, [rbp-40]
    inc rax
    mov [rbp-40], rax
    jmp .obj_loop
.free_object_vec:
    mov rdi, [rbp-24]
    test rdi, rdi
    jz .free_self
    call free
    jmp .free_self
.free_self:
    mov rdi, [rbp-8]
    call free
.noop:
    mov rsp, rbp
    pop rbp
    ret

; --- parsing -----------------------------------------------------------
; Everything below reads through a json_ctx*. Registers never carry state
; across a `call` in this file (json_ctx fields and frame slots do); see
; the note above json_object_set for why.

; void skip_ws(json_ctx *ctx) -- leaf, no calls, free use of registers.
skip_ws:
    mov rax, [rdi + json_ctx.p]
    mov rcx, [rdi + json_ctx.end]
.loop:
    cmp rax, rcx
    jae .done
    movzx edx, byte [rax]
    cmp dl, ' '
    je .adv
    cmp dl, 9
    je .adv
    cmp dl, 10
    je .adv
    cmp dl, 13
    je .adv
    jmp .done
.adv:
    inc rax
    jmp .loop
.done:
    mov [rdi + json_ctx.p], rax
    ret

; int expect_literal(json_ctx *ctx, const char *lit, u64 lit_len) --
; matches and consumes `lit` at the cursor, or leaves the cursor untouched.
expect_literal:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rax, [rdi + json_ctx.p]
    mov rcx, [rdi + json_ctx.end]
    sub rcx, rax
    cmp rcx, rdx
    jb .no
    mov rdi, rax
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call memcmp
    test eax, eax
    jnz .no
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    add rax, [rbp-24]
    mov [rcx + json_ctx.p], rax
    mov eax, 1
    jmp .done
.no:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; int read_hex4(json_ctx *ctx) -- consumes exactly 4 hex digits and returns
; their value 0..0xFFFF in eax, or -1 (and leaves the cursor alone) if fewer
; than 4 hex digits remain. Leaf: no calls, r8-r11 used freely.
read_hex4:
    mov rax, [rdi + json_ctx.p]
    mov rcx, [rdi + json_ctx.end]
    lea rdx, [rax + 4]
    cmp rdx, rcx
    ja .bad
    xor r8d, r8d
    mov r9, 4
    mov r10, rax
.loop:
    test r9, r9
    jz .finish
    movzx r11d, byte [r10]
    cmp r11b, '0'
    jb .bad
    cmp r11b, '9'
    ja .not_digit
    sub r11d, '0'
    jmp .accum
.not_digit:
    cmp r11b, 'A'
    jb .bad
    cmp r11b, 'F'
    jbe .upper
    cmp r11b, 'a'
    jb .bad
    cmp r11b, 'f'
    ja .bad
    sub r11d, 'a'
    add r11d, 10
    jmp .accum
.upper:
    sub r11d, 'A'
    add r11d, 10
.accum:
    shl r8d, 4
    add r8d, r11d
    inc r10
    dec r9
    jmp .loop
.finish:
    mov [rdi + json_ctx.p], r10
    mov eax, r8d
    ret
.bad:
    mov eax, -1
    ret

; void utf8_append(buf *b, u32 codepoint) -- encodes one Unicode code point
; as 1-4 UTF-8 bytes appended to *b.
utf8_append:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    cmp rsi, 0x80
    jb .one
    cmp rsi, 0x800
    jb .two
    cmp rsi, 0x10000
    jb .three
    jmp .four
.one:
    mov rdi, [rbp-8]
    mov esi, [rbp-16]
    call buf_append_byte
    jmp .done
.two:
    mov rax, [rbp-16]
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xC0
    mov rdi, [rbp-8]
    mov esi, ecx
    call buf_append_byte
    mov eax, [rbp-16]
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
    jmp .done
.three:
    mov eax, [rbp-16]
    mov ecx, eax
    shr ecx, 12
    or ecx, 0xE0
    mov rdi, [rbp-8]
    mov esi, ecx
    call buf_append_byte
    mov eax, [rbp-16]
    shr eax, 6
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
    mov eax, [rbp-16]
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
    jmp .done
.four:
    mov eax, [rbp-16]
    mov ecx, eax
    shr ecx, 18
    or ecx, 0xF0
    mov rdi, [rbp-8]
    mov esi, ecx
    call buf_append_byte
    mov eax, [rbp-16]
    shr eax, 12
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
    mov eax, [rbp-16]
    shr eax, 6
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
    mov eax, [rbp-16]
    and eax, 0x3F
    or eax, 0x80
    mov rdi, [rbp-8]
    mov esi, eax
    call buf_append_byte
.done:
    mov rsp, rbp
    pop rbp
    ret

; int parse_string_raw(json_ctx *ctx, char **out_ptr, u64 *out_len) --
; decodes a JSON string literal (cursor on the opening quote) into a freshly
; malloc'd buffer, handling \", \\, \/, \b, \f, \n, \r, \t, \uXXXX and
; surrogate pairs. A raw control byte (including NUL) is refused rather than
; silently copied through or truncated.
parse_string_raw:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [rbp-8], rdi     ; ctx
    mov [rbp-16], rsi    ; out_ptr
    mov [rbp-24], rdx    ; out_len
    lea rdi, [rbp-64]    ; local buf (buf.data=-64, .len=-56, .cap=-48)
    call buf_init
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    inc rax
    mov [rcx + json_ctx.p], rax
.loop:
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    movzx edx, byte [rax]
    cmp dl, '"'
    je .close
    cmp dl, '\'
    je .escape
    cmp dl, 0x20
    jb .bad
    inc rax
    mov [rcx + json_ctx.p], rax
    lea rdi, [rbp-64]
    movzx esi, dl
    call buf_append_byte
    jmp .loop
.escape:
    inc rax
    mov [rcx + json_ctx.p], rax
    ; rdx was clobbered by the `movzx edx, byte [rax]` above (it held
    ; ctx.end for the bounds check, not the character) -- reload it fresh
    ; rather than trusting it to have survived, which is exactly the bug an
    ; earlier draft of this function had here.
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    movzx esi, byte [rax]
    inc rax
    mov [rcx + json_ctx.p], rax
    cmp sil, '"'
    je .esc_lit
    cmp sil, '\'
    je .esc_lit
    cmp sil, '/'
    je .esc_lit
    cmp sil, 'b'
    je .esc_b
    cmp sil, 'f'
    je .esc_f
    cmp sil, 'n'
    je .esc_n
    cmp sil, 'r'
    je .esc_r
    cmp sil, 't'
    je .esc_t
    cmp sil, 'u'
    je .esc_u
    jmp .bad
.esc_lit:
    lea rdi, [rbp-64]
    call buf_append_byte
    jmp .loop
.esc_b:
    lea rdi, [rbp-64]
    mov esi, 0x08
    call buf_append_byte
    jmp .loop
.esc_f:
    lea rdi, [rbp-64]
    mov esi, 0x0C
    call buf_append_byte
    jmp .loop
.esc_n:
    lea rdi, [rbp-64]
    mov esi, 0x0A
    call buf_append_byte
    jmp .loop
.esc_r:
    lea rdi, [rbp-64]
    mov esi, 0x0D
    call buf_append_byte
    jmp .loop
.esc_t:
    lea rdi, [rbp-64]
    mov esi, 0x09
    call buf_append_byte
    jmp .loop
.esc_u:
    mov rdi, [rbp-8]
    call read_hex4
    cmp eax, 0
    jl .bad
    mov [rbp-32], rax     ; codepoint (zero-extended by the cmp/jl above)
    cmp eax, 0xD800
    jb .emit_cp
    cmp eax, 0xDBFF
    ja .emit_cp
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    lea r8, [rax + 2]
    cmp r8, rdx
    ja .emit_cp
    cmp byte [rax], '\'
    jne .emit_cp
    cmp byte [rax+1], 'u'
    jne .emit_cp
    add rax, 2
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call read_hex4
    cmp eax, 0
    jl .bad
    cmp eax, 0xDC00
    jb .emit_cp
    cmp eax, 0xDFFF
    ja .emit_cp
    mov ecx, eax
    mov eax, [rbp-32]
    sub eax, 0xD800
    shl eax, 10
    sub ecx, 0xDC00
    add eax, ecx
    add eax, 0x10000
    mov [rbp-32], rax
.emit_cp:
    lea rdi, [rbp-64]
    mov rsi, [rbp-32]
    call utf8_append
    jmp .loop
.close:
    inc rax
    mov rcx, [rbp-8]
    mov [rcx + json_ctx.p], rax
    mov rax, [rbp-56]
    mov rcx, [rbp-24]
    mov [rcx], rax
    mov rax, [rbp-64]
    mov rcx, [rbp-16]
    mov [rcx], rax
    mov eax, 1
    jmp .done
.unterminated:
.bad:
    lea rdi, [rbp-64]
    call buf_free
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *parse_string_value(json_ctx *ctx) -- wraps parse_string_raw's
; decoded buffer directly as a JV_STRING node (no extra copy).
parse_string_value:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    lea rsi, [rbp-16]
    lea rdx, [rbp-24]
    call parse_string_raw
    test eax, eax
    jz .fail
    call alloc_node
    test rax, rax
    jz .oom
    mov qword [rax + json_value.tag], JV_STRING
    mov rcx, [rbp-16]
    mov [rax + json_value.ptr], rcx
    mov rcx, [rbp-24]
    mov [rax + json_value.len], rcx
    jmp .done
.oom:
    mov rdi, [rbp-16]
    test rdi, rdi
    jz .fail
    call free
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *parse_number(json_ctx *ctx)
;
; Accumulates an overflow-checked u64 integer AND a running double in
; parallel while scanning digits (both are cheap, and doing both avoids a
; second pass): the result is JV_INT with full 64-bit precision whenever the
; literal has no '.' or exponent and fits in 64 bits -- important for
; Convex's nanosecond sync timestamps, which routinely exceed 2^53 and lose
; precision if parsed as a double (a real bug found in an earlier client on
; this project, per LESSONS.md). Only a literal that actually contains '.'
; or an exponent, or one whose integer part overflows 64 bits, becomes
; JV_DOUBLE.
parse_number:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [rbp-8], rdi
    mov rax, [rdi + json_ctx.p]
    mov [rbp-48], rax        ; cursor
    mov rax, [rdi + json_ctx.end]
    mov [rbp-56], rax        ; end
    mov qword [rbp-16], 0    ; neg
    mov qword [rbp-24], 0    ; ival
    mov qword [rbp-32], 0    ; overflow flag
    pxor xmm0, xmm0
    movq [rbp-40], xmm0      ; dval
    mov qword [rbp-64], 0    ; is_float
    mov qword [rbp-72], 0    ; frac_count

    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .bad
    cmp byte [rax], '-'
    jne .no_sign
    mov qword [rbp-16], 1
    inc rax
    mov [rbp-48], rax
.no_sign:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .bad
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    ja .bad
    cmp dl, '0'
    jne .int_loop
    inc rax
    mov [rbp-48], rax
    cmp rax, rcx
    jae .after_int
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .after_int
    cmp dl, '9'
    ja .after_int
    jmp .bad
.int_loop:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .after_int
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .after_int
    cmp dl, '9'
    ja .after_int
    sub edx, '0'
    mov r10d, edx
    mov rax, [rbp-24]
    mov r9, 10
    mul r9
    jc .mark_overflow
    add rax, r10
    jc .mark_overflow
    mov [rbp-24], rax
    jmp .int_have_ival
.mark_overflow:
    mov qword [rbp-32], 1
.int_have_ival:
    movq xmm0, [rbp-40]
    mulsd xmm0, [rel ten_const]
    cvtsi2sd xmm1, r10d
    addsd xmm0, xmm1
    movq [rbp-40], xmm0
    mov rax, [rbp-48]
    inc rax
    mov [rbp-48], rax
    jmp .int_loop
.after_int:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .no_frac
    cmp byte [rax], '.'
    jne .no_frac
    mov qword [rbp-64], 1
    inc rax
    mov [rbp-48], rax
    cmp rax, rcx
    jae .bad
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    ja .bad
.frac_loop:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .no_frac
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .no_frac
    cmp dl, '9'
    ja .no_frac
    sub edx, '0'
    movq xmm0, [rbp-40]
    mulsd xmm0, [rel ten_const]
    cvtsi2sd xmm1, edx
    addsd xmm0, xmm1
    movq [rbp-40], xmm0
    mov rax, [rbp-72]
    inc rax
    mov [rbp-72], rax
    mov rax, [rbp-48]
    inc rax
    mov [rbp-48], rax
    jmp .frac_loop
.no_frac:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .no_exp
    movzx edx, byte [rax]
    cmp dl, 'e'
    je .has_exp
    cmp dl, 'E'
    je .has_exp
    jmp .no_exp
.has_exp:
    mov qword [rbp-64], 1
    inc rax
    mov [rbp-48], rax
    xor r10d, r10d
    cmp rax, rcx
    jae .bad
    movzx edx, byte [rax]
    cmp dl, '+'
    jne .check_minus
    inc rax
    mov [rbp-48], rax
    jmp .exp_digits_check
.check_minus:
    cmp dl, '-'
    jne .exp_digits_check
    mov r10d, 1
    inc rax
    mov [rbp-48], rax
.exp_digits_check:
    mov rax, [rbp-48]
    cmp rax, rcx
    jae .bad
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    ja .bad
    xor r11d, r11d
.exp_loop:
    mov rax, [rbp-48]
    mov rcx, [rbp-56]
    cmp rax, rcx
    jae .exp_done
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .exp_done
    cmp dl, '9'
    ja .exp_done
    sub edx, '0'
    imul r11d, r11d, 10
    add r11d, edx
    cmp r11d, 2000
    jle .exp_ok
    mov r11d, 2000
.exp_ok:
    mov rax, [rbp-48]
    inc rax
    mov [rbp-48], rax
    jmp .exp_loop
.exp_done:
    mov eax, r11d
    test r10d, r10d
    jz .exp_pos
    neg eax
.exp_pos:
    movsxd rax, eax
    sub rax, [rbp-72]
    movq xmm0, [rbp-40]
    test rax, rax
    jz .scale_done
    jg .scale_up
    neg rax
.scale_down_loop:
    test rax, rax
    jz .scale_done
    divsd xmm0, [rel ten_const]
    dec rax
    jmp .scale_down_loop
.scale_up:
.scale_up_loop:
    test rax, rax
    jz .scale_done
    mulsd xmm0, [rel ten_const]
    dec rax
    jmp .scale_up_loop
.scale_done:
    movq [rbp-40], xmm0
    jmp .no_exp_after
.no_exp:
    mov rax, [rbp-72]
    test rax, rax
    jz .no_exp_after
    movq xmm0, [rbp-40]
.no_exp_scale_loop:
    test rax, rax
    jz .no_exp_scale_done
    divsd xmm0, [rel ten_const]
    dec rax
    jmp .no_exp_scale_loop
.no_exp_scale_done:
    movq [rbp-40], xmm0
.no_exp_after:
    mov rax, [rbp-16]
    test rax, rax
    jz .finalize
    mov rax, [rbp-24]
    neg rax
    mov [rbp-24], rax
    movq xmm0, [rbp-40]
    movsd xmm1, [rel neg_zero]
    xorpd xmm0, xmm1
    movq [rbp-40], xmm0
.finalize:
    call alloc_node
    test rax, rax
    jz .oom
    mov [rbp-80], rax
    mov rcx, [rbp-64]
    mov r8, [rbp-32]
    or rcx, r8
    jnz .as_double
    mov rax, [rbp-80]
    mov qword [rax + json_value.tag], JV_INT
    mov rcx, [rbp-24]
    mov [rax + json_value.ival], rcx
    jmp .return_node
.as_double:
    mov rax, [rbp-80]
    mov qword [rax + json_value.tag], JV_DOUBLE
    mov rcx, [rbp-40]
    mov [rax + json_value.dval], rcx
.return_node:
    mov rcx, [rbp-8]
    mov rdx, [rbp-48]
    mov [rcx + json_ctx.p], rdx
    mov rax, [rbp-80]
    jmp .done
.oom:
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    xor eax, eax
    jmp .done
.bad:
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *parse_value(json_ctx *ctx) -- dispatches on the current byte.
; Every value, container or leaf, root or nested, is allocated through
; exactly one call to this function, which is why the node-count safety
; valve lives here rather than being duplicated in parse_object/parse_array.
parse_value:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rax, [rdi + json_ctx.nodes]
    cmp rax, JSON_MAX_NODES
    jae .too_many
    inc rax
    mov [rdi + json_ctx.nodes], rax
    mov rax, [rdi + json_ctx.p]
    mov rcx, [rdi + json_ctx.end]
    cmp rax, rcx
    jae .eof
    movzx edx, byte [rax]
    cmp dl, '"'
    je .is_string
    cmp dl, '{'
    je .is_object
    cmp dl, '['
    je .is_array
    cmp dl, 't'
    je .is_true
    cmp dl, 'f'
    je .is_false
    cmp dl, 'n'
    je .is_null
    cmp dl, '-'
    je .is_number
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    ja .bad
.is_number:
    mov rdi, [rbp-8]
    call parse_number
    jmp .done
.is_string:
    mov rdi, [rbp-8]
    call parse_string_value
    jmp .done
.is_object:
    mov rdi, [rbp-8]
    call parse_object
    jmp .done
.is_array:
    mov rdi, [rbp-8]
    call parse_array
    jmp .done
.is_true:
    mov rdi, [rbp-8]
    lea rsi, [rel lit_true]
    mov edx, 4
    call expect_literal
    test eax, eax
    jz .bad
    mov edi, 1
    call json_new_bool
    jmp .done
.is_false:
    mov rdi, [rbp-8]
    lea rsi, [rel lit_false]
    mov edx, 5
    call expect_literal
    test eax, eax
    jz .bad
    xor edi, edi
    call json_new_bool
    jmp .done
.is_null:
    mov rdi, [rbp-8]
    lea rsi, [rel lit_null]
    mov edx, 4
    call expect_literal
    test eax, eax
    jz .bad
    call json_new_null
    jmp .done
.bad:
.eof:
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    xor eax, eax
    jmp .done
.too_many:
    mov qword [rdi + json_ctx.err], 1
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *parse_array(json_ctx *ctx) -- cursor is on the opening '['.
parse_array:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    call json_new_array
    test rax, rax
    jz .oom
    mov [rbp-16], rax
    mov rcx, [rbp-8]
    mov rdx, [rcx + json_ctx.depth]
    cmp rdx, JSON_MAX_DEPTH
    jae .too_deep
    inc rdx
    mov [rcx + json_ctx.depth], rdx
    mov rax, [rcx + json_ctx.p]
    inc rax
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call skip_ws
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    cmp byte [rax], ']'
    jne .elem_loop
    inc rax
    mov [rcx + json_ctx.p], rax
    jmp .depth_pop_ok
.elem_loop:
    mov rdi, [rbp-8]
    call parse_value
    test rax, rax
    jz .fail
    mov [rbp-24], rax
    mov rdi, [rbp-16]
    mov rsi, rax
    call json_array_push
    test eax, eax
    jnz .push_ok
    mov rdi, [rbp-24]
    call json_free
    jmp .fail
.push_ok:
    mov rdi, [rbp-8]
    call skip_ws
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    cmp byte [rax], ','
    jne .check_close
    inc rax
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call skip_ws
    jmp .elem_loop
.check_close:
    cmp byte [rax], ']'
    jne .fail
    inc rax
    mov [rcx + json_ctx.p], rax
.depth_pop_ok:
    mov rcx, [rbp-8]
    mov rdx, [rcx + json_ctx.depth]
    dec rdx
    mov [rcx + json_ctx.depth], rdx
    mov rax, [rbp-16]
    jmp .done
.unterminated:
.fail:
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    mov rdi, [rbp-16]
    call json_free
    xor eax, eax
    jmp .done
.too_deep:
    mov qword [rcx + json_ctx.err], 1
    mov rdi, [rbp-16]
    call json_free
    xor eax, eax
    jmp .done
.oom:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; json_value *parse_object(json_ctx *ctx) -- cursor is on the opening '{'.
parse_object:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    call json_new_object
    test rax, rax
    jz .oom
    mov [rbp-16], rax
    mov rcx, [rbp-8]
    mov rdx, [rcx + json_ctx.depth]
    cmp rdx, JSON_MAX_DEPTH
    jae .too_deep
    inc rdx
    mov [rcx + json_ctx.depth], rdx
    mov rax, [rcx + json_ctx.p]
    inc rax
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call skip_ws
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    cmp byte [rax], '}'
    jne .member_loop
    inc rax
    mov [rcx + json_ctx.p], rax
    jmp .depth_pop_ok
.member_loop:
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    cmp byte [rax], '"'
    jne .fail
    mov rdi, [rbp-8]
    lea rsi, [rbp-24]
    lea rdx, [rbp-32]
    call parse_string_raw
    test eax, eax
    jz .fail_noitem
    mov rdi, [rbp-8]
    call skip_ws
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated_freekey
    cmp byte [rax], ':'
    jne .fail_freekey
    inc rax
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call skip_ws
    mov rdi, [rbp-8]
    call parse_value
    test rax, rax
    jz .fail_freekey
    mov [rbp-40], rax
    mov rdi, [rbp-16]
    mov rsi, [rbp-24]
    mov rdx, [rbp-32]
    mov rcx, [rbp-40]
    call json_object_set
    ; Save the result to the frame before `call free` below -- free's return
    ; value is unspecified, and testing eax straight after it here was a
    ; real, previously shipped bug: it read garbage instead of
    ; json_object_set's actual result and could take the "failed" branch
    ; even on success, freeing a value node that was already attached to
    ; the object and causing a genuine double free once the object itself
    ; was freed.
    mov [rbp-48], eax
    mov rdi, [rbp-24]
    call free
    mov eax, [rbp-48]
    test eax, eax
    jnz .set_ok
    mov rdi, [rbp-40]
    call json_free
    jmp .fail_noitem
.set_ok:
    mov rdi, [rbp-8]
    call skip_ws
    mov rcx, [rbp-8]
    mov rax, [rcx + json_ctx.p]
    mov rdx, [rcx + json_ctx.end]
    cmp rax, rdx
    jae .unterminated
    cmp byte [rax], ','
    jne .check_close
    inc rax
    mov [rcx + json_ctx.p], rax
    mov rdi, rcx
    call skip_ws
    jmp .member_loop
.check_close:
    cmp byte [rax], '}'
    jne .fail
    inc rax
    mov [rcx + json_ctx.p], rax
.depth_pop_ok:
    mov rcx, [rbp-8]
    mov rdx, [rcx + json_ctx.depth]
    dec rdx
    mov [rcx + json_ctx.depth], rdx
    mov rax, [rbp-16]
    jmp .done
.unterminated_freekey:
.fail_freekey:
    mov rdi, [rbp-24]
    call free
    jmp .fail
.unterminated:
.fail:
.fail_noitem:
    mov rcx, [rbp-8]
    mov qword [rcx + json_ctx.err], 1
    mov rdi, [rbp-16]
    call json_free
    xor eax, eax
    jmp .done
.too_deep:
    mov qword [rcx + json_ctx.err], 1
    mov rdi, [rbp-16]
    call json_free
    xor eax, eax
    jmp .done
.oom:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; int json_parse(const char *text, u64 len, json_value **out)
; Parses one JSON value and requires the whole input (after trailing
; whitespace) to be consumed; trailing garbage is a parse error, not a
; silently-ignored suffix. *out is 0 on any failure.
json_parse:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdx         ; out
    mov [rbp-56], rdi        ; ctx.p = text
    add rdi, rsi
    mov [rbp-48], rdi        ; ctx.end
    mov qword [rbp-40], 0    ; ctx.depth
    mov qword [rbp-32], 0    ; ctx.nodes
    mov qword [rbp-24], 0    ; ctx.err
    lea rdi, [rbp-56]
    call skip_ws
    lea rdi, [rbp-56]
    call parse_value
    mov [rbp-16], rax
    lea rdi, [rbp-56]
    call skip_ws
    mov rcx, [rbp-24]
    test rcx, rcx
    jnz .fail
    mov rax, [rbp-16]
    test rax, rax
    jz .fail
    mov rcx, [rbp-56]
    cmp rcx, [rbp-48]
    jne .fail_free
    mov rcx, [rbp-8]
    mov [rcx], rax
    mov eax, 1
    jmp .done
.fail_free:
    mov rdi, rax
    call json_free
.fail:
    mov rcx, [rbp-8]
    mov qword [rcx], 0
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; void serialize_string(buf *out, const char *p, u64 len) -- writes a
; JSON-quoted, escaped string. Bytes >= 0x20 that are not '"' or '\\' pass
; through unchanged (this project does not re-validate UTF-8 on the way
; back out; see convex_json.s's parse-side note on that same tradeoff).
serialize_string:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi     ; out
    mov [rbp-16], rsi    ; p
    mov [rbp-24], rdx    ; len
    mov rdi, [rbp-8]
    mov esi, '"'
    call buf_append_byte
    mov qword [rbp-32], 0
.loop:
    mov rax, [rbp-32]
    cmp rax, [rbp-24]
    jae .close
    mov rcx, [rbp-16]
    movzx edx, byte [rcx + rax]
    cmp dl, '"'
    je .esc_quote
    cmp dl, '\'
    je .esc_backslash
    cmp dl, 0x08
    je .esc_b
    cmp dl, 0x0C
    je .esc_f
    cmp dl, 0x0A
    je .esc_n
    cmp dl, 0x0D
    je .esc_r
    cmp dl, 0x09
    je .esc_t
    cmp dl, 0x20
    jb .esc_u
    mov rdi, [rbp-8]
    movzx esi, dl
    call buf_append_byte
    jmp .next
.esc_quote:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, '"'
    call buf_append_byte
    jmp .next
.esc_backslash:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    jmp .next
.esc_b:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 'b'
    call buf_append_byte
    jmp .next
.esc_f:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 'f'
    call buf_append_byte
    jmp .next
.esc_n:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 'n'
    call buf_append_byte
    jmp .next
.esc_r:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 'r'
    call buf_append_byte
    jmp .next
.esc_t:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 't'
    call buf_append_byte
    jmp .next
.esc_u:
    mov rdi, [rbp-8]
    mov esi, '\'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, 'u'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, '0'
    call buf_append_byte
    mov rdi, [rbp-8]
    mov esi, '0'
    call buf_append_byte
    mov rax, [rbp-32]
    mov rcx, [rbp-16]
    movzx edx, byte [rcx + rax]
    mov ecx, edx
    shr cl, 4
    cmp cl, 10
    jb .hi_digit
    add cl, 'A'-10
    jmp .hi_done
.hi_digit:
    add cl, '0'
.hi_done:
    mov rdi, [rbp-8]
    movzx esi, cl
    call buf_append_byte
    mov rax, [rbp-32]
    mov rcx, [rbp-16]
    movzx edx, byte [rcx + rax]
    and dl, 0x0F
    cmp dl, 10
    jb .lo_digit
    add dl, 'A'-10
    jmp .lo_done
.lo_digit:
    add dl, '0'
.lo_done:
    mov rdi, [rbp-8]
    movzx esi, dl
    call buf_append_byte
.next:
    mov rax, [rbp-32]
    inc rax
    mov [rbp-32], rax
    jmp .loop
.close:
    mov rdi, [rbp-8]
    mov esi, '"'
    call buf_append_byte
    mov rsp, rbp
    pop rbp
    ret

; void format_double(buf *out, double value) -- decimal text. Convex JSON
; may write an integral value as e.g. "0.0"; matching that, an integral
; result is always printed with a ".0" suffix rather than as a bare
; integer. This is a bounded fixed-point formatter (6 fractional digits,
; trailing zeros trimmed), not a general shortest-round-trip dtoa -- see the
; manifest limitations for why that tradeoff was made deliberately.
format_double:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    movq rax, xmm0
    mov rcx, rax
    shr rcx, 63
    mov [rbp-16], rcx          ; sign
    btr rax, 63                 ; abs value bit pattern
    movq xmm0, rax
    mov rcx, rax
    shr rcx, 52
    and ecx, 0x7FF
    cmp ecx, 0x7FF
    je .not_finite
    ucomisd xmm0, [rel big_threshold]
    ja .big_fallback
    mulsd xmm0, [rel scale_1e6]
    addsd xmm0, [rel half_const]
    cvttsd2si rax, xmm0
    mov rcx, 1000000
    xor rdx, rdx
    div rcx
    mov [rbp-32], rax           ; int_part
    mov [rbp-40], rdx            ; frac_part
    mov rcx, [rbp-16]
    test rcx, rcx
    jz .no_minus1
    mov rdi, [rbp-8]
    mov esi, '-'
    call buf_append_byte
.no_minus1:
    mov rdi, [rbp-8]
    mov rsi, [rbp-32]
    call buf_append_u64
    mov rdi, [rbp-8]
    mov esi, '.'
    call buf_append_byte
    mov rax, [rbp-40]
    test rax, rax
    jnz .has_frac
    mov rdi, [rbp-8]
    mov esi, '0'
    call buf_append_byte
    jmp .done
.has_frac:
    mov rax, [rbp-40]
    mov r10, 6
    lea r8, [rbp-42]
.digit_loop:
    dec r8
    xor rdx, rdx
    mov r9, 10
    div r9
    add dl, '0'
    mov [r8], dl
    dec r10
    jnz .digit_loop
    mov byte [rbp-42], 0
    lea r8, [rbp-43]
.trim_scan:
    cmp byte [r8], '0'
    jne .trim_found
    dec r8
    jmp .trim_scan
.trim_found:
    inc r8
    mov byte [r8], 0
    mov rdi, [rbp-8]
    lea rsi, [rbp-48]
    call buf_append_cstr
    jmp .done
.big_fallback:
    addsd xmm0, [rel half_const]
    cvttsd2si rax, xmm0
    mov [rbp-32], rax
    mov rcx, [rbp-16]
    test rcx, rcx
    jz .no_minus2
    mov rdi, [rbp-8]
    mov esi, '-'
    call buf_append_byte
.no_minus2:
    mov rdi, [rbp-8]
    mov rsi, [rbp-32]
    call buf_append_u64
    mov rdi, [rbp-8]
    lea rsi, [rel dot_zero]
    call buf_append_cstr
    jmp .done
.not_finite:
    mov rdi, [rbp-8]
    lea rsi, [rel lit_null]
    mov edx, 4
    call buf_append
.done:
    mov rsp, rbp
    pop rbp
    ret

; void json_serialize(json_value *v, buf *out) -- recursive text writer.
json_serialize:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi         ; v
    mov [rbp-16], rsi        ; out
    mov rax, [rdi + json_value.tag]
    cmp rax, JV_NULL
    je .s_null
    cmp rax, JV_FALSE
    je .s_false
    cmp rax, JV_TRUE
    je .s_true
    cmp rax, JV_INT
    je .s_int
    cmp rax, JV_DOUBLE
    je .s_double
    cmp rax, JV_STRING
    je .s_string
    cmp rax, JV_ARRAY
    je .s_array
    cmp rax, JV_OBJECT
    je .s_object
    jmp .done
.s_null:
    mov rdi, [rbp-16]
    lea rsi, [rel lit_null]
    mov edx, 4
    call buf_append
    jmp .done
.s_false:
    mov rdi, [rbp-16]
    lea rsi, [rel lit_false]
    mov edx, 5
    call buf_append
    jmp .done
.s_true:
    mov rdi, [rbp-16]
    lea rsi, [rel lit_true]
    mov edx, 4
    call buf_append
    jmp .done
.s_int:
    mov rdi, [rbp-16]
    mov rax, [rbp-8]
    mov rsi, [rax + json_value.ival]
    call buf_append_i64
    jmp .done
.s_double:
    mov rax, [rbp-8]
    movq xmm0, [rax + json_value.dval]
    mov rdi, [rbp-16]
    call format_double
    jmp .done
.s_string:
    mov rax, [rbp-8]
    mov rdi, [rbp-16]
    mov rsi, [rax + json_value.ptr]
    mov rdx, [rax + json_value.len]
    call serialize_string
    jmp .done
.s_array:
    mov rdi, [rbp-16]
    mov esi, '['
    call buf_append_byte
    mov rax, [rbp-8]
    mov rcx, [rax + json_value.len]
    mov [rbp-24], rcx
    mov rcx, [rax + json_value.ptr]
    mov [rbp-40], rcx
    mov qword [rbp-32], 0
.arr_loop:
    mov rax, [rbp-32]
    cmp rax, [rbp-24]
    jae .arr_close
    test rax, rax
    jz .arr_no_comma
    mov rdi, [rbp-16]
    mov esi, ','
    call buf_append_byte
.arr_no_comma:
    mov rax, [rbp-32]
    mov rcx, [rbp-40]
    mov rdi, [rcx + rax*8]
    mov rsi, [rbp-16]
    call json_serialize
    mov rax, [rbp-32]
    inc rax
    mov [rbp-32], rax
    jmp .arr_loop
.arr_close:
    mov rdi, [rbp-16]
    mov esi, ']'
    call buf_append_byte
    jmp .done
.s_object:
    mov rdi, [rbp-16]
    mov esi, '{'
    call buf_append_byte
    mov rax, [rbp-8]
    mov rcx, [rax + json_value.len]
    mov [rbp-24], rcx
    mov rcx, [rax + json_value.ptr]
    mov [rbp-40], rcx
    mov qword [rbp-32], 0
.obj_loop:
    mov rax, [rbp-32]
    cmp rax, [rbp-24]
    jae .obj_close
    test rax, rax
    jz .obj_no_comma
    mov rdi, [rbp-16]
    mov esi, ','
    call buf_append_byte
.obj_no_comma:
    mov rax, [rbp-32]
    imul rax, rax, json_entry_size
    add rax, [rbp-40]
    mov rdi, [rbp-16]
    mov rsi, [rax + json_entry.key_ptr]
    mov rdx, [rax + json_entry.key_len]
    call serialize_string
    mov rdi, [rbp-16]
    mov esi, ':'
    call buf_append_byte
    mov rax, [rbp-32]
    imul rax, rax, json_entry_size
    add rax, [rbp-40]
    mov rdi, [rax + json_entry.value]
    mov rsi, [rbp-16]
    call json_serialize
    mov rax, [rbp-32]
    inc rax
    mov [rbp-32], rax
    jmp .obj_loop
.obj_close:
    mov rdi, [rbp-16]
    mov esi, '}'
    call buf_append_byte
.done:
    mov rsp, rbp
    pop rbp
    ret

section .rodata
    align 8
    ten_const: dq 10.0
    neg_zero:  dq 0x8000000000000000
    big_threshold: dq 1.0e12
    scale_1e6: dq 1000000.0
    half_const: dq 0.5
    dot_zero: db ".0", 0
    lit_true:  db "true"
    lit_false: db "false"
    lit_null:  db "null"
