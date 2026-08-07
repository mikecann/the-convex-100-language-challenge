; ---------------------------------------------------------------------------
; convex_ws.s -- RFC 6455 WebSocket framing over a convex_conn (plain TCP or
; TLS). This file is protocol-agnostic: it knows nothing about Convex's sync
; messages, only about the HTTP Upgrade handshake, the frame wire format,
; client-side masking, fragmented-message reassembly, control frames
; interleaved mid-fragment, and validating a reassembled text message's
; UTF-8 exactly once. convex_live.s builds the Convex sync state machine on
; top of the primitives here.
;
; SHA-1 and base64 are the handshake's only cryptographic/encoding needs:
; SHA-1 comes from libcrypto (already linked for TLS); base64 is written out
; below the same way JSON and HTTP framing are elsewhere in this client.
;
; Same fixed-frame stack discipline as the rest of this client (see
; convex_buf.s's header comment for why): every function here spills every
; argument it needs to survive a `call` into its own frame slot and reloads
; it afterward. Nothing is ever passed by assuming a fixed offset into a
; *different* function's frame -- an earlier draft of this file tried that
; shortcut for a tiny "emit one base64 character" helper and it was wrong
; the moment it was written (a callee's rbp has no fixed arithmetic
; relationship to its caller's rbp; only explicit arguments cross that
; boundary safely). Replaced before it ever ran.
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
extern convex_connect
extern convex_conn_close
extern convex_conn_write_all
extern convex_conn_read_some
extern find_bytes
extern ci_find
extern SHA1
extern RAND_bytes
extern malloc
extern free
extern memcpy
extern memmove

section .text

global base64_encode
global ws_open
global ws_close
global ws_send_frame
global ws_recv_more
global ws_pump_message
global utf8_validate

; --- base64 -----------------------------------------------------------------

; void b64_emit(buf *out, int sextet) -- appends alphabet[sextet] to *out.
b64_emit:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi          ; out
    mov [rbp-16], esi         ; sextet
    lea rcx, [rel b64_alphabet]
    movzx eax, byte [rcx + rsi]
    mov [rbp-24], eax
    mov rdi, [rbp-8]
    mov esi, [rbp-24]
    call buf_append_byte
    mov rsp, rbp
    pop rbp
    ret

; int base64_encode(const u8 *data, u64 len, buf *out) -- standard alphabet,
; '=' padded. Appends to *out (does not reset it).
base64_encode:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi          ; data
    mov [rbp-16], rsi         ; len
    mov [rbp-24], rdx         ; out
    xor r8, r8
    mov [rbp-32], r8          ; i
.triples:
    mov rax, [rbp-16]
    sub rax, [rbp-32]
    cmp rax, 3
    jb .tail
    mov rcx, [rbp-8]
    add rcx, [rbp-32]
    movzx eax, byte [rcx]
    shl eax, 16
    movzx edx, byte [rcx+1]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rcx+2]
    or eax, edx
    mov [rbp-40], eax         ; 24-bit accumulator
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 18
    and esi, 0
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 12
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 6
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rax, [rbp-32]
    add rax, 3
    mov [rbp-32], rax
    jmp .triples
.tail:
    mov rax, [rbp-16]
    sub rax, [rbp-32]         ; remaining 0, 1 or 2 bytes
    test rax, rax
    jz .done
    cmp rax, 1
    je .one_left
    ; two bytes left
    mov rcx, [rbp-8]
    add rcx, [rbp-32]
    movzx eax, byte [rcx]
    shl eax, 16
    movzx edx, byte [rcx+1]
    shl edx, 8
    or eax, edx
    mov [rbp-40], eax
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 18
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 12
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 6
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov esi, '='
    call buf_append_byte
    jmp .done
.one_left:
    mov rcx, [rbp-8]
    add rcx, [rbp-32]
    movzx eax, byte [rcx]
    shl eax, 16
    mov [rbp-40], eax
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 18
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov eax, [rbp-40]
    shr eax, 12
    mov esi, eax
    and esi, 0x3F
    call b64_emit
    mov rdi, [rbp-24]
    mov esi, '='
    call buf_append_byte
    mov rdi, [rbp-24]
    mov esi, '='
    call buf_append_byte
.done:
    mov eax, 1
    mov rsp, rbp
    pop rbp
    ret

; --- handshake ---------------------------------------------------------

; int ws_build_key(buf *key_b64) -- 16 random bytes, base64-encoded.
%define BK_KEYB64 -8
%define BK_RAW    -24        ; 16 bytes: rbp-24 .. rbp-9
ws_build_key:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+BK_KEYB64], rdi
    lea rdi, [rbp+BK_RAW]
    mov esi, 16
    call RAND_bytes
    cmp eax, 1
    jne .fail
    lea rdi, [rbp+BK_RAW]
    mov esi, 16
    mov rdx, [rbp+BK_KEYB64]
    call base64_encode
    test eax, eax
    jz .fail
    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef BK_KEYB64
%undef BK_RAW

; int ws_compute_accept(const char *key_ptr, u64 key_len, buf *out_accept)
; Sec-WebSocket-Accept = base64(SHA1(key . GUID)), the RFC 6455 handshake
; check that proves the peer actually understood our Upgrade request rather
; than, say, an HTTP proxy echoing something unrelated back.
%define CA_KEYPTR   -8
%define CA_KEYLEN   -16
%define CA_OUT      -24
%define CA_COMBINED -56        ; buf struct, 24 bytes: rbp-56..rbp-33
%define CA_DIGEST   -80        ; 20 bytes: rbp-80..rbp-61 (SHA-1 digest)
ws_compute_accept:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+CA_KEYPTR], rdi
    mov [rbp+CA_KEYLEN], rsi
    mov [rbp+CA_OUT], rdx
    lea rdi, [rbp+CA_COMBINED]
    call buf_init
    lea rdi, [rbp+CA_COMBINED]
    mov rsi, [rbp+CA_KEYPTR]
    mov rdx, [rbp+CA_KEYLEN]
    call buf_append
    test eax, eax
    jz .fail
    lea rdi, [rbp+CA_COMBINED]
    lea rsi, [rel ws_guid]
    mov edx, ws_guid_len
    call buf_append
    test eax, eax
    jz .fail
    mov rdi, [rbp+CA_COMBINED + buf.data]
    mov rsi, [rbp+CA_COMBINED + buf.len]
    lea rdx, [rbp+CA_DIGEST]
    call SHA1
    lea rdi, [rbp+CA_DIGEST]
    mov esi, 20
    mov rdx, [rbp+CA_OUT]
    call base64_encode
    lea rdi, [rbp+CA_COMBINED]
    call buf_free
    mov eax, 1
    jmp .done
.fail:
    lea rdi, [rbp+CA_COMBINED]
    call buf_free
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef CA_KEYPTR
%undef CA_KEYLEN
%undef CA_OUT
%undef CA_COMBINED
%undef CA_DIGEST

; int ws_send_handshake_request(convex_conn *conn, convex_url *url,
;                                const char *user_agent, u64 ua_len,
;                                const char *key_ptr, u64 key_len)
%define SR_CONN   -8
%define SR_URL    -16
%define SR_UA     -24
%define SR_UALEN  -32
%define SR_KEYPTR -40
%define SR_KEYLEN -48
%define SR_RESULT -56
%define SR_REQ    -88          ; buf struct, 24 bytes: rbp-88..rbp-65
ws_send_handshake_request:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+SR_CONN], rdi
    mov [rbp+SR_URL], rsi
    mov [rbp+SR_UA], rdx
    mov [rbp+SR_UALEN], rcx
    mov [rbp+SR_KEYPTR], r8
    mov [rbp+SR_KEYLEN], r9

    lea rdi, [rbp+SR_REQ]
    call buf_init
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel ws_req_get]
    call buf_append_cstr
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel ws_hdr_host]
    call buf_append_cstr
    mov rax, [rbp+SR_URL]
    mov rsi, [rax + convex_url.host_ptr]
    mov rdx, [rax + convex_url.host_len]
    lea rdi, [rbp+SR_REQ]
    call buf_append
    lea rdi, [rbp+SR_REQ]
    mov esi, ':'
    call buf_append_byte
    mov rax, [rbp+SR_URL]
    mov rsi, [rax + convex_url.port]
    lea rdi, [rbp+SR_REQ]
    call buf_append_u64
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel crlf2]
    mov edx, 2
    call buf_append
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel ws_hdr_fixed]
    call buf_append_cstr
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel ws_hdr_key]
    call buf_append_cstr
    mov rsi, [rbp+SR_KEYPTR]
    mov rdx, [rbp+SR_KEYLEN]
    lea rdi, [rbp+SR_REQ]
    call buf_append
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel crlf2]
    mov edx, 2
    call buf_append
    mov rax, [rbp+SR_UALEN]
    test rax, rax
    jz .no_ua
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel ws_hdr_client]
    call buf_append_cstr
    mov rsi, [rbp+SR_UA]
    mov rdx, [rbp+SR_UALEN]
    lea rdi, [rbp+SR_REQ]
    call buf_append
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel crlf2]
    mov edx, 2
    call buf_append
.no_ua:
    lea rdi, [rbp+SR_REQ]
    lea rsi, [rel crlf2]
    mov edx, 2
    call buf_append

    mov rdi, [rbp+SR_CONN]
    mov rax, [rbp+SR_REQ + buf.data]
    mov rsi, rax
    mov rdx, [rbp+SR_REQ + buf.len]
    call convex_conn_write_all
    mov [rbp+SR_RESULT], rax
    lea rdi, [rbp+SR_REQ]
    call buf_free
    mov rax, [rbp+SR_RESULT]
    mov rsp, rbp
    pop rbp
    ret
%undef SR_CONN
%undef SR_URL
%undef SR_UA
%undef SR_UALEN
%undef SR_KEYPTR
%undef SR_KEYLEN
%undef SR_RESULT
%undef SR_REQ

; i64 ws_read_handshake_response(convex_conn *conn, buf *accept_out,
;                                 buf *leftover_out)
; Reads the HTTP response headers (reusing the same bounded read-until-
; terminator loop convex_http_exchange uses), copies the Sec-WebSocket-
; Accept header's value into *accept_out and any bytes already buffered
; past the header terminator into *leftover_out (a real server can pack the
; first WebSocket frame into the same TCP segment as the 101 response), and
; returns the numeric status code, or -1 on any transport/framing failure.
%define RR_CONN    -8
%define RR_ACCEPT  -16
%define RR_LEFT    -24
%define RR_RAW     -56         ; buf struct, 24 bytes: rbp-56..rbp-33
%define RR_HDREND  -64
%define RR_BODYOFF -72
%define RR_STATUS  -80
ws_read_handshake_response:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+RR_CONN], rdi
    mov [rbp+RR_ACCEPT], rsi
    mov [rbp+RR_LEFT], rdx
    lea rdi, [rbp+RR_RAW]
    call buf_init
.header_loop:
    mov rdi, [rbp+RR_RAW + buf.data]
    mov rsi, [rbp+RR_RAW + buf.len]
    lea rdx, [rel header_terminator4]
    mov ecx, 4
    call find_bytes
    cmp rax, -1
    jne .headers_found
    mov rcx, [rbp+RR_RAW + buf.len]
    cmp rcx, CONVEX_MAX_HEADER_BYTES
    jae .fail
    mov rdi, [rbp+RR_CONN]
    lea rsi, [rbp+RR_RAW]
    call ws_hs_read_more
    cmp eax, 0
    jle .fail
    jmp .header_loop
.headers_found:
    mov [rbp+RR_HDREND], rax
    mov rax, [rbp+RR_HDREND]
    add rax, 4
    mov [rbp+RR_BODYOFF], rax
    ; status code: first space, then up to 3 digits
    mov rdi, [rbp+RR_RAW + buf.data]
    mov rsi, [rbp+RR_HDREND]
    lea rdx, [rel single_space1]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    je .fail
    mov rcx, [rbp+RR_RAW + buf.data]
    add rcx, rax
    inc rcx
    xor r8, r8
    xor r9, r9
.status_digits:
    cmp r9, 3
    jae .status_done
    movzx edx, byte [rcx]
    cmp dl, '0'
    jb .status_done
    cmp dl, '9'
    ja .status_done
    sub edx, '0'
    imul r8, r8, 10
    add r8, rdx
    inc rcx
    inc r9
    jmp .status_digits
.status_done:
    test r9, r9
    jz .fail
    mov [rbp+RR_STATUS], r8
    ; Sec-WebSocket-Accept header value
    mov rdi, [rbp+RR_RAW + buf.data]
    mov rsi, [rbp+RR_HDREND]
    lea rdx, [rel ws_hdr_accept_name]
    mov ecx, ws_hdr_accept_name_len
    call ci_find
    cmp rax, -1
    je .fail
    mov rcx, [rbp+RR_RAW + buf.data]
    add rcx, rax
    add rcx, ws_hdr_accept_name_len
    mov r10, [rbp+RR_RAW + buf.data]
    add r10, [rbp+RR_HDREND]        ; header block end
.accept_skip_ws:
    cmp rcx, r10
    jae .fail
    cmp byte [rcx], ' '
    jne .accept_value_start
    inc rcx
    jmp .accept_skip_ws
.accept_value_start:
    mov r11, rcx                    ; value start
.accept_scan:
    cmp rcx, r10
    jae .accept_value_end
    cmp byte [rcx], 13
    je .accept_value_end
    inc rcx
    jmp .accept_scan
.accept_value_end:
    mov rdi, [rbp+RR_ACCEPT]
    mov rsi, r11
    mov rdx, rcx
    sub rdx, r11
    call buf_append
    test eax, eax
    jz .fail
    ; leftover bytes past the header terminator, if any arrived already
    mov rax, [rbp+RR_RAW + buf.len]
    sub rax, [rbp+RR_BODYOFF]
    jle .no_leftover
    mov rdi, [rbp+RR_LEFT]
    mov rax, [rbp+RR_RAW + buf.data]
    add rax, [rbp+RR_BODYOFF]
    mov rsi, rax
    mov rax, [rbp+RR_RAW + buf.len]
    sub rax, [rbp+RR_BODYOFF]
    mov rdx, rax
    call buf_append
.no_leftover:
    lea rdi, [rbp+RR_RAW]
    call buf_free
    mov rax, [rbp+RR_STATUS]
    jmp .done
.fail:
    lea rdi, [rbp+RR_RAW]
    call buf_free
    mov rax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef RR_CONN
%undef RR_ACCEPT
%undef RR_LEFT
%undef RR_RAW
%undef RR_HDREND
%undef RR_BODYOFF
%undef RR_STATUS

; int ws_hs_read_more(convex_conn *conn, buf *raw) -- grows raw by up to
; 4096 bytes read directly into its own spare capacity, exactly like
; convex_http.s's private read_more (duplicated rather than shared across
; translation units to keep each file's exported surface self-contained).
ws_hs_read_more:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov rdi, rsi
    mov esi, 4096
    call buf_reserve
    test eax, eax
    jz .fail
    mov rcx, [rbp-16]
    mov rax, [rcx + buf.data]
    add rax, [rcx + buf.len]
    mov rdi, [rbp-8]
    mov rsi, rax
    mov edx, 4096
    call convex_conn_read_some
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

; int ws_open(convex_url *url, const char *user_agent, u64 ua_len,
;             ws_conn *out)
; Connects (TCP, or TLS with the same full peer verification convex_connect
; already gives HTTP calls), performs the Upgrade handshake, and leaves
; *out ready for ws_pump_message/ws_send_frame on success. On any failure
; the underlying transport is closed and *out is left with .open = 0.
%define WO_URL    -8
%define WO_UA     -16
%define WO_UALEN  -24
%define WO_OUT    -32
%define WO_KEYB64 -56          ; buf struct: rbp-56..rbp-33
%define WO_ACCEPT -80          ; buf struct: rbp-80..rbp-57
%define WO_EXPECT -104         ; buf struct: rbp-104..rbp-81
%define WO_LEFT   -128         ; buf struct: rbp-128..rbp-105
%define WO_STATUS -136
ws_open:
    push rbp
    mov rbp, rsp
    sub rsp, 144
    mov [rbp+WO_URL], rdi
    mov [rbp+WO_UA], rsi
    mov [rbp+WO_UALEN], rdx
    mov [rbp+WO_OUT], rcx

    mov qword [rcx + ws_conn.assembling], 0
    mov qword [rcx + ws_conn.asm_opcode], 0
    mov qword [rcx + ws_conn.open], 0
    mov qword [rcx + ws_conn.recv_off], 0
    lea rdi, [rcx + ws_conn.recv]
    call buf_init
    mov rcx, [rbp+WO_OUT]
    lea rdi, [rcx + ws_conn.asmbuf]
    call buf_init

    mov rcx, [rbp+WO_OUT]
    mov rdi, [rbp+WO_URL]
    lea rsi, [rcx + ws_conn.conn]
    call convex_connect
    test eax, eax
    jz .fail_noclose

    lea rdi, [rbp+WO_KEYB64]
    call buf_init
    lea rdi, [rbp+WO_KEYB64]
    call ws_build_key
    test eax, eax
    jz .fail_close

    mov rcx, [rbp+WO_OUT]
    mov rdi, [rcx + ws_conn.conn]
    mov rsi, [rbp+WO_URL]
    mov rdx, [rbp+WO_UA]
    mov rcx, [rbp+WO_UALEN]
    mov r8, [rbp+WO_KEYB64 + buf.data]
    mov r9, [rbp+WO_KEYB64 + buf.len]
    call ws_send_handshake_request
    test eax, eax
    jz .fail_close

    lea rdi, [rbp+WO_ACCEPT]
    call buf_init
    lea rdi, [rbp+WO_LEFT]
    call buf_init
    mov rcx, [rbp+WO_OUT]
    mov rdi, [rcx + ws_conn.conn]
    lea rsi, [rbp+WO_ACCEPT]
    lea rdx, [rbp+WO_LEFT]
    call ws_read_handshake_response
    mov [rbp+WO_STATUS], rax
    cmp qword [rbp+WO_STATUS], 101
    jne .fail_close

    lea rdi, [rbp+WO_EXPECT]
    call buf_init
    mov rdi, [rbp+WO_KEYB64 + buf.data]
    mov rsi, [rbp+WO_KEYB64 + buf.len]
    lea rdx, [rbp+WO_EXPECT]
    call ws_compute_accept
    test eax, eax
    jz .fail_close

    mov rax, [rbp+WO_ACCEPT + buf.len]
    cmp rax, [rbp+WO_EXPECT + buf.len]
    jne .fail_close
    mov rdi, [rbp+WO_ACCEPT + buf.data]
    mov rsi, [rbp+WO_EXPECT + buf.data]
    mov rdx, [rbp+WO_EXPECT + buf.len]
    call memcmp
    test eax, eax
    jnz .fail_close

    ; success: fold any leftover post-handshake bytes into the ws_conn's
    ; own receive buffer so the very first frame read never loses them.
    mov rcx, [rbp+WO_OUT]
    mov rax, [rbp+WO_LEFT + buf.len]
    test rax, rax
    jz .no_leftover
    lea rdi, [rcx + ws_conn.recv]
    mov rsi, [rbp+WO_LEFT + buf.data]
    mov rdx, [rbp+WO_LEFT + buf.len]
    call buf_append
.no_leftover:
    mov rcx, [rbp+WO_OUT]
    mov qword [rcx + ws_conn.open], 1
    mov eax, 1
    jmp .cleanup

.fail_close:
    mov rcx, [rbp+WO_OUT]
    lea rdi, [rcx + ws_conn.conn]
    call convex_conn_close
.fail_noclose:
    xor eax, eax
.cleanup:
    mov [rbp+WO_STATUS], rax        ; stash result across the frees below
    lea rdi, [rbp+WO_KEYB64]
    call buf_free
    lea rdi, [rbp+WO_ACCEPT]
    call buf_free
    lea rdi, [rbp+WO_EXPECT]
    call buf_free
    lea rdi, [rbp+WO_LEFT]
    call buf_free
    mov rax, [rbp+WO_STATUS]
    mov rsp, rbp
    pop rbp
    ret
%undef WO_URL
%undef WO_UA
%undef WO_UALEN
%undef WO_OUT
%undef WO_KEYB64
%undef WO_ACCEPT
%undef WO_EXPECT
%undef WO_LEFT
%undef WO_STATUS

; void ws_close(ws_conn *w) -- best-effort close frame (never waited on),
; then tears down the transport and frees both internal buffers. Safe to
; call on a *w that was never successfully opened (ws_open zeroes .open in
; that case, or the caller may have zeroed the whole struct).
%define WC_W -8
ws_close:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+WC_W], rdi
    mov rax, [rdi + ws_conn.open]
    test rax, rax
    jz .no_frame
    mov rdi, [rbp+WC_W]
    mov esi, WS_OP_CLOSE
    xor edx, edx
    xor ecx, ecx
    call ws_send_frame
.no_frame:
    mov rax, [rbp+WC_W]
    mov qword [rax + ws_conn.open], 0
    lea rdi, [rax + ws_conn.conn]
    call convex_conn_close
    mov rax, [rbp+WC_W]
    lea rdi, [rax + ws_conn.recv]
    call buf_free
    mov rax, [rbp+WC_W]
    lea rdi, [rax + ws_conn.asmbuf]
    call buf_free
    mov rax, [rbp+WC_W]
    mov qword [rax + ws_conn.assembling], 0
    mov rsp, rbp
    pop rbp
    ret
%undef WC_W

; int ws_send_frame(ws_conn *w, int opcode, const u8 *payload, u64 len)
; Always masks (RFC 6455 requires every client-to-server frame to be
; masked with a fresh random key) and always sends FIN=1 -- this client
; never fragments its own outgoing messages, since every message it sends
; (Connect, ModifyQuerySet, Pong, Close) comfortably fits in one frame.
%define SF_W       -8
%define SF_OPCODE  -16
%define SF_PAYLOAD -24
%define SF_LEN     -32
%define SF_HDRLEN  -40
%define SF_MASK    -56       ; 4 bytes: rbp-56..rbp-53
%define SF_HDR     -80       ; 14 bytes: rbp-80..rbp-67
%define SF_MASKED  -88
%define SF_I       -96
ws_send_frame:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    mov [rbp+SF_W], rdi
    mov [rbp+SF_OPCODE], esi
    mov [rbp+SF_PAYLOAD], rdx
    mov [rbp+SF_LEN], rcx

    lea rdi, [rbp+SF_MASK]
    mov esi, 4
    call RAND_bytes
    cmp eax, 1
    jne .fail_noalloc

    mov eax, [rbp+SF_OPCODE]
    and eax, 0x0F
    or eax, 0x80
    mov byte [rbp+SF_HDR], al

    mov rax, [rbp+SF_LEN]
    cmp rax, 126
    jb .short_len
    cmp rax, 0x10000
    jb .mid_len
    ; Long form. This client's own outgoing messages never approach 4 GiB,
    ; so the high 32 bits of the length are always zero here -- a
    ; deliberate bound, not a general 64-bit encoder.
    mov byte [rbp+SF_HDR+1], (0x80 | 127)
    mov byte [rbp+SF_HDR+2], 0
    mov byte [rbp+SF_HDR+3], 0
    mov byte [rbp+SF_HDR+4], 0
    mov byte [rbp+SF_HDR+5], 0
    mov rcx, rax
    shr rcx, 24
    mov byte [rbp+SF_HDR+6], cl
    mov rcx, rax
    shr rcx, 16
    mov byte [rbp+SF_HDR+7], cl
    mov rcx, rax
    shr rcx, 8
    mov byte [rbp+SF_HDR+8], cl
    mov byte [rbp+SF_HDR+9], al
    mov dword [rbp+SF_HDRLEN], 10
    jmp .have_header
.mid_len:
    mov byte [rbp+SF_HDR+1], (0x80 | 126)
    mov rcx, rax
    shr rcx, 8
    mov byte [rbp+SF_HDR+2], cl
    mov byte [rbp+SF_HDR+3], al
    mov dword [rbp+SF_HDRLEN], 4
    jmp .have_header
.short_len:
    mov ecx, eax
    or ecx, 0x80
    mov byte [rbp+SF_HDR+1], cl
    mov dword [rbp+SF_HDRLEN], 2
.have_header:
    mov eax, [rbp+SF_HDRLEN]
    lea rdi, [rbp+SF_HDR]
    add rdi, rax
    mov edx, [rbp+SF_MASK]
    mov [rdi], edx
    add eax, 4
    mov [rbp+SF_HDRLEN], eax

    mov rdi, [rbp+SF_W]
    lea rsi, [rbp+SF_HDR]
    mov eax, [rbp+SF_HDRLEN]
    mov rdx, rax
    call convex_conn_write_all
    test eax, eax
    jz .fail_noalloc

    mov rax, [rbp+SF_LEN]
    test rax, rax
    jz .no_payload
    mov rdi, rax
    call malloc
    test rax, rax
    jz .fail_noalloc
    mov [rbp+SF_MASKED], rax
    mov qword [rbp+SF_I], 0
.mask_loop:
    mov rax, [rbp+SF_I]
    cmp rax, [rbp+SF_LEN]
    jae .mask_done
    mov rcx, [rbp+SF_PAYLOAD]
    movzx edx, byte [rcx + rax]
    mov rcx, rax
    and rcx, 3
    movzx r8d, byte [rbp+SF_MASK + rcx]
    xor edx, r8d
    mov rcx, [rbp+SF_MASKED]
    mov [rcx + rax], dl
    inc qword [rbp+SF_I]
    jmp .mask_loop
.mask_done:
    mov rdi, [rbp+SF_W]
    mov rsi, [rbp+SF_MASKED]
    mov rdx, [rbp+SF_LEN]
    call convex_conn_write_all
    mov [rbp+SF_I], rax         ; reuse: the masking loop that lived in
                                 ; this slot has already finished
    mov rdi, [rbp+SF_MASKED]
    call free
    mov rax, [rbp+SF_I]
    jmp .done
.no_payload:
    mov eax, 1
    jmp .done
.fail_noalloc:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef SF_W
%undef SF_OPCODE
%undef SF_PAYLOAD
%undef SF_LEN
%undef SF_HDRLEN
%undef SF_MASK
%undef SF_HDR
%undef SF_MASKED
%undef SF_I

; int ws_recv_more(ws_conn *w) -- one bounded read of the underlying
; transport straight into w->recv's spare capacity. 1 progress, 0 clean
; EOF, -1 error. Callers only invoke this once per event-loop iteration,
; after poll() (or SSL_pending) said the socket had bytes -- never in a
; retry loop -- so this never blocks waiting for bytes that were never
; announced as ready.
%define RM_W -8
ws_recv_more:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp+RM_W], rdi
    mov rax, [rbp+RM_W]
    lea rdi, [rax + ws_conn.recv]
    mov esi, 16384
    call buf_reserve
    test eax, eax
    jz .fail
    mov rcx, [rbp+RM_W]
    lea rdx, [rcx + ws_conn.recv]
    mov r8, [rdx + buf.data]
    add r8, [rdx + buf.len]
    lea rdi, [rcx + ws_conn.conn]
    mov rsi, r8
    mov edx, 16384
    call convex_conn_read_some
    cmp rax, 0
    jl .fail
    jz .eof
    mov rcx, [rbp+RM_W]
    lea rdx, [rcx + ws_conn.recv]
    add [rdx + buf.len], rax
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
%undef RM_W

; int ws_take_frame(ws_conn *w, u64 *opcode_out, u64 *fin_out,
;                    u8 **payload_out, u64 *len_out)
; Parses exactly one frame from whatever is already buffered in w->recv
; starting at w->recv_off -- never reads the socket itself. 1 = a frame was
; parsed (payload_out is a fresh malloc'd copy the caller owns, or 0 for a
; zero-length payload), 0 = not enough buffered yet, -1 = the peer violated
; the framing (a masked server frame, a nonzero RSV bit, or a declared
; length over WS_MAX_MESSAGE_BYTES).
%define TF_W       -8
%define TF_OPOUT   -16
%define TF_FINOUT  -24
%define TF_PLOUT   -32
%define TF_LENOUT  -40
%define TF_AVAIL   -48
%define TF_BASE    -56       ; recv.data + recv_off, this call's fixed view
%define TF_BYTE0   -64
%define TF_BYTE1   -72
%define TF_HDRLEN  -80
%define TF_PLEN    -88
ws_take_frame:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    mov [rbp+TF_W], rdi
    mov [rbp+TF_OPOUT], rsi
    mov [rbp+TF_FINOUT], rdx
    mov [rbp+TF_PLOUT], rcx
    mov [rbp+TF_LENOUT], r8

    mov rax, [rdi + ws_conn.recv + buf.len]
    sub rax, [rdi + ws_conn.recv_off]
    mov [rbp+TF_AVAIL], rax
    cmp rax, 2
    jb .need_more
    mov rcx, [rdi + ws_conn.recv + buf.data]
    add rcx, [rdi + ws_conn.recv_off]
    mov [rbp+TF_BASE], rcx
    movzx eax, byte [rcx]
    mov [rbp+TF_BYTE0], rax
    movzx eax, byte [rcx+1]
    mov [rbp+TF_BYTE1], rax

    mov rax, [rbp+TF_BYTE0]
    and rax, 0x70
    jnz .protocol_error         ; a reserved bit is set; no extension is
                                 ; negotiated, so this can only be a bug or
                                 ; a peer speaking a different protocol
    mov rax, [rbp+TF_BYTE1]
    test rax, 0x80
    jnz .protocol_error         ; a compliant server never masks its frames

    mov rax, [rbp+TF_BYTE1]
    and rax, 0x7F
    cmp rax, 126
    jb .short_plen
    je .mid_plen
    ; 127: 8-byte extended length
    cmp qword [rbp+TF_AVAIL], 10
    jb .need_more
    xor rax, rax
    xor rcx, rcx
.ext64_loop:
    cmp rcx, 8
    jae .ext64_done
    mov rdx, [rbp+TF_BASE]
    movzx r8d, byte [rdx + 2 + rcx]
    shl rax, 8
    or rax, r8
    inc rcx
    jmp .ext64_loop
.ext64_done:
    mov [rbp+TF_PLEN], rax
    mov dword [rbp+TF_HDRLEN], 10
    jmp .have_lengths
.mid_plen:
    cmp qword [rbp+TF_AVAIL], 4
    jb .need_more
    mov rdx, [rbp+TF_BASE]
    movzx eax, byte [rdx+2]
    shl eax, 8
    movzx ecx, byte [rdx+3]
    or eax, ecx
    mov [rbp+TF_PLEN], rax
    mov dword [rbp+TF_HDRLEN], 4
    jmp .have_lengths
.short_plen:
    mov [rbp+TF_PLEN], rax
    mov dword [rbp+TF_HDRLEN], 2
.have_lengths:
    cmp qword [rbp+TF_PLEN], WS_MAX_MESSAGE_BYTES
    ja .protocol_error
    mov eax, [rbp+TF_HDRLEN]
    add rax, [rbp+TF_PLEN]      ; total bytes this frame needs
    cmp rax, [rbp+TF_AVAIL]
    ja .need_more

    ; have a complete frame: copy the payload out, advance recv_off
    mov rax, [rbp+TF_PLEN]
    test rax, rax
    jz .zero_payload
    mov rdi, rax
    call malloc
    test rax, rax
    jz .oom
    mov rdi, rax
    mov rsi, [rbp+TF_BASE]
    add rsi, [rbp+TF_HDRLEN]
    mov rdx, [rbp+TF_PLEN]
    call memcpy
    mov rcx, [rbp+TF_PLOUT]
    mov [rcx], rax
    jmp .have_copy
.zero_payload:
    mov rcx, [rbp+TF_PLOUT]
    mov qword [rcx], 0
.have_copy:
    mov rcx, [rbp+TF_OPOUT]
    mov rax, [rbp+TF_BYTE0]
    and rax, 0x0F
    mov [rcx], rax
    mov rcx, [rbp+TF_FINOUT]
    mov rax, [rbp+TF_BYTE0]
    shr rax, 7
    and rax, 1
    mov [rcx], rax
    mov rcx, [rbp+TF_LENOUT]
    mov rax, [rbp+TF_PLEN]
    mov [rcx], rax

    mov rdi, [rbp+TF_W]
    mov eax, [rbp+TF_HDRLEN]
    add rax, [rbp+TF_PLEN]
    add [rdi + ws_conn.recv_off], rax

    ; compact once the consumed prefix is either everything buffered or
    ; has grown past a modest threshold -- bounds how large w->recv can
    ; grow under a peer that sends many small frames back to back.
    mov rdi, [rbp+TF_W]
    mov rax, [rdi + ws_conn.recv_off]
    cmp rax, [rdi + ws_conn.recv + buf.len]
    je .compact
    cmp rax, 65536
    jb .parsed_ok
.compact:
    mov rdi, [rbp+TF_W]
    mov rax, [rdi + ws_conn.recv_off]
    test rax, rax
    jz .parsed_ok
    mov rsi, [rdi + ws_conn.recv + buf.data]
    mov rdx, [rdi + ws_conn.recv + buf.len]
    sub rdx, rax
    lea rcx, [rsi + rax]         ; source = data + recv_off
    mov [rbp+TF_BASE], rdx       ; stash remaining length across the call
    mov rdi, rsi
    mov rsi, rcx
    call memmove
    mov rdi, [rbp+TF_W]
    mov rax, [rbp+TF_BASE]
    mov [rdi + ws_conn.recv + buf.len], rax
    mov qword [rdi + ws_conn.recv_off], 0
.parsed_ok:
    mov eax, 1
    jmp .done
.oom:
    xor eax, eax
    jmp .protocol_error_ret
.need_more:
    xor eax, eax
    jmp .done
.protocol_error:
.protocol_error_ret:
    mov eax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef TF_W
%undef TF_OPOUT
%undef TF_FINOUT
%undef TF_PLOUT
%undef TF_LENOUT
%undef TF_AVAIL
%undef TF_BASE
%undef TF_BYTE0
%undef TF_BYTE1
%undef TF_HDRLEN
%undef TF_PLEN

; int ws_pump_message(ws_conn *w, u64 *kind_out, u8 **data_out,
;                      u64 *len_out)
; Consumes as many already-buffered frames as it takes to either produce
; one complete, UTF-8-checked message, observe a Close, run out of
; buffered bytes, or hit a framing error. Never touches the socket -- see
; ws_recv_more's contract. Ping/Pong are handled transparently and never
; surface to the caller; a Ping received mid-fragmentation is answered
; immediately without disturbing the in-progress reassembly, which is
; exactly the interleaving RFC 6455 requires receivers to tolerate.
; Returns: 1 = message ready (*kind_out is WS_OP_TEXT or WS_OP_BIN),
; 2 = peer sent Close, 0 = need more bytes, -1 = protocol error.
%define PM_W      -8
%define PM_KOUT   -16
%define PM_DOUT   -24
%define PM_LOUT   -32
%define PM_OPCODE -40
%define PM_FIN    -48
%define PM_PAYLOAD -56
%define PM_PLEN   -64
ws_pump_message:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [rbp+PM_W], rdi
    mov [rbp+PM_KOUT], rsi
    mov [rbp+PM_DOUT], rdx
    mov [rbp+PM_LOUT], rcx
.loop:
    mov rdi, [rbp+PM_W]
    lea rsi, [rbp+PM_OPCODE]
    lea rdx, [rbp+PM_FIN]
    lea rcx, [rbp+PM_PAYLOAD]
    lea r8, [rbp+PM_PLEN]
    call ws_take_frame
    cmp eax, 0
    je .need_more
    cmp eax, -1
    je .error

    mov rax, [rbp+PM_OPCODE]
    cmp rax, WS_OP_PING
    je .on_ping
    cmp rax, WS_OP_PONG
    je .on_pong
    cmp rax, WS_OP_CLOSE
    je .on_close
    cmp rax, WS_OP_TEXT
    je .on_data_start
    cmp rax, WS_OP_BIN
    je .on_data_start
    cmp rax, WS_OP_CONT
    je .on_cont
    jmp .free_and_error         ; unknown opcode

.on_ping:
    mov rdi, [rbp+PM_W]
    mov esi, WS_OP_PONG
    mov rdx, [rbp+PM_PAYLOAD]
    mov rcx, [rbp+PM_PLEN]
    call ws_send_frame
    test eax, eax
    jz .free_and_error
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .loop
    mov rdi, rax
    call free
    jmp .loop

.on_pong:
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .loop
    mov rdi, rax
    call free
    jmp .loop

.on_close:
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .close_no_payload
    mov rdi, rax
    call free
.close_no_payload:
    mov eax, 2
    jmp .done

.on_data_start:
    mov rdi, [rbp+PM_W]
    mov rax, [rdi + ws_conn.assembling]
    test rax, rax
    jnz .free_and_error          ; a new data frame while one is already
                                  ; in flight is not valid WS framing
    mov rax, [rbp+PM_FIN]
    test rax, rax
    jz .start_fragment
    ; single-frame message
    mov rax, [rbp+PM_OPCODE]
    cmp rax, WS_OP_TEXT
    jne .single_ready
    mov rdi, [rbp+PM_PAYLOAD]
    mov rsi, [rbp+PM_PLEN]
    call utf8_validate
    test eax, eax
    jz .free_and_error
.single_ready:
    mov rcx, [rbp+PM_KOUT]
    mov rax, [rbp+PM_OPCODE]
    mov [rcx], rax
    mov rcx, [rbp+PM_DOUT]
    mov rax, [rbp+PM_PAYLOAD]
    mov [rcx], rax
    mov rcx, [rbp+PM_LOUT]
    mov rax, [rbp+PM_PLEN]
    mov [rcx], rax
    mov eax, 1
    jmp .done
.start_fragment:
    mov rdi, [rbp+PM_W]
    mov qword [rdi + ws_conn.assembling], 1
    mov rax, [rbp+PM_OPCODE]
    mov [rdi + ws_conn.asm_opcode], rax
    lea rdi, [rdi + ws_conn.asmbuf]
    call buf_free
    mov rdi, [rbp+PM_W]
    lea rdi, [rdi + ws_conn.asmbuf]
    call buf_init
    mov rax, [rbp+PM_PLEN]
    test rax, rax
    jz .fragment_appended
    mov rdi, [rbp+PM_W]
    lea rdi, [rdi + ws_conn.asmbuf]
    mov rsi, [rbp+PM_PAYLOAD]
    mov rdx, [rbp+PM_PLEN]
    call buf_append
    test eax, eax
    jz .free_and_error
.fragment_appended:
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .loop
    mov rdi, rax
    call free
    jmp .loop

.on_cont:
    mov rdi, [rbp+PM_W]
    mov rax, [rdi + ws_conn.assembling]
    test rax, rax
    jz .free_and_error           ; a continuation with nothing in progress
    mov rax, [rbp+PM_PLEN]
    test rax, rax
    jz .cont_no_append
    mov rdi, [rbp+PM_W]
    lea rdi, [rdi + ws_conn.asmbuf]
    mov rsi, [rbp+PM_PAYLOAD]
    mov rdx, [rbp+PM_PLEN]
    call buf_append
    test eax, eax
    jz .free_and_error
.cont_no_append:
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .cont_no_free
    mov rdi, rax
    call free
.cont_no_free:
    mov rax, [rbp+PM_FIN]
    test rax, rax
    jz .loop                     ; more fragments still to come
    ; message complete: validate (if text) over the WHOLE reassembled
    ; buffer, exactly once -- never per fragment, which is the whole point
    ; of this state machine.
    mov rdi, [rbp+PM_W]
    mov rax, [rdi + ws_conn.asm_opcode]
    cmp rax, WS_OP_TEXT
    jne .cont_copy_out
    lea rsi, [rdi + ws_conn.asmbuf + buf.data]
    mov rdi, [rsi]
    mov rax, [rbp+PM_W]
    mov rsi, [rax + ws_conn.asmbuf + buf.len]
    call utf8_validate
    test eax, eax
    jz .assembling_error
.cont_copy_out:
    mov rax, [rbp+PM_W]
    mov rax, [rax + ws_conn.asmbuf + buf.len]
    test rax, rax
    jnz .cont_alloc
    mov rcx, [rbp+PM_DOUT]
    mov qword [rcx], 0
    jmp .cont_have_copy
.cont_alloc:
    mov rdi, rax
    call malloc
    test rax, rax
    jz .assembling_error
    ; Stash the fresh allocation in a frame slot (never a bare push/pop
    ; around a call: that would shift rsp by 8 for the duration of
    ; `call memcpy` and violate the 16-byte-aligned-at-call-sites
    ; invariant every function in this client relies on -- see
    ; convex_buf.s's header comment for the crash that taught this rule).
    mov [rbp+PM_PAYLOAD], rax
    mov rdi, rax
    mov rcx, [rbp+PM_W]
    mov rsi, [rcx + ws_conn.asmbuf + buf.data]
    mov rdx, [rcx + ws_conn.asmbuf + buf.len]
    call memcpy
    mov rax, [rbp+PM_PAYLOAD]
    mov rcx, [rbp+PM_DOUT]
    mov [rcx], rax
.cont_have_copy:
    mov rcx, [rbp+PM_LOUT]
    mov rax, [rbp+PM_W]
    mov rax, [rax + ws_conn.asmbuf + buf.len]
    mov [rcx], rax
    mov rcx, [rbp+PM_KOUT]
    mov rax, [rbp+PM_W]
    mov rax, [rax + ws_conn.asm_opcode]
    mov [rcx], rax
    mov rax, [rbp+PM_W]
    mov qword [rax + ws_conn.assembling], 0
    lea rdi, [rax + ws_conn.asmbuf]
    call buf_free
    mov rax, [rbp+PM_W]
    lea rdi, [rax + ws_conn.asmbuf]
    call buf_init
    mov eax, 1
    jmp .done

.assembling_error:
    mov rax, [rbp+PM_W]
    mov qword [rax + ws_conn.assembling], 0
    lea rdi, [rax + ws_conn.asmbuf]
    call buf_free
    mov rax, [rbp+PM_W]
    lea rdi, [rax + ws_conn.asmbuf]
    call buf_init
    jmp .error

.free_and_error:
    mov rax, [rbp+PM_PAYLOAD]
    test rax, rax
    jz .error
    mov rdi, rax
    call free
.error:
    mov eax, -1
    jmp .done
.need_more:
    xor eax, eax
    jmp .done
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef PM_W
%undef PM_KOUT
%undef PM_DOUT
%undef PM_LOUT
%undef PM_OPCODE
%undef PM_FIN
%undef PM_PAYLOAD
%undef PM_PLEN

; --- UTF-8 validation --------------------------------------------------

; int utf8_validate(const u8 *p, u64 len) -- strict RFC 3629 validation:
; rejects overlong encodings, encoded surrogates (U+D800-U+DFFF), and
; anything past U+10FFFF. Called exactly once per reassembled WebSocket
; text message (see ws_pump_message above), never per fragment -- a
; message can (and, in this project's own test fixture, deliberately does)
; split a multi-byte character's bytes across a frame boundary, which
; would make each fragment individually invalid UTF-8 even though the
; concatenation is well-formed.
%define UV_P   -8
%define UV_LEN -16
%define UV_I   -24
utf8_validate:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp+UV_P], rdi
    mov [rbp+UV_LEN], rsi
    mov qword [rbp+UV_I], 0
.loop:
    mov rax, [rbp+UV_I]
    cmp rax, [rbp+UV_LEN]
    jae .valid
    mov rcx, [rbp+UV_P]
    movzx edx, byte [rcx + rax]
    cmp dl, 0x80
    jb .advance1                 ; ASCII
    cmp dl, 0xC2
    jb .invalid                  ; 0x80-0xC1: stray continuation or
                                  ; overlong 2-byte lead
    cmp dl, 0xE0
    jb .seq2
    cmp dl, 0xF0
    jb .seq3
    cmp dl, 0xF4
    jbe .seq4
    jmp .invalid
.seq2:
    mov rax, [rbp+UV_I]
    add rax, 1
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx edx, byte [rcx + rax]
    cmp dl, 0x80
    jb .invalid
    cmp dl, 0xBF
    ja .invalid
    mov rax, [rbp+UV_I]
    add rax, 2
    mov [rbp+UV_I], rax
    jmp .loop
.seq3:
    ; overlong/surrogate guard on the second byte, per its lead byte
    mov r9, rdx                  ; lead byte, preserved across the checks
    mov rax, [rbp+UV_I]
    add rax, 1
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx r8d, byte [rcx + rax]
    cmp r8b, 0x80
    jb .invalid
    cmp r8b, 0xBF
    ja .invalid
    cmp r9b, 0xE0
    jne .seq3_not_e0
    cmp r8b, 0xA0
    jb .invalid                  ; overlong
    jmp .seq3_second_ok
.seq3_not_e0:
    cmp r9b, 0xED
    jne .seq3_second_ok
    cmp r8b, 0xA0
    jae .invalid                  ; encodes a UTF-16 surrogate
.seq3_second_ok:
    mov rax, [rbp+UV_I]
    add rax, 2
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx r8d, byte [rcx + rax]
    cmp r8b, 0x80
    jb .invalid
    cmp r8b, 0xBF
    ja .invalid
    mov rax, [rbp+UV_I]
    add rax, 3
    mov [rbp+UV_I], rax
    jmp .loop
.seq4:
    mov r9, rdx
    mov rax, [rbp+UV_I]
    add rax, 1
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx r8d, byte [rcx + rax]
    cmp r8b, 0x80
    jb .invalid
    cmp r8b, 0xBF
    ja .invalid
    cmp r9b, 0xF0
    jne .seq4_not_f0
    cmp r8b, 0x90
    jb .invalid                  ; overlong
    jmp .seq4_second_ok
.seq4_not_f0:
    cmp r9b, 0xF4
    jne .seq4_second_ok
    cmp r8b, 0x90
    jae .invalid                  ; would encode past U+10FFFF
.seq4_second_ok:
    mov rax, [rbp+UV_I]
    add rax, 2
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx r8d, byte [rcx + rax]
    cmp r8b, 0x80
    jb .invalid
    cmp r8b, 0xBF
    ja .invalid
    mov rax, [rbp+UV_I]
    add rax, 3
    cmp rax, [rbp+UV_LEN]
    jae .invalid
    mov rcx, [rbp+UV_P]
    movzx r8d, byte [rcx + rax]
    cmp r8b, 0x80
    jb .invalid
    cmp r8b, 0xBF
    ja .invalid
    mov rax, [rbp+UV_I]
    add rax, 4
    mov [rbp+UV_I], rax
    jmp .loop
.advance1:
    mov rax, [rbp+UV_I]
    inc rax
    mov [rbp+UV_I], rax
    jmp .loop
.valid:
    mov eax, 1
    jmp .done
.invalid:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret
%undef UV_P
%undef UV_LEN
%undef UV_I

section .rodata
    b64_alphabet: db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    ws_guid: db "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ws_guid_len equ $ - ws_guid
    ws_req_get: db "GET /api/sync HTTP/1.1", 13, 10, 0
    ws_hdr_host: db "Host: ", 0
    ws_hdr_fixed: db "Upgrade: websocket", 13, 10, "Connection: Upgrade", 13, 10, "Sec-WebSocket-Version: 13", 13, 10, 0
    ws_hdr_key: db "Sec-WebSocket-Key: ", 0
    ws_hdr_client: db "Convex-Client: ", 0
    ws_hdr_accept_name: db "sec-websocket-accept:"
    ws_hdr_accept_name_len equ $ - ws_hdr_accept_name
    crlf2: db 13, 10
    header_terminator4: db 13, 10, 13, 10
    single_space1: db " "
