/* NDJSON adapter protocol v1 conformance executable for the XPL client.
 *
 * This is test infrastructure, not public client code: it drives
 * convex.xpl's HTTP entry points (convex_init, convex_call,
 * convex_set_auth) from the shared controller's NDJSON commands. Every
 * protocol event is built by direct string concatenation, since a
 * flat, known-shape event is simpler to build correctly than to route
 * through the general JSON scanner meant for arbitrary Convex values.
 *
 * Scope: this client's manifest declares only the "http" capability
 * (see the README for why), so subscribe/unsubscribe/debugDisconnect
 * are answered with a ProtocolError explaining that Live is not
 * implemented here -- even though convex.xpl does implement a working
 * Live subscription, used directly by the canonical example, which
 * needs it to reproduce the universal example transcript. Concatenating
 * multiple subscriptions behind distinct subscriptionIds, with delivery
 * running concurrently with new commands arriving on stdin, needs
 * either real threads or a select()-based event loop; XPL cannot call
 * a function through a runtime computed pointer (no thread start
 * routine to hand to pthread_create), so that is future work, not
 * something attempted halfway here.
 *
 * I/O: this file reads and writes raw file descriptors directly
 * (POSIX read()/write()) instead of XPL's input()/output() unit
 * builtins, because the XPL runtime gives no documented way to force
 * a unit to be unbuffered or to flush it on demand, and a fully
 * buffered stdout would silently stall the NDJSON exchange under
 * Docker (stdout is a pipe, not a terminal, so C's stdio would
 * default to block buffering it). Framing (one line in, one line out)
 * is implemented directly on top of raw reads, the same technique
 * convex.xpl already uses for HTTP and WebSocket framing.
 */

declare LISTEN_BACKLOG literally '1';

read: procedure(fd, buf, len) fixed external;
    declare fd fixed, buf address, len fixed;
end read;

write: procedure(fd, buf, len) fixed external;
    declare fd fixed, buf address, len fixed;
end write;

bind: procedure(fd, addr, addrlen) fixed external;
    declare fd fixed, addr address, addrlen fixed;
end bind;

listen: procedure(fd, backlog) fixed external;
    declare fd fixed, backlog fixed;
end listen;

accept: procedure(fd, addr, addrlen) fixed external;
    declare fd fixed, addr address, addrlen address;
end accept;

inet_pton: procedure(af, src, dst) fixed external;
    declare af fixed, src address, dst address;
end inet_pton;

declare g_adapter_in_fd fixed;
declare g_adapter_out_fd fixed;
declare adapterbuf(RECV_BUF_SIZE - 1) bit(8);
declare g_adapter_total fixed;
declare g_adapter_consumed fixed;

write_stderr: procedure(text);
    declare text character, line character, p address;
    line = text || LF;
    p = saddr(line);
    call write(2, p, length(line));
end write_stderr;

adapter_write_line: procedure(text) fixed;
    declare text character, line character, p address;
    declare total fixed, written fixed, n fixed;
    line = text || LF;
    total = length(line);
    p = saddr(line);
    written = 0;
    do while written < total;
        n = write(g_adapter_out_fd, p + written, total - written);
        if n <= 0 then return 0;
        written = written + n;
    end;
    return 1;
end adapter_write_line;

/* Returns the next newline-delimited command, without its trailing
   newline, or '' at end of input. A line that arrives without a
   final newline (the peer closed right after it) is still returned
   once, matching how a shell pipe's last line behaves. */
adapter_read_line: procedure character;
    declare base address, i fixed, n fixed, line character, remain fixed;
    base = addr(adapterbuf(0));
    do while 1;
        if g_adapter_consumed >= g_adapter_total then do;
            g_adapter_total = 0;
            g_adapter_consumed = 0;
        end;
        i = g_adapter_consumed;
        do while i < g_adapter_total & corebyte(base + i) ~= 10;
            i = i + 1;
        end;
        if i < g_adapter_total then do;
            line = build_descriptor(i - g_adapter_consumed, base + g_adapter_consumed);
            g_adapter_consumed = i + 1;
            return line;
        end;
        if g_adapter_total >= RECV_BUF_SIZE then do;
            remain = g_adapter_total - g_adapter_consumed;
            do i = 0 to remain - 1;
                corebyte(base + i) = corebyte(base + g_adapter_consumed + i);
            end;
            g_adapter_total = remain;
            g_adapter_consumed = 0;
            if g_adapter_total >= RECV_BUF_SIZE then return '';
        end;
        n = read(g_adapter_in_fd, base + g_adapter_total, RECV_BUF_SIZE - g_adapter_total);
        if n <= 0 then do;
            if g_adapter_total > g_adapter_consumed then do;
                line = build_descriptor(g_adapter_total - g_adapter_consumed,
                    base + g_adapter_consumed);
                g_adapter_consumed = g_adapter_total;
                return line;
            end;
            return '';
        end;
        g_adapter_total = g_adapter_total + n;
    end;
end adapter_read_line;

/* Parses ADAPTER_LISTEN as host:port (the host must be a plain IPv4
   address, matching every other client's adapter), binds a listening
   socket restricted to that address, accepts exactly one controller
   connection, and points the adapter's raw I/O at it. */
setup_tcp_adapter: procedure(spec) fixed;
    declare spec character, colon fixed, host character, port fixed;
    declare hostbuf character(64), local(15) bit(8), lbase address;
    declare listener fixed, peer fixed, rc fixed;

    colon = find_byte(spec, 0, length(spec), 58);
    if colon <= 0 | colon >= length(spec) - 1 then do;
        call write_stderr('ADAPTER_LISTEN must be host:port');
        return 0;
    end;
    host = substr(spec, 0, colon);
    port = parse_uint(spec, colon + 1, length(spec) - colon - 1);
    if port <= 0 | port > 65535 then do;
        call write_stderr('ADAPTER_LISTEN has an invalid port');
        return 0;
    end;
    hostbuf = host;

    listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if listener < 0 then do;
        call write_stderr('adapter listen socket() failed');
        return 0;
    end;

    lbase = addr(local(0));
    call zero_mem(lbase, 16);
    corebyte(lbase) = AF_INET;
    corebyte(lbase + 2) = shr(port, 8) & 255;
    corebyte(lbase + 3) = port & 255;
    if inet_pton(AF_INET, addr(hostbuf), lbase + 4) ~= 1 then do;
        call write_stderr('ADAPTER_LISTEN host must be an IPv4 address');
        call close(listener);
        return 0;
    end;

    rc = bind(listener, lbase, 16);
    if rc = 0 then rc = listen(listener, LISTEN_BACKLOG);
    if rc ~= 0 then do;
        call write_stderr('adapter listen failed');
        call close(listener);
        return 0;
    end;

    peer = accept(listener, 0, 0);
    call close(listener);
    if peer < 0 then do;
        call write_stderr('adapter accept failed');
        return 0;
    end;
    g_adapter_in_fd = peer;
    g_adapter_out_fd = peer;
    return 1;
end setup_tcp_adapter;

/* --- Event builders -------------------------------------------------- */

emit_ready: procedure(id);
    declare id character, line character;
    line = '{"protocolVersion":1,"id":' || json_encode_string('', id) ||
        ',"type":"ready","language":"xpl","implementation":' ||
        json_encode_string('', 'native-xpl-gcc-openssl') ||
        ',"runtime":' || json_encode_string('', 'XPL 1.0 / gcc / glibc') || '}';
    call adapter_write_line(line);
end emit_ready;

emit_result: procedure(id, value_json, logs_json);
    declare id character, value_json character, logs_json character, line character;
    line = '{"id":' || json_encode_string('', id) || ',"type":"result","value":' ||
        value_json || ',"logs":' || logs_json || '}';
    call adapter_write_line(line);
end emit_result;

emit_simple: procedure(id, kind);
    declare id character, kind character, line character;
    line = '{"id":' || json_encode_string('', id) || ',"type":' ||
        json_encode_string('', kind) || '}';
    call adapter_write_line(line);
end emit_simple;

/* Every error this adapter reports is a top level protocol/transport
   error tied to the command's own id -- this client has no active
   subscriptions, so the "subscription" flavour of this event never
   applies. data_json may be '' to omit the optional "data" member. */
emit_error: procedure(id, name, message, data_json);
    declare id character, name character, message character, data_json character;
    declare line character;
    line = '{"type":"error"';
    if length(id) > 0 then line = line || ',"id":' || json_encode_string('', id);
    line = line || ',"error":{"name":' || json_encode_string('', name) ||
        ',"message":' || json_encode_string('', message);
    if length(data_json) > 0 then line = line || ',"data":' || data_json;
    line = line || '}}';
    call adapter_write_line(line);
end emit_error;

/* --- Command dispatch -------------------------------------------------- */

declare g_client_ready fixed;

ensure_client: procedure fixed;
    if g_client_ready = 1 then return 1;
    if convex_init = 0 then return 0;
    g_client_ready = 1;
    return 1;
end ensure_client;

handle_call: procedure(op, id, cmd);
    declare op character, id character, cmd character;
    declare found fixed, path character, args_span character;

    found = json_find_member(cmd, 1, 'path');
    if found = 0 then do;
        call emit_error(id, 'ProtocolError', 'a call command needs a path', '');
        return;
    end;
    path = json_decode_string(cmd, g_span_start, g_span_end);

    found = json_find_member(cmd, 1, 'args');
    if found = 1 then
        args_span = substr(cmd, g_span_start, g_span_end - g_span_start);
    else args_span = '{}';

    if ensure_client = 0 then do;
        call emit_error(id, g_error_name, g_error_message, '');
        return;
    end;

    if convex_call(op, path, args_span) = 1 then
        call emit_result(id, g_value_json, g_logs_json);
    else do;
        if g_has_error_data = 1 then
            call emit_error(id, g_error_name, g_error_message, g_error_data_json);
        else
            call emit_error(id, g_error_name, g_error_message, '');
    end;
end handle_call;

handle_set_auth: procedure(id, cmd);
    declare id character, cmd character, found fixed, token character;
    found = json_find_member(cmd, 1, 'token');
    if found = 0 then do;
        call emit_error(id, 'ProtocolError', 'setAuth needs a token', '');
        return;
    end;
    token = json_decode_string(cmd, g_span_start, g_span_end);
    if ensure_client = 0 then do;
        call emit_error(id, g_error_name, g_error_message, '');
        return;
    end;
    call convex_set_auth(token);
    call emit_simple(id, 'ack');
end handle_set_auth;

/* True when s is exactly one well-formed JSON object: it starts with
   '{', its braces (and any nested brackets) balance back to zero,
   and only whitespace follows the matching close. json_skip_value
   cannot tell this apart from a truncated object like "{malformed"
   on its own -- it also stops at end of input, having simply run out
   of bytes to look at rather than having found a real closing brace,
   so an adapter command line needs this stricter check instead. */
line_is_json_object: procedure(s) fixed;
    declare s character, n fixed, i fixed, c fixed, depth fixed, done fixed, ok fixed;
    n = length(s);
    if n = 0 then return 0;
    if byte(s, 0) ~= 123 then return 0;
    depth = 0;
    i = 0;
    done = 0;
    ok = 0;
    do while i < n & done = 0;
        c = byte(s, i);
        if c = 34 then i = json_skip_string(s, i);
        else do;
            if c = 123 | c = 91 then depth = depth + 1;
            else if c = 125 | c = 93 then do;
                depth = depth - 1;
                if depth = 0 then do;
                    ok = 1;
                    done = 1;
                end;
            end;
            i = i + 1;
        end;
    end;
    if ok = 0 then return 0;
    do while i < n;
        c = byte(s, i);
        if c ~= 32 & c ~= 9 & c ~= 13 & c ~= 10 then return 0;
        i = i + 1;
    end;
    return 1;
end line_is_json_object;

dispatch: procedure(cmd) fixed;
    declare cmd character, found fixed, id character, op character;
    declare version fixed;

    found = json_find_member(cmd, 1, 'id');
    if found = 1 then id = json_decode_string(cmd, g_span_start, g_span_end);
    else id = '';

    found = json_find_member(cmd, 1, 'op');
    if found = 1 then op = json_decode_string(cmd, g_span_start, g_span_end);
    else op = '';

    if raw_eq(op, 0, length(op), 'hello') = 1 then do;
        found = json_find_member(cmd, 1, 'protocolVersion');
        version = -1;
        if found = 1 then
            version = parse_uint(cmd, g_span_start, g_span_end - g_span_start);
        if version ~= 1 then
            call emit_error(id, 'ProtocolError', 'unsupported adapter protocol version', '');
        else
            call emit_ready(id);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'query') = 1 |
            raw_eq(op, 0, length(op), 'mutation') = 1 |
            raw_eq(op, 0, length(op), 'action') = 1 then do;
        call handle_call(op, id, cmd);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'setAuth') = 1 then do;
        call handle_set_auth(id, cmd);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'subscribe') = 1 |
            raw_eq(op, 0, length(op), 'unsubscribe') = 1 |
            raw_eq(op, 0, length(op), 'debugDisconnect') = 1 then do;
        call emit_error(id, 'ProtocolError',
            'Live is not implemented by this adapter (see manifest.yaml)', '');
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'close') = 1 then do;
        call emit_simple(id, 'closed');
        return 0;
    end;
    call emit_error(id, 'ProtocolError', 'unknown adapter operation', '');
    return 1;
end dispatch;

/* --- Entry point -------------------------------------------------- */

declare listen_spec character;
declare line character;
declare running fixed;

/* LF is otherwise only set up lazily inside convex_init, which a
   hello-then-close session never calls; NDJSON framing needs it from
   the very first line this adapter writes. */
byte(LF, 0) = 10;
g_client_ready = 0;
listen_spec = env_get('ADAPTER_LISTEN');
if length(listen_spec) > 0 then do;
    if setup_tcp_adapter(listen_spec) = 0 then call exit(1);
end;
else do;
    g_adapter_in_fd = 0;
    g_adapter_out_fd = 1;
end;

running = 1;
do while running = 1;
    line = adapter_read_line;
    if length(line) = 0 then running = 0;
    else do;
        if line_is_json_object(line) = 0 then
            call emit_error('', 'ProtocolError', 'malformed adapter command', '');
        else running = dispatch(line);
    end;
end;
call close(g_adapter_in_fd);
eof
