/* Convex client core for XPL.
 *
 * This file holds every Convex-specific behaviour: URL parsing, the HTTP
 * request/response cycle, and a hand written JSON scanner. XPL has no
 * module system, so the Docker build concatenates this file ahead of each
 * entry point (the conformance adapter, the canonical example, and the
 * language-local test program) before invoking the compiler -- the same
 * role a C header plus translation unit would play, done with `cat`
 * instead of `#include`.
 *
 * FFI policy: every EXTERNAL declaration below names a real POSIX socket
 * call or a real OpenSSL function. inline() is never used anywhere in this
 * client -- not even for a header include -- because sockaddr_in and
 * struct addrinfo are built and read entirely with corebyte()/coreword()
 * memory pokes at their well known glibc x86-64 offsets. All HTTP framing,
 * JSON encoding/decoding, and the Convex sync-profile request shape are
 * implemented as ordinary XPL statements.
 *
 * XPL has no recursion (nested procedures are compiled to C functions with
 * static locals, so a procedure cannot safely call itself) and no structs,
 * so the JSON scanner below is iterative: skip_value tracks nesting with a
 * plain integer depth counter rather than a parse tree, and callers that
 * only need to relay a JSON fragment (Convex call arguments, a result
 * value, log lines) copy the exact source bytes for that fragment instead
 * of rebuilding it from a decoded structure.
 */

declare FREESPACE literally '0x2000000';

declare AF_INET literally '2';
declare SOCK_STREAM literally '1';
declare IPPROTO_TCP literally '6';
declare SSL_VERIFY_PEER literally '1';
declare SSL_CTRL_SET_TLSEXT_HOSTNAME literally '55';
declare SSL_ERROR_WANT_READ literally '2';
declare SSL_ERROR_WANT_WRITE literally '3';
declare SSL_ERROR_ZERO_RETURN literally '6';

declare CONVEX_MAX_BODY literally '2097152';
declare RECV_BUF_SIZE literally '2101248';

/* ------------------------------------------------------------------ */
/* libc: sockets and DNS                                              */
/* ------------------------------------------------------------------ */

socket: procedure(domain, kind, protocol) fixed external;
    declare domain fixed, kind fixed, protocol fixed;
end socket;

connect: procedure(fd, addr, addrlen) fixed external;
    declare fd fixed, addr address, addrlen fixed;
end connect;

send: procedure(fd, buf, len, flags) fixed external;
    declare fd fixed, buf address, len fixed, flags fixed;
end send;

recv: procedure(fd, buf, len, flags) fixed external;
    declare fd fixed, buf address, len fixed, flags fixed;
end recv;

close: procedure(fd) fixed external;
    declare fd fixed;
end close;

getaddrinfo: procedure(node, service, hints, res) fixed external;
    declare node address, service address, hints address, res address;
end getaddrinfo;

freeaddrinfo: procedure(res) external;
    declare res address;
end freeaddrinfo;

getenv: procedure(name) address external;
    declare name address;
end getenv;

/* ------------------------------------------------------------------ */
/* OpenSSL: TLS transport                                             */
/* ------------------------------------------------------------------ */

TLS_client_method: procedure address external;
end TLS_client_method;

SSL_CTX_new: procedure(meth) address external;
    declare meth address;
end SSL_CTX_new;

SSL_CTX_set_default_verify_paths: procedure(ctx) fixed external;
    declare ctx address;
end SSL_CTX_set_default_verify_paths;

SSL_CTX_set_verify: procedure(ctx, mode, cb) external;
    declare ctx address, mode fixed, cb address;
end SSL_CTX_set_verify;

SSL_new: procedure(ctx) address external;
    declare ctx address;
end SSL_new;

SSL_set_fd: procedure(ssl, fd) fixed external;
    declare ssl address, fd fixed;
end SSL_set_fd;

SSL_set1_host: procedure(ssl, hostname) fixed external;
    declare ssl address, hostname address;
end SSL_set1_host;

SSL_ctrl: procedure(ssl, cmd, larg, parg) address external;
    declare ssl address, cmd fixed, larg fixed, parg address;
end SSL_ctrl;

SSL_connect: procedure(ssl) fixed external;
    declare ssl address;
end SSL_connect;

SSL_write: procedure(ssl, buf, len) fixed external;
    declare ssl address, buf address, len fixed;
end SSL_write;

SSL_read: procedure(ssl, buf, len) fixed external;
    declare ssl address, buf address, len fixed;
end SSL_read;

SSL_get_error: procedure(ssl, ret) fixed external;
    declare ssl address, ret fixed;
end SSL_get_error;

SSL_shutdown: procedure(ssl) fixed external;
    declare ssl address;
end SSL_shutdown;

SSL_free: procedure(ssl) external;
    declare ssl address;
end SSL_free;

SSL_CTX_free: procedure(ctx) external;
    declare ctx address;
end SSL_CTX_free;

/* ------------------------------------------------------------------ */
/* Global result / error state.                                       */
/*                                                                    */
/* XPL procedures return exactly one scalar value and cannot receive  */
/* array or struct out-parameters, so operations that report more     */
/* than one fact (a JSON span, a decoded error) publish the extra     */
/* facts through these globals immediately after returning. This      */
/* mirrors the errno convention: read the globals right after the     */
/* call that set them, before making another call that could reuse    */
/* them.                                                               */
/* ------------------------------------------------------------------ */

declare CRLF character(2);
declare LF character(1);

declare g_convex_url character(512);
declare g_convex_tls fixed;
declare g_convex_host character(256);
declare g_convex_port fixed;
declare g_convex_prefix character(256);
declare g_auth_token character(4096);
declare g_has_auth fixed;

declare g_span_start fixed, g_span_end fixed;
declare g_field_found fixed;

declare g_call_ok fixed;
declare g_value_json character;
declare g_logs_json character;
declare g_error_name character;
declare g_error_message character;
declare g_error_data_json character;
declare g_has_error_data fixed;

declare recvbuf(RECV_BUF_SIZE - 1) bit(8);

/* ------------------------------------------------------------------ */
/* Small general helpers                                              */
/* ------------------------------------------------------------------ */

/* Zero n bytes starting at base. Used to build sockaddr/addrinfo hint
   structures without ever touching a C struct declaration. */
zero_mem: procedure(base, n);
    declare base address, n fixed, i fixed;
    do i = 0 to n - 1;
        corebyte(base + i) = 0;
    end;
end zero_mem;

/* Length of a null terminated C string at an arbitrary address. */
cstrlen: procedure(base) fixed;
    declare base address, n fixed;
    n = 0;
    do while corebyte(base + n) ~= 0;
        n = n + 1;
    end;
    return n;
end cstrlen;

/* Wrap a null terminated C string (for example the result of getenv())
   as an XPL string without copying it. */
str_from_cstr: procedure(base) character;
    declare base address;
    if base = 0 then return '';
    return build_descriptor(cstrlen(base), base);
end str_from_cstr;

/* Read an environment variable into a fixed length buffer (so the
   result is null terminated and safe to pass to EXTERNAL calls) and
   return it as an XPL string. Returns '' when unset.

   Formal parameters may not be arrays in XPL, and a fixed length
   CHARACTER(n) is implemented as one -- passing "name" straight
   through would silently pass only its first byte. name is declared
   as an ordinary (dynamic, descriptor based) CHARACTER instead and
   copied into a local fixed buffer, which is what actually gets a
   null terminated address to hand to an EXTERNAL call. */
env_get: procedure(name) character;
    declare name character, buf character(128), p address;
    buf = name;
    p = getenv(addr(buf));
    return str_from_cstr(p);
end env_get;

/* Unsigned decimal integer found in s(start .. start+len-1). Non-digit
   bytes are treated as a malformed value and yield -1. */
parse_uint: procedure(s, start, len) fixed;
    declare s character, start fixed, len fixed, i fixed, v fixed, c fixed;
    if len <= 0 then return -1;
    v = 0;
    do i = 0 to len - 1;
        c = byte(s, start + i);
        if c < 48 | c > 57 then return -1;
        v = v * 10 + (c - 48);
    end;
    return v;
end parse_uint;

/* Case-insensitive ASCII byte compare of two equal-length spans. */
ieq_byte: procedure(a, b) fixed;
    declare a fixed, b fixed, la fixed, lb fixed;
    la = a;
    lb = b;
    if la >= 65 & la <= 90 then la = la + 32;
    if lb >= 65 & lb <= 90 then lb = lb + 32;
    if la = lb then return 1;
    return 0;
end ieq_byte;

/* True when s(start .. start+len-1) equals the literal ref, ignoring
   ASCII case. Used to find "Content-Length" regardless of how the peer
   capitalised it. */
ci_eq: procedure(s, start, len, ref) fixed;
    declare s character, start fixed, len fixed, ref character, i fixed;
    if len ~= length(ref) then return 0;
    do i = 0 to len - 1;
        if ieq_byte(byte(s, start + i), byte(ref, i)) = 0 then return 0;
    end;
    return 1;
end ci_eq;

/* Exact byte compare of s(start .. start+len-1) against the literal ref. */
raw_eq: procedure(s, start, len, ref) fixed;
    declare s character, start fixed, len fixed, ref character, i fixed;
    if len ~= length(ref) then return 0;
    do i = 0 to len - 1;
        if byte(s, start + i) ~= byte(ref, i) then return 0;
    end;
    return 1;
end raw_eq;

/* Append the UTF-8 encoding of a Unicode code point to a growing string.
   Used only by json_decode_string, which builds text for control fields
   (ids, paths, tokens, error messages); JSON payload fragments (call
   arguments, result values, log lines) are always relayed as raw source
   spans instead, so this never runs on the large-payload path. */
append_utf8: procedure(acc, cp) character;
    declare acc character, cp fixed, buf character(4);
    if cp < 0 then cp = 65533;
    if cp <= 127 then do;
        byte(buf, 0) = cp;
        return acc || substr(buf, 0, 1);
    end;
    if cp <= 2047 then do;
        byte(buf, 0) = 192 | shr(cp, 6);
        byte(buf, 1) = 128 | (cp & 63);
        return acc || substr(buf, 0, 2);
    end;
    if cp <= 65535 then do;
        byte(buf, 0) = 224 | shr(cp, 12);
        byte(buf, 1) = 128 | (shr(cp, 6) & 63);
        byte(buf, 2) = 128 | (cp & 63);
        return acc || substr(buf, 0, 3);
    end;
    byte(buf, 0) = 240 | shr(cp, 18);
    byte(buf, 1) = 128 | (shr(cp, 12) & 63);
    byte(buf, 2) = 128 | (shr(cp, 6) & 63);
    byte(buf, 3) = 128 | (cp & 63);
    return acc || substr(buf, 0, 4);
end append_utf8;

/* Value of one hex digit, or -1 for an invalid one. */
hex_digit: procedure(c) fixed;
    declare c fixed;
    if c >= 48 & c <= 57 then return c - 48;
    if c >= 97 & c <= 102 then return c - 97 + 10;
    if c >= 65 & c <= 70 then return c - 65 + 10;
    return -1;
end hex_digit;

/* Four hex digits starting at s(pos) as a 0..65535 code unit, or -1. */
hex4: procedure(s, pos) fixed;
    declare s character, pos fixed, i fixed, d fixed, v fixed;
    v = 0;
    do i = 0 to 3;
        d = hex_digit(byte(s, pos + i));
        if d < 0 then return -1;
        v = v * 16 + d;
    end;
    return v;
end hex4;

/* -------------------------------------------------------------------
   JSON scanner.

   These procedures walk a JSON text held in an XPL CHARACTER value
   using plain integer positions. skip_value tracks object/array
   nesting with an integer depth counter instead of building a parse
   tree -- XPL has neither structs nor recursion, and every caller in
   this client only ever needs either a decoded scalar (a short control
   field such as "op" or "path") or the exact source span of a larger
   fragment (call arguments, a result value, log lines), which it
   relays without ever materialising a tree.
   ------------------------------------------------------------------- */

json_skip_ws: procedure(s, i) fixed;
    declare s character, i fixed, c fixed;
    do while i < length(s);
        c = byte(s, i);
        if c ~= 32 & c ~= 9 & c ~= 10 & c ~= 13 then return i;
        i = i + 1;
    end;
    return i;
end json_skip_ws;

/* s(i) must be the opening quote of a JSON string. Returns the index
   just past the matching, unescaped closing quote. */
json_skip_string: procedure(s, i) fixed;
    declare s character, i fixed, n fixed, c fixed;
    n = length(s);
    i = i + 1;
    do while i < n & byte(s, i) ~= 34;
        c = byte(s, i);
        if c = 92 then i = i + 2;
        else i = i + 1;
    end;
    return i + 1;
end json_skip_string;

/* Returns the index just past the JSON value starting at or after s(i)
   (leading whitespace is skipped). Objects and arrays are skipped by
   depth counter; strings inside them are skipped whole first so a
   brace or bracket byte inside quoted text is never miscounted. */
json_skip_value: procedure(s, i) fixed;
    declare s character, i fixed, n fixed, c fixed, depth fixed, done fixed;
    n = length(s);
    i = json_skip_ws(s, i);
    if i >= n then return i;
    c = byte(s, i);
    if c = 34 then return json_skip_string(s, i);
    if c = 123 | c = 91 then do;
        depth = 1;
        i = i + 1;
        done = 0;
        do while depth > 0 & done = 0;
            if i >= n then done = 1;
            else do;
                c = byte(s, i);
                if c = 34 then i = json_skip_string(s, i);
                else do;
                    if c = 123 | c = 91 then depth = depth + 1;
                    else if c = 125 | c = 93 then depth = depth - 1;
                    i = i + 1;
                end;
            end;
        end;
        return i;
    end;
    /* number, true, false, or null: run to the next structural byte */
    done = 0;
    do while i < n & done = 0;
        c = byte(s, i);
        if c = 44 | c = 125 | c = 93 | c = 32 | c = 9 | c = 10 | c = 13
        then done = 1;
        else i = i + 1;
    end;
    return i;
end json_skip_value;

/* Decode the JSON string literal s(start .. end-1) (start is the
   opening quote, end is one past the closing quote, exactly the span
   json_skip_string returns) into a plain XPL string. */
json_decode_string: procedure(s, start, fin) character;
    declare s character, start fixed, fin fixed, i fixed, c fixed;
    declare out character, hi fixed, lo fixed, cp fixed;
    out = '';
    i = start + 1;
    do while i < fin - 1;
        c = byte(s, i);
        if c = 92 then do;
            c = byte(s, i + 1);
            if c = 34 then do; out = out || '"'; i = i + 2; end;
            else if c = 92 then do; out = out || '\'; i = i + 2; end;
            else if c = 47 then do; out = out || '/'; i = i + 2; end;
            else if c = 98 then do; out = append_utf8(out, 8); i = i + 2; end;
            else if c = 102 then do; out = append_utf8(out, 12); i = i + 2; end;
            else if c = 110 then do; out = append_utf8(out, 10); i = i + 2; end;
            else if c = 114 then do; out = append_utf8(out, 13); i = i + 2; end;
            else if c = 116 then do; out = append_utf8(out, 9); i = i + 2; end;
            else if c = 117 then do;
                hi = hex4(s, i + 2);
                if hi < 0 then hi = 65533;
                i = i + 6;
                if hi >= 55296 & hi <= 56319 & i + 1 < fin
                        & byte(s, i) = 92 & byte(s, i + 1) = 117 then do;
                    lo = hex4(s, i + 2);
                    if lo >= 56320 & lo <= 57343 then do;
                        cp = 65536 + shl(hi - 55296, 10) + (lo - 56320);
                        i = i + 6;
                    end;
                    else cp = hi;
                end;
                else cp = hi;
                out = append_utf8(out, cp);
            end;
            else do; out = out || substr(s, i + 1, 1); i = i + 2; end;
        end;
        else do;
            out = out || substr(s, i, 1);
            i = i + 1;
        end;
    end;
    return out;
end json_decode_string;

/* Append value (a plain XPL string) to acc as an escaped, quoted JSON
   string literal. Used only for control fields this client builds
   itself (ids it echoes back, the function path, synthesised error
   text); JSON payload fragments are relayed as raw spans instead. */
json_encode_string: procedure(acc, value) character;
    declare acc character, value character, i fixed, n fixed, c fixed;
    declare out character, hexbuf character(8);
    out = acc || '"';
    n = length(value);
    do i = 0 to n - 1;
        c = byte(value, i);
        if c = 34 then out = out || '\"';
        else if c = 92 then out = out || '\\';
        else if c = 10 then out = out || '\n';
        else if c = 13 then out = out || '\r';
        else if c = 9 then out = out || '\t';
        else if c < 32 then do;
            call xsprintf(hexbuf, '\u%4.4x', c);
            out = out || hexbuf;
        end;
        else out = out || substr(value, i, 1);
    end;
    return out || '"';
end json_encode_string;

/* Scan a flat JSON object whose body starts at s(i) (the character
   right after its opening '{') for member "key". On a match this sets
   g_span_start/g_span_end to the value's exact source span (so the
   caller can relay it verbatim) and returns 1; otherwise returns 0.
   Only top level members are visited -- exactly what every caller
   needs, since every object this client reads (adapter commands,
   Convex HTTP responses) is a flat record of known field names. */
json_find_member: procedure(s, i, key) fixed;
    declare s character, i fixed, key character, n fixed;
    declare keystart fixed, keyend fixed, valstart fixed, valend fixed;
    declare matched fixed, found fixed, more fixed;
    n = length(s);
    i = json_skip_ws(s, i);
    found = 0;
    more = 1;
    do while more = 1;
        if i >= n then more = 0;
        else if byte(s, i) = 125 then more = 0;
        else do;
            keystart = i;
            keyend = json_skip_string(s, i);
            matched = raw_eq(s, keystart + 1, keyend - keystart - 2, key);
            i = json_skip_ws(s, keyend);
            i = i + 1; /* colon */
            i = json_skip_ws(s, i);
            valstart = i;
            valend = json_skip_value(s, i);
            if matched = 1 then do;
                g_span_start = valstart;
                g_span_end = valend;
                found = 1;
            end;
            i = json_skip_ws(s, valend);
            if i < n & byte(s, i) = 44 then do;
                i = i + 1;
                i = json_skip_ws(s, i);
            end;
            else more = 0;
        end;
    end;
    return found;
end json_find_member;

/* First index in s(start .. fin-1) holding byte target, or -1. */
find_byte: procedure(s, start, fin, target) fixed;
    declare s character, start fixed, fin fixed, target fixed, i fixed;
    do i = start to fin - 1;
        if byte(s, i) = target then return i;
    end;
    return -1;
end find_byte;

/* ------------------------------------------------------------------ */
/* Convex deployment URL                                              */
/* ------------------------------------------------------------------ */

/* Split a CONVEX_URL of the form scheme://host[:port][/prefix] into
   g_convex_tls/g_convex_host/g_convex_port/g_convex_prefix. Returns 1
   on a recognised http(s) URL, 0 otherwise. */
convex_configure: procedure(url) fixed;
    declare url character, n fixed, i fixed;
    declare host_start fixed, host_end fixed, port_start fixed, plen fixed;
    n = length(url);
    if n >= 8 & raw_eq(url, 0, 8, 'https://') = 1 then do;
        g_convex_tls = 1;
        i = 8;
    end;
    else if n >= 7 & raw_eq(url, 0, 7, 'http://') = 1 then do;
        g_convex_tls = 0;
        i = 7;
    end;
    else return 0;
    host_start = i;
    do while i < n & byte(url, i) ~= 58 & byte(url, i) ~= 47;
        i = i + 1;
    end;
    host_end = i;
    if host_end = host_start then return 0;
    g_convex_host = substr(url, host_start, host_end - host_start);
    if i < n then
        if byte(url, i) = 58 then do;
            i = i + 1;
            port_start = i;
            do while i < n & byte(url, i) ~= 47;
                i = i + 1;
            end;
            g_convex_port = parse_uint(url, port_start, i - port_start);
            if g_convex_port <= 0 then return 0;
        end;
    if g_convex_port <= 0 then do;
        if g_convex_tls = 1 then g_convex_port = 443;
        else g_convex_port = 80;
    end;
    if i < n then g_convex_prefix = substr(url, i, n - i);
    else g_convex_prefix = '';
    plen = length(g_convex_prefix);
    if plen > 0 then
        if byte(g_convex_prefix, plen - 1) = 47 then
            g_convex_prefix = substr(g_convex_prefix, 0, plen - 1);
    return 1;
end convex_configure;

/* ------------------------------------------------------------------ */
/* TCP + TLS transport                                                */
/*                                                                     */
/* Each Convex HTTP call opens a fresh TLS connection and closes it    */
/* when the response has been read. DNS is resolved with getaddrinfo, */
/* restricted to IPv4/TCP with a hand-zeroed struct addrinfo hints     */
/* block; the resulting struct addrinfo and struct sockaddr_in are     */
/* read with coreword()/corelongword() at their fixed glibc x86-64     */
/* offsets rather than any inline() struct declaration.                */
/* ------------------------------------------------------------------ */

/* Connections are addressed by slot rather than by a single shared
   global: slot 0 is the short-lived connection convex_call opens and
   closes for one HTTP request/response, and slot 1 is the Live
   WebSocket connection, which stays open across many HTTP calls (for
   example the mutation between two subscription updates in the
   canonical example). Sharing one set of globals between them would
   let an HTTP call's transport_close silently sever a still-open Live
   connection out from under it -- exactly the bug that first made the
   example's second Live update time out. */
declare HTTP_SLOT literally '0';
declare WS_SLOT literally '1';
declare conn_fd(1) fixed;
declare conn_ssl(1) address;
declare conn_tls_ctx(1) address;

/* Opens a TCP connection to host:port in the given slot and, when
   use_tls = 1, completes a TLS handshake with certificate and
   hostname verification. On success sets conn_fd(slot) (and
   conn_ssl(slot), nonzero only when TLS was used) and returns 1;
   returns 0 on failure with g_error_message explaining why. The
   approved local backend used by verify/verify-all is plain HTTP, and
   the hosted target is HTTPS, so both paths through this client have
   to work: transport_write_all/transport_read_chunk below key off
   conn_ssl(slot) so every caller after this point is transport
   agnostic.

   host is an ordinary (dynamic) CHARACTER parameter, not a fixed
   length one -- see the comment on env_get for why a CHARACTER(n)
   formal parameter would silently truncate to one byte. It is copied
   into hostbuf, a genuine local fixed buffer, whose address is what
   every EXTERNAL call below actually needs: passing a CHARACTER value
   itself (fixed length or not) to an EXTERNAL parameter yields its
   descriptor, not the byte address of its text, so every raw pointer
   handed to libc or OpenSSL here is taken with addr(). */
transport_connect: procedure(host, port, use_tls, slot) fixed;
    declare host character, port fixed, use_tls fixed, slot fixed;
    declare hostbuf character(256);
    declare hints(47) bit(8), service character(16), hbase address;
    declare res address, rc fixed, ai_addr address, ai_addrlen fixed;
    declare meth address, ctx address, ssl address, fd fixed;

    hostbuf = host;
    hbase = addr(hints(0));
    call zero_mem(hbase, 48);
    coreword(hbase + 4) = AF_INET;
    coreword(hbase + 8) = SOCK_STREAM;
    coreword(hbase + 12) = IPPROTO_TCP;

    call xsprintf(service, '%d', port);
    res = 0;
    rc = getaddrinfo(addr(hostbuf), addr(service), hbase, addr(res));
    if rc ~= 0 | res = 0 then do;
        g_error_message = 'DNS lookup failed for ' || host;
        return 0;
    end;

    ai_addrlen = coreword(res + 16);
    ai_addr = corelongword(res + 24);

    fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if fd < 0 then do;
        call freeaddrinfo(res);
        g_error_message = 'socket() failed';
        return 0;
    end;

    rc = connect(fd, ai_addr, ai_addrlen);
    call freeaddrinfo(res);
    if rc ~= 0 then do;
        call close(fd);
        g_error_message = 'connect() failed to ' || host;
        return 0;
    end;

    conn_fd(slot) = fd;
    conn_ssl(slot) = 0;
    conn_tls_ctx(slot) = 0;
    if use_tls = 0 then return 1;

    meth = TLS_client_method;
    ctx = SSL_CTX_new(meth);
    if ctx = 0 then do;
        call close(fd);
        g_error_message = 'SSL_CTX_new failed';
        return 0;
    end;
    call SSL_CTX_set_default_verify_paths(ctx);
    call SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, 0);
    ssl = SSL_new(ctx);
    call SSL_set_fd(ssl, fd);
    rc = SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, addr(hostbuf));
    rc = SSL_set1_host(ssl, addr(hostbuf));
    rc = SSL_connect(ssl);
    if rc ~= 1 then do;
        call SSL_free(ssl);
        call SSL_CTX_free(ctx);
        call close(fd);
        g_error_message = 'TLS handshake failed with ' || host;
        return 0;
    end;
    conn_ssl(slot) = ssl;
    conn_tls_ctx(slot) = ctx;
    return 1;
end transport_connect;

transport_close: procedure(slot);
    declare slot fixed;
    if conn_ssl(slot) ~= 0 then do;
        call SSL_shutdown(conn_ssl(slot));
        call SSL_free(conn_ssl(slot));
        call SSL_CTX_free(conn_tls_ctx(slot));
    end;
    call close(conn_fd(slot));
    conn_ssl(slot) = 0;
    conn_fd(slot) = -1;
end transport_close;

/* Writes all of data over the connection in slot, looping on partial
   writes. saddr() is read once and only ever advanced by plain
   arithmetic afterwards (never re-derived mid-loop), because it is
   only valid until the next XPL string allocation, and this loop
   performs none. */
transport_write_all: procedure(data, slot) fixed;
    declare data character, slot fixed, p address;
    declare total fixed, written fixed, n fixed;
    total = length(data);
    p = saddr(data);
    written = 0;
    do while written < total;
        if conn_ssl(slot) ~= 0 then
            n = SSL_write(conn_ssl(slot), p + written, total - written);
        else n = send(conn_fd(slot), p + written, total - written, 0);
        if n <= 0 then return 0;
        written = written + n;
    end;
    return 1;
end transport_write_all;

/* Reads up to cap bytes into memory at base on the connection in slot.
   Returns the number of bytes read, or a value <= 0 on a clean close
   or error -- the same convention SSL_read uses, so every caller can
   treat both transports identically. */
transport_read_chunk: procedure(base, cap, slot) fixed;
    declare base address, cap fixed, slot fixed;
    if conn_ssl(slot) ~= 0 then return SSL_read(conn_ssl(slot), base, cap);
    return recv(conn_fd(slot), base, cap, 0);
end transport_read_chunk;

/* First index of a blank line (CRLFCRLF) in s, or -1 if not present
   yet. Re-scans from the start on every call; response headers are
   small so this costs nothing next to the network round trip. */
find_header_end: procedure(s) fixed;
    declare s character, n fixed, i fixed;
    n = length(s);
    i = 0;
    do while i + 3 < n;
        if byte(s, i) = 13 & byte(s, i + 1) = 10 & byte(s, i + 2) = 13
                & byte(s, i + 3) = 10 then return i + 4;
        i = i + 1;
    end;
    return -1;
end find_header_end;

declare g_hdr_val_start fixed;
declare g_hdr_val_end fixed;

/* Looks for header "name" (case-insensitively) among the header lines
   s(0 .. header_end-1) of an HTTP response or WebSocket upgrade
   response. On a match, sets g_hdr_val_start/g_hdr_val_end to its
   (whitespace trimmed) value span and returns 1; returns 0 if absent. */
find_header_value: procedure(s, header_end, name) fixed;
    declare s character, header_end fixed, name character;
    declare i fixed, line_start fixed, colon fixed, vs fixed, ve fixed;
    i = 0;
    do while i < header_end;
        line_start = i;
        do while i < header_end & byte(s, i) ~= 13;
            i = i + 1;
        end;
        colon = find_byte(s, line_start, i, 58);
        if colon >= 0 then
            if ci_eq(s, line_start, colon - line_start, name) = 1 then do;
                vs = colon + 1;
                do while vs < i & byte(s, vs) = 32;
                    vs = vs + 1;
                end;
                ve = i;
                do while ve > vs & byte(s, ve - 1) = 32;
                    ve = ve - 1;
                end;
                g_hdr_val_start = vs;
                g_hdr_val_end = ve;
                return 1;
            end;
        i = i + 2;
    end;
    return 0;
end find_header_value;

declare g_response_content_length fixed;

/* Looks for a Content-Length header among the header lines s(0 ..
   header_end-1) and stores its value in g_response_content_length.
   Returns 1 if found (and numeric), 0 otherwise. */
extract_content_length: procedure(s, header_end) fixed;
    declare s character, header_end fixed, v fixed;
    if find_header_value(s, header_end, 'Content-Length') = 0 then return 0;
    v = parse_uint(s, g_hdr_val_start, g_hdr_val_end - g_hdr_val_start);
    if v < 0 then return 0;
    g_response_content_length = v;
    return 1;
end extract_content_length;

declare g_resp_total fixed;
declare g_header_end fixed;

/* Reads a full HTTP response into recvbuf: headers, then either
   exactly Content-Length body bytes or, absent that header, every
   byte up to the peer closing the connection (this client always
   sends "Connection: close", so the peer is expected to close once
   its response is complete). Returns 1 on success. */
http_read_response: procedure fixed;
    declare n fixed, want_len fixed, have_cl fixed;
    declare closed fixed, ok fixed, base address, resp character;

    base = addr(recvbuf(0));
    g_resp_total = 0;
    g_header_end = -1;
    have_cl = 0;
    want_len = 0;
    closed = 0;
    ok = 0;

    do while ok = 0 & closed = 0 & g_resp_total < RECV_BUF_SIZE;
        n = transport_read_chunk(base + g_resp_total, RECV_BUF_SIZE - g_resp_total,
            HTTP_SLOT);
        if n > 0 then do;
            g_resp_total = g_resp_total + n;
            if g_header_end < 0 then do;
                resp = build_descriptor(g_resp_total, base);
                g_header_end = find_header_end(resp);
                if g_header_end >= 0 & have_cl = 0 then do;
                    have_cl = extract_content_length(resp, g_header_end);
                    if have_cl = 1 then
                        want_len = g_header_end + g_response_content_length;
                end;
            end;
            if g_header_end >= 0 & have_cl = 1 & g_resp_total >= want_len
            then ok = 1;
        end;
        else closed = 1;
    end;
    if g_header_end < 0 then return 0;
    if have_cl = 0 & closed = 0 then return 0;
    return 1;
end http_read_response;

/* ------------------------------------------------------------------ */
/* Convex HTTP call                                                    */
/* ------------------------------------------------------------------ */

/* Reads the flat top level JSON object in body and fills the g_call_*
   globals from its "status"/"value"/"errorMessage"/"errorData"/
   "logLines" members. Returns 1 for a successful call, 0 otherwise
   (including a malformed or unrecognised response, which is reported
   as a ProtocolError). */
parse_convex_response: procedure(body) fixed;
    declare body character, found fixed, status_text character;

    if length(body) = 0 then do;
        g_error_name = 'TransportError';
        g_error_message = 'HTTP response body was empty';
        return 0;
    end;
    if byte(body, 0) ~= 123 then do;
        g_error_name = 'TransportError';
        g_error_message = 'HTTP response was not JSON';
        return 0;
    end;

    found = json_find_member(body, 1, 'logLines');
    if found = 1 then
        g_logs_json = substr(body, g_span_start, g_span_end - g_span_start);
    else g_logs_json = '[]';

    found = json_find_member(body, 1, 'status');
    if found = 0 then do;
        g_error_name = 'ProtocolError';
        g_error_message = 'HTTP response has unknown Convex status';
        return 0;
    end;
    status_text = json_decode_string(body, g_span_start, g_span_end);

    if raw_eq(status_text, 0, length(status_text), 'success') = 1 then do;
        found = json_find_member(body, 1, 'value');
        if found = 0 then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'HTTP success response missing value';
            return 0;
        end;
        g_value_json = substr(body, g_span_start, g_span_end - g_span_start);
        g_call_ok = 1;
        return 1;
    end;

    if raw_eq(status_text, 0, length(status_text), 'error') = 1 then do;
        found = json_find_member(body, 1, 'errorMessage');
        if found = 1 then
            g_error_message = json_decode_string(body, g_span_start, g_span_end);
        else g_error_message = '';
        g_error_name = 'FunctionError';
        found = json_find_member(body, 1, 'errorData');
        if found = 1 then do;
            g_error_data_json = substr(body, g_span_start, g_span_end - g_span_start);
            g_has_error_data = 1;
        end;
        return 0;
    end;

    g_error_name = 'ProtocolError';
    g_error_message = 'HTTP response has unknown Convex status';
    return 0;
end parse_convex_response;

/* Performs one Convex HTTP call: op is "query", "mutation", or
   "action"; path is the plain (already decoded) function path;
   args_json is the exact source span of the caller's "args" JSON
   object, relayed unchanged into the request body. On return, exactly
   one of (g_call_ok = 1, g_value_json/g_logs_json set) or (g_call_ok
   = 0, g_error_name/g_error_message[/g_error_data_json] set) holds. */
convex_call: procedure(op, path, args_json) fixed;
    declare op character, path character, args_json character;
    declare body character, req character, resp character;
    declare path_line character(600), auth_header character(4200);

    g_call_ok = 0;
    g_value_json = 'null';
    g_logs_json = '[]';
    g_error_name = '';
    g_error_message = '';
    g_error_data_json = 'null';
    g_has_error_data = 0;

    body = '{"path":' || json_encode_string('', path) || ',"args":' ||
        args_json || ',"format":"json"}';
    if length(body) > CONVEX_MAX_BODY then do;
        g_error_name = 'ProtocolError';
        g_error_message = 'request body exceeds the maximum size';
        return 0;
    end;

    call xsprintf(path_line, 'POST %s/api/%s HTTP/1.1', g_convex_prefix, op);
    if length(g_auth_token) > 0 then
        call xsprintf(auth_header, 'Authorization: Bearer %s', g_auth_token);
    else auth_header = '';

    req = path_line || CRLF ||
        'Host: ' || g_convex_host || CRLF ||
        'Content-Type: application/json' || CRLF ||
        'Accept: application/json' || CRLF ||
        'Convex-Client: xpl-0.1.0' || CRLF ||
        'Connection: close' || CRLF ||
        'Content-Length: ' || length(body) || CRLF;
    if length(auth_header) > 0 then req = req || auth_header || CRLF;
    req = req || CRLF || body;

    if transport_connect(g_convex_host, g_convex_port, g_convex_tls, HTTP_SLOT) = 0
    then do;
        g_error_name = 'TransportError';
        return 0;
    end;
    if transport_write_all(req, HTTP_SLOT) = 0 then do;
        call transport_close(HTTP_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed writing the HTTP request';
        return 0;
    end;
    if http_read_response = 0 then do;
        call transport_close(HTTP_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed reading the HTTP response';
        return 0;
    end;
    call transport_close(HTTP_SLOT);

    resp = build_descriptor(g_resp_total, addr(recvbuf(0)));
    return parse_convex_response(substr(resp, g_header_end,
        g_resp_total - g_header_end));
end convex_call;

/* ------------------------------------------------------------------ */
/* Public entry points                                                 */
/* ------------------------------------------------------------------ */

/* Reads CONVEX_URL (required) and CONVEX_AUTH_TOKEN (optional) from
   the environment and configures the deployment endpoint. Must be
   called once before convex_call. Returns 1 on success; on failure
   g_error_name/g_error_message explain why. */
convex_init: procedure fixed;
    declare url character;
    byte(CRLF, 0) = 13;
    byte(CRLF, 1) = 10;
    byte(LF, 0) = 10;
    g_auth_token = '';
    url = env_get('CONVEX_URL');
    if length(url) = 0 then do;
        g_error_name = 'ProtocolError';
        g_error_message = 'CONVEX_URL is required';
        return 0;
    end;
    g_convex_url = url;
    if convex_configure(g_convex_url) = 0 then do;
        g_error_name = 'ProtocolError';
        g_error_message = 'CONVEX_URL is not a valid http(s) URL';
        return 0;
    end;
    url = env_get('CONVEX_AUTH_TOKEN');
    if length(url) > 0 then g_auth_token = url;
    return 1;
end convex_init;

/* Sets (or, given '', clears) the bearer token sent with every
   subsequent call. */
convex_set_auth: procedure(token);
    declare token character;
    g_auth_token = token;
end convex_set_auth;

/* ------------------------------------------------------------------ */
/* Live: WebSocket transport and the Convex sync protocol             */
/*                                                                     */
/* This client keeps at most one active subscription (queryId is      */
/* always 0), which is what the canonical example and the adapter's   */
/* single-subscription conformance path both need. Frame reads and    */
/* protocol-message handling run on the one thread that owns this     */
/* connection -- there is no concurrent access to the socket to guard */
/* against, since XPL has no way to call a function through a runtime */
/* computed pointer and therefore no threads of its own.              */
/* ------------------------------------------------------------------ */

declare SOL_SOCKET literally '1';
declare SO_RCVTIMEO literally '20';

setsockopt: procedure(fd, level, optname, optval, optlen) fixed external;
    declare fd fixed, level fixed, optname fixed, optval address, optlen fixed;
end setsockopt;

RAND_bytes: procedure(buf, num) fixed external;
    declare buf address, num fixed;
end RAND_bytes;

SHA1: procedure(d, n, md) address external;
    declare d address, n fixed, md address;
end SHA1;

EVP_EncodeBlock: procedure(t, f, dlen) fixed external;
    declare t address, f address, dlen fixed;
end EVP_EncodeBlock;

/* Sets a receive timeout on fd so a peer that stops sending (rather
   than closing) cannot block Live reads forever; transport_read_chunk
   then reports a timeout the same way it reports a closed connection. */
set_recv_timeout: procedure(fd, ms);
    declare fd fixed, ms fixed, tv(15) bit(8), tvbase address;
    tvbase = addr(tv(0));
    call zero_mem(tvbase, 16);
    corelongword(tvbase) = ms / 1000;
    corelongword(tvbase + 8) = (ms mod 1000) * 1000;
    call setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tvbase, 16);
end set_recv_timeout;

/* A version-4-ish UUID built from OpenSSL randomness. Convex only
   needs this to be unique per connection, not cryptographically
   unpredictable. */
make_uuid: procedure character;
    declare b(15) bit(8), bb address, out character(40);
    bb = addr(b(0));
    call RAND_bytes(bb, 16);
    b(6) = (b(6) & 15) | 64;
    b(8) = (b(8) & 63) | 128;
    call xsprintf(out,
        '%2.2x%2.2x%2.2x%2.2x-%2.2x%2.2x-%2.2x%2.2x-%2.2x%2.2x-%2.2x%2.2x%2.2x%2.2x%2.2x%2.2x',
        b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7),
        b(8), b(9), b(10), b(11), b(12), b(13), b(14), b(15));
    return out;
end make_uuid;

/* Sends one WebSocket frame carrying payload with the given opcode
   (1 = text, 10 = pong). Client frames must be masked (RFC 6455); the
   mask itself does not need to be unpredictable, only present, so a
   fresh 4 random bytes from OpenSSL is more than enough. payload is
   capped at 65535 bytes -- ample for the Connect/ModifyQuerySet
   control messages and pong echoes this client ever sends.

   The whole frame (header, mask, masked payload) is assembled with
   corebyte() into one raw buffer and wrapped with build_descriptor()
   exactly once, rather than through a CHARACTER(n) header value: a
   fixed length CHARACTER is converted to a plain CHARACTER by
   scanning for its first null byte, and a random mask byte can
   legitimately be zero, which would silently truncate the frame right
   inside the header or the mask. build_descriptor's explicit length
   sidesteps that scan entirely. */
ws_send_frame: procedure(opcode, payload) fixed;
    declare opcode fixed, payload character;
    declare n fixed, mask(3) bit(8), mbase address;
    declare hlen fixed, i fixed;
    declare framebuf(65551) bit(8), fbase address;

    n = length(payload);
    if n > 65535 then return 0;

    mbase = addr(mask(0));
    call RAND_bytes(mbase, 4);
    fbase = addr(framebuf(0));

    corebyte(fbase) = 128 | opcode;
    if n < 126 then do;
        corebyte(fbase + 1) = 128 | n;
        hlen = 2;
    end;
    else do;
        corebyte(fbase + 1) = 128 | 126;
        corebyte(fbase + 2) = shr(n, 8) & 255;
        corebyte(fbase + 3) = n & 255;
        hlen = 4;
    end;
    corebyte(fbase + hlen) = mask(0);
    corebyte(fbase + hlen + 1) = mask(1);
    corebyte(fbase + hlen + 2) = mask(2);
    corebyte(fbase + hlen + 3) = mask(3);
    hlen = hlen + 4;

    do i = 0 to n - 1;
        corebyte(fbase + hlen + i) = byte(payload, i) xor mask(i mod 4);
    end;

    return transport_write_all(build_descriptor(hlen + n, fbase), WS_SLOT);
end ws_send_frame;

/* Reads headers only (no body is expected -- either a "101 Switching
   Protocols" upgrade response, or an error response this client
   rejects outright), leaving any bytes already read past the blank
   line in recvbuf for ws_recv_message to pick up as the start of the
   frame stream. */
ws_read_handshake_response: procedure fixed;
    declare n fixed, base address, closed fixed;
    base = addr(recvbuf(0));
    g_resp_total = 0;
    g_header_end = -1;
    closed = 0;
    do while g_header_end < 0 & closed = 0 & g_resp_total < RECV_BUF_SIZE;
        n = transport_read_chunk(base + g_resp_total, RECV_BUF_SIZE - g_resp_total,
            WS_SLOT);
        if n > 0 then do;
            g_resp_total = g_resp_total + n;
            g_header_end = find_header_end(build_descriptor(g_resp_total, base));
        end;
        else closed = 1;
    end;
    if g_header_end < 0 then return 0;
    return 1;
end ws_read_handshake_response;

declare g_ws_total fixed;
declare g_ws_consumed fixed;
declare g_ws_message character;

/* Reclaims recvbuf once every byte read so far has been consumed by a
   parsed frame, so a long-lived subscription does not walk the buffer
   all the way to RECV_BUF_SIZE one small Transition at a time. */
ws_reclaim: procedure;
    if g_ws_consumed >= g_ws_total then do;
        g_ws_total = 0;
        g_ws_consumed = 0;
    end;
end ws_reclaim;

/* Ensures at least need unread bytes are buffered, reading more from
   the connection as necessary. Returns 0 on a closed connection, a
   read error, a read timeout, or the frame stream outgrowing recvbuf. */
ws_ensure: procedure(need) fixed;
    declare need fixed, base address, n fixed;
    base = addr(recvbuf(0));
    do while g_ws_total - g_ws_consumed < need;
        if g_ws_total >= RECV_BUF_SIZE then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'WebSocket frame stream exceeded the receive buffer';
            return 0;
        end;
        n = transport_read_chunk(base + g_ws_total, RECV_BUF_SIZE - g_ws_total, WS_SLOT);
        if n <= 0 then do;
            g_error_name = 'TransportError';
            g_error_message = 'WebSocket read failed, timed out, or the peer closed';
            return 0;
        end;
        g_ws_total = g_ws_total + n;
    end;
    return 1;
end ws_ensure;

/* Reads one complete WebSocket message into g_ws_message, transparently
   reassembling fin=0 continuation frames, replying to pings with a
   pong carrying the same payload, and skipping pongs. Returns 0 on a
   close frame, a masked server frame (a protocol violation -- RFC 6455
   requires the server never to mask), an oversized frame, a connection
   error, or a read timeout. */
ws_recv_message: procedure fixed;
    declare base address, b0 fixed, b1 fixed, fin fixed, opcode fixed;
    declare masked fixed, paylen fixed, hdrlen fixed;
    declare payload_start fixed, more fixed, message character;

    call ws_reclaim;
    message = '';
    more = 1;

    do while more = 1;
        if ws_ensure(2) = 0 then return 0;
        base = addr(recvbuf(0));
        b0 = corebyte(base + g_ws_consumed);
        b1 = corebyte(base + g_ws_consumed + 1);
        fin = b0 & 128;
        opcode = b0 & 15;
        masked = b1 & 128;
        paylen = b1 & 127;
        hdrlen = 2;
        if paylen = 126 then do;
            if ws_ensure(4) = 0 then return 0;
            base = addr(recvbuf(0));
            paylen = corebyte(base + g_ws_consumed + 2) * 256 +
                corebyte(base + g_ws_consumed + 3);
            hdrlen = 4;
        end;
        else if paylen = 127 then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'oversized WebSocket frame';
            return 0;
        end;
        if masked ~= 0 then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'server WebSocket frames must not be masked';
            return 0;
        end;
        if paylen > RECV_BUF_SIZE - 16 then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'WebSocket message too large';
            return 0;
        end;
        if ws_ensure(hdrlen + paylen) = 0 then return 0;
        base = addr(recvbuf(0));
        payload_start = g_ws_consumed + hdrlen;
        g_ws_consumed = g_ws_consumed + hdrlen + paylen;

        if opcode = 8 then do;
            call ws_reclaim;
            g_error_name = 'TransportError';
            g_error_message = 'WebSocket connection was closed by the peer';
            return 0;
        end;
        else if opcode = 9 then
            call ws_send_frame(10, build_descriptor(paylen, base + payload_start));
        else if opcode = 1 | opcode = 0 then do;
            message = message || build_descriptor(paylen, base + payload_start);
            if fin ~= 0 then do;
                g_ws_message = message;
                more = 0;
            end;
        end;
        else if opcode ~= 10 then do;
            g_error_name = 'ProtocolError';
            g_error_message = 'unsupported WebSocket frame';
            return 0;
        end;
        call ws_reclaim;
    end;
    return 1;
end ws_recv_message;

/* Opens the transport, performs the WebSocket handshake over it (an
   HTTP/1.1 GET with the Upgrade/Connection/Sec-WebSocket-Key headers),
   and verifies Sec-WebSocket-Accept without ever decoding it: this
   client recomputes the same base64(SHA1(key + GUID)) itself and
   compares the two encoded strings byte for byte. */
ws_connect: procedure fixed;
    declare keybytes(15) bit(8), keyb64(31) bit(8), keystr character;
    declare cbuf character(96), digest(19) bit(8), digestbase address;
    declare acceptbuf(31) bit(8), acceptlen fixed, expect character;
    declare hdrline character(600), req character, resp character;

    if transport_connect(g_convex_host, g_convex_port, g_convex_tls, WS_SLOT) = 0
    then return 0;
    call set_recv_timeout(conn_fd(WS_SLOT), 10000);

    call RAND_bytes(addr(keybytes(0)), 16);
    keystr = build_descriptor(EVP_EncodeBlock(addr(keyb64(0)),
        addr(keybytes(0)), 16), addr(keyb64(0)));

    call xsprintf(hdrline, 'GET %s/api/sync HTTP/1.1', g_convex_prefix);
    req = hdrline || CRLF ||
        'Host: ' || g_convex_host || CRLF ||
        'Upgrade: websocket' || CRLF ||
        'Connection: Upgrade' || CRLF ||
        'Sec-WebSocket-Key: ' || keystr || CRLF ||
        'Sec-WebSocket-Version: 13' || CRLF ||
        'Convex-Client: xpl-0.1.0' || CRLF || CRLF;
    if transport_write_all(req, WS_SLOT) = 0 then do;
        call transport_close(WS_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed writing the WebSocket upgrade request';
        return 0;
    end;

    if ws_read_handshake_response = 0 then do;
        call transport_close(WS_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed reading the WebSocket upgrade response';
        return 0;
    end;
    resp = build_descriptor(g_resp_total, addr(recvbuf(0)));
    if raw_eq(resp, 9, 3, '101') = 0 then do;
        call transport_close(WS_SLOT);
        g_error_name = 'ProtocolError';
        g_error_message = 'WebSocket upgrade was not accepted';
        return 0;
    end;

    cbuf = keystr || '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    digestbase = addr(digest(0));
    call SHA1(addr(cbuf), length(cbuf), digestbase);
    acceptlen = EVP_EncodeBlock(addr(acceptbuf(0)), digestbase, 20);
    expect = build_descriptor(acceptlen, addr(acceptbuf(0)));

    if find_header_value(resp, g_header_end, 'Sec-WebSocket-Accept') = 0
    then do;
        call transport_close(WS_SLOT);
        g_error_name = 'ProtocolError';
        g_error_message = 'WebSocket upgrade response had no Sec-WebSocket-Accept';
        return 0;
    end;
    if raw_eq(resp, g_hdr_val_start, g_hdr_val_end - g_hdr_val_start, expect) = 0
    then do;
        call transport_close(WS_SLOT);
        g_error_name = 'ProtocolError';
        g_error_message = 'WebSocket Sec-WebSocket-Accept did not match';
        return 0;
    end;

    /* Anything already read past the header block belongs to the
       frame stream, so seed the WebSocket buffer rather than discard
       it -- the server is free to pipeline its first frame right
       after the 101 response. */
    g_ws_total = g_resp_total;
    g_ws_consumed = g_header_end;
    return 1;
end ws_connect;

declare g_query_set fixed;
declare g_sub_pending_value character;
declare g_sub_pending_logs character;
declare g_sub_pending_error_message character;
declare g_sub_pending_is_error fixed;

/* Interprets one decoded WebSocket text message. Returns 1 when it was
   a Transition carrying an update (QueryUpdated or QueryFailed) for
   this client's one subscription (queryId 0), with the result left in
   g_sub_pending_*; returns 0 for every other message (an unrelated
   Transition, a Ping, a MutationResponse/ActionResponse this client
   never triggers since mutations run over HTTP), meaning "keep
   waiting for the next message". */
handle_ws_message: procedure(msg) fixed;
    declare msg character, found fixed;
    declare i fixed, n fixed, item_start fixed, item_end fixed;
    declare qid fixed, more fixed, result fixed;

    found = json_find_member(msg, 1, 'type');
    if found = 0 then return 0;
    if raw_eq(msg, g_span_start, g_span_end - g_span_start, '"Transition"') = 0
    then return 0;

    found = json_find_member(msg, 1, 'modifications');
    if found = 0 then return 0;

    i = g_span_start + 1;
    n = g_span_end - 1;
    more = 1;
    result = 0;
    do while more = 1;
        i = json_skip_ws(msg, i);
        if i >= n | byte(msg, i) = 93 then more = 0;
        else do;
            item_start = i;
            item_end = json_skip_value(msg, i);

            qid = -1;
            found = json_find_member(msg, item_start + 1, 'queryId');
            if found = 1 then
                qid = parse_uint(msg, g_span_start, g_span_end - g_span_start);

            if qid = 0 then do;
                found = json_find_member(msg, item_start + 1, 'type');
                if found = 1 & raw_eq(msg, g_span_start,
                        g_span_end - g_span_start, '"QueryUpdated"') = 1 then do;
                    found = json_find_member(msg, item_start + 1, 'value');
                    if found = 1 then
                        g_sub_pending_value = substr(msg, g_span_start,
                            g_span_end - g_span_start);
                    else g_sub_pending_value = 'null';
                    found = json_find_member(msg, item_start + 1, 'logLines');
                    if found = 1 then
                        g_sub_pending_logs = substr(msg, g_span_start,
                            g_span_end - g_span_start);
                    else g_sub_pending_logs = '[]';
                    g_sub_pending_is_error = 0;
                    result = 1;
                    more = 0;
                end;
                else if found = 1 & raw_eq(msg, g_span_start,
                        g_span_end - g_span_start, '"QueryFailed"') = 1 then do;
                    found = json_find_member(msg, item_start + 1, 'errorMessage');
                    if found = 1 then
                        g_sub_pending_error_message =
                            json_decode_string(msg, g_span_start, g_span_end);
                    else g_sub_pending_error_message = '';
                    g_sub_pending_is_error = 1;
                    result = 1;
                    more = 0;
                end;
            end;

            if more = 1 then do;
                i = json_skip_ws(msg, item_end);
                if i < n & byte(msg, i) = 44 then i = i + 1;
            end;
        end;
    end;
    return result;
end handle_ws_message;

/* Opens the Live connection and subscribes to (path, args_json), the
   only subscription this client supports at a time. args_json is the
   exact source span of the caller's args object, matching how
   convex_call relays HTTP call arguments. Returns 1 on success. */
convex_subscribe: procedure(path, args_json) fixed;
    declare path character, args_json character, msg character, sid character;

    if ws_connect = 0 then do;
        g_error_name = 'TransportError';
        return 0;
    end;

    sid = make_uuid;
    msg = '{"type":"Connect","sessionId":' || json_encode_string('', sid) ||
        ',"connectionCount":0,"lastCloseReason":' ||
        json_encode_string('', 'InitialConnect') || ',"clientTs":0}';
    if ws_send_frame(1, msg) = 0 then do;
        call transport_close(WS_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed sending Connect';
        return 0;
    end;

    msg = '{"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,' ||
        '"modifications":[{"type":"Add","queryId":0,"udfPath":' ||
        json_encode_string('', path) || ',"args":[' || args_json || ']}]}';
    if ws_send_frame(1, msg) = 0 then do;
        call transport_close(WS_SLOT);
        g_error_name = 'TransportError';
        g_error_message = 'failed sending the initial subscription';
        return 0;
    end;
    g_query_set = 1;
    return 1;
end convex_subscribe;

/* Blocks for the next Live update to this client's subscription,
   skipping unrelated protocol messages along the way. Returns 1 with
   g_sub_pending_* set, or 0 on a closed connection, a protocol error,
   or a read timeout (g_error_name/g_error_message explain which). */
convex_subscription_next: procedure fixed;
    declare got fixed;
    got = 0;
    do while got = 0;
        if ws_recv_message = 0 then return 0;
        got = handle_ws_message(g_ws_message);
    end;
    return 1;
end convex_subscription_next;

/* Removes the active subscription and closes the Live connection. */
convex_unsubscribe: procedure;
    declare msg character;
    msg = '{"type":"ModifyQuerySet","baseVersion":' || g_query_set ||
        ',"newVersion":' || (g_query_set + 1) ||
        ',"modifications":[{"type":"Remove","queryId":0}]}';
    call ws_send_frame(1, msg);
    call transport_close(WS_SLOT);
end convex_unsubscribe;
