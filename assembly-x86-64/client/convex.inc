; ---------------------------------------------------------------------------
; convex.inc -- shared struct layouts, constants and extern declarations for
; the native x86-64 Convex client. This file is textually included (%include)
; into every client/*.s translation unit; it defines no code of its own.
;
; Calling convention throughout: System V AMD64 (integer/pointer args in rdi,
; rsi, rdx, rcx, r8, r9, return in rax, 16-byte stack alignment at `call`,
; caller-saved rax/rcx/rdx/rsi/rdi/r8-r11, callee-saved rbx/rbp/r12-r15).
; Every one of *our* functions below follows this convention so client code,
; the adapter and libc/libssl calls compose without extra glue.
; ---------------------------------------------------------------------------

%ifndef CONVEX_INC
%define CONVEX_INC

; --- libc primitives (memory, string, process, sockets) -------------------
; These are ordinary OS/runtime primitives, not Convex or JSON logic -- the
; same primitives a C client would get from libc. Every byte of HTTP framing,
; WebSocket framing, NDJSON and JSON handling below is hand-written assembly.
extern malloc
extern realloc
extern free
extern memcpy
extern memmove
extern memset
extern memcmp
extern strlen
extern socket
extern connect
extern shutdown
extern close
extern write
extern read
extern poll
extern clock_gettime
extern getenv
extern exit
extern __errno_location
extern getaddrinfo
extern freeaddrinfo
extern setsockopt
extern strncmp
extern bind
extern listen
extern accept
extern inet_pton
extern atoi
extern gnu_get_libc_version

; --- sockets / addrinfo (glibc x86-64 layouts; OS primitives, not Convex
; or HTTP logic) --------------------------------------------------------
AF_UNSPEC    equ 0
AF_INET      equ 2
AF_INET6     equ 10
SOCK_STREAM  equ 1
SOL_SOCKET   equ 1
SO_RCVTIMEO  equ 20
SO_SNDTIMEO  equ 21

struc addrinfo
    .ai_flags:    resd 1
    .ai_family:   resd 1
    .ai_socktype: resd 1
    .ai_protocol: resd 1
    .ai_addrlen:  resd 1
    .ai_pad:      resd 1  ; glibc pads here so ai_addr lands 8-byte aligned
    .ai_addr:     resq 1
    .ai_canonname: resq 1
    .ai_next:     resq 1
endstruc

; struct timeval, for SO_RCVTIMEO/SO_SNDTIMEO
struc timeval
    .tv_sec:  resq 1
    .tv_usec: resq 1
endstruc

; struct sockaddr_in, for the adapter's ADAPTER_LISTEN bind/accept.
struc sockaddr_in
    .sin_family: resw 1
    .sin_port:   resw 1
    .sin_addr:   resd 1
    .sin_zero:   resb 8
endstruc

X509_V_OK equ 0
SSL_ERROR_ZERO_RETURN equ 6

; Transport bounds: how long a single blocking socket call may take, and how
; many bytes of response headers this client will buffer before giving up
; on a peer that never sends a terminator.
CONVEX_IO_TIMEOUT_SECS equ 30
CONVEX_MAX_HEADER_BYTES equ 65536

; --- libssl / libcrypto (TLS only; called directly via the C ABI) ---------
extern TLS_client_method
extern SSL_CTX_new
extern SSL_CTX_free
extern SSL_CTX_set_verify
extern SSL_CTX_set_default_verify_paths
extern SSL_CTX_ctrl              ; SSL_CTX_set_min_proto_version is a macro
                                  ; over this in this OpenSSL, not its own
                                  ; exported symbol -- confirmed by reading
                                  ; openssl/ssl.h in the build image rather
                                  ; than assuming the friendly wrapper name
                                  ; resolves at link time.
extern SSL_new
extern SSL_free
extern SSL_set_fd
extern SSL_ctrl                  ; used for the SNI hostname control call
extern SSL_set1_host             ; hostname verification target
extern SSL_get_verify_result
extern SSL_connect
extern SSL_read
extern SSL_write
extern SSL_shutdown
extern SSL_get_error
extern RAND_bytes                ; randomness for WS masking keys / run ids
extern SHA1                      ; one-shot SHA-1 for the WS handshake accept

; SSL_CTX_set_verify(ctx, mode, callback=NULL)
SSL_VERIFY_PEER          equ 1
; SSL_ctrl opcode for setting the TLSEXT SNI hostname (openssl/ssl.h)
SSL_CTRL_SET_TLSEXT_HOSTNAME equ 55
TLSEXT_NAMETYPE_host_name equ 0
; TLS1_2_VERSION from openssl/tls1.h
TLS1_2_VERSION equ 0x0303
; SSL_CTX_ctrl opcode for the minimum negotiated protocol version
SSL_CTRL_SET_MIN_PROTO_VERSION equ 123

; --- JSON value tags --------------------------------------------------------
JV_NULL   equ 0
JV_FALSE  equ 1
JV_TRUE   equ 2
JV_INT    equ 3
JV_DOUBLE equ 4
JV_STRING equ 5
JV_ARRAY  equ 6
JV_OBJECT equ 7

; json_value: a tagged node. Every variant uses a fixed-size 48 byte record
; so arrays of nodes (object entries hold a pointer, not an inline node) are
; simple to index. Unused fields for a given tag are left zero.
struc json_value
    .tag:    resq 1   ; one of JV_* above (kept qword-sized for alignment)
    .ival:   resq 1   ; JV_INT: signed 64-bit value
    .dval:   resq 1   ; JV_DOUBLE: IEEE-754 bit pattern
    .ptr:    resq 1   ; JV_STRING: char*; JV_ARRAY: json_value**; JV_OBJECT: entries*
    .len:    resq 1   ; JV_STRING: byte length; JV_ARRAY/OBJECT: element count
    .cap:    resq 1   ; JV_ARRAY/OBJECT: allocated element capacity
endstruc

; json_entry: one key/value pair inside a JV_OBJECT's entry array.
struc json_entry
    .key_ptr: resq 1
    .key_len: resq 1
    .value:   resq 1  ; json_value*
endstruc

; json_ctx: parser cursor and safety-valve counters, threaded through every
; recursive-descent call by pointer so the guards apply to the whole parse.
struc json_ctx
    .p:     resq 1   ; current read position
    .end:   resq 1   ; one past the last valid byte
    .depth: resq 1   ; current container nesting depth
    .nodes: resq 1   ; total json_value nodes allocated so far
    .err:   resq 1   ; nonzero once any rule below is violated
endstruc

JSON_MAX_DEPTH equ 128     ; matches the nesting bound documented elsewhere
JSON_MAX_NODES equ 200000  ; generous but bounded against pathological input

; buf: a growable byte buffer used for building HTTP requests, WS frames and
; serialized JSON text.
struc buf
    .data: resq 1
    .len:  resq 1
    .cap:  resq 1
endstruc

; convex_conn: one connected transport (plain TCP or TLS-wrapped).
struc convex_conn
    .fd:      resq 1   ; socket fd, or -1 when closed
    .ssl:     resq 1   ; SSL*, or 0 for plaintext connections
    .ctx:     resq 1   ; SSL_CTX*, or 0 for plaintext connections
    .is_tls:  resq 1   ; 1 if this connection is wrapped in TLS
endstruc

; convex_url: a parsed deployment URL (scheme://host[:port][/path]).
struc convex_url
    .is_https: resq 1
    .host_ptr: resq 1
    .host_len: resq 1
    .port:     resq 1
    .path_ptr: resq 1  ; may be zero-length; never includes trailing text
    .path_len: resq 1
endstruc

; convex_error: mirrors the adapter/example error shape (name + message).
; A zero name_len means "no error".
struc convex_error
    .name_ptr: resq 1
    .name_len: resq 1
    .msg_ptr:  resq 1
    .msg_len:  resq 1
    .data:     resq 1  ; json_value* structured error data, or 0
endstruc

; convex_client: the handle returned by convex_new. url_text_owned is the
; client's own malloc'd copy of the deployment URL; convex_url's pointers
; inside .url point into that copy (not the caller's buffer), so the
; caller's original string may be freed or reused immediately after
; convex_new returns -- matching the C client's `duplicate(url)` contract.
struc convex_client
    .url:        resb convex_url_size
    .url_text_owned: resq 1
    .user_agent_ptr: resq 1
    .user_agent_len: resq 1
    .auth_ptr:   resq 1   ; current bearer token bytes, or 0
    .auth_len:   resq 1
endstruc

; convex_result: the decoded outcome of a successful convex_call.
struc convex_result
    .value: resq 1   ; json_value*, owned by the caller after the call
    .logs:  resq 1   ; json_value* (array) or 0 when the response omitted it
endstruc

CONVEX_OP_QUERY    equ 0
CONVEX_OP_MUTATION equ 1
CONVEX_OP_ACTION   equ 2

%endif ; CONVEX_INC
