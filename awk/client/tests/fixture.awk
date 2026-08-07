# Language-local test fixture.
#
# The tests need a peer: something that answers HTTP requests, completes an
# RFC6455 handshake, and plays scripted Convex sync traffic. This program is
# that peer. Each test starts it as a co-process, reads the port it bound from
# the first line of its output, and then drives it by writing command lines to
# its standard input.
#
#   gawk -f fixture.awk -v ROLE=http
#   gawk -f fixture.awk -v ROLE=sync
#   gawk -f fixture.awk -v ROLE=tls -v CERTIFICATE=... -v KEY=...
#
# It uses convexext only for raw bounded sockets, clocks, TLS, and the handshake
# digest. WebSocket framing below is implemented independently in Awk, so a bug
# in the client's C frame parser cannot make both halves agree by accident.

@load "convexext"

BEGIN {
    B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    IO_OK = 1
    IO_TIMEOUT = 0
    IO_EOF = -1
    IO_ERROR = -2
    for (FIXTURE_INDEX = 0; FIXTURE_INDEX < 256; FIXTURE_INDEX++) {
        FIXTURE_BYTE[FIXTURE_INDEX] = convex_byte(FIXTURE_INDEX)
        FIXTURE_ORD[FIXTURE_BYTE[FIXTURE_INDEX]] = FIXTURE_INDEX
    }

    CONTROL = convex_attach(0)
    LISTENER = convex_listen("127.0.0.1", 0)
    if (CONTROL < 0 || LISTENER < 0) {
        print "fixture: cannot start: " convex_last_error() > "/dev/stderr"
        exit 1
    }
    print convex_port(LISTENER)
    fflush("/dev/stdout")

    if (ROLE == "http") {
        exit fixture_http()
    }
    if (ROLE == "sync") {
        exit fixture_sync()
    }
    if (ROLE == "deployment") {
        exit fixture_deployment()
    }
    if (ROLE == "tls") {
        exit fixture_tls()
    }
    print "fixture: unknown role " ROLE > "/dev/stderr"
    exit 1
}

# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

function control_line(timeout_ms,    deadline, status, chunk, newline, line) {
    deadline = convex_now_ms() + timeout_ms
    for (;;) {
        newline = index(CONTROL_BUFFER, "\n")
        if (newline > 0) {
            line = substr(CONTROL_BUFFER, 1, newline - 1)
            CONTROL_BUFFER = substr(CONTROL_BUFFER, newline + 1)
            return line
        }
        if (CONTROL_EOF) {
            QUIT = 1
            return "quit"
        }
        status = convex_recv(CONTROL, 4096, remaining(deadline), chunk)
        if (status == IO_OK) {
            CONTROL_BUFFER = CONTROL_BUFFER chunk["data"]
            continue
        }
        if (status == IO_EOF) {
            CONTROL_EOF = 1
            QUIT = 1
            return "quit"
        }
        return ""
    }
}

function remaining(deadline,    left) {
    left = deadline - convex_now_ms()
    return left < 0 ? 0 : left
}

function read_request(handle, timeout_ms, out,    deadline, buffer, chunk, status, header_end, length_, body) {
    delete out
    deadline = convex_now_ms() + timeout_ms
    buffer = ""
    header_end = 0
    while (header_end == 0) {
        status = convex_recv(handle, 65536, remaining(deadline), chunk)
        if (status != IO_OK) {
            return 0
        }
        buffer = buffer chunk["data"]
        header_end = index(buffer, "\r\n\r\n")
    }
    out["head"] = substr(buffer, 1, header_end - 1)
    body = substr(buffer, header_end + 4)
    length_ = 0
    if (match(tolower(out["head"]), /content-length:[ ]*[0-9]+/)) {
        length_ = substr(tolower(out["head"]), RSTART, RLENGTH)
        sub(/^content-length:[ ]*/, "", length_)
        length_ += 0
    }
    while (length(body) < length_) {
        status = convex_recv(handle, 65536, remaining(deadline), chunk)
        if (status != IO_OK) {
            return 0
        }
        body = body chunk["data"]
    }
    out["body"] = body
    return 1
}

function header_value(head, name,    lines, count, position, line, colon) {
    count = split(head, lines, /\r?\n/)
    for (position = 1; position <= count; position++) {
        line = lines[position]
        colon = index(line, ":")
        if (colon < 2) {
            continue
        }
        if (tolower(substr(line, 1, colon - 1)) == tolower(name)) {
            line = substr(line, colon + 1)
            sub(/^[ \t]+/, "", line)
            sub(/[ \t\r]+$/, "", line)
            return line
        }
    }
    return ""
}

function json_response(handle, body,    text) {
    text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
    text = text "Content-Length: " length(body) "\r\nConnection: close\r\n\r\n" body
    convex_send(handle, text, 2000)
}

function json_response_status(handle, status, body,    text) {
    text = "HTTP/1.1 " status "\r\nContent-Type: application/json\r\n"
    text = text "Content-Length: " length(body) "\r\nConnection: close\r\n\r\n" body
    convex_send(handle, text, 2000)
}

# --------------------------------------------------------------------------
# Independent RFC6455 server framing
# --------------------------------------------------------------------------

function ws_byte(value) {
    return FIXTURE_BYTE[value]
}

function ws_ord(character) {
    return FIXTURE_ORD[character]
}

function ws_send(handle, opcode, payload, fin,    length_, header, value, shift) {
    length_ = length(payload)
    if (length_ > 1048576) {
        return IO_ERROR
    }
    header = ws_byte((fin ? 128 : 0) + opcode)
    if (length_ < 126) {
        header = header ws_byte(length_)
    } else if (length_ <= 65535) {
        header = header ws_byte(126) ws_byte(int(length_ / 256)) ws_byte(length_ % 256)
    } else {
        header = header ws_byte(127)
        for (shift = 7; shift >= 0; shift--) {
            value = int(length_ / (256 ^ shift)) % 256
            header = header ws_byte(value)
        }
    }
    return convex_send(handle, header payload, 2000)
}

function ws_fill(handle, needed, deadline,    status, chunk) {
    while (length(WS_BUFFER) < needed) {
        status = convex_recv(handle, 65536, remaining(deadline), chunk)
        if (status != IO_OK) {
            WS_LAST_STATUS = status
            return 0
        }
        WS_BUFFER = WS_BUFFER chunk["data"]
        if (length(WS_BUFFER) > 1114112) {
            WS_LAST_STATUS = IO_ERROR
            return 0
        }
    }
    return 1
}

function ws_recv(handle, timeout_ms, out,    deadline, first, second, fin, opcode, masked, length_, offset, index_, mask, payload, byte) {
    delete out
    deadline = convex_now_ms() + timeout_ms
    WS_LAST_STATUS = IO_TIMEOUT
    if (!ws_fill(handle, 2, deadline)) {
        return WS_LAST_STATUS
    }
    first = ws_ord(substr(WS_BUFFER, 1, 1))
    second = ws_ord(substr(WS_BUFFER, 2, 1))
    fin = and(first, 128) != 0
    opcode = and(first, 15)
    masked = and(second, 128) != 0
    length_ = and(second, 127)
    offset = 3
    if (length_ == 126) {
        if (!ws_fill(handle, 4, deadline)) {
            return WS_LAST_STATUS
        }
        length_ = ws_ord(substr(WS_BUFFER, 3, 1)) * 256 + ws_ord(substr(WS_BUFFER, 4, 1))
        if (length_ < 126) {
            return IO_ERROR
        }
        offset = 5
    } else if (length_ == 127) {
        if (!ws_fill(handle, 10, deadline)) {
            return WS_LAST_STATUS
        }
        length_ = 0
        for (index_ = 3; index_ <= 10; index_++) {
            length_ = length_ * 256 + ws_ord(substr(WS_BUFFER, index_, 1))
        }
        if (length_ < 65536) {
            return IO_ERROR
        }
        offset = 11
    }
    if (!masked || length_ > 1048576 ||
        ((opcode == 8 || opcode == 9 || opcode == 10) && (!fin || length_ > 125))) {
        return IO_ERROR
    }
    if (!ws_fill(handle, offset + 3 + length_, deadline)) {
        return WS_LAST_STATUS
    }
    for (index_ = 0; index_ < 4; index_++) {
        mask[index_] = ws_ord(substr(WS_BUFFER, offset + index_, 1))
    }
    offset += 4
    payload = ""
    for (index_ = 0; index_ < length_; index_++) {
        byte = xor(ws_ord(substr(WS_BUFFER, offset + index_, 1)), mask[index_ % 4])
        payload = payload ws_byte(byte)
    }
    WS_BUFFER = substr(WS_BUFFER, offset + length_)
    if (opcode == 8) {
        out["kind"] = "close"
    } else if (opcode == 9) {
        out["kind"] = "ping"
    } else if (opcode == 10) {
        out["kind"] = "pong"
    } else if (opcode == 1 && fin) {
        out["kind"] = "text"
    } else {
        return IO_ERROR
    }
    out["payload"] = payload
    return IO_OK
}

# --------------------------------------------------------------------------
# HTTP role
#
# The response is chosen by the Convex function path in the request body, so a
# test picks its case by calling that path.
# --------------------------------------------------------------------------

function fixture_http(    handle, request, path, body, authorization, served) {
    for (served = 0; served < 64 && !QUIT; served++) {
        handle = convex_accept(LISTENER, 500)
        if (handle < 0) {
            control_line(0)
            continue
        }
        if (!read_request(handle, 5000, request)) {
            convex_close(handle)
            continue
        }
        path = request["body"]
        sub(/^.*"path":"/, "", path)
        sub(/".*$/, "", path)
        authorization = header_value(request["head"], "authorization")

        if (path == "demo:state") {
            json_response(handle, "{\"status\":\"success\",\"value\":{\"room\":\"r\",\"count\":0}," \
                "\"logLines\":[]}")
        } else if (path == "demo:echo") {
            # The exact Authorization header is echoed back so the client test
            # can assert the bytes it put on the wire.
            json_response(handle, "{\"status\":\"success\",\"value\":{\"authorization\":\"" \
                authorization "\"},\"logLines\":[\"demo:echo received a JSON-safe value\"]}")
        } else if (path == "demo:fail") {
            json_response(handle, "{\"status\":\"error\",\"errorMessage\":\"Intentional conformance failure\"," \
                "\"errorData\":{\"code\":\"AWK_EXPECTED\"},\"logLines\":[]}")
        } else if (path == "demo:chunked") {
            body = "{\"status\":\"success\",\"value\":{\"count\":7},\"logLines\":[]}"
            convex_send(handle, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                "Transfer-Encoding: chunked\r\n\r\n", 2000)
            convex_send(handle, sprintf("%x\r\n%s\r\n", 20, substr(body, 1, 20)), 2000)
            convex_send(handle, sprintf("%x\r\n%s\r\n", length(body) - 20, substr(body, 21)), 2000)
            convex_send(handle, "0\r\n\r\n", 2000)
        } else if (path == "demo:garbage") {
            convex_send(handle, "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\n" \
                "not-json!", 2000)
        } else if (path == "demo:silent") {
            # Hold the connection open and say nothing. Only the client's own
            # read deadline can end this exchange.
            control_line(3000)
            convex_close(handle)
            continue
        } else if (path == "demo:badlogs") {
            json_response(handle, "{\"status\":\"success\",\"value\":1,\"logLines\":[7]}")
        } else if (path == "demo:http500") {
            json_response_status(handle, "500 Internal Server Error",
                "{\"status\":\"success\",\"value\":{\"wrong\":true},\"logLines\":[]}")
        } else if (path == "demo:missingmessage") {
            json_response(handle, "{\"status\":\"error\",\"errorData\":{\"code\":\"X\"},\"logLines\":[]}")
        } else if (path == "demo:clte") {
            body = "{\"status\":\"success\",\"value\":null,\"logLines\":[]}"
            convex_send(handle, "HTTP/1.1 200 OK\r\nContent-Length: " length(body) \
                "\r\nTransfer-Encoding: chunked\r\n\r\n" body, 2000)
        } else if (path == "demo:oversizedchunk") {
            convex_send(handle, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n200000\r\n", 2000)
        } else if (path == "demo:badchunk") {
            convex_send(handle, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX0\r\n\r\n", 2000)
        } else {
            json_response(handle, "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
        }
        convex_close(handle)
    }
    return 0
}

# --------------------------------------------------------------------------
# Sync role
#
# A scripted Convex sync server. It completes the RFC6455 upgrade, tracks the
# query set the client asks for, and emits Transitions when the test tells it
# to. Timestamps are canonical little-endian uint64 base64, the same shape the
# real deployment uses.
# --------------------------------------------------------------------------

function timestamp(counter,    bytes, position, group, result, first, second, third) {
    # Little-endian uint64 for a small counter: only the low byte varies.
    bytes[0] = counter % 256
    bytes[1] = int(counter / 256) % 256
    for (position = 2; position < 8; position++) {
        bytes[position] = 0
    }
    result = ""
    for (group = 0; group < 2; group++) {
        first = bytes[group * 3]
        second = bytes[group * 3 + 1]
        third = bytes[group * 3 + 2]
        result = result substr(B64, int(first / 4) + 1, 1)
        result = result substr(B64, (first % 4) * 16 + int(second / 16) + 1, 1)
        result = result substr(B64, (second % 16) * 4 + int(third / 64) + 1, 1)
        result = result substr(B64, (third % 64) + 1, 1)
    }
    first = bytes[6]
    second = bytes[7]
    result = result substr(B64, int(first / 4) + 1, 1)
    result = result substr(B64, (first % 4) * 16 + int(second / 16) + 1, 1)
    result = result substr(B64, (second % 16) * 4 + 1, 1)
    return result "="
}

function version_object(query_set, counter) {
    return "{\"querySet\":" query_set ",\"identity\":0,\"ts\":\"" timestamp(counter) "\"}"
}

function accept_websocket(timeout_ms,    handle, request, key, accept, response, leftover) {
    handle = convex_accept(LISTENER, timeout_ms)
    if (handle < 0) {
        return -1
    }
    if (!read_request(handle, 5000, request)) {
        convex_close(handle)
        return -1
    }
    key = header_value(request["head"], "sec-websocket-key")
    accept = convex_sha1_base64(key WS_GUID)
    response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
    response = response "Connection: Upgrade\r\nSec-WebSocket-Accept: " accept "\r\n\r\n"
    convex_send(handle, response, 2000)
    WS_BUFFER = request["body"]
    return handle
}

function sync_send(text) {
    return ws_send(SOCKET, 1, text, 1)
}

# Every connection restarts the sync state, because a reconnecting client also
# restarts from the zero query-set version and the zero timestamp.
function sync_accept(timeout_ms,    handle) {
    handle = accept_websocket(timeout_ms)
    if (handle < 0) {
        return -1
    }
    TIMESTAMP = 0
    REMOTE_QUERY_SET = 0
    PENDING_QUERY_SET = 0
    return handle
}

# A Transition always starts from the version the client currently believes and
# ends at the query-set version it last asked for, exactly like the deployment.
function sync_transition(modifications,    message) {
    message = "{\"type\":\"Transition\",\"startVersion\":" version_object(REMOTE_QUERY_SET, TIMESTAMP)
    TIMESTAMP++
    message = message ",\"endVersion\":" version_object(PENDING_QUERY_SET, TIMESTAMP)
    message = message ",\"modifications\":[" modifications "]}"
    REMOTE_QUERY_SET = PENDING_QUERY_SET
    return sync_send(message)
}

function sync_drain(budget_ms,    deadline) {
    deadline = convex_now_ms() + budget_ms
    while (SOCKET >= 0 && remaining(deadline) > 0) {
        if (!sync_read(remaining(deadline) > 20 ? 20 : remaining(deadline))) {
            return 0
        }
    }
    return 1
}

function sync_read(timeout_ms,    status, frame, node) {
    status = ws_recv(SOCKET, timeout_ms, frame)
    if (status == IO_TIMEOUT) {
        return 1
    }
    if (status != IO_OK) {
        SOCKET = -1
        return 0
    }
    if (frame["kind"] == "close") {
        SOCKET = -1
        return 0
    }
    if (frame["kind"] != "text") {
        return 1
    }
    # Track the query set version the client asked for so later Transitions
    # continue from the version it believes in.
    if (frame["payload"] ~ /"type":"ModifyQuerySet"/) {
        node = frame["payload"]
        sub(/^.*"newVersion":/, "", node)
        sub(/[^0-9].*$/, "", node)
        PENDING_QUERY_SET = node + 0
        SAW_MODIFY++
        if (frame["payload"] ~ /"type":"Add"/) {
            SAW_ADD++
        }
        if (frame["payload"] ~ /"type":"Remove"/) {
            SAW_REMOVE++
        }
    }
    if (frame["payload"] ~ /"type":"Connect"/) {
        SAW_CONNECT++
        CONNECT_MESSAGE = frame["payload"]
    }
    return 1
}

function fixture_sync(    command, words, count, query_id, value, chunk) {
    SOCKET = -1
    for (;;) {
        if (SOCKET < 0) {
            SOCKET = sync_accept(500)
        }
        if (SOCKET >= 0) {
            if (!sync_read(10)) {
                continue
            }
        }
        command = control_line(10)
        if (command == "") {
            continue
        }
        count = split(command, words, / /)
        if (words[1] == "quit") {
            if (SOCKET >= 0) {
                convex_close(SOCKET)
            }
            return 0
        }
        if (SOCKET < 0) {
            # Commands that need a live socket wait for the client to arrive,
            # then let its Connect and ModifyQuerySet land first.
            SOCKET = sync_accept(5000)
            if (SOCKET < 0) {
                continue
            }
            sync_drain(300)
            if (SOCKET < 0) {
                continue
            }
        }
        query_id = words[2] + 0
        if (words[1] == "update") {
            sync_transition("{\"type\":\"QueryUpdated\",\"queryId\":" query_id \
                ",\"value\":{\"count\":" words[3] "},\"logLines\":[]}")
        } else if (words[1] == "fail") {
            sync_transition("{\"type\":\"QueryFailed\",\"queryId\":" query_id \
                ",\"errorMessage\":\"Increment the room to repair this reactive query\"," \
                "\"errorData\":{\"code\":\"" words[3] "\"},\"logLines\":[]}")
        } else if (words[1] == "removed") {
            sync_transition("{\"type\":\"QueryRemoved\",\"queryId\":" query_id "}")
        } else if (words[1] == "ping") {
            ws_send(SOCKET, 9, "keepalive", 1)
        } else if (words[1] == "junk") {
            sync_send("{\"type\":\"Nonsense\"}")
        } else if (words[1] == "closeframe") {
            ws_send(SOCKET, 8, sprintf("%c%c", 3, 232), 1)
            convex_close(SOCKET)
            SOCKET = -1
        } else if (words[1] == "drop") {
            convex_close(SOCKET)
            SOCKET = -1
        } else if (words[1] == "fragment2") {
            ws_send(SOCKET, 9, "mid-message", 1)
            ws_send(SOCKET, 0, substr(FRAGMENT, FRAGMENT_CHUNK + 1,
                FRAGMENT_CHUNK), 0)
        } else if (words[1] == "fragment3") {
            ws_send(SOCKET, 0, substr(FRAGMENT, FRAGMENT_CHUNK * 2 + 1), 1)
        } else if (words[1] == "fragment") {
            # One logical message split across three frames with a control
            # frame interleaved. The test sends fragment2 and fragment3 later,
            # so the client's parser has to survive read timeouts mid-message.
            value = "{\"type\":\"Transition\",\"startVersion\":" version_object(REMOTE_QUERY_SET, TIMESTAMP)
            TIMESTAMP++
            value = value ",\"endVersion\":" version_object(PENDING_QUERY_SET, TIMESTAMP)
            REMOTE_QUERY_SET = PENDING_QUERY_SET
            value = value ",\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":" query_id \
                ",\"value\":{\"count\":" words[3] ",\"note\":\"fragmented \303\251\"},\"logLines\":[]}]}"
            FRAGMENT = value
            FRAGMENT_CHUNK = int(length(value) / 3)
            ws_send(SOCKET, 1, substr(value, 1, FRAGMENT_CHUNK), 0)
        } else if (words[1] == "report") {
            print "connect=" SAW_CONNECT " modify=" SAW_MODIFY " add=" SAW_ADD \
                " remove=" SAW_REMOVE
            print CONNECT_MESSAGE
            fflush("/dev/stdout")
        }
    }
}

# --------------------------------------------------------------------------
# Deployment role
#
# A miniature counter deployment that answers both halves of the canonical
# example on one port: the documented HTTP endpoints and the sync WebSocket. It
# holds one counter, so the example's 0 -> 1 journey is reproduced end to end
# without a real backend.
# --------------------------------------------------------------------------

function deployment_state(room) {
    return "{\"room\":\"" room "\",\"count\":" COUNT ",\"lastLanguage\":null," \
        "\"latestRunId\":null,\"updatedAt\":null}"
}

function deployment_publish(    modifications) {
    if (SOCKET < 0 || QUERY_ID == "") {
        return 0
    }
    modifications = "{\"type\":\"QueryUpdated\",\"queryId\":" QUERY_ID \
        ",\"value\":" deployment_state(ROOM) ",\"logLines\":[]}"
    return sync_transition(modifications)
}

function deployment_upgrade(handle, request,    key, accept, response) {
    key = header_value(request["head"], "sec-websocket-key")
    accept = convex_sha1_base64(key WS_GUID)
    response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
    response = response "Connection: Upgrade\r\nSec-WebSocket-Accept: " accept "\r\n\r\n"
    convex_send(handle, response, 2000)
    SOCKET = handle
    QUERY_ID = ""
    TIMESTAMP = 0
    REMOTE_QUERY_SET = 0
    PENDING_QUERY_SET = 0
    WS_BUFFER = request["body"]
    return handle
}

function deployment_sync(timeout_ms,    status, frame, payload, added) {
    status = ws_recv(SOCKET, timeout_ms, frame)
    if (status == IO_TIMEOUT) {
        return 1
    }
    if (status != IO_OK || frame["kind"] == "close") {
        convex_close(SOCKET)
        SOCKET = -1
        return 1
    }
    if (frame["kind"] != "text") {
        return 1
    }
    payload = frame["payload"]
    if (payload ~ /"type":"ModifyQuerySet"/) {
        added = payload
        sub(/^.*"newVersion":/, "", added)
        sub(/[^0-9].*$/, "", added)
        PENDING_QUERY_SET = added + 0
        if (payload ~ /"type":"Add"/) {
            added = payload
            sub(/^.*"type":"Add","queryId":/, "", added)
            sub(/[^0-9].*$/, "", added)
            QUERY_ID = added + 0
            # The deployment hydrates a new query straight away.
            deployment_publish()
        }
        if (payload ~ /"type":"Remove"/) {
            QUERY_ID = ""
        }
    }
    return 1
}

function fixture_deployment(    handle, request, path, body) {
    COUNT = 0
    ROOM = "example"
    SOCKET = -1
    QUERY_ID = ""
    while (!QUIT) {
        if (SOCKET >= 0) {
            deployment_sync(10)
        }
        handle = convex_accept(LISTENER, 200)
        if (handle >= 0) {
            if (!read_request(handle, 5000, request)) {
                convex_close(handle)
            } else if (tolower(request["head"]) ~ /upgrade: *websocket/) {
                deployment_upgrade(handle, request)
            } else {
                path = request["body"]
                sub(/^.*"path":"/, "", path)
                sub(/".*$/, "", path)
                body = request["body"]
                if (match(body, /"room":"[^"]*"/)) {
                    ROOM = substr(body, RSTART + 8, RLENGTH - 9)
                }
                if (path == "demo:increment") {
                    COUNT++
                    json_response(handle, "{\"status\":\"success\",\"value\":{\"applied\":true," \
                        "\"state\":" deployment_state(ROOM) "},\"logLines\":[]}")
                    convex_close(handle)
                    # The mutation is visible to the subscription immediately
                    # afterwards, exactly as a reactive query would be.
                    deployment_publish()
                    continue
                }
                json_response(handle, "{\"status\":\"success\",\"value\":" \
                    deployment_state(ROOM) ",\"logLines\":[]}")
                convex_close(handle)
            }
        }
        control_line(10)
    }
    return 0
}

# --------------------------------------------------------------------------
# TLS role: a real TLS peer for the transport test.
# --------------------------------------------------------------------------

function fixture_tls(    handle, request, served) {
    for (served = 0; served < 8 && !QUIT; served++) {
        handle = convex_test_tls_accept(LISTENER, CERTIFICATE, KEY, 1000)
        if (handle < 0) {
            control_line(0)
            continue
        }
        if (read_request(handle, 5000, request)) {
            json_response(handle, "{\"status\":\"success\",\"value\":{\"count\":0},\"logLines\":[]}")
        }
        convex_close(handle)
    }
    return 0
}
