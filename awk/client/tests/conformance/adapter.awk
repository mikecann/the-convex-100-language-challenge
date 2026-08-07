# NDJSON adapter protocol v1 for the shared conformance controller.
#
# This is test infrastructure, not public client code. Every operation is
# forwarded to the real client in client/convex.awk; nothing here talks to
# Convex directly. Stdout (or the controller socket) carries protocol events
# only, and diagnostics go to stderr.
#
# Awk has one thread, so this loop *is* the Live owner: it alternates between
# pumping the WebSocket owner and reading one controller command, and both
# halves are bounded by monotonic deadlines from the extension.

@include "convex.awk"

BEGIN {
    if (ADAPTER_LIBRARY_ONLY == 1 || ENVIRON["ADAPTER_LIBRARY_ONLY"] == "1") {
        # The language-local adapter tests include this file to exercise its
        # framing and dispatch functions without opening any socket.
        adapter_setup_limits()
    } else {
        exit adapter_main()
    }
}

function adapter_setup_limits() {
    delete ADAPTER_OUT_TEXT
    delete ADAPTER_OUT_SIZE
    delete ADAPTER_OUT_DROP
    ADAPTER_LINE_LIMIT = 1048576
    ADAPTER_OUTPUT_COUNT = 8
    ADAPTER_OUTPUT_BYTES = 4194304
    ADAPTER_PUMP_MS = 15
    ADAPTER_READ_MS = 15
    ADAPTER_FLUSH_MS = 250
    ADAPTER_OUT_HEAD = 1
    ADAPTER_OUT_TAIL = 0
    ADAPTER_OUT_BYTES = 0
    ADAPTER_IN_BUFFER = ""
    ADAPTER_EOF = 0
    ADAPTER_DONE = 0
    ADAPTER_STATUS = 0
    ADAPTER_LANGUAGE = "awk"
    ADAPTER_IMPLEMENTATION = "native-awk-convexext-0.1.0"
    ADAPTER_INPUT = -1
    ADAPTER_OUTPUT = -1
}

function adapter_diagnostic(text) {
    print "convex-adapter: " text > "/dev/stderr"
    fflush("/dev/stderr")
}

function adapter_main(    url, listener, address, host, port, separator) {
    adapter_setup_limits()

    url = ENVIRON["CONVEX_URL"]
    if (url == "") {
        adapter_diagnostic("CONVEX_URL is required")
        return 1
    }
    if (!convex_open(url, "awk-0.1.0")) {
        adapter_diagnostic(convex_error_message())
        return 1
    }

    address = ENVIRON["ADAPTER_LISTEN"]
    if (address == "") {
        # Stdin and stdout carry the same NDJSON stream when the controller
        # runs the adapter as a child process.
        ADAPTER_INPUT = convex_attach(0)
        ADAPTER_OUTPUT = convex_attach(1)
        if (ADAPTER_INPUT < 0 || ADAPTER_OUTPUT < 0) {
            adapter_diagnostic("cannot attach to stdin and stdout: " convex_last_error())
            return 1
        }
    } else {
        separator = adapter_last_colon(address)
        if (separator < 2) {
            adapter_diagnostic("ADAPTER_LISTEN must be host:port")
            return 1
        }
        host = substr(address, 1, separator - 1)
        port = substr(address, separator + 1) + 0
        listener = convex_listen(host, port)
        if (listener < 0) {
            adapter_diagnostic("cannot listen on " address ": " convex_last_error())
            return 1
        }
        # The isolated harness starts this container first, so the accept
        # deadline has to cover the controller's own start-up.
        ADAPTER_INPUT = convex_accept(listener, 120000)
        if (ADAPTER_INPUT < 0) {
            adapter_diagnostic("no controller connected: " convex_last_error())
            return 1
        }
        convex_close(listener)
        ADAPTER_OUTPUT = ADAPTER_INPUT
    }

    adapter_loop()
    adapter_flush(ADAPTER_FLUSH_MS)
    return ADAPTER_STATUS
}

function adapter_last_colon(text,    position, found) {
    found = 0
    for (position = 1; position <= length(text); position++) {
        if (substr(text, position, 1) == ":") {
            found = position
        }
    }
    return found
}

function adapter_loop(    line) {
    while (!ADAPTER_DONE) {
        # Give the Live owner a slice, publish whatever it produced, then take
        # at most one controller command.
        convex_live_pump(ADAPTER_PUMP_MS)
        adapter_publish_updates()
        line = adapter_read_line(ADAPTER_READ_MS)
        if (line != "") {
            adapter_command(line)
        } else if (ADAPTER_EOF) {
            return
        }
        adapter_flush(ADAPTER_FLUSH_MS)
    }
}

# ---------------------------------------------------------------------------
# Controller input
# ---------------------------------------------------------------------------

function adapter_read_line(timeout_ms,    deadline, status, chunk, newline, line) {
    deadline = convex_now_ms() + timeout_ms
    for (;;) {
        newline = index(ADAPTER_IN_BUFFER, "\n")
        if (newline > 0) {
            line = substr(ADAPTER_IN_BUFFER, 1, newline - 1)
            ADAPTER_IN_BUFFER = substr(ADAPTER_IN_BUFFER, newline + 1)
            sub(/\r$/, "", line)
            return line
        }
        if (length(ADAPTER_IN_BUFFER) > ADAPTER_LINE_LIMIT) {
            adapter_diagnostic("controller line exceeds " ADAPTER_LINE_LIMIT " bytes")
            ADAPTER_IN_BUFFER = ""
            ADAPTER_EOF = 1
            ADAPTER_STATUS = 1
            return ""
        }
        if (ADAPTER_EOF) {
            return ""
        }
        status = convex_recv(ADAPTER_INPUT, 65536, cx_remaining(deadline), chunk)
        if (status == CX_IO_OK) {
            ADAPTER_IN_BUFFER = ADAPTER_IN_BUFFER chunk["data"]
            continue
        }
        if (status == CX_IO_TIMEOUT) {
            return ""
        }
        if (status == CX_IO_EOF) {
            ADAPTER_EOF = 1
            return ""
        }
        adapter_diagnostic("controller read failed: " chunk["error"])
        ADAPTER_EOF = 1
        ADAPTER_STATUS = 1
        return ""
    }
}

# ---------------------------------------------------------------------------
# Controller output
#
# Events are charged before they are queued and stay charged while a write is
# in flight, so a controller that stops reading cannot hide memory in a blocked
# writer. Responses are never dropped; subscription events are.
# ---------------------------------------------------------------------------

function adapter_emit(text, droppable,    position, size) {
    size = length(text) + 64
    position = ++ADAPTER_OUT_TAIL
    ADAPTER_OUT_TEXT[position] = text
    ADAPTER_OUT_SIZE[position] = size
    ADAPTER_OUT_DROP[position] = droppable
    ADAPTER_OUT_BYTES += size
    while (adapter_output_count() > ADAPTER_OUTPUT_COUNT ||
           ADAPTER_OUT_BYTES > ADAPTER_OUTPUT_BYTES) {
        if (!adapter_drop_oldest()) {
            # Only responses are left and the budget is still exceeded. Failing
            # loudly is the bounded answer; silently growing is not.
            adapter_diagnostic("output budget exhausted by undroppable responses")
            ADAPTER_OUT_BYTES -= ADAPTER_OUT_SIZE[position]
            delete ADAPTER_OUT_TEXT[position]
            delete ADAPTER_OUT_SIZE[position]
            delete ADAPTER_OUT_DROP[position]
            while (ADAPTER_OUT_TAIL >= ADAPTER_OUT_HEAD &&
                   !(ADAPTER_OUT_TAIL in ADAPTER_OUT_TEXT)) {
                ADAPTER_OUT_TAIL--
            }
            ADAPTER_DONE = 1
            ADAPTER_STATUS = 1
            return 0
        }
    }
    return 1
}

function adapter_output_count(    position, count) {
    count = 0
    for (position = ADAPTER_OUT_HEAD; position <= ADAPTER_OUT_TAIL; position++) {
        if (position in ADAPTER_OUT_TEXT) {
            count++
        }
    }
    return count
}

function adapter_drop_oldest(    position) {
    for (position = ADAPTER_OUT_HEAD; position <= ADAPTER_OUT_TAIL; position++) {
        if (!(position in ADAPTER_OUT_TEXT)) {
            continue
        }
        if (!ADAPTER_OUT_DROP[position]) {
            continue
        }
        ADAPTER_OUT_BYTES -= ADAPTER_OUT_SIZE[position]
        delete ADAPTER_OUT_TEXT[position]
        delete ADAPTER_OUT_SIZE[position]
        delete ADAPTER_OUT_DROP[position]
        ADAPTER_DROPPED++
        return 1
    }
    return 0
}

function adapter_flush(budget_ms,    deadline, position, status) {
    if (ADAPTER_OUTPUT < 0) {
        return 0
    }
    deadline = convex_now_ms() + budget_ms
    for (position = ADAPTER_OUT_HEAD; position <= ADAPTER_OUT_TAIL; position++) {
        if (!(position in ADAPTER_OUT_TEXT)) {
            ADAPTER_OUT_HEAD = position + 1
            continue
        }
        status = convex_send(ADAPTER_OUTPUT, ADAPTER_OUT_TEXT[position] "\n",
            cx_remaining(deadline))
        if (status != CX_IO_OK) {
            if (status == CX_IO_TIMEOUT) {
                return 0
            }
            adapter_diagnostic("controller write failed: " convex_last_error())
            ADAPTER_DONE = 1
            ADAPTER_STATUS = 1
            return 0
        }
        ADAPTER_OUT_BYTES -= ADAPTER_OUT_SIZE[position]
        delete ADAPTER_OUT_TEXT[position]
        delete ADAPTER_OUT_SIZE[position]
        delete ADAPTER_OUT_DROP[position]
        ADAPTER_OUT_HEAD = position + 1
    }
    if (ADAPTER_OUT_HEAD > ADAPTER_OUT_TAIL) {
        ADAPTER_OUT_HEAD = 1
        ADAPTER_OUT_TAIL = 0
        ADAPTER_OUT_BYTES = 0
    }
    return 1
}

# ---------------------------------------------------------------------------
# Event shapes
#
# The shared schema forbids serialising an absent field as null, so each event
# is built from exactly the members it has.
# ---------------------------------------------------------------------------

function adapter_error_object(name, message, data) {
    return "{\"name\":" cx_json_quote(name) \
        ",\"message\":" cx_json_quote(message) \
        ",\"data\":" (data == "" ? "null" : data) "}"
}

function adapter_ready(id) {
    return "{\"protocolVersion\":1,\"id\":" cx_json_quote(id) \
        ",\"type\":\"ready\",\"language\":" cx_json_quote(ADAPTER_LANGUAGE) \
        ",\"implementation\":" cx_json_quote(ADAPTER_IMPLEMENTATION) \
        ",\"runtime\":" cx_json_quote(convex_runtime_version()) "}"
}

function adapter_result(id, value, logs) {
    return "{\"id\":" cx_json_quote(id) ",\"type\":\"result\",\"value\":" value \
        ",\"logs\":" (logs == "" ? "[]" : logs) "}"
}

function adapter_error(id, name, message, data) {
    return "{" (adapter_id_valid(id) ? "\"id\":" cx_json_quote(id) "," : "") \
        "\"type\":\"error\",\"error\":" \
        adapter_error_object(name, message, data) "}"
}

function adapter_ack(id) {
    return "{\"id\":" cx_json_quote(id) ",\"type\":\"ack\"}"
}

function adapter_closed(id) {
    return "{\"id\":" cx_json_quote(id) ",\"type\":\"closed\"}"
}

function adapter_subscription_value(subscription_id, value, logs) {
    return "{\"type\":\"subscription\",\"subscriptionId\":" cx_json_quote(subscription_id) \
        ",\"value\":" value ",\"logs\":" (logs == "" ? "[]" : logs) "}"
}

function adapter_subscription_error(subscription_id, name, message, data, logs) {
    return "{\"type\":\"subscription\",\"subscriptionId\":" cx_json_quote(subscription_id) \
        ",\"error\":" adapter_error_object(name, message, data) \
        (logs == "" || logs == "[]" ? "" : ",\"logs\":" logs) "}"
}

function adapter_publish_updates(    update) {
    while (convex_next_update(update)) {
        if (update["errorName"] != "") {
            adapter_emit(adapter_subscription_error(update["tag"], update["errorName"],
                update["errorMessage"], update["errorData"], update["logs"]), 1)
        } else {
            adapter_emit(adapter_subscription_value(update["tag"], update["value"],
                update["logs"]), 1)
        }
    }
}

# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

function adapter_id_valid(value,    position, byte, count) {
    if (value == "" || !convex_utf8_valid(value)) {
        return 0
    }
    count = 0
    for (position = 1; position <= length(value); position++) {
        byte = CX_ORD[substr(value, position, 1)]
        if (byte < 128 || byte >= 192) {
            count++
        }
    }
    return count >= 1 && count <= 128
}

function adapter_object_allowed(root, allowed,    position, key, seen) {
    for (position = 1; position <= cx_json_count(root); position++) {
        key = cx_json_key(root, position)
        if (key in seen || index("," allowed ",", "," key ",") == 0) {
            return 0
        }
        seen[key] = 1
    }
    return 1
}

function adapter_required_string(root, key, id_kind,    node, value) {
    node = cx_json_find(root, key)
    if (node < 0 || cx_json_type(node) != "string") {
        return 0
    }
    value = cx_json_text(node)
    return id_kind ? adapter_id_valid(value) : 1
}

function adapter_validate_command(root, operation,    node, version) {
    ADAPTER_VALIDATION_ERROR = "command does not match adapter protocol v1"
    if (!adapter_required_string(root, "id", 1) ||
        !adapter_required_string(root, "op", 0)) {
        return 0
    }
    if (operation == "hello") {
        node = cx_json_find(root, "protocolVersion")
        return adapter_object_allowed(root, "protocolVersion,id,op") &&
            node >= 0 && cx_json_type(node) == "number" &&
            convex_integral(cx_json_text(node)) && cx_json_text(node) + 0 == 1
    }
    if (operation == "query" || operation == "mutation" || operation == "action") {
        node = cx_json_find(root, "args")
        return adapter_object_allowed(root, "id,op,path,args") &&
            adapter_required_string(root, "path", 0) &&
            length(cx_json_text(cx_json_find(root, "path"))) >= 3 &&
            node >= 0 && cx_json_type(node) == "object"
    }
    if (operation == "setAuth") {
        return adapter_object_allowed(root, "id,op,token") &&
            adapter_required_string(root, "token", 0)
    }
    if (operation == "subscribe" || operation == "unsubscribe") {
        node = cx_json_find(root, "args")
        if (!adapter_object_allowed(root, "id,op,subscriptionId,path,args") ||
            !adapter_required_string(root, "subscriptionId", 1)) {
            return 0
        }
        if (cx_json_find(root, "path") >= 0 && !adapter_required_string(root, "path", 0)) {
            return 0
        }
        return node < 0 || cx_json_type(node) == "object"
    }
    if (operation == "debugDisconnect" || operation == "close") {
        return adapter_object_allowed(root, "id,op")
    }
    ADAPTER_VALIDATION_ERROR = "unknown operation: " operation
    return 0
}

function adapter_command(line,    mark, root, id, operation, node, path, arguments, subscription_id, token, version) {
    mark = cx_json_mark()
    root = cx_json_parse(line, ADAPTER_LINE_LIMIT)
    if (root < 0 || cx_json_type(root) != "object") {
        cx_json_release(mark)
        adapter_emit("{\"type\":\"error\",\"error\":" \
            adapter_error_object("ProtocolError", "the controller sent invalid JSON", "null") "}", 0)
        return 0
    }

    node = cx_json_find(root, "id")
    id = (node >= 0 && cx_json_type(node) == "string") ? cx_json_text(node) : ""
    node = cx_json_find(root, "op")
    operation = (node >= 0 && cx_json_type(node) == "string") ? cx_json_text(node) : ""

    if (!adapter_validate_command(root, operation)) {
        cx_json_release(mark)
        adapter_emit(adapter_error(id, "ProtocolError", ADAPTER_VALIDATION_ERROR, "null"), 0)
        return 0
    }

    node = cx_json_find(root, "path")
    path = (node >= 0 && cx_json_type(node) == "string") ? cx_json_text(node) : ""
    node = cx_json_find(root, "args")
    arguments = (node >= 0) ? cx_json_encode(node) : "{}"
    node = cx_json_find(root, "subscriptionId")
    subscription_id = (node >= 0 && cx_json_type(node) == "string") ? cx_json_text(node) : ""
    node = cx_json_find(root, "token")
    token = (node >= 0 && cx_json_type(node) == "string") ? cx_json_text(node) : ""
    node = cx_json_find(root, "protocolVersion")
    version = (node >= 0 && cx_json_type(node) == "number") ? cx_json_text(node) + 0 : 0
    cx_json_release(mark)

    if (operation == "hello") {
        adapter_emit(adapter_ready(id), 0)
        return 1
    }
    if (operation == "query" || operation == "mutation" || operation == "action") {
        return adapter_call(id, operation, path, arguments)
    }
    if (operation == "setAuth") {
        if (!convex_set_auth(token)) {
            adapter_emit(adapter_error(id, convex_error_name(), convex_error_message(),
                convex_error_data()), 0)
            return 0
        }
        adapter_emit(adapter_ack(id), 0)
        return 1
    }
    if (operation == "subscribe" || operation == "unsubscribe") {
        if (subscription_id == "") {
            adapter_emit(adapter_error(id, "ProtocolError",
                operation " requires a subscription identifier", "null"), 0)
            return 0
        }
    }
    if (operation == "subscribe") {
        if (!convex_subscribe(subscription_id, path, arguments)) {
            adapter_emit(adapter_error(id, convex_error_name(), convex_error_message(),
                convex_error_data()), 0)
            return 0
        }
        adapter_emit(adapter_ack(id), 0)
        return 1
    }
    if (operation == "unsubscribe") {
        # convex_unsubscribe retires the old relay and purges anything it had
        # queued before returning, so this acknowledgement is a real barrier.
        convex_unsubscribe(subscription_id)
        adapter_emit(adapter_ack(id), 0)
        return 1
    }
    if (operation == "debugDisconnect") {
        if (!convex_debug_disconnect()) {
            adapter_emit(adapter_error(id, convex_error_name(), convex_error_message(),
                convex_error_data()), 0)
            return 0
        }
        adapter_emit(adapter_ack(id), 0)
        return 1
    }
    if (operation == "close") {
        convex_close_live(1000)
        adapter_emit(adapter_closed(id), 0)
        ADAPTER_DONE = 1
        return 1
    }
    return 0
}

function adapter_call(id, operation, path, arguments,    outcome, response) {
    if (operation == "query") {
        outcome = convex_query(path, arguments, response)
    } else if (operation == "mutation") {
        outcome = convex_mutation(path, arguments, response)
    } else {
        outcome = convex_action(path, arguments, response)
    }
    if (outcome) {
        adapter_emit(adapter_result(id, response["value"], response["logs"]), 0)
        return 1
    }
    # A structured failure stays structured: function, protocol, and transport
    # errors are distinct names and never collapse into a successful value.
    adapter_emit(adapter_error(id, convex_error_name(), convex_error_message(),
        convex_error_data()), 0)
    return 0
}
