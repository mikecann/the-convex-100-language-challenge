; ---------------------------------------------------------------------------
; convex_client.s -- the public Convex HTTP API: convex_new, convex_free,
; convex_set_auth, convex_call. This is Convex-specific protocol logic (the
; request envelope { path, args, format: "json" }, the response envelope
; { status, value, errorMessage, errorData, logLines }, and the /api/query,
; /api/mutation, /api/action routing), so unlike convex_http.s it delegates
; nothing to a library beyond the transport primitives already provided by
; convex_http.s.
;
; Ownership contract: convex_call takes ownership of the `args` json_value*
; passed to it (it becomes part of the request tree and is freed together
; with it) -- the caller must not read or free it afterward. This differs
; from the C client's refcounted borrow only because this project's JSON
; value model has no refcounting; it is documented here and in the README.
;
; Same fixed-frame stack discipline as the rest of this client.
; ---------------------------------------------------------------------------
default rel
%include "convex.inc"

extern buf_init
extern buf_free
extern buf_append
extern buf_append_byte
extern buf_append_cstr
extern buf_append_u64
extern json_new_object
extern json_new_string
extern json_new_int
extern json_object_set
extern json_object_get
extern json_free
extern json_parse
extern json_serialize
extern convex_url_parse
extern convex_connect
extern convex_conn_close
extern convex_http_exchange

section .text

global convex_new
global convex_free
global convex_set_auth
global convex_call
global find_and_null_entry

; convex_client *convex_new(const char *url, u64 url_len,
;                           const char *version, u64 version_len,
;                           convex_error *err)
convex_new:
    push rbp
    mov rbp, rsp
    sub rsp, 80
    mov [rbp-8], rdi           ; url
    mov [rbp-16], rsi          ; url_len
    mov [rbp-24], rdx          ; version
    mov [rbp-32], rcx          ; version_len
    mov [rbp-40], r8           ; err
    mov edi, convex_client_size
    call malloc
    test rax, rax
    jz .oom_bare
    mov [rbp-48], rax          ; client
    mov rax, [rbp-16]
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .oom_free_client
    mov [rbp-56], rax          ; url copy
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call memcpy
    mov rax, [rbp-56]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0
    mov rcx, [rbp-48]
    mov rax, [rbp-56]
    mov [rcx + convex_client.url_text_owned], rax
    mov rdi, rax
    mov rsi, [rbp-16]
    lea rdx, [rcx + convex_client.url]
    call convex_url_parse
    test eax, eax
    jz .bad_url
    mov rax, [rbp-32]
    test rax, rax
    jnz .have_version
    lea rax, [rel default_version]
    mov [rbp-24], rax
    mov qword [rbp-32], default_version_len
.have_version:
    mov rax, [rbp-32]
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .oom_free_urltext
    mov [rbp-64], rax          ; user-agent copy
    mov rdi, rax
    mov rsi, [rbp-24]
    mov rdx, [rbp-32]
    call memcpy
    mov rax, [rbp-64]
    mov rcx, [rbp-32]
    mov byte [rax + rcx], 0
    mov rcx, [rbp-48]
    mov rax, [rbp-64]
    mov [rcx + convex_client.user_agent_ptr], rax
    mov rdx, [rbp-32]
    mov [rcx + convex_client.user_agent_len], rdx
    mov qword [rcx + convex_client.auth_ptr], 0
    mov qword [rcx + convex_client.auth_len], 0
    mov rax, rcx
    jmp .done
.bad_url:
    mov rdi, [rbp-40]
    call set_error_bad_url
    mov rdi, [rbp-56]
    call free
    mov rdi, [rbp-48]
    call free
    xor eax, eax
    jmp .done
.oom_free_urltext:
    mov rdi, [rbp-56]
    call free
.oom_free_client:
    mov rdi, [rbp-48]
    call free
.oom_bare:
    mov rdi, [rbp-40]
    call set_error_oom
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; void convex_free(convex_client *c)
convex_free:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    test rdi, rdi
    jz .done
    mov [rbp-8], rdi
    mov rax, [rdi + convex_client.url_text_owned]
    test rax, rax
    jz .no_url
    mov rdi, rax
    call free
.no_url:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_client.user_agent_ptr]
    test rax, rax
    jz .no_ua
    mov rdi, rax
    call free
.no_ua:
    mov rdi, [rbp-8]
    mov rax, [rdi + convex_client.auth_ptr]
    test rax, rax
    jz .no_auth
    mov rdi, rax
    call free
.no_auth:
    mov rdi, [rbp-8]
    call free
.done:
    mov rsp, rbp
    pop rbp
    ret

; int convex_set_auth(convex_client *c, const char *token, u64 token_len,
;                      convex_error *err)
convex_set_auth:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov rax, [rdi + convex_client.auth_ptr]
    test rax, rax
    jz .no_old
    mov rdi, rax
    call free
    mov rcx, [rbp-8]
    mov qword [rcx + convex_client.auth_ptr], 0
    mov qword [rcx + convex_client.auth_len], 0
.no_old:
    mov rax, [rbp-24]
    test rax, rax
    jz .cleared
    lea rdi, [rax + 1]
    call malloc
    test rax, rax
    jz .oom
    mov rcx, [rbp-8]
    mov [rcx + convex_client.auth_ptr], rax
    mov rdi, rax
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    call memcpy
    mov rcx, [rbp-8]
    mov rax, [rcx + convex_client.auth_ptr]
    mov rdx, [rbp-24]
    mov byte [rax + rdx], 0
    mov [rcx + convex_client.auth_len], rdx
.cleared:
    mov eax, 1
    jmp .done
.oom:
    mov rdi, [rbp-32]
    call set_error_oom
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- error helpers (not global; internal to this file) --------------------

set_error_oom:
    test rdi, rdi
    jz .done
    lea rax, [rel err_name_error]
    mov [rdi + convex_error.name_ptr], rax
    mov qword [rdi + convex_error.name_len], err_name_error_len
    lea rax, [rel err_msg_oom]
    mov [rdi + convex_error.msg_ptr], rax
    mov qword [rdi + convex_error.msg_len], err_msg_oom_len
    mov qword [rdi + convex_error.data], 0
.done:
    ret

set_error_bad_url:
    test rdi, rdi
    jz .done
    lea rax, [rel err_name_error]
    mov [rdi + convex_error.name_ptr], rax
    mov qword [rdi + convex_error.name_len], err_name_error_len
    lea rax, [rel err_msg_bad_url]
    mov [rdi + convex_error.msg_ptr], rax
    mov qword [rdi + convex_error.msg_len], err_msg_bad_url_len
    mov qword [rdi + convex_error.data], 0
.done:
    ret

; rdi=err, rsi=name_ptr, rdx=name_len, rcx=msg_ptr, r8=msg_len, r9=data
set_error_full:
    test rdi, rdi
    jz .done
    mov [rdi + convex_error.name_ptr], rsi
    mov [rdi + convex_error.name_len], rdx
    mov [rdi + convex_error.msg_ptr], rcx
    mov [rdi + convex_error.msg_len], r8
    mov [rdi + convex_error.data], r9
.done:
    ret

; int convex_call(convex_client *client, int op, const char *path,
;                  u64 path_len, json_value *args, convex_result *out,
;                  convex_error *err)   [err arrives on the stack: the 7th
;                  integer argument, at [rbp+16] once our own prologue has
;                  run, per the System V AMD64 ABI's stack-argument area]
convex_call:
    push rbp
    mov rbp, rsp
    sub rsp, 288
    mov [rbp-8], rdi            ; client
    mov [rbp-16], rsi           ; op
    mov [rbp-24], rdx           ; path
    mov [rbp-32], rcx           ; path_len
    mov [rbp-40], r8            ; args
    mov [rbp-48], r9            ; out
    mov rax, [rbp + 16]
    mov [rbp-56], rax           ; err
    mov qword [rbp-232], 0      ; connected flag

    mov rax, [rbp-40]
    test rax, rax
    jz .bad_args
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_OBJECT
    jne .bad_args

    mov rax, [rbp-16]
    cmp rax, CONVEX_OP_QUERY
    je .op_query
    cmp rax, CONVEX_OP_MUTATION
    je .op_mutation
    lea rax, [rel op_action]
    mov [rbp-104], rax
    mov qword [rbp-112], op_action_len
    jmp .have_op
.op_query:
    lea rax, [rel op_query]
    mov [rbp-104], rax
    mov qword [rbp-112], op_query_len
    jmp .have_op
.op_mutation:
    lea rax, [rel op_mutation]
    mov [rbp-104], rax
    mov qword [rbp-112], op_mutation_len
.have_op:
    call json_new_object
    test rax, rax
    jz .oom_bare
    mov [rbp-64], rax           ; request object

    mov rdi, [rbp-24]
    mov rsi, [rbp-32]
    call json_new_string
    test rax, rax
    jz .oom_free_request
    mov [rbp-120], rax
    mov rdi, [rbp-64]
    lea rsi, [rel key_path]
    mov edx, key_path_len
    mov rcx, [rbp-120]
    call json_object_set
    test eax, eax
    jz .oom_free_request_and_120

    mov rdi, [rbp-64]
    lea rsi, [rel key_args]
    mov edx, key_args_len
    mov rcx, [rbp-40]
    call json_object_set
    test eax, eax
    jz .oom_free_request_and_args

    lea rdi, [rel str_json]
    mov esi, str_json_len
    call json_new_string
    test rax, rax
    jz .oom_free_request
    mov [rbp-120], rax
    mov rdi, [rbp-64]
    lea rsi, [rel key_format]
    mov edx, key_format_len
    mov rcx, [rbp-120]
    call json_object_set
    test eax, eax
    jz .oom_free_request_and_120

    lea rdi, [rbp-96]           ; body buf
    call buf_init
    mov rdi, [rbp-64]
    lea rsi, [rbp-96]
    call json_serialize

    ; --- build the HTTP/1.1 request text ---
    lea rdi, [rbp-144]          ; reqtext buf
    call buf_init
    lea rdi, [rbp-144]
    lea rsi, [rel method_post]
    call buf_append_cstr
    lea rdi, [rbp-144]
    lea rsi, [rel path_api_prefix]
    call buf_append_cstr
    lea rdi, [rbp-144]
    mov rsi, [rbp-104]
    mov rdx, [rbp-112]
    call buf_append
    lea rdi, [rbp-144]
    lea rsi, [rel http_version_line]
    call buf_append_cstr
    lea rdi, [rbp-144]
    lea rsi, [rel hdr_host]
    call buf_append_cstr
    mov rcx, [rbp-8]
    lea rax, [rcx + convex_client.url]
    mov rsi, [rax + convex_url.host_ptr]
    mov rdx, [rax + convex_url.host_len]
    lea rdi, [rbp-144]
    call buf_append
    lea rdi, [rbp-144]
    mov esi, ':'
    call buf_append_byte
    mov rcx, [rbp-8]
    lea rax, [rcx + convex_client.url]
    mov rsi, [rax + convex_url.port]
    lea rdi, [rbp-144]
    call buf_append_u64
    lea rdi, [rbp-144]
    lea rsi, [rel crlf]
    mov edx, 2
    call buf_append
    lea rdi, [rbp-144]
    lea rsi, [rel hdr_static]
    call buf_append_cstr
    mov rcx, [rbp-8]
    mov rax, [rcx + convex_client.user_agent_ptr]
    test rax, rax
    jz .no_ua_header
    lea rdi, [rbp-144]
    lea rsi, [rel hdr_convex_client]
    call buf_append_cstr
    mov rcx, [rbp-8]
    mov rsi, [rcx + convex_client.user_agent_ptr]
    mov rdx, [rcx + convex_client.user_agent_len]
    lea rdi, [rbp-144]
    call buf_append
    lea rdi, [rbp-144]
    lea rsi, [rel crlf]
    mov edx, 2
    call buf_append
.no_ua_header:
    mov rcx, [rbp-8]
    mov rax, [rcx + convex_client.auth_ptr]
    test rax, rax
    jz .no_auth_header
    lea rdi, [rbp-144]
    lea rsi, [rel hdr_authorization]
    call buf_append_cstr
    mov rcx, [rbp-8]
    mov rsi, [rcx + convex_client.auth_ptr]
    mov rdx, [rcx + convex_client.auth_len]
    lea rdi, [rbp-144]
    call buf_append
    lea rdi, [rbp-144]
    lea rsi, [rel crlf]
    mov edx, 2
    call buf_append
.no_auth_header:
    lea rdi, [rbp-144]
    lea rsi, [rel hdr_content_length_prefix]
    call buf_append_cstr
    lea rdi, [rbp-144]
    mov rsi, [rbp-88]            ; body.len
    call buf_append_u64
    lea rdi, [rbp-144]
    lea rsi, [rel double_crlf]
    mov edx, 4
    call buf_append
    ; append the JSON body bytes
    mov rax, [rbp-96]            ; body.data
    mov rcx, [rbp-88]            ; body.len
    lea rdi, [rbp-144]
    mov rsi, rax
    mov rdx, rcx
    call buf_append

    lea rdi, [rbp-96]
    call buf_free

    ; --- connect and exchange ---
    mov rcx, [rbp-8]
    lea rdi, [rcx + convex_client.url]
    lea rsi, [rbp-176]           ; conn
    call convex_connect
    test eax, eax
    jz .transport_fail
    mov qword [rbp-232], 1

    lea rdi, [rbp-216]           ; response body buf
    call buf_init
    lea rdi, [rbp-176]
    lea rsi, [rbp-144]
    lea rdx, [rbp-184]           ; status
    lea rcx, [rbp-216]
    call convex_http_exchange
    test eax, eax
    jz .transport_fail_close

    lea rdi, [rbp-176]
    call convex_conn_close
    mov qword [rbp-232], 0

    lea rdi, [rbp-144]
    call buf_free

    ; parse the response JSON
    mov rax, [rbp-216]
    mov rdi, rax                 ; response.data
    mov rsi, [rbp-208]           ; response.len
    lea rdx, [rbp-224]
    call json_parse
    lea rdi, [rbp-216]
    call buf_free
    test eax, eax
    jz .protocol_bad_json

    mov rax, [rbp-224]           ; response value tree
    mov rdi, rax
    lea rsi, [rel key_status]
    mov edx, key_status_len
    call json_object_get
    mov [rbp-240], rax           ; status node

    mov rdi, [rbp-224]
    lea rsi, [rel key_value]
    mov edx, key_value_len
    call json_object_get
    mov [rbp-248], rax           ; value node (may be 0 -- absent key)

    mov rax, [rbp-240]
    test rax, rax
    jz .protocol_unknown_status
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .protocol_unknown_status

    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel status_success]
    mov ecx, status_success_len
    call bytes_equal
    test eax, eax
    jz .check_error_status

    ; success: require a "value" key to be present (matches the C client's
    ; has_value check -- Convex always includes it on success, and its
    ; absence would mean a malformed response)
    mov rax, [rbp-248]
    test rax, rax
    jnz .success_have_value
    ; value key genuinely absent (not JSON null, which would still be a
    ; non-zero json_value* of tag JV_NULL) -- treat as protocol error
    jmp .protocol_unknown_status
.success_have_value:
    mov rcx, [rbp-48]            ; out
    mov [rcx + convex_result.value], rax
    mov rdi, [rbp-224]
    lea rsi, [rel key_log_lines]
    mov edx, key_log_lines_len
    call json_object_get
    mov rcx, [rbp-48]
    mov [rcx + convex_result.logs], rax
    ; detach value/logs from the response tree before freeing it, then
    ; free the now-childless envelope plus "status"
    mov rdi, [rbp-224]
    call detach_and_free_envelope
    mov eax, 1
    jmp .done

.check_error_status:
    mov rdi, [rax + json_value.ptr]
    mov rsi, [rax + json_value.len]
    lea rdx, [rel status_error]
    mov ecx, status_error_len
    call bytes_equal
    test eax, eax
    jz .protocol_unknown_status

    mov rdi, [rbp-224]
    lea rsi, [rel key_error_message]
    mov edx, key_error_message_len
    call json_object_get
    mov [rbp-256], rax           ; errorMessage node (may be 0)

    mov rdi, [rbp-224]
    lea rsi, [rel key_error_data]
    mov edx, key_error_data_len
    call json_object_get
    mov [rbp-264], rax           ; errorData node (may be 0)

    mov rax, [rbp-256]
    test rax, rax
    jz .use_default_message
    mov rcx, [rax + json_value.tag]
    cmp rcx, JV_STRING
    jne .use_default_message
    mov rcx, [rax + json_value.ptr]
    mov [rbp-272], rcx
    mov rcx, [rax + json_value.len]
    mov [rbp-280], rcx
    jmp .have_message
.use_default_message:
    lea rax, [rel err_msg_function_default]
    mov [rbp-272], rax
    mov qword [rbp-280], err_msg_function_default_len
.have_message:
    mov rdi, [rbp-56]            ; err
    test rdi, rdi
    jz .error_status_no_err_out
    lea rsi, [rel err_name_function]
    mov edx, err_name_function_len
    mov rcx, [rbp-272]
    mov r8, [rbp-280]
    mov r9, [rbp-264]
    call set_error_full
.error_status_no_err_out:
    ; detach errorData (which set_error_full above already captured a
    ; pointer to on the caller's behalf) before freeing the envelope, so
    ; the caller's error->data subtree outlives this free.
    mov rdi, [rbp-224]
    call detach_error_data_and_free
    xor eax, eax
    jmp .done

.protocol_unknown_status:
.protocol_bad_json:
    mov rdi, [rbp-56]
    test rdi, rdi
    jz .protocol_no_err_out
    lea rsi, [rel err_name_protocol]
    mov edx, err_name_protocol_len
    lea rcx, [rel err_msg_protocol]
    mov r8, err_msg_protocol_len
    xor r9, r9
    call set_error_full
.protocol_no_err_out:
    mov rax, [rbp-224]
    test rax, rax
    jz .done_fail
    mov rdi, rax
    call json_free
    jmp .done_fail

.transport_fail_close:
    lea rdi, [rbp-176]
    call convex_conn_close
    mov qword [rbp-232], 0
.transport_fail:
    lea rdi, [rbp-144]
    call buf_free
    mov rdi, [rbp-56]
    test rdi, rdi
    jz .done_fail
    lea rsi, [rel err_name_transport]
    mov edx, err_name_transport_len
    lea rcx, [rel err_msg_transport]
    mov r8, err_msg_transport_len
    xor r9, r9
    call set_error_full
    jmp .done_fail

.oom_free_request_and_120:
    mov rdi, [rbp-120]
    call json_free
.oom_free_request:
    mov rdi, [rbp-64]
    call json_free
    jmp .oom_bare
.oom_free_request_and_args:
    ; json_object_set for "args" failed before taking ownership; the
    ; caller's args tree was never attached, so it is still theirs -- do
    ; not free it here, only the (otherwise empty) request shell.
    mov rdi, [rbp-64]
    call json_free
.oom_bare:
    mov rdi, [rbp-56]
    call set_error_oom
.bad_args:
    xor eax, eax
    jmp .done_fail
.done_fail:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; --- small internal helpers -------------------------------------------

; int bytes_equal(const char *a, u64 a_len, const char *b, u64 b_len)
bytes_equal:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    cmp rsi, rcx
    jne .no
    test rsi, rsi
    jz .yes
    ; memcmp wants (s1, s2, n); our own args are (a, a_len, b, b_len), so
    ; rdi is already s1=a but rsi/rdx must be reassembled into s2=b, n=len
    ; -- calling straight through without doing this was a real, previously
    ; shipped bug (rsi/rdx held a_len/b at that point, not b/len).
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

; void detach_and_free_envelope(json_value *response) -- frees every part
; of the response envelope except the "value" and "logLines" subtrees,
; which the caller already took ownership of.
detach_and_free_envelope:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    lea rsi, [rel key_value]
    mov edx, key_value_len
    call find_and_null_entry
    mov rdi, [rbp-8]
    lea rsi, [rel key_log_lines]
    mov edx, key_log_lines_len
    call find_and_null_entry
    mov rdi, [rbp-8]
    call json_free
    mov rsp, rbp
    pop rbp
    ret

; void detach_error_data_and_free(json_value *response) -- frees the
; response envelope except "errorData", which set_error_full already
; captured a pointer to.
detach_error_data_and_free:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    lea rsi, [rel key_error_data]
    mov edx, key_error_data_len
    call find_and_null_entry
    mov rdi, [rbp-8]
    call json_free
    mov rsp, rbp
    pop rbp
    ret

; void find_and_null_entry(json_value *obj, const char *key, u64 key_len)
; Walks obj's entries directly (rather than calling json_object_get) so the
; matching entry's `value` slot can be zeroed in place, preventing
; json_free from recursing into a subtree the caller now owns.
find_and_null_entry:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov rax, [rdi + json_value.ptr]
    mov [rbp-32], rax
    mov rax, [rdi + json_value.len]
    mov [rbp-40], rax
    mov qword [rbp-48], 0
.scan:
    mov rax, [rbp-48]
    cmp rax, [rbp-40]
    jae .done
    imul rax, rax, json_entry_size
    add rax, [rbp-32]
    mov rcx, [rax + json_entry.key_len]
    cmp rcx, [rbp-24]
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
    mov qword [rax + json_entry.value], 0
    jmp .done
.next:
    mov rax, [rbp-48]
    inc rax
    mov [rbp-48], rax
    jmp .scan
.done:
    mov rsp, rbp
    pop rbp
    ret

section .rodata
    default_version: db "assembly-x86-64-0.1.0"
    default_version_len equ $ - default_version
    op_query: db "query"
    op_query_len equ $ - op_query
    op_mutation: db "mutation"
    op_mutation_len equ $ - op_mutation
    op_action: db "action"
    op_action_len equ $ - op_action
    key_path: db "path"
    key_path_len equ $ - key_path
    key_args: db "args"
    key_args_len equ $ - key_args
    key_format: db "format"
    key_format_len equ $ - key_format
    str_json: db "json"
    str_json_len equ $ - str_json
    key_status: db "status"
    key_status_len equ $ - key_status
    key_value: db "value"
    key_value_len equ $ - key_value
    key_log_lines: db "logLines"
    key_log_lines_len equ $ - key_log_lines
    key_error_message: db "errorMessage"
    key_error_message_len equ $ - key_error_message
    key_error_data: db "errorData"
    key_error_data_len equ $ - key_error_data
    status_success: db "success"
    status_success_len equ $ - status_success
    status_error: db "error"
    status_error_len equ $ - status_error
    method_post: db "POST ", 0
    path_api_prefix: db "/api/", 0
    http_version_line: db " HTTP/1.1", 13, 10, 0
    hdr_host: db "Host: ", 0
    hdr_static: db "Content-Type: application/json", 13, 10, "Accept: application/json", 13, 10, "Connection: close", 13, 10, 0
    hdr_convex_client: db "Convex-Client: ", 0
    hdr_authorization: db "Authorization: Bearer ", 0
    hdr_content_length_prefix: db "Content-Length: ", 0
    crlf: db 13, 10
    double_crlf: db 13, 10, 13, 10
    err_name_error: db "Error"
    err_name_error_len equ $ - err_name_error
    err_msg_oom: db "out of memory"
    err_msg_oom_len equ $ - err_msg_oom
    err_msg_bad_url: db "invalid deployment URL"
    err_msg_bad_url_len equ $ - err_msg_bad_url
    err_name_transport: db "TransportError"
    err_name_transport_len equ $ - err_name_transport
    err_msg_transport: db "could not complete the HTTP request"
    err_msg_transport_len equ $ - err_msg_transport
    err_name_protocol: db "ProtocolError"
    err_name_protocol_len equ $ - err_name_protocol
    err_msg_protocol: db "HTTP response was not valid Convex JSON"
    err_msg_protocol_len equ $ - err_msg_protocol
    err_name_function: db "FunctionError"
    err_name_function_len equ $ - err_name_function
    err_msg_function_default: db "Convex function failed"
    err_msg_function_default_len equ $ - err_msg_function_default
