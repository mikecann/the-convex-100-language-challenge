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

/* --- Live: subscription table and the WebSocket side of the reactor ---- */
/*                                                                        */
/* There is exactly one Live worker: this reactor. It owns every read,   */
/* write, reconnect, and query-set version change on the WebSocket, and  */
/* dispatch by subscriptionId is a table lookup and an if-chain -- never */
/* a call through a runtime computed pointer -- so none of this needs a  */
/* thread. A subscription's table slot index doubles as its Convex       */
/* queryId, which keeps mapping a Transition's modifications back to a   */
/* subscriptionId a single array read.                                   */

declare MAX_SUBS literally '31';
declare sub_active(MAX_SUBS) fixed;
declare sub_id(MAX_SUBS) character;
declare sub_path(MAX_SUBS) character;
declare sub_args(MAX_SUBS) character;
declare sub_has_value(MAX_SUBS) fixed;
declare sub_last_value(MAX_SUBS) character;

declare g_ws_connected fixed;
declare g_query_set_version fixed;
declare g_reconnect_at_ms address;
declare g_backoff_ms fixed;
declare g_connections fixed;
declare g_last_close_reason character;

find_sub_slot: procedure(sid) fixed;
    declare sid character, i fixed;
    do i = 0 to MAX_SUBS;
        if sub_active(i) = 1 & raw_eq(sub_id(i), 0, length(sub_id(i)), sid) = 1
        then return i;
    end;
    return -1;
end find_sub_slot;

find_free_slot: procedure fixed;
    declare i fixed;
    do i = 0 to MAX_SUBS;
        if sub_active(i) = 0 then return i;
    end;
    return -1;
end find_free_slot;

any_active_sub: procedure fixed;
    declare i fixed;
    do i = 0 to MAX_SUBS;
        if sub_active(i) = 1 then return 1;
    end;
    return 0;
end any_active_sub;

ws_send_add: procedure(query_id, path, args_json) fixed;
    declare query_id fixed, path character, args_json character, msg character;
    msg = '{"type":"ModifyQuerySet","baseVersion":' || g_query_set_version ||
        ',"newVersion":' || (g_query_set_version + 1) ||
        ',"modifications":[{"type":"Add","queryId":' || query_id ||
        ',"udfPath":' || json_encode_string('', path) || ',"args":[' ||
        args_json || ']}]}';
    if ws_send_frame(1, msg) = 0 then return 0;
    g_query_set_version = g_query_set_version + 1;
    return 1;
end ws_send_add;

ws_send_remove: procedure(query_id) fixed;
    declare query_id fixed, msg character, ok fixed;
    msg = '{"type":"ModifyQuerySet","baseVersion":' || g_query_set_version ||
        ',"newVersion":' || (g_query_set_version + 1) ||
        ',"modifications":[{"type":"Remove","queryId":' || query_id || '}]}';
    ok = ws_send_frame(1, msg);
    if ok = 1 then g_query_set_version = g_query_set_version + 1;
    return ok;
end ws_send_remove;

/* Opens the Live connection, sends Connect, then re-adds every
   currently active table entry (an initial connect and a post
   disconnect reconnect are the same operation: query set version 0,
   the full active set re-Added fresh). Returns 1 on success. */
live_connect: procedure fixed;
    declare msg character, sid character, i fixed, ok fixed;
    if ws_connect = 0 then return 0;

    sid = make_uuid;
    msg = '{"type":"Connect","sessionId":' || json_encode_string('', sid) ||
        ',"connectionCount":' || g_connections ||
        ',"lastCloseReason":' || json_encode_string('', g_last_close_reason) ||
        ',"clientTs":0}';
    if ws_send_frame(1, msg) = 0 then do;
        call transport_close(WS_SLOT);
        return 0;
    end;

    g_query_set_version = 0;
    ok = 1;
    do i = 0 to MAX_SUBS;
        if sub_active(i) = 1 & ok = 1 then
            ok = ws_send_add(i, sub_path(i), sub_args(i));
    end;
    if ok = 0 then do;
        call transport_close(WS_SLOT);
        return 0;
    end;

    g_ws_connected = 1;
    g_backoff_ms = 100;
    return 1;
end live_connect;

/* Retires the old connection (if one is open) and schedules the next
   reconnect attempt with exponential backoff from 100 ms up to a
   15 s cap -- the same profile every Live-capable client in this
   repository uses. Safe to call whether or not a connection is
   currently open, so both an unexpected close and a deliberate
   debugDisconnect can share it. */
live_disconnect: procedure(reason);
    declare reason character;
    if g_ws_connected = 1 then do;
        call transport_close(WS_SLOT);
        g_connections = g_connections + 1;
    end;
    g_ws_connected = 0;
    g_last_close_reason = reason;
    g_reconnect_at_ms = now_ms + g_backoff_ms;
    g_backoff_ms = g_backoff_ms * 2;
    if g_backoff_ms > 15000 then g_backoff_ms = 15000;
end live_disconnect;

emit_subscription_value: procedure(sid, value_json, logs_json);
    declare sid character, value_json character, logs_json character;
    declare line character;
    line = '{"type":"subscription","subscriptionId":' ||
        json_encode_string('', sid) || ',"value":' || value_json ||
        ',"logs":' || logs_json || '}';
    call adapter_write_line(line);
end emit_subscription_value;

emit_subscription_error: procedure(sid, name, message, data_json);
    declare sid character, name character, message character, data_json character;
    declare line character;
    line = '{"type":"subscription","subscriptionId":' ||
        json_encode_string('', sid) || ',"error":{"name":' ||
        json_encode_string('', name) || ',"message":' ||
        json_encode_string('', message);
    if length(data_json) > 0 then line = line || ',"data":' || data_json;
    line = line || '}}';
    call adapter_write_line(line);
end emit_subscription_error;

/* Walks one decoded WebSocket text message. A Transition's
   modifications are fanned out to whichever active subscription each
   queryId (== table slot index) names; Ping/MutationResponse/
   ActionResponse and a modification naming an inactive or unknown
   queryId (a Remove that is still in flight when a fresh Add for the
   same slot arrives) are silently ignored rather than erroring the
   connection.

   A rehydration that reconnecting after debugDisconnect triggers --
   resubscribing from scratch always replays the query's current value
   even when it has not changed since the last one this adapter
   already delivered -- is suppressed: only a value that actually
   differs from the last one sent for that subscription is emitted, so
   the sequence a caller observes stays initial value, disconnect
   acknowledgement, external change, updated value, with no duplicate
   in between. An error is never suppressed this way (there is no
   equivalent "nothing changed" case for a QueryFailed). */
dispatch_transition: procedure(msg);
    declare msg character, more fixed, slot fixed, changed fixed;
    if ws_transition_begin(msg) = 0 then return;
    more = 1;
    do while more = 1;
        more = ws_transition_next;
        if more = 1 & g_mod_query_id >= 0 & g_mod_query_id <= MAX_SUBS then do;
            slot = g_mod_query_id;
            if sub_active(slot) = 1 then do;
                if g_mod_is_error = 1 then do;
                    if g_mod_has_error_data = 1 then
                        call emit_subscription_error(sub_id(slot),
                            'FunctionError', g_mod_error_message,
                            g_mod_error_data_json);
                    else
                        call emit_subscription_error(sub_id(slot),
                            'FunctionError', g_mod_error_message, '');
                end;
                else if g_mod_is_update = 1 then do;
                    changed = 1;
                    if sub_has_value(slot) = 1 then
                        if raw_eq(g_mod_value_json, 0, length(g_mod_value_json),
                                sub_last_value(slot)) = 1
                        then changed = 0;
                    if changed = 1 then
                        call emit_subscription_value(sub_id(slot),
                            g_mod_value_json, g_mod_logs_json);
                    sub_last_value(slot) = g_mod_value_json;
                    sub_has_value(slot) = 1;
                end;
            end;
        end;
    end;
end dispatch_transition;

/* --- Command dispatch -------------------------------------------------- */

declare g_client_ready fixed;

ensure_client: procedure fixed;
    if g_client_ready = 1 then return 1;
    if convex_init = 0 then return 0;
    g_client_ready = 1;
    return 1;
end ensure_client;

handle_subscribe: procedure(id, cmd);
    declare id character, cmd character, found fixed;
    declare sid character, path character, args_span character;
    declare slot fixed, ok fixed;

    found = json_find_member(cmd, 1, 'subscriptionId');
    if found = 0 then do;
        call emit_error(id, 'ProtocolError', 'subscribe needs a subscriptionId', '');
        return;
    end;
    sid = json_decode_string(cmd, g_span_start, g_span_end);

    found = json_find_member(cmd, 1, 'path');
    if found = 0 then do;
        call emit_error(id, 'ProtocolError', 'subscribe needs a path', '');
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

    /* A repeat subscribe on an id already in use invalidates the old
       one before the new one is added, matching how a same-ID
       replacement must never let a stale value cross the swap. */
    slot = find_sub_slot(sid);
    if slot >= 0 then do;
        if g_ws_connected = 1 then ok = ws_send_remove(slot);
        sub_active(slot) = 0;
    end;

    slot = find_free_slot;
    if slot < 0 then do;
        call emit_error(id, 'ProtocolError', 'too many concurrent subscriptions', '');
        return;
    end;

    sub_id(slot) = sid;
    sub_path(slot) = path;
    sub_args(slot) = args_span;
    sub_active(slot) = 1;
    sub_has_value(slot) = 0;

    if g_ws_connected = 0 then ok = live_connect;
    else ok = ws_send_add(slot, path, args_span);

    if ok = 0 then do;
        sub_active(slot) = 0;
        call emit_error(id, g_error_name, g_error_message, '');
        return;
    end;
    call emit_simple(id, 'ack');
end handle_subscribe;

handle_unsubscribe: procedure(id, cmd);
    declare id character, cmd character, found fixed;
    declare sid character, slot fixed, ok fixed;
    found = json_find_member(cmd, 1, 'subscriptionId');
    if found = 0 then do;
        call emit_error(id, 'ProtocolError', 'unsubscribe needs a subscriptionId', '');
        return;
    end;
    sid = json_decode_string(cmd, g_span_start, g_span_end);
    slot = find_sub_slot(sid);
    if slot >= 0 then do;
        sub_active(slot) = 0;
        if g_ws_connected = 1 then ok = ws_send_remove(slot);
    end;
    /* Unsubscribing an id this adapter has no record of is treated as
       success: it is already gone, which is what the caller wanted. */
    call emit_simple(id, 'ack');
end handle_unsubscribe;

handle_debug_disconnect: procedure(id, cmd);
    declare id character, cmd character;
    if g_ws_connected = 0 then do;
        call emit_error(id, 'TransportError', 'Live WebSocket is not connected', '');
        return;
    end;
    /* The old connection is retired (live_disconnect closes it) and
       reconnect work is scheduled (the backoff deadline is set)
       before this acknowledges, so the shared controller can rely on
       the ack meaning both have already happened. */
    call live_disconnect('DebugDisconnect');
    call emit_simple(id, 'ack');
end handle_debug_disconnect;

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
    if raw_eq(op, 0, length(op), 'subscribe') = 1 then do;
        call handle_subscribe(id, cmd);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'unsubscribe') = 1 then do;
        call handle_unsubscribe(id, cmd);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'debugDisconnect') = 1 then do;
        call handle_debug_disconnect(id, cmd);
        return 1;
    end;
    if raw_eq(op, 0, length(op), 'close') = 1 then do;
        call emit_simple(id, 'closed');
        return 0;
    end;
    call emit_error(id, 'ProtocolError', 'unknown adapter operation', '');
    return 1;
end dispatch;

/* --- Entry point: the poll driven reactor --------------------------- */
/*                                                                      */
/* Two file descriptors, one loop: the controller connection (NDJSON    */
/* commands in, events out) and, once at least one subscription needs   */
/* it, the Live WebSocket. Nothing here is threaded and nothing is      */
/* called through a runtime computed pointer -- nfds is 1 or 2, and the */
/* two branches below are it. */

declare POLLIN literally '1';
declare POLLHUP literally '16';
declare POLLREADABLE literally '17';

poll: procedure(fds, nfds, timeout_ms) fixed external;
    declare fds address, nfds address, timeout_ms fixed;
end poll;

declare listen_spec character;
declare line character;
declare running fixed;
declare pfds(15) bit(8);
declare pbase address;
declare poll_nfds fixed;
declare poll_timeout_ms fixed;
declare poll_rc fixed;
declare revents_controller fixed;
declare revents_ws fixed;
declare init_i fixed;

/* LF is otherwise only set up lazily inside convex_init, which a
   hello-then-close session never calls; NDJSON framing needs it from
   the very first line this adapter writes. */
byte(LF, 0) = 10;
g_client_ready = 0;
g_ws_connected = 0;
g_connections = 0;
g_backoff_ms = 100;
g_reconnect_at_ms = 0;
g_last_close_reason = 'InitialConnect';
do init_i = 0 to MAX_SUBS;
    sub_active(init_i) = 0;
end;

listen_spec = env_get('ADAPTER_LISTEN');
if length(listen_spec) > 0 then do;
    if setup_tcp_adapter(listen_spec) = 0 then call exit(1);
end;
else do;
    g_adapter_in_fd = 0;
    g_adapter_out_fd = 1;
end;

pbase = addr(pfds(0));
running = 1;
do while running = 1;
    if g_ws_connected = 0 & any_active_sub = 1 & now_ms >= g_reconnect_at_ms then do;
        if live_connect = 0 then call live_disconnect('ReconnectFailed');
    end;

    /* poll() only reports bytes still sitting in the kernel socket
       buffer. It cannot see application-buffered bytes this client
       already pulled out of the socket with a read() -- which
       happens routinely here, since the WebSocket handshake reads
       whatever the peer sent along with its 101 response (the server
       is free to pipeline the first frame right after it), and since
       one read() can return more than one complete frame at once.
       Drain everything already sitting in recvbuf before ever asking
       poll() whether there is anything new on the wire; otherwise a
       pipelined or batched message can sit unprocessed until some
       unrelated event happens to make the socket "ready" again. */
    do while g_ws_connected = 1 & g_ws_total > g_ws_consumed;
        if ws_recv_message = 1 then call dispatch_transition(g_ws_message);
        else call live_disconnect('TransportError');
    end;

    /* The same "poll() cannot see bytes this client already read()"
       gap applies to the controller connection: TCP mode's peer can
       write an NDJSON command and its own close (or two commands
       back to back) in one go, which one read() can pull in as a
       single batch -- exactly what the shared harness's synchronous
       request/response pairing does. Drain every buffered line before
       ever polling for new controller activity. */
    do while running = 1 & g_adapter_total > g_adapter_consumed;
        line = adapter_read_line;
        if length(line) = 0 then running = 0;
        else do;
            if line_is_json_object(line) = 0 then
                call emit_error('', 'ProtocolError', 'malformed adapter command', '');
            else running = dispatch(line);
        end;
    end;

    /* Both drain loops above may have already decided to stop (a
       close command, or a controller EOF); skip straight to the next
       (and final) `running = 1` check at the top of this loop rather
       than building a pollfd set and waiting on a connection that is
       done. */
    if running = 1 then do;
        coreword(pbase) = g_adapter_in_fd;
        corehalfword(pbase + 4) = POLLIN;
        corehalfword(pbase + 6) = 0;
        poll_nfds = 1;
        if g_ws_connected = 1 then do;
            coreword(pbase + 8) = conn_fd(WS_SLOT);
            corehalfword(pbase + 12) = POLLIN;
            corehalfword(pbase + 14) = 0;
            poll_nfds = 2;
        end;

        /* A bounded wait only when a reconnect is pending, so the
           backoff deadline above is re-checked promptly; otherwise
           there is nothing to wake up for except real activity on
           either fd. */
        if g_ws_connected = 0 & any_active_sub = 1 then poll_timeout_ms = 200;
        else poll_timeout_ms = -1;

        poll_rc = poll(pbase, poll_nfds, poll_timeout_ms);
        if poll_rc > 0 then do;
            /* revents is checked against POLLIN | POLLHUP, not POLLIN
               alone: once the peer has half closed its write side,
               poll() reports POLLHUP on every call from then on
               (persistently "ready", the classic busy-spin shape)
               whether or not this side has drained every buffered
               byte first, and a bare POLLIN check never fires again
               to notice. Treating either bit as "attempt a read" both
               drains the last buffered bytes and reaches the read()
               that turns them into a clean EOF. */
            revents_controller = corehalfword(pbase + 6);
            if (revents_controller & POLLREADABLE) ~= 0 then do;
                line = adapter_read_line;
                if length(line) = 0 then running = 0;
                else do;
                    if line_is_json_object(line) = 0 then
                        call emit_error('', 'ProtocolError', 'malformed adapter command', '');
                    else running = dispatch(line);
                end;
            end;
            if running = 1 & poll_nfds = 2 then do;
                revents_ws = corehalfword(pbase + 14);
                if (revents_ws & POLLREADABLE) ~= 0 then do;
                    if ws_recv_message = 1 then call dispatch_transition(g_ws_message);
                    else call live_disconnect('TransportError');
                end;
            end;
        end;
    end;
end;
call close(g_adapter_in_fd);
eof
