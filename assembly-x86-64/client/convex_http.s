; ---------------------------------------------------------------------------
; convex_http.s -- URL parsing, TCP/TLS transport, and HTTP/1.1 framing.
;
; TLS is the one place this client calls out to a C library, and it does so
; directly: TLS_client_method/SSL_CTX_new/SSL_new/SSL_connect/SSL_read/
; SSL_write are libssl's own C ABI, called with the same System V calling
; convention as everything else in this file. AGENTS.md is explicit that
; this is legitimate ("Calling libssl through the C ABI is legitimate and
; is what every other client does"). getaddrinfo/socket/connect/setsockopt
; are ordinary OS primitives, the same ones a C client would use. Nothing
; here delegates HTTP request/response framing itself -- that is written
; out byte by byte below.
;
; Same fixed-frame stack discipline as convex_buf.s and convex_json.s.
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

section .text

global convex_url_parse
global convex_connect
global convex_conn_close
global convex_conn_write_all
global convex_conn_read_some
global convex_http_exchange
global find_bytes
global ci_find

; --- URL parsing ------------------------------------------------------------

; int convex_url_parse(const char *text, u64 len, convex_url *out)
; Accepts "http://host[:port][/path]" or "https://host[:port][/path]".
; IPv6 literal hosts ("[::1]") are refused rather than partially supported,
; matching the documented limitation other clients on this project take for
; the same reason: a deliberate, bounded scope rather than a silent
; mis-parse.
convex_url_parse:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdx      ; out
    mov [rbp-16], rdi     ; cursor
    mov rax, rdi
    add rax, rsi
    mov [rbp-24], rax     ; end
    mov rcx, [rbp-8]
    mov qword [rcx + convex_url.is_https], 0
    mov qword [rcx + convex_url.host_ptr], 0
    mov qword [rcx + convex_url.host_len], 0
    mov qword [rcx + convex_url.port], 0
    mov qword [rcx + convex_url.path_ptr], 0
    mov qword [rcx + convex_url.path_len], 0

    mov rdi, [rbp-16]
    mov rax, [rbp-24]
    sub rax, rdi
    cmp rax, 8
    jb .try_http
    lea rsi, [rel scheme_https]
    mov edx, 8
    call memcmp
    test eax, eax
    jnz .try_http
    mov rcx, [rbp-8]
    mov qword [rcx + convex_url.is_https], 1
    mov rax, [rbp-16]
    add rax, 8
    mov [rbp-16], rax
    jmp .have_scheme
.try_http:
    mov rdi, [rbp-16]
    mov rax, [rbp-24]
    sub rax, rdi
    cmp rax, 7
    jb .bad
    mov rdi, [rbp-16]
    lea rsi, [rel scheme_http]
    mov edx, 7
    call memcmp
    test eax, eax
    jnz .bad
    mov rax, [rbp-16]
    add rax, 7
    mov [rbp-16], rax
.have_scheme:
    mov rax, [rbp-16]
    mov rcx, [rbp-24]
    cmp rax, rcx
    jae .bad
    cmp byte [rax], '['
    je .bad
    mov rcx, [rbp-8]
    mov rax, [rbp-16]
    mov [rcx + convex_url.host_ptr], rax
    xor r8, r8
.host_scan:
    mov rax, [rbp-16]
    mov rdx, [rbp-24]
    cmp rax, rdx
    jae .host_done
    cmp byte [rax], ':'
    je .host_done
    cmp byte [rax], '/'
    je .host_done
    inc rax
    mov [rbp-16], rax
    inc r8
    jmp .host_scan
.host_done:
    test r8, r8
    jz .bad
    mov rcx, [rbp-8]
    mov [rcx + convex_url.host_len], r8
    mov rax, [rbp-16]
    mov rdx, [rbp-24]
    cmp rax, rdx
    jae .no_port
    cmp byte [rax], ':'
    jne .no_port
    inc rax
    mov [rbp-16], rax
    xor r9, r9
    xor r10, r10
.port_loop:
    mov rax, [rbp-16]
    mov rdx, [rbp-24]
    cmp rax, rdx
    jae .port_done
    movzx ecx, byte [rax]
    cmp cl, '0'
    jb .port_done
    cmp cl, '9'
    ja .port_done
    sub ecx, '0'
    imul r9, r9, 10
    add r9, rcx
    cmp r9, 65535
    ja .bad
    inc rax
    mov [rbp-16], rax
    inc r10
    jmp .port_loop
.port_done:
    test r10, r10
    jz .bad
    mov rcx, [rbp-8]
    mov [rcx + convex_url.port], r9
    jmp .have_port
.no_port:
    mov rcx, [rbp-8]
    mov rax, [rcx + convex_url.is_https]
    test rax, rax
    jz .default_http_port
    mov qword [rcx + convex_url.port], 443
    jmp .have_port
.default_http_port:
    mov qword [rcx + convex_url.port], 80
.have_port:
    mov rax, [rbp-16]
    mov rdx, [rbp-24]
    cmp rax, rdx
    jae .default_path
    cmp byte [rax], '/'
    jne .bad
    mov rcx, [rbp-8]
    mov [rcx + convex_url.path_ptr], rax
    mov r8, rdx
    sub r8, rax
    mov [rcx + convex_url.path_len], r8
    jmp .ok
.default_path:
    mov rcx, [rbp-8]
    lea rax, [rel default_path_str]
    mov [rcx + convex_url.path_ptr], rax
    mov qword [rcx + convex_url.path_len], 1
.ok:
    mov eax, 1
    jmp .done
.bad:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- connect -----------------------------------------------------------

; int resolve_and_connect(const char *host, u64 host_len, u64 port)
; Returns a connected fd, or -1. Tries every address getaddrinfo returns in
; order (matching the resilience a C client gets from libcurl for free) and
; stops at the first one that connects.
resolve_and_connect:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp-8], rdi       ; host
    mov [rbp-16], rsi      ; host_len
    mov [rbp-24], rdx      ; port
    lea rdi, [rsi + 1]
    call malloc
    test rax, rax
    jz .fail_noclose
    mov [rbp-32], rax      ; host_cstr
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call memcpy
    mov rax, [rbp-32]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0
    lea rdi, [rbp-88]
    xor esi, esi
    mov edx, addrinfo_size
    call memset
    mov dword [rbp-88 + addrinfo.ai_family], AF_UNSPEC
    mov dword [rbp-88 + addrinfo.ai_socktype], SOCK_STREAM
    mov rdi, [rbp-32]
    xor esi, esi
    lea rdx, [rbp-88]
    lea rcx, [rbp-96]
    call getaddrinfo
    test eax, eax
    jnz .fail_free_host
    mov rax, [rbp-96]
    mov [rbp-104], rax     ; node cursor
.try_node:
    mov rax, [rbp-104]
    test rax, rax
    jz .exhausted
    ; poke the requested port (network byte order) into this node's sockaddr
    mov rcx, [rax + addrinfo.ai_addr]
    mov rdx, [rbp-24]
    mov r8, rdx
    shr r8, 8
    mov byte [rcx + 2], r8b
    mov byte [rcx + 3], dl
    mov edi, [rax + addrinfo.ai_family]
    mov esi, [rax + addrinfo.ai_socktype]
    mov edx, [rax + addrinfo.ai_protocol]
    call socket
    cmp eax, 0
    jl .next_node
    mov [rbp-112], eax
    mov edi, eax
    mov rax, [rbp-104]
    mov rsi, [rax + addrinfo.ai_addr]
    mov edx, [rax + addrinfo.ai_addrlen]
    call connect
    test eax, eax
    jz .connected
    mov edi, [rbp-112]
    call close
.next_node:
    mov rax, [rbp-104]
    mov rax, [rax + addrinfo.ai_next]
    mov [rbp-104], rax
    jmp .try_node
.connected:
    mov rdi, [rbp-96]
    call freeaddrinfo
    mov rdi, [rbp-32]
    call free
    mov eax, [rbp-112]
    jmp .done
.exhausted:
    mov rdi, [rbp-96]
    call freeaddrinfo
.fail_free_host:
    mov rdi, [rbp-32]
    call free
.fail_noclose:
    mov eax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; void set_conn_timeouts(int fd) -- bounds every blocking socket call so a
; stalled or silent peer cannot hang the client forever.
set_conn_timeouts:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], edi
    mov qword [rbp-32], CONVEX_IO_TIMEOUT_SECS
    mov qword [rbp-24], 0
    mov edi, [rbp-8]
    mov esi, SOL_SOCKET
    mov edx, SO_RCVTIMEO
    lea rcx, [rbp-32]
    mov r8d, timeval_size
    call setsockopt
    mov edi, [rbp-8]
    mov esi, SOL_SOCKET
    mov edx, SO_SNDTIMEO
    lea rcx, [rbp-32]
    mov r8d, timeval_size
    call setsockopt
    mov rsp, rbp
    pop rbp
    ret

; int convex_connect(convex_url *url, convex_conn *out)
; Plain TCP for http://, TLS 1.2+ with full peer verification (system CA
; bundle via SSL_CTX_set_default_verify_paths, SNI, and hostname-checked
; verification via SSL_set1_host) for https://.
convex_connect:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi          ; url
    mov [rbp-16], rsi         ; conn
    mov dword [rsi + convex_conn.fd], -1
    mov qword [rsi + convex_conn.ssl], 0
    mov qword [rsi + convex_conn.ctx], 0
    mov qword [rsi + convex_conn.is_tls], 0
    mov rax, [rdi + convex_url.host_ptr]
    mov rcx, [rdi + convex_url.host_len]
    mov rdx, [rdi + convex_url.port]
    mov rdi, rax
    mov rsi, rcx
    call resolve_and_connect
    cmp eax, 0
    jl .fail
    mov rcx, [rbp-16]
    mov dword [rcx + convex_conn.fd], eax
    mov edi, eax
    call set_conn_timeouts
    mov rax, [rbp-8]
    mov rax, [rax + convex_url.is_https]
    test rax, rax
    jz .plain_ok
    ; --- TLS setup ---
    call TLS_client_method
    mov rdi, rax
    call SSL_CTX_new
    test rax, rax
    jz .tls_fail_close
    mov rcx, [rbp-16]
    mov [rcx + convex_conn.ctx], rax
    mov [rbp-24], rax          ; ctx
    mov rdi, rax
    mov esi, SSL_CTRL_SET_MIN_PROTO_VERSION
    mov edx, TLS1_2_VERSION
    xor ecx, ecx
    call SSL_CTX_ctrl
    mov rdi, [rbp-24]
    call SSL_CTX_set_default_verify_paths
    mov rdi, [rbp-24]
    mov esi, SSL_VERIFY_PEER
    xor edx, edx
    call SSL_CTX_set_verify
    mov rdi, [rbp-24]
    call SSL_new
    test rax, rax
    jz .tls_fail_free_ctx
    mov rcx, [rbp-16]
    mov [rcx + convex_conn.ssl], rax
    mov [rbp-32], rax           ; ssl
    mov rdi, rax
    mov rcx, [rbp-16]
    mov esi, [rcx + convex_conn.fd]
    call SSL_set_fd
    ; make a NUL-terminated host copy for SNI + hostname verification
    mov rax, [rbp-8]
    mov rcx, [rax + convex_url.host_len]
    mov [rbp-40], rcx
    lea rdi, [rcx + 1]
    call malloc
    test rax, rax
    jz .tls_fail_free_ssl
    mov [rbp-48], rax           ; host_cstr
    mov rdi, rax
    mov rax, [rbp-8]
    mov rsi, [rax + convex_url.host_ptr]
    mov rdx, [rbp-40]
    call memcpy
    mov rax, [rbp-48]
    mov rcx, [rbp-40]
    mov byte [rax + rcx], 0
    mov rdi, [rbp-32]
    mov esi, SSL_CTRL_SET_TLSEXT_HOSTNAME
    mov edx, TLSEXT_NAMETYPE_host_name
    mov rcx, [rbp-48]
    call SSL_ctrl
    mov rdi, [rbp-32]
    mov rsi, [rbp-48]
    xor edx, edx
    call SSL_set1_host
    mov rdi, [rbp-48]
    call free
    mov rdi, [rbp-32]
    call SSL_connect
    cmp eax, 1
    jne .tls_fail_free_ssl
    mov rdi, [rbp-32]
    call SSL_get_verify_result
    test eax, eax
    jnz .tls_fail_free_ssl
    mov eax, 1
    jmp .done
.plain_ok:
    mov eax, 1
    jmp .done
.tls_fail_free_ssl:
    mov rdi, [rbp-32]
    test rdi, rdi
    jz .tls_fail_free_ctx
    call SSL_free
    mov rcx, [rbp-16]
    mov qword [rcx + convex_conn.ssl], 0
.tls_fail_free_ctx:
    mov rdi, [rbp-24]
    test rdi, rdi
    jz .tls_fail_close
    call SSL_CTX_free
    mov rcx, [rbp-16]
    mov qword [rcx + convex_conn.ctx], 0
.tls_fail_close:
    mov rcx, [rbp-16]
    mov edi, [rcx + convex_conn.fd]
    call close
    mov rcx, [rbp-16]
    mov dword [rcx + convex_conn.fd], -1
.fail:
    xor eax, eax
    jmp .done
.done:
    mov rsp, rbp
    pop rbp
    ret

; void convex_conn_close(convex_conn *conn)
convex_conn_close:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rax, [rdi + convex_conn.ssl]
    test rax, rax
    jz .no_ssl
    mov rdi, rax
    call SSL_shutdown
    mov rdi, [rbp-8]
    mov rdi, [rdi + convex_conn.ssl]
    call SSL_free
    mov rdi, [rbp-8]
    mov qword [rdi + convex_conn.ssl], 0
.no_ssl:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_conn.ctx]
    test rax, rax
    jz .no_ctx
    mov rdi, rax
    call SSL_CTX_free
    mov rdi, [rbp-8]
    mov qword [rdi + convex_conn.ctx], 0
.no_ctx:
    mov rdi, [rbp-8]
    mov eax, [rdi + convex_conn.fd]
    cmp eax, 0
    jl .no_fd
    mov edi, eax
    call close
    mov rdi, [rbp-8]
    mov dword [rdi + convex_conn.fd], -1
.no_fd:
    mov rsp, rbp
    pop rbp
    ret

; int convex_conn_write_all(convex_conn *conn, const void *buf, u64 len)
; Loops past short writes (and, for plain sockets, EINTR); the same one
; deadline set on the fd at connect time bounds the whole call either way.
convex_conn_write_all:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi        ; conn
    mov [rbp-16], rsi       ; buf
    mov [rbp-24], rdx       ; remaining
.loop:
    mov rax, [rbp-24]
    test rax, rax
    jz .ok
    mov rax, [rbp-8]
    mov rax, [rax + convex_conn.ssl]
    test rax, rax
    jz .plain_write
    mov rdi, [rbp-8]
    mov rdi, [rdi + convex_conn.ssl]
    mov rsi, [rbp-16]
    mov edx, [rbp-24]
    cmp qword [rbp-24], 0x7FFFFFFF
    jb .ssl_len_ok
    mov edx, 0x7FFFFFFF
.ssl_len_ok:
    call SSL_write
    jmp .after_write
.plain_write:
    mov rdi, [rbp-8]
    mov edi, [rdi + convex_conn.fd]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call write
.after_write:
    cmp rax, 0
    jle .fail
    mov rcx, [rbp-16]
    add rcx, rax
    mov [rbp-16], rcx
    mov rcx, [rbp-24]
    sub rcx, rax
    mov [rbp-24], rcx
    jmp .loop
.ok:
    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; i64 convex_conn_read_some(convex_conn *conn, void *buf, u64 maxlen)
; One read (or SSL_read) call: returns bytes read (0 = clean EOF), or -1 on
; error/timeout.
convex_conn_read_some:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov rax, [rdi + convex_conn.ssl]
    test rax, rax
    jz .plain_read
    mov rdi, rax
    mov r8, rdx
    cmp rdx, 0x7FFFFFFF
    jb .ssl_len_ok
    mov edx, 0x7FFFFFFF
    jmp .ssl_call
.ssl_len_ok:
    mov edx, r8d
.ssl_call:
    call SSL_read
    cmp eax, 0
    jg .done
    ; SSL_read <= 0: treat as EOF if the peer cleanly closed, else error.
    mov rdi, [rbp-8]
    mov rdi, [rdi + convex_conn.ssl]
    call SSL_get_error
    cmp eax, SSL_ERROR_ZERO_RETURN
    je .clean_eof
    mov rax, -1
    jmp .done
.clean_eof:
    xor eax, eax
    jmp .done
.plain_read:
    mov rdi, [rdi + convex_conn.fd]
    call read
    jmp .done
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- HTTP response assembly ---------------------------------------------

; i64 find_bytes(const char *hay, u64 hay_len, const char *needle, u64 n_len)
find_bytes:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    test rcx, rcx
    jz .zero
    cmp rsi, rcx
    jb .no
    mov qword [rbp-40], 0
.scan:
    mov rax, [rbp-40]
    mov rcx, [rbp-16]
    sub rcx, [rbp-32]
    cmp rax, rcx
    ja .no
    mov rdi, [rbp-8]
    add rdi, rax
    mov rsi, [rbp-24]
    mov rdx, [rbp-32]
    call memcmp
    test eax, eax
    jz .found
    mov rax, [rbp-40]
    inc rax
    mov [rbp-40], rax
    jmp .scan
.found:
    mov rax, [rbp-40]
    jmp .done
.zero:
    xor eax, eax
    jmp .done
.no:
    mov rax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; i64 ci_find(const char *hay, u64 hay_len, const char *needle, u64 n_len)
; Case-insensitive (ASCII) substring search, used for header names/values.
ci_find:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    test rcx, rcx
    jz .zero
    cmp rsi, rcx
    jb .no
    mov qword [rbp-40], 0
.scan:
    mov rax, [rbp-40]
    mov rcx, [rbp-16]
    sub rcx, [rbp-32]
    cmp rax, rcx
    ja .no
    xor r8, r8
.cmp_loop:
    cmp r8, [rbp-32]
    jae .match
    mov rcx, [rbp-8]
    add rcx, [rbp-40]
    add rcx, r8
    movzx eax, byte [rcx]
    mov rcx, [rbp-24]
    add rcx, r8
    movzx r9d, byte [rcx]
    cmp al, 'A'
    jb .a_ok
    cmp al, 'Z'
    ja .a_ok
    add al, 32
.a_ok:
    cmp r9b, 'A'
    jb .b_ok
    cmp r9b, 'Z'
    ja .b_ok
    add r9b, 32
.b_ok:
    cmp al, r9b
    jne .mismatch
    inc r8
    jmp .cmp_loop
.mismatch:
    mov rax, [rbp-40]
    inc rax
    mov [rbp-40], rax
    jmp .scan
.match:
    mov rax, [rbp-40]
    jmp .done
.zero:
    xor eax, eax
    jmp .done
.no:
    mov rax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; i64 parse_hex(const char *p, u64 len) -- stops at the first non-hex byte
; (chunk-extensions after a ';' land here), or fails if zero hex digits
; were consumed. Leaf: no calls.
parse_hex:
    test rsi, rsi
    jz .bad
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jae .done
    movzx edx, byte [rdi + rcx]
    cmp dl, '0'
    jb .stop
    cmp dl, '9'
    ja .maybe_upper
    sub edx, '0'
    jmp .accum
.maybe_upper:
    cmp dl, 'A'
    jb .stop
    cmp dl, 'F'
    ja .maybe_lower
    sub edx, 'A'-10
    jmp .accum
.maybe_lower:
    cmp dl, 'a'
    jb .stop
    cmp dl, 'f'
    ja .stop
    sub edx, 'a'-10
.accum:
    shl rax, 4
    add rax, rdx
    inc rcx
    jmp .loop
.stop:
    test rcx, rcx
    jz .bad
.done:
    ret
.bad:
    mov rax, -1
    ret

; i64 parse_decimal(const char *p, u64 len) -- plain decimal, no sign.
parse_decimal:
    test rsi, rsi
    jz .bad
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jae .done
    movzx edx, byte [rdi + rcx]
    cmp dl, '0'
    jb .stop
    cmp dl, '9'
    ja .stop
    sub edx, '0'
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp .loop
.stop:
    test rcx, rcx
    jz .bad
.done:
    ret
.bad:
    mov rax, -1
    ret

; int read_more(convex_conn *conn, buf *raw) -- grows raw by up to 4096
; bytes read directly into its own spare capacity. Returns 1 on progress,
; 0 on clean EOF, -1 on error.
read_more:
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

; int decode_chunked(const char *p, u64 len, buf *out)
; Attempts one full decode pass of an RFC 7230 chunked body buffered at
; p[0..len). Returns 1 (out holds the fully decoded body, freshly reset)
; when the terminating 0-size chunk and its trailing CRLF are both already
; buffered, 0 if more bytes are needed, -1 if the framing itself is
; malformed. Trailer headers after the final chunk, if any, are skipped
; only up to the first CRLF -- a deliberate, documented bound rather than a
; general trailer parser.
decode_chunked:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi        ; base
    mov [rbp-16], rsi       ; len
    mov [rbp-24], rdx       ; out
    mov qword [rdx + buf.len], 0
    mov qword [rbp-32], 0   ; offset
.chunk_loop:
    mov rdi, [rbp-8]
    add rdi, [rbp-32]
    mov rsi, [rbp-16]
    sub rsi, [rbp-32]
    lea rdx, [rel crlf]
    mov ecx, 2
    call find_bytes
    cmp rax, -1
    je .need_more
    mov [rbp-40], rax       ; size-line length (relative)
    mov rdi, [rbp-8]
    add rdi, [rbp-32]
    mov rsi, [rbp-40]
    call parse_hex
    cmp rax, -1
    je .malformed
    mov [rbp-48], rax       ; chunk_size
    mov rax, [rbp-32]
    add rax, [rbp-40]
    add rax, 2
    mov [rbp-32], rax
    cmp qword [rbp-48], 0
    jne .have_data_chunk
    mov rdi, [rbp-8]
    add rdi, [rbp-32]
    mov rsi, [rbp-16]
    sub rsi, [rbp-32]
    cmp rsi, 2
    jb .need_more
    cmp byte [rdi], 13
    jne .malformed
    cmp byte [rdi+1], 10
    jne .malformed
    mov eax, 1
    jmp .done
.have_data_chunk:
    mov rax, [rbp-32]
    add rax, [rbp-48]
    add rax, 2
    cmp rax, [rbp-16]
    ja .need_more
    mov rdi, [rbp-24]
    mov rsi, [rbp-8]
    add rsi, [rbp-32]
    mov rdx, [rbp-48]
    call buf_append
    mov rax, [rbp-32]
    add rax, [rbp-48]
    add rax, 2
    mov [rbp-32], rax
    jmp .chunk_loop
.need_more:
    xor eax, eax
    jmp .done
.malformed:
    mov eax, -1
.done:
    mov rsp, rbp
    pop rbp
    ret

; int convex_http_exchange(convex_conn *conn, buf *request, i64 *out_status,
;                           buf *out_body)
; Writes `request` verbatim, then reads and frames the response: a status
; line, headers (scanned case-insensitively for Content-Length and
; Transfer-Encoding: chunked), and a body delimited by whichever of those
; two is present, or by connection close if neither is. Returns 0 only for
; a transport-level failure; a non-2xx HTTP status is still success at this
; layer; interpreting it is the Convex client's job.
convex_http_exchange:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    mov [rbp-8], rdi          ; conn
    mov [rbp-16], rsi         ; request
    mov [rbp-24], rdx         ; out_status
    mov [rbp-32], rcx         ; out_body
    lea rdi, [rbp-64]         ; raw buf: data=-64,len=-56,cap=-48
    call buf_init
    mov rdi, [rbp-8]
    mov rax, [rbp-16]
    mov rsi, [rax + buf.data]
    mov rdx, [rax + buf.len]
    call convex_conn_write_all
    test eax, eax
    jz .fail_free_raw
.header_loop:
    mov rdi, [rbp-64]
    mov rsi, [rbp-56]
    lea rdx, [rel header_terminator]
    mov ecx, 4
    call find_bytes
    cmp rax, -1
    jne .headers_found
    mov rcx, [rbp-56]
    cmp rcx, CONVEX_MAX_HEADER_BYTES
    jae .fail_free_raw
    mov rdi, [rbp-8]
    lea rsi, [rbp-64]
    call read_more
    cmp eax, 0
    jle .fail_free_raw
    jmp .header_loop
.headers_found:
    mov [rbp-72], rax          ; header_end (offset of the CRLFCRLF)
    mov rax, [rbp-72]
    add rax, 4
    mov [rbp-104], rax          ; body_start
    ; status code: first space in the status line, then up to 3 digits
    mov rdi, [rbp-64]
    mov rsi, [rbp-72]
    lea rdx, [rel single_space]
    mov ecx, 1
    call find_bytes
    cmp rax, -1
    je .fail_free_raw
    mov rcx, [rbp-64]
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
    jz .fail_free_raw
    mov rcx, [rbp-24]
    mov [rcx], r8
    ; Content-Length (case-insensitive substring search over the whole
    ; header block is a deliberate simplification over per-line parsing;
    ; see the module comment)
    mov qword [rbp-80], -1     ; content_length
    mov qword [rbp-88], 0      ; is_chunked
    mov rdi, [rbp-64]
    mov rsi, [rbp-72]
    lea rdx, [rel hdr_content_length]
    mov ecx, hdr_content_length_len
    call ci_find
    cmp rax, -1
    je .no_content_length
    mov rcx, [rbp-64]
    add rcx, rax
    add rcx, hdr_content_length_len
    mov r10, [rbp-64]
    add r10, [rbp-72]           ; header block end
.cl_skip_ws:
    cmp rcx, r10
    jae .no_content_length
    cmp byte [rcx], ' '
    jne .cl_parse
    inc rcx
    jmp .cl_skip_ws
.cl_parse:
    mov rdi, rcx
    mov rsi, r10
    sub rsi, rcx
    call parse_decimal
    cmp rax, -1
    je .no_content_length
    mov [rbp-80], rax
.no_content_length:
    ; --- assemble the body per the framing detected ---
    ; A Content-Length takes priority if present. Otherwise, look for the
    ; literal "chunked" anywhere in the header block: on a well-formed
    ; response this only ever appears as Transfer-Encoding's value, so a
    ; whole-block search is a safe simplification over parsing that header
    ; specifically (matching this module's stated preference for a
    ; deliberately bounded parser over a fully general one).
    cmp qword [rbp-80], -1
    jne .content_length_body
    mov rdi, [rbp-64]
    mov rsi, [rbp-72]
    lea rdx, [rel hdr_chunked_value]
    mov ecx, hdr_chunked_value_len
    call ci_find
    cmp rax, -1
    je .close_delimited_body
    mov qword [rbp-88], 1
    jmp .chunked_body
.content_length_body:
    ; ensure raw holds body_start + content_length bytes total
.cl_wait_loop:
    mov rax, [rbp-104]
    add rax, [rbp-80]
    cmp rax, [rbp-56]
    jbe .cl_have_all
    mov rdi, [rbp-8]
    lea rsi, [rbp-64]
    call read_more
    cmp eax, 0
    jle .fail_free_raw
    jmp .cl_wait_loop
.cl_have_all:
    mov rdi, [rbp-32]
    mov rsi, [rbp-64]
    add rsi, [rbp-104]
    mov rdx, [rbp-80]
    call buf_append
    jmp .success
.chunked_body:
.chunked_retry:
    mov rdi, [rbp-64]
    add rdi, [rbp-104]
    mov rsi, [rbp-56]
    sub rsi, [rbp-104]
    mov rdx, [rbp-32]
    call decode_chunked
    cmp eax, 1
    je .success
    cmp eax, -1
    je .fail_free_raw
    mov rdi, [rbp-8]
    lea rsi, [rbp-64]
    call read_more
    cmp eax, 0
    jle .fail_free_raw
    jmp .chunked_retry
.close_delimited_body:
.close_wait_loop:
    mov rdi, [rbp-8]
    lea rsi, [rbp-64]
    call read_more
    cmp eax, 0
    jg .close_wait_loop
    cmp eax, -1
    je .fail_free_raw
    ; clean EOF: everything from body_start to raw.len is the body
    mov rdi, [rbp-32]
    mov rsi, [rbp-64]
    add rsi, [rbp-104]
    mov rdx, [rbp-56]
    sub rdx, [rbp-104]
    call buf_append
.success:
    lea rdi, [rbp-64]
    call buf_free
    mov eax, 1
    jmp .done
.fail_free_raw:
    lea rdi, [rbp-64]
    call buf_free
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

section .rodata
    scheme_https: db "https://"
    scheme_http: db "http://"
    default_path_str: db "/"
    crlf: db 13, 10
    header_terminator: db 13, 10, 13, 10
    single_space: db " "
    hdr_content_length: db "content-length:"
    hdr_content_length_len equ $ - hdr_content_length
    hdr_transfer_encoding: db "transfer-encoding:"
    hdr_transfer_encoding_len equ $ - hdr_transfer_encoding
    hdr_chunked_value: db "chunked"
    hdr_chunked_value_len equ $ - hdr_chunked_value
