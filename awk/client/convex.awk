# convex.awk - a native Convex client written in GNU Awk.
#
# The Convex behaviour lives here: the documented JSON HTTP envelope, a JSON
# reader and writer, the pinned Live sync profile, and the single-owner Live
# state machine that reconnects and replays subscriptions. The convexext gawk
# extension underneath supplies only what an ordinary language runtime would
# already give an implementer: deadline-bounded TCP/TLS sockets, a monotonic
# clock, SHA-1/base64/randomness, and RFC6455 frame encode/decode.
#
# Include it with `@include "convex.awk"` and open a client with convex_open().

@load "convexext"

BEGIN {
    cx_setup()
}

# ---------------------------------------------------------------------------
# Constants and lookup tables
# ---------------------------------------------------------------------------

function cx_setup(    index_, character) {
    if (CX_READY == 1) {
        return
    }
    CX_READY = 1

    CX_HEX_DIGITS = "0123456789abcdef"

    # Byte tables. The client runs under LC_ALL=C so every Awk string operation
    # is a byte operation, which is what keeps UTF-8 payloads intact.
    for (index_ = 1; index_ < 256; index_++) {
        character = sprintf("%c", index_)
        CX_CHR[index_] = character
        CX_ORD[character] = index_
    }
    for (index_ = 0; index_ < 16; index_++) {
        CX_HEX_VALUE[substr(CX_HEX_DIGITS, index_ + 1, 1)] = index_
        CX_HEX_VALUE[toupper(substr(CX_HEX_DIGITS, index_ + 1, 1))] = index_
    }

    # A JSON string only needs escaping for quote, backslash, and C0 controls.
    # Building the class from real bytes avoids depending on how a particular
    # Awk spells numeric escapes inside a regexp.
    CX_ESCAPE_REGEX = "[\"\\\\" CX_CHR[1] "-" CX_CHR[31] "]"

    # Transport status codes, mirrored from convexext.c.
    CX_IO_OK = 1
    CX_IO_TIMEOUT = 0
    CX_IO_EOF = -1
    CX_IO_ERROR = -2

    # Bounds. Awk holds whole values in memory, so these are deliberately far
    # below the shared 128 MiB adapter limit.
    CX_JSON_MAX_BYTES = 1048576
    CX_JSON_MAX_DEPTH = 128
    CX_JSON_MAX_NODES = 8192
    CX_HTTP_MAX_BODY = 1048576
    CX_HTTP_MAX_HEADERS = 65536
    CX_HTTP_CONNECT_MS = 5000
    CX_HTTP_TOTAL_MS = 15000
    CX_LIVE_CONNECT_MS = 5000
    CX_LIVE_WRITE_MS = 2000
    CX_LIVE_MAX_SUBSCRIPTIONS = 64
    # Replay serializes every active Add into one 1 MiB WebSocket message. Keep
    # charged state below that wire limit with room for JSON field overhead.
    CX_LIVE_SUBSCRIPTION_BYTES = 786432
    CX_LIVE_QUEUE_COUNT = 8
    CX_LIVE_QUEUE_BYTES = 4194304
    CX_LIVE_INITIAL_BACKOFF_MS = 100
    CX_LIVE_MAX_BACKOFF_MS = 15000
    CX_LIVE_INITIAL_TIMESTAMP = "AAAAAAAAAAA="
    CX_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    CX_JSON_NEXT = 0
    CX_LIVE_SOCKET = -1
    CX_LIVE_GENERATION = 0
    CX_QUEUE_HEAD = 1
    CX_QUEUE_TAIL = 0
    CX_QUEUE_BYTES = 0
    CX_TOKEN = ""
    CX_ERROR_NAME = ""
    CX_ERROR_MESSAGE = ""
    CX_ERROR_DATA = "null"
}

function cx_fail(name, message) {
    CX_ERROR_NAME = name
    CX_ERROR_MESSAGE = message
    CX_ERROR_DATA = "null"
    return 0
}

function convex_error_name() {
    return CX_ERROR_NAME
}

function convex_error_message() {
    return CX_ERROR_MESSAGE
}

function convex_error_data() {
    return CX_ERROR_DATA
}

# ---------------------------------------------------------------------------
# Byte and encoding helpers
# ---------------------------------------------------------------------------

# A random RFC4122 version 4 session identifier. Convex's sync protocol keys a
# session by this value, so a fresh one per client keeps runs independent.
function cx_uuid(    hex, variant) {
    hex = convex_random_hex(16)
    if (length(hex) != 32) {
        return ""
    }
    variant = substr(CX_HEX_DIGITS, 8 + (CX_HEX_VALUE[substr(hex, 17, 1)] % 4) + 1, 1)
    return substr(hex, 1, 8) "-" substr(hex, 9, 4) "-4" substr(hex, 14, 3) \
        "-" variant substr(hex, 18, 3) "-" substr(hex, 21, 12)
}

# Encode one Unicode code point as UTF-8 bytes, used when a JSON \uXXXX escape
# has to become the same bytes an unescaped document would have carried.
function cx_utf8(code,    result) {
    if (code < 0x80) {
        return CX_CHR[code]
    }
    if (code < 0x800) {
        return CX_CHR[0xc0 + int(code / 64)] CX_CHR[0x80 + (code % 64)]
    }
    if (code < 0x10000) {
        result = CX_CHR[0xe0 + int(code / 4096)]
        result = result CX_CHR[0x80 + (int(code / 64) % 64)]
        return result CX_CHR[0x80 + (code % 64)]
    }
    result = CX_CHR[0xf0 + int(code / 262144)]
    result = result CX_CHR[0x80 + (int(code / 4096) % 64)]
    result = result CX_CHR[0x80 + (int(code / 64) % 64)]
    return result CX_CHR[0x80 + (code % 64)]
}

# ---------------------------------------------------------------------------
# JSON
#
# Values live in a shared node store rather than in Awk strings so that nested
# documents can be inspected without re-parsing. Nodes are allocated in order
# and released back to a mark, which keeps a long-running adapter bounded.
# ---------------------------------------------------------------------------

function cx_json_mark() {
    return CX_JSON_NEXT
}

function cx_json_release(mark,    node, child) {
    for (node = CX_JSON_NEXT - 1; node >= mark; node--) {
        for (child = 1; child <= CX_JSON_COUNT[node]; child++) {
            delete CX_JSON_KEY[node, child]
            delete CX_JSON_CHILD[node, child]
        }
        delete CX_JSON_TYPE[node]
        delete CX_JSON_VALUE[node]
        delete CX_JSON_COUNT[node]
    }
    CX_JSON_NEXT = mark
}

function cx_json_node(type, value,    node) {
    if (CX_JSON_NEXT >= CX_JSON_MAX_NODES) {
        CX_JSON_ERROR = "JSON document exceeds " CX_JSON_MAX_NODES " nodes"
        return -1
    }
    node = CX_JSON_NEXT++
    CX_JSON_TYPE[node] = type
    CX_JSON_VALUE[node] = value
    CX_JSON_COUNT[node] = 0
    return node
}

function cx_json_type(node) {
    return CX_JSON_TYPE[node]
}

function cx_json_text(node) {
    return CX_JSON_VALUE[node]
}

function cx_json_count(node) {
    return CX_JSON_COUNT[node]
}

function cx_json_child(node, position) {
    if (position < 1 || position > CX_JSON_COUNT[node]) {
        return -1
    }
    return CX_JSON_CHILD[node, position]
}

function cx_json_key(node, position) {
    return CX_JSON_KEY[node, position]
}

function cx_json_find(node, key,    position) {
    if (CX_JSON_TYPE[node] != "object") {
        return -1
    }
    for (position = 1; position <= CX_JSON_COUNT[node]; position++) {
        if (CX_JSON_KEY[node, position] == key) {
            return CX_JSON_CHILD[node, position]
        }
    }
    return -1
}

function cx_json_parse(text, limit,    root) {
    CX_JSON_ERROR = ""
    if (limit == 0) {
        limit = CX_JSON_MAX_BYTES
    }
    if (length(text) > limit) {
        CX_JSON_ERROR = "JSON input exceeds " limit " bytes"
        return -1
    }
    CX_JSON_SOURCE = text
    CX_JSON_POSITION = 1
    CX_JSON_LENGTH = length(text)
    root = cx_json_read_value(0)
    if (root < 0) {
        return -1
    }
    cx_json_skip_space()
    if (CX_JSON_POSITION <= CX_JSON_LENGTH) {
        CX_JSON_ERROR = "trailing content after the JSON value"
        return -1
    }
    return root
}

function cx_json_skip_space(    character) {
    while (CX_JSON_POSITION <= CX_JSON_LENGTH) {
        character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
        if (character != " " && character != "\t" && character != "\n" && character != "\r") {
            return
        }
        CX_JSON_POSITION++
    }
}

function cx_json_read_value(depth,    character) {
    if (depth > CX_JSON_MAX_DEPTH) {
        CX_JSON_ERROR = "JSON nesting exceeds " CX_JSON_MAX_DEPTH " levels"
        return -1
    }
    cx_json_skip_space()
    if (CX_JSON_POSITION > CX_JSON_LENGTH) {
        CX_JSON_ERROR = "JSON value ended early"
        return -1
    }
    character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
    if (character == "{") {
        return cx_json_read_object(depth)
    }
    if (character == "[") {
        return cx_json_read_array(depth)
    }
    if (character == "\"") {
        return cx_json_read_string_node()
    }
    if (character == "t") {
        return cx_json_read_literal("true")
    }
    if (character == "f") {
        return cx_json_read_literal("false")
    }
    if (character == "n") {
        return cx_json_read_literal("null")
    }
    return cx_json_read_number()
}

function cx_json_read_literal(word,    node) {
    if (substr(CX_JSON_SOURCE, CX_JSON_POSITION, length(word)) != word) {
        CX_JSON_ERROR = "unexpected JSON token"
        return -1
    }
    CX_JSON_POSITION += length(word)
    node = cx_json_node(word, word)
    return node
}

function cx_json_read_number(    start, character, literal) {
    start = CX_JSON_POSITION
    while (CX_JSON_POSITION <= CX_JSON_LENGTH) {
        character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
        if (character !~ /^[-+0-9.eE]$/) {
            break
        }
        CX_JSON_POSITION++
    }
    literal = substr(CX_JSON_SOURCE, start, CX_JSON_POSITION - start)
    if (literal !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
        CX_JSON_ERROR = "invalid JSON number"
        return -1
    }
    # The literal is kept verbatim. Re-encoding through an Awk double would
    # quietly rewrite values such as 1e30 or 0.30000000000000004.
    return cx_json_node("number", literal)
}

function cx_json_read_object(depth,    node, key, child, character, position) {
    node = cx_json_node("object", "")
    if (node < 0) {
        return -1
    }
    CX_JSON_POSITION++
    cx_json_skip_space()
    if (substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1) == "}") {
        CX_JSON_POSITION++
        return node
    }
    for (;;) {
        cx_json_skip_space()
        if (substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1) != "\"") {
            CX_JSON_ERROR = "JSON object key must be a string"
            return -1
        }
        key = cx_json_read_string()
        if (CX_JSON_ERROR != "") {
            return -1
        }
        cx_json_skip_space()
        if (substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1) != ":") {
            CX_JSON_ERROR = "JSON object key is missing its colon"
            return -1
        }
        CX_JSON_POSITION++
        child = cx_json_read_value(depth + 1)
        if (child < 0) {
            return -1
        }
        position = ++CX_JSON_COUNT[node]
        CX_JSON_KEY[node, position] = key
        CX_JSON_CHILD[node, position] = child
        cx_json_skip_space()
        character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
        if (character == ",") {
            CX_JSON_POSITION++
            continue
        }
        if (character == "}") {
            CX_JSON_POSITION++
            return node
        }
        CX_JSON_ERROR = "JSON object is missing a comma or brace"
        return -1
    }
}

function cx_json_read_array(depth,    node, child, character, position) {
    node = cx_json_node("array", "")
    if (node < 0) {
        return -1
    }
    CX_JSON_POSITION++
    cx_json_skip_space()
    if (substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1) == "]") {
        CX_JSON_POSITION++
        return node
    }
    for (;;) {
        child = cx_json_read_value(depth + 1)
        if (child < 0) {
            return -1
        }
        position = ++CX_JSON_COUNT[node]
        CX_JSON_CHILD[node, position] = child
        cx_json_skip_space()
        character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
        if (character == ",") {
            CX_JSON_POSITION++
            continue
        }
        if (character == "]") {
            CX_JSON_POSITION++
            return node
        }
        CX_JSON_ERROR = "JSON array is missing a comma or bracket"
        return -1
    }
}

function cx_json_read_string_node(    text) {
    text = cx_json_read_string()
    if (CX_JSON_ERROR != "") {
        return -1
    }
    return cx_json_node("string", text)
}

function cx_json_read_string(    result, character, code, low) {
    result = ""
    CX_JSON_POSITION++
    for (;;) {
        if (CX_JSON_POSITION > CX_JSON_LENGTH) {
            CX_JSON_ERROR = "JSON string is unterminated"
            return ""
        }
        character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
        if (character == "\"") {
            CX_JSON_POSITION++
            return result
        }
        if (character == "\\") {
            CX_JSON_POSITION++
            character = substr(CX_JSON_SOURCE, CX_JSON_POSITION, 1)
            if (character == "\"" || character == "\\" || character == "/") {
                result = result character
            } else if (character == "b") {
                result = result CX_CHR[8]
            } else if (character == "f") {
                result = result CX_CHR[12]
            } else if (character == "n") {
                result = result "\n"
            } else if (character == "r") {
                result = result "\r"
            } else if (character == "t") {
                result = result "\t"
            } else if (character == "u") {
                code = cx_json_read_hex4()
                if (CX_JSON_ERROR != "") {
                    return ""
                }
                if (code >= 0xdc00 && code <= 0xdfff) {
                    CX_JSON_ERROR = "JSON string has an unpaired low surrogate"
                    return ""
                }
                if (code >= 0xd800 && code <= 0xdbff) {
                    if (substr(CX_JSON_SOURCE, CX_JSON_POSITION + 1, 2) != "\\u") {
                        CX_JSON_ERROR = "JSON string has an unpaired high surrogate"
                        return ""
                    }
                    CX_JSON_POSITION += 2
                    low = cx_json_read_hex4()
                    if (CX_JSON_ERROR != "") {
                        return ""
                    }
                    if (low < 0xdc00 || low > 0xdfff) {
                        CX_JSON_ERROR = "JSON surrogate pair is malformed"
                        return ""
                    }
                    code = 0x10000 + (code - 0xd800) * 1024 + (low - 0xdc00)
                }
                if (code == 0) {
                    # An embedded NUL cannot survive Awk string handling, so it
                    # is refused rather than silently truncating a value.
                    CX_JSON_ERROR = "JSON strings containing U+0000 are unsupported"
                    return ""
                }
                result = result cx_utf8(code)
            } else {
                CX_JSON_ERROR = "unsupported JSON escape"
                return ""
            }
            CX_JSON_POSITION++
            continue
        }
        if (CX_ORD[character] < 32) {
            CX_JSON_ERROR = "JSON string has an unescaped control character"
            return ""
        }
        result = result character
        CX_JSON_POSITION++
    }
}

function cx_json_read_hex4(    text, position, digit, code) {
    text = substr(CX_JSON_SOURCE, CX_JSON_POSITION + 1, 4)
    if (length(text) != 4) {
        CX_JSON_ERROR = "JSON \\u escape is truncated"
        return 0
    }
    code = 0
    for (position = 1; position <= 4; position++) {
        digit = substr(text, position, 1)
        if (digit !~ /^[0-9a-fA-F]$/) {
            CX_JSON_ERROR = "JSON \\u escape is not hexadecimal"
            return 0
        }
        code = code * 16 + CX_HEX_VALUE[digit]
    }
    CX_JSON_POSITION += 4
    return code
}

function cx_json_quote(text,    result, position, character, code) {
    if (text !~ CX_ESCAPE_REGEX) {
        return "\"" text "\""
    }
    result = "\""
    for (position = 1; position <= length(text); position++) {
        character = substr(text, position, 1)
        code = CX_ORD[character]
        if (character == "\"") {
            result = result "\\\""
        } else if (character == "\\") {
            result = result "\\\\"
        } else if (character == "\n") {
            result = result "\\n"
        } else if (character == "\r") {
            result = result "\\r"
        } else if (character == "\t") {
            result = result "\\t"
        } else if (code == 8) {
            result = result "\\b"
        } else if (code == 12) {
            result = result "\\f"
        } else if (code < 32) {
            result = result sprintf("\\u%04x", code)
        } else {
            result = result character
        }
    }
    return result "\""
}

function cx_json_encode(node,    type, result, position) {
    type = CX_JSON_TYPE[node]
    if (type == "object") {
        result = "{"
        for (position = 1; position <= CX_JSON_COUNT[node]; position++) {
            if (position > 1) {
                result = result ","
            }
            result = result cx_json_quote(CX_JSON_KEY[node, position]) ":"
            result = result cx_json_encode(CX_JSON_CHILD[node, position])
        }
        return result "}"
    }
    if (type == "array") {
        result = "["
        for (position = 1; position <= CX_JSON_COUNT[node]; position++) {
            if (position > 1) {
                result = result ","
            }
            result = result cx_json_encode(CX_JSON_CHILD[node, position])
        }
        return result "]"
    }
    if (type == "string") {
        return cx_json_quote(CX_JSON_VALUE[node])
    }
    return CX_JSON_VALUE[node]
}

# Convex log lines are always an array of strings. Anything else is a protocol
# problem rather than a value to forward, so this returns "" to say so.
function cx_logs_text(node,    position) {
    if (node < 0) {
        return "[]"
    }
    if (cx_json_type(node) != "array") {
        return ""
    }
    for (position = 1; position <= cx_json_count(node); position++) {
        if (cx_json_type(cx_json_child(node, position)) != "string") {
            return ""
        }
    }
    return cx_json_encode(node)
}

# Convex may report an integral number as 0 or as 0.0. Accept both, and reject
# fractional, non-finite, or out-of-range values instead of rounding them.
function convex_integral(literal,    value, digits, bound) {
    if (literal !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) {
        return 0
    }
    # A bare integer literal right past the safe-integer boundary (for
    # example 9007199254740993, one past 2^53) rounds down to exactly
    # 9007199254740992 when converted to an Awk double, which would make the
    # range check below pass by losing the very precision it is meant to
    # check. Compare its digits directly instead of trusting that rounding.
    if (literal !~ /[.eE]/) {
        digits = literal
        sub(/^-/, "", digits)
        bound = "9007199254740992"
        if (length(digits) > length(bound) || \
            (length(digits) == length(bound) && digits > bound)) {
            return 0
        }
        return 1
    }
    value = literal + 0
    if (value < -9007199254740992 || value > 9007199254740992) {
        return 0
    }
    return value == int(value)
}

# ---------------------------------------------------------------------------
# Deployment URL
# ---------------------------------------------------------------------------

function cx_parse_url(url, target,    rest, slash, authority, colon, port, suffix) {
    delete target
    if (url ~ ("[" CX_CHR[1] "-" CX_CHR[31] CX_CHR[127] "]") || index(url, "@") > 0 ||
        index(url, "?") > 0 || index(url, "#") > 0) {
        return cx_fail("ConfigError", "deployment URL contains unsupported authority or control data")
    }
    if (url ~ /^https:\/\//) {
        target["secure"] = 1
        rest = substr(url, 9)
    } else if (url ~ /^http:\/\//) {
        target["secure"] = 0
        rest = substr(url, 8)
    } else {
        return cx_fail("ConfigError", "deployment URL must start with http:// or https://")
    }
    slash = index(rest, "/")
    if (slash > 0) {
        authority = substr(rest, 1, slash - 1)
        suffix = substr(rest, slash)
        if (suffix != "/") {
            return cx_fail("ConfigError", "deployment URL must not contain a path")
        }
    } else {
        authority = rest
    }
    if (authority == "") {
        return cx_fail("ConfigError", "deployment URL has no host")
    }
    if (index(authority, "[") > 0) {
        return cx_fail("ConfigError", "bracketed IPv6 deployment URLs are not supported")
    }
    colon = match(authority, /:[0-9]+$/)
    if (colon > 0) {
        target["host"] = substr(authority, 1, colon - 1)
        port = substr(authority, colon + 1) + 0
        if (port < 1 || port > 65535) {
            return cx_fail("ConfigError", "deployment URL port is invalid")
        }
        target["port"] = port
    } else {
        target["host"] = authority
        target["port"] = target["secure"] ? 443 : 80
    }
    if (target["host"] == "") {
        return cx_fail("ConfigError", "deployment URL has no host")
    }
    if (target["host"] !~ /^[A-Za-z0-9.-]+$/ || target["host"] ~ /^\./ ||
        target["host"] ~ /\.$/ || target["host"] ~ /\.\./) {
        return cx_fail("ConfigError", "deployment URL host is invalid")
    }
    target["hostHeader"] = target["host"]
    if ((target["secure"] && target["port"] != 443) ||
        (!target["secure"] && target["port"] != 80)) {
        target["hostHeader"] = target["hostHeader"] ":" target["port"]
    }
    return 1
}

function convex_open(url, client_version,    parsed) {
    cx_setup()
    if (!cx_parse_url(url, parsed)) {
        return 0
    }
    CX_URL = url
    CX_SECURE = parsed["secure"]
    CX_HOST = parsed["host"]
    CX_PORT = parsed["port"]
    CX_HOST_HEADER = parsed["hostHeader"]
    CX_CLIENT_VERSION = client_version == "" ? "awk-0.1.0" : client_version
    if (!cx_header_value(CX_CLIENT_VERSION)) {
        return cx_fail("ConfigError", "client version is not a safe HTTP header value")
    }
    CX_TOKEN = ""
    CX_SESSION_ID = cx_uuid()
    if (CX_SESSION_ID == "") {
        return cx_fail("ConfigError", "cannot generate a session identifier")
    }
    CX_LIVE_LAST_CLOSE = "InitialConnect"
    CX_LIVE_MAX_TIMESTAMP = CX_LIVE_INITIAL_TIMESTAMP
    CX_LIVE_CONNECTION_COUNT = 0
    CX_LIVE_BACKOFF_MS = CX_LIVE_INITIAL_BACKOFF_MS
    CX_LIVE_NEXT_CONNECT_MS = 0
    CX_LIVE_NEXT_QUERY_ID = 0
    CX_LIVE_QUERY_SET_VERSION = 0
    CX_LIVE_ACTIVE_BYTES = 0
    CX_LIVE_SUBSCRIPTION_COUNT = 0
    CX_LIVE_REMOTE_QUERY_SET = 0
    CX_LIVE_REMOTE_IDENTITY = 0
    CX_LIVE_REMOTE_TIMESTAMP = CX_LIVE_INITIAL_TIMESTAMP
    CX_QUEUE_DROPPED = 0
    return 1
}

# Quote an Awk string as a JSON string. Callers build small argument objects
# with it instead of pasting values into a format string.
function convex_quote(text) {
    return cx_json_quote(text)
}

function convex_set_auth(token) {
    if (!cx_header_value(token)) {
        return cx_fail("ClientError", "auth token is not a safe HTTP header value")
    }
    CX_TOKEN = token
    return 1
}

function cx_header_value(value) {
    return length(value) <= 8192 && value !~ ("[" CX_CHR[1] "-" CX_CHR[31] CX_CHR[127] "]")
}

# Deadlines are part of the client's contract, so they are configurable rather
# than hidden. A zero leaves that budget unchanged.
function convex_set_timeouts(connect_ms, total_ms, live_connect_ms, live_write_ms) {
    if (connect_ms > 0) {
        CX_HTTP_CONNECT_MS = connect_ms
    }
    if (total_ms > 0) {
        CX_HTTP_TOTAL_MS = total_ms
    }
    if (live_connect_ms > 0) {
        CX_LIVE_CONNECT_MS = live_connect_ms
    }
    if (live_write_ms > 0) {
        CX_LIVE_WRITE_MS = live_write_ms
    }
    return 1
}

function convex_runtime_version() {
    return "gawk " PROCINFO["version"] "; " convex_version()
}

# ---------------------------------------------------------------------------
# HTTP transport
#
# One request, one connection. The exchange is bounded end to end: a deadline
# covers connect, write, and the whole response, and the body is capped before
# it can be parsed.
# ---------------------------------------------------------------------------

function cx_http_request(request_path, body, response,    handle, deadline, request, chunk, buffer, header_end, status, headers, length_, remaining, result, connect_budget) {
    delete response
    deadline = convex_now_ms() + CX_HTTP_TOTAL_MS
    connect_budget = cx_remaining(deadline)
    if (connect_budget > CX_HTTP_CONNECT_MS) {
        connect_budget = CX_HTTP_CONNECT_MS
    }
    handle = convex_connect(CX_HOST, CX_PORT, CX_SECURE, connect_budget)
    if (handle < 0) {
        return cx_fail("TransportError", convex_last_error())
    }

    request = "POST " request_path " HTTP/1.1\r\n"
    request = request "Host: " CX_HOST_HEADER "\r\n"
    request = request "Content-Type: application/json\r\n"
    request = request "Accept: application/json\r\n"
    request = request "Connection: close\r\n"
    request = request "Convex-Client: " CX_CLIENT_VERSION "\r\n"
    if (CX_TOKEN != "") {
        # The token is sent verbatim; the client never inspects or reshapes it.
        request = request "Authorization: Bearer " CX_TOKEN "\r\n"
    }
    request = request "Content-Length: " length(body) "\r\n\r\n" body

    if (convex_send(handle, request, cx_remaining(deadline)) != CX_IO_OK) {
        result = convex_last_error()
        convex_close(handle)
        return cx_fail("TransportError", "request write failed: " result)
    }

    buffer = ""
    header_end = 0
    while (header_end == 0) {
        result = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
        if (result == CX_IO_OK) {
            buffer = buffer chunk["data"]
            header_end = index(buffer, "\r\n\r\n")
            if ((header_end == 0 && length(buffer) > CX_HTTP_MAX_HEADERS) ||
                header_end > CX_HTTP_MAX_HEADERS) {
                convex_close(handle)
                return cx_fail("ProtocolError", "HTTP headers exceed the response limit")
            }
            continue
        }
        convex_close(handle)
        if (result == CX_IO_TIMEOUT) {
            return cx_fail("TransportError", "timed out reading the HTTP response header")
        }
        if (result == CX_IO_EOF) {
            return cx_fail("TransportError", "the deployment closed the connection before responding")
        }
        return cx_fail("TransportError", "response read failed: " chunk["error"])
    }

    status = cx_http_status(substr(buffer, 1, header_end - 1))
    if (status < 0) {
        convex_close(handle)
        return 0
    }
    if (!cx_http_headers(substr(buffer, 1, header_end - 1), headers)) {
        convex_close(handle)
        return 0
    }
    buffer = substr(buffer, header_end + 4)

    if (headers["transfer-encoding"] != "" && headers["content-length"] != "") {
        convex_close(handle)
        return cx_fail("ProtocolError", "HTTP response has both Transfer-Encoding and Content-Length")
    }
    if (headers["transfer-encoding"] != "" &&
        tolower(headers["transfer-encoding"]) != "chunked") {
        convex_close(handle)
        return cx_fail("ProtocolError", "HTTP response uses an unsupported transfer encoding")
    }
    if (tolower(headers["transfer-encoding"]) == "chunked") {
        result = cx_http_read_chunked(handle, deadline, buffer, response)
    } else if (headers["content-length"] != "") {
        if (headers["content-length"] !~ /^(0|[1-9][0-9]*)$/) {
            convex_close(handle)
            return cx_fail("ProtocolError", "HTTP Content-Length is invalid")
        }
        length_ = headers["content-length"] + 0
        if (length_ < 0 || length_ > CX_HTTP_MAX_BODY) {
            convex_close(handle)
            return cx_fail("ProtocolError", "HTTP body exceeds the response limit")
        }
        while (length(buffer) < length_) {
            remaining = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
            if (remaining != CX_IO_OK) {
                convex_close(handle)
                return cx_fail("TransportError", "the HTTP body ended early")
            }
            buffer = buffer chunk["data"]
        }
        response["body"] = substr(buffer, 1, length_)
        result = 1
    } else {
        # Connection: close framing. Read until the peer really is finished.
        for (;;) {
            remaining = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
            if (remaining == CX_IO_EOF) {
                break
            }
            if (remaining != CX_IO_OK) {
                convex_close(handle)
                return cx_fail("TransportError", "the HTTP body did not complete")
            }
            buffer = buffer chunk["data"]
            if (length(buffer) > CX_HTTP_MAX_BODY) {
                convex_close(handle)
                return cx_fail("ProtocolError", "HTTP body exceeds the response limit")
            }
        }
        response["body"] = buffer
        result = 1
    }

    convex_close(handle)
    if (!result) {
        return 0
    }
    response["status"] = status
    return 1
}

function cx_remaining(deadline,    left) {
    left = deadline - convex_now_ms()
    return left < 0 ? 0 : left
}

function cx_http_status(header_block,    line, code) {
    line = header_block
    sub(/\r?\n.*$/, "", line)
    if (line !~ /^HTTP\/1\.[01] [0-9][0-9][0-9]([ \t].*)?$/) {
        cx_fail("ProtocolError", "HTTP status line is invalid")
        return -1
    }
    code = substr(line, 10, 3) + 0
    if (code < 100 || code > 599) {
        cx_fail("ProtocolError", "HTTP status code is invalid")
        return -1
    }
    return code
}

function cx_http_headers(header_block, headers,    lines, count, position, line, colon, name, value) {
    delete headers
    count = split(header_block, lines, /\r?\n/)
    for (position = 2; position <= count; position++) {
        line = lines[position]
        if (line ~ /^[ \t]/) {
            return cx_fail("ProtocolError", "folded HTTP headers are not supported")
        }
        colon = index(line, ":")
        if (colon < 2) {
            return cx_fail("ProtocolError", "HTTP header line is malformed")
        }
        name = tolower(substr(line, 1, colon - 1))
        if (name !~ /^[!#$%&'*+.^_`|~0-9a-z-]+$/ || name in headers) {
            return cx_fail("ProtocolError", "HTTP header name is invalid or duplicated")
        }
        value = substr(line, colon + 1)
        sub(/^[ \t]+/, "", value)
        sub(/[ \t]+$/, "", value)
        if (!cx_header_value(value) && value != "") {
            return cx_fail("ProtocolError", "HTTP header value contains control data")
        }
        # Names fold, values do not: Sec-WebSocket-Accept is base64 and its case
        # is significant.
        headers[name] = value
    }
    return 1
}

function cx_http_read_chunked(handle, deadline, buffer, response,    body, line_end, size_line, size, chunk, result, trailers_end, trailer_headers) {
    body = ""
    for (;;) {
        line_end = index(buffer, "\r\n")
        while (line_end == 0) {
            result = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
            if (result != CX_IO_OK) {
                return cx_fail("TransportError", "chunked HTTP body ended early")
            }
            buffer = buffer chunk["data"]
            if (length(buffer) > CX_HTTP_MAX_HEADERS) {
                return cx_fail("ProtocolError", "chunked HTTP size line exceeds the response limit")
            }
            line_end = index(buffer, "\r\n")
        }
        size_line = substr(buffer, 1, line_end - 1)
        sub(/;.*$/, "", size_line)
        if (size_line !~ /^[0-9a-fA-F]+$/) {
            return cx_fail("ProtocolError", "chunked HTTP size is invalid")
        }
        size = cx_hex_value(size_line)
        buffer = substr(buffer, line_end + 2)
        if (size == 0) {
            while (substr(buffer, 1, 2) != "\r\n" && index(buffer, "\r\n\r\n") == 0) {
                if (length(buffer) > CX_HTTP_MAX_HEADERS) {
                    return cx_fail("ProtocolError", "HTTP trailers exceed the response limit")
                }
                result = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
                if (result != CX_IO_OK) {
                    return cx_fail("TransportError", "chunked HTTP trailers ended early")
                }
                buffer = buffer chunk["data"]
            }
            if (substr(buffer, 1, 2) != "\r\n") {
                trailers_end = index(buffer, "\r\n\r\n")
                if (!cx_http_headers("HTTP/1.1 200 OK\r\n" \
                    substr(buffer, 1, trailers_end - 1), trailer_headers) ||
                    trailer_headers["content-length"] != "" ||
                    trailer_headers["transfer-encoding"] != "") {
                    return cx_fail("ProtocolError", "chunked HTTP trailers are invalid")
                }
            }
            response["body"] = body
            return 1
        }
        if (length(body) + size > CX_HTTP_MAX_BODY) {
            return cx_fail("ProtocolError", "HTTP body exceeds the response limit")
        }
        while (length(buffer) < size + 2) {
            result = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
            if (result != CX_IO_OK) {
                return cx_fail("TransportError", "chunked HTTP body ended early")
            }
            buffer = buffer chunk["data"]
        }
        if (substr(buffer, size + 1, 2) != "\r\n") {
            return cx_fail("ProtocolError", "chunked HTTP data is missing its terminator")
        }
        body = body substr(buffer, 1, size)
        buffer = substr(buffer, size + 3)
    }
}

function cx_hex_value(text,    position, value) {
    value = 0
    for (position = 1; position <= length(text); position++) {
        value = value * 16 + CX_HEX_VALUE[substr(text, position, 1)]
    }
    return value
}

# ---------------------------------------------------------------------------
# Convex HTTP functions
# ---------------------------------------------------------------------------

function convex_query(path, arguments, result) {
    return cx_call("query", path, arguments, result)
}

function convex_mutation(path, arguments, result) {
    return cx_call("mutation", path, arguments, result)
}

function convex_action(path, arguments, result) {
    return cx_call("action", path, arguments, result)
}

function cx_call(operation, path, arguments, result,    mark, arguments_node, body, response, payload, status, value, logs, message, data) {
    delete result
    if (CX_URL == "") {
        return cx_fail("ConfigError", "the client is not open")
    }
    if (path !~ /^[^ \t\r\n:]+:[^ \t\r\n:]+$/) {
        return cx_fail("ClientError", "function path must be module:function")
    }

    mark = cx_json_mark()
    arguments_node = cx_json_parse(arguments, CX_JSON_MAX_BYTES)
    if (arguments_node < 0 || cx_json_type(arguments_node) != "object") {
        cx_json_release(mark)
        return cx_fail("ClientError",
            "arguments must be a JSON object" (CX_JSON_ERROR == "" ? "" : ": " CX_JSON_ERROR))
    }
    # Convex's documented public format. Only `json` is claimed here; the
    # tagged convex_encoded_json format is deliberately out of scope.
    body = "{\"path\":" cx_json_quote(path) ",\"args\":" cx_json_encode(arguments_node) ",\"format\":\"json\"}"
    cx_json_release(mark)

    if (!cx_http_request("/api/" operation, body, response)) {
        return 0
    }
    if (response["status"] < 200 || response["status"] >= 300) {
        return cx_fail("TransportError", "Convex HTTP request returned status " response["status"])
    }

    mark = cx_json_mark()
    payload = cx_json_parse(response["body"], CX_JSON_MAX_BYTES)
    if (payload < 0 || cx_json_type(payload) != "object") {
        cx_json_release(mark)
        return cx_fail("ProtocolError",
            "HTTP " response["status"] " returned a non-Convex body" \
            (CX_JSON_ERROR == "" ? "" : ": " CX_JSON_ERROR))
    }

    status = cx_json_find(payload, "status")
    logs = cx_logs_text(cx_json_find(payload, "logLines"))
    if (logs == "") {
        cx_json_release(mark)
        return cx_fail("ProtocolError", "Convex logLines must be an array of strings")
    }
    result["logs"] = logs

    if (status >= 0 && cx_json_type(status) == "string" && cx_json_text(status) == "success") {
        value = cx_json_find(payload, "value")
        if (value < 0) {
            cx_json_release(mark)
            return cx_fail("ProtocolError", "a successful Convex response has no value")
        }
        result["value"] = cx_json_encode(value)
        cx_json_release(mark)
        return 1
    }

    if (status >= 0 && cx_json_type(status) == "string" && cx_json_text(status) == "error") {
        message = cx_json_find(payload, "errorMessage")
        data = cx_json_find(payload, "errorData")
        if (message < 0 || cx_json_type(message) != "string") {
            cx_json_release(mark)
            return cx_fail("ProtocolError", "a failed Convex response has no errorMessage string")
        }
        CX_ERROR_NAME = "FunctionError"
        CX_ERROR_MESSAGE = cx_json_text(message)
        CX_ERROR_DATA = data >= 0 ? cx_json_encode(data) : "null"
        cx_json_release(mark)
        return 0
    }

    cx_json_release(mark)
    return cx_fail("ProtocolError",
        "HTTP " response["status"] " response has an unknown status")
}

# ---------------------------------------------------------------------------
# Live: WebSocket handshake
# ---------------------------------------------------------------------------

function cx_ws_connect(deadline,    handle, key, accept, request, buffer, chunk, header_end, status, headers, result) {
    handle = convex_connect(CX_HOST, CX_PORT, CX_SECURE, cx_remaining(deadline))
    if (handle < 0) {
        cx_fail("TransportError", convex_last_error())
        return -1
    }
    # A fresh 16 byte nonce per RFC6455. The expected accept value is derived
    # here and checked below, so a proxy that answers 101 without completing the
    # upgrade is still rejected.
    key = convex_random_base64(16)
    accept = convex_sha1_base64(key CX_WS_GUID)

    request = "GET /api/sync HTTP/1.1\r\n"
    request = request "Host: " CX_HOST_HEADER "\r\n"
    request = request "Upgrade: websocket\r\n"
    request = request "Connection: Upgrade\r\n"
    request = request "Sec-WebSocket-Key: " key "\r\n"
    request = request "Sec-WebSocket-Version: 13\r\n"
    request = request "Convex-Client: " CX_CLIENT_VERSION "\r\n\r\n"
    if (convex_send(handle, request, cx_remaining(deadline)) != CX_IO_OK) {
        result = convex_last_error()
        convex_close(handle)
        cx_fail("TransportError", "WebSocket upgrade write failed: " result)
        return -1
    }

    buffer = ""
    header_end = 0
    while (header_end == 0) {
        result = convex_recv(handle, 65536, cx_remaining(deadline), chunk)
        if (result != CX_IO_OK) {
            convex_close(handle)
            cx_fail("TransportError", "the WebSocket upgrade did not complete")
            return -1
        }
        buffer = buffer chunk["data"]
        header_end = index(buffer, "\r\n\r\n")
        if ((header_end == 0 && length(buffer) > CX_HTTP_MAX_HEADERS) ||
            header_end > CX_HTTP_MAX_HEADERS) {
            convex_close(handle)
            cx_fail("ProtocolError", "the WebSocket upgrade response is too large")
            return -1
        }
    }

    status = cx_http_status(substr(buffer, 1, header_end - 1))
    if (status < 0 || !cx_http_headers(substr(buffer, 1, header_end - 1), headers)) {
        convex_close(handle)
        return -1
    }
    if (status != 101 || !cx_http_has_token(headers["upgrade"], "websocket") ||
        !cx_http_has_token(headers["connection"], "upgrade") ||
        headers["sec-websocket-extensions"] != "") {
        convex_close(handle)
        cx_fail("ProtocolError", "the deployment refused the WebSocket upgrade")
        return -1
    }
    if (headers["sec-websocket-accept"] != accept) {
        convex_close(handle)
        cx_fail("ProtocolError", "the WebSocket accept key did not match")
        return -1
    }

    # Anything the server already sent after the handshake belongs to the frame
    # parser, not to this header read.
    if (length(buffer) > header_end + 3) {
        if (convex_ws_unread(handle, substr(buffer, header_end + 4)) != CX_IO_OK) {
            result = convex_last_error()
            convex_close(handle)
            cx_fail("ProtocolError", "cannot retain WebSocket bytes after upgrade: " result)
            return -1
        }
    }
    return handle
}

function cx_http_has_token(value, wanted,    parts, count, position, token) {
    count = split(value, parts, /,/)
    for (position = 1; position <= count; position++) {
        token = parts[position]
        sub(/^[ \t]+/, "", token)
        sub(/[ \t]+$/, "", token)
        if (tolower(token) == wanted) {
            return 1
        }
    }
    return 0
}

# ---------------------------------------------------------------------------
# Live: single-owner state machine
#
# Awk runs one thread, so the adapter loop *is* the owner: every socket read,
# write, reconnect, and query-set version change happens in these functions and
# nowhere else. Subscriptions never touch the socket themselves.
# ---------------------------------------------------------------------------

function cx_live_send(text,    result) {
    if (CX_LIVE_SOCKET < 0) {
        return 0
    }
    result = convex_ws_send(CX_LIVE_SOCKET, 1, text, CX_LIVE_WRITE_MS)
    if (result != CX_IO_OK) {
        cx_live_retire("TransportError", "Live write failed: " convex_last_error(), 1)
        return 0
    }
    return 1
}

# Drop the current transport. Retiring bumps the generation so that anything
# still queued from the old connection can be recognised and discarded.
function cx_live_retire(name, message, publish,    query_id) {
    if (CX_LIVE_SOCKET >= 0) {
        convex_close(CX_LIVE_SOCKET)
        CX_LIVE_SOCKET = -1
    }
    CX_LIVE_GENERATION++
    CX_LIVE_QUERY_SET_VERSION = 0
    CX_LIVE_REMOTE_QUERY_SET = 0
    CX_LIVE_REMOTE_IDENTITY = 0
    CX_LIVE_REMOTE_TIMESTAMP = CX_LIVE_INITIAL_TIMESTAMP
    CX_LIVE_LAST_CLOSE = message == "" ? "ClientClosed" : message
    # Values already queued belong to the retired transport generation. Drop
    # them before publishing this generation's structured fault events.
    cx_queue_clear()
    cx_live_schedule_reconnect()
    if (publish) {
        # A transport fault is reported to every live subscription, but none of
        # them are cancelled: the reconnect below restores them.
        for (query_id in CX_SUB_PATH) {
            cx_live_publish_error(query_id + 0, name, message)
        }
    }
}

function cx_live_schedule_reconnect() {
    CX_LIVE_NEXT_CONNECT_MS = convex_now_ms() + CX_LIVE_BACKOFF_MS
    CX_LIVE_BACKOFF_MS *= 2
    if (CX_LIVE_BACKOFF_MS > CX_LIVE_MAX_BACKOFF_MS) {
        CX_LIVE_BACKOFF_MS = CX_LIVE_MAX_BACKOFF_MS
    }
}

function cx_live_connect_message(    message) {
    message = "{\"type\":\"Connect\",\"sessionId\":" cx_json_quote(CX_SESSION_ID)
    message = message ",\"connectionCount\":" CX_LIVE_CONNECTION_COUNT
    message = message ",\"lastCloseReason\":" cx_json_quote(CX_LIVE_LAST_CLOSE)
    message = message ",\"clientTs\":0"
    if (CX_LIVE_MAX_TIMESTAMP != CX_LIVE_INITIAL_TIMESTAMP) {
        message = message ",\"maxObservedTimestamp\":" cx_json_quote(CX_LIVE_MAX_TIMESTAMP)
    }
    return message "}"
}

function cx_live_add_modification(query_id) {
    return "{\"type\":\"Add\",\"queryId\":" query_id \
        ",\"udfPath\":" cx_json_quote(CX_SUB_PATH[query_id]) \
        ",\"args\":[" CX_SUB_ARGS[query_id] "]}"
}

# Bring up a connection and replay the whole active query set on it. Every
# reconnect re-sends these Add operations, which is what makes a subscription
# survive a dropped socket.
function cx_live_connect(    handle, deadline, message, query_id, modifications, count) {
    deadline = convex_now_ms() + CX_LIVE_CONNECT_MS
    handle = cx_ws_connect(deadline)
    if (handle < 0) {
        CX_LIVE_CONNECTION_COUNT++
        CX_LIVE_LAST_CLOSE = CX_ERROR_MESSAGE
        cx_live_schedule_reconnect()
        return 0
    }
    CX_LIVE_SOCKET = handle
    CX_LIVE_REMOTE_QUERY_SET = 0
    CX_LIVE_REMOTE_IDENTITY = 0
    CX_LIVE_REMOTE_TIMESTAMP = CX_LIVE_INITIAL_TIMESTAMP
    CX_LIVE_QUERY_SET_VERSION = 0

    if (!cx_live_send(cx_live_connect_message())) {
        return 0
    }
    CX_LIVE_CONNECTION_COUNT++

    modifications = ""
    count = 0
    for (query_id in CX_SUB_PATH) {
        if (count > 0) {
            modifications = modifications ","
        }
        modifications = modifications cx_live_add_modification(query_id + 0)
        count++
    }
    if (count > 0) {
        message = "{\"type\":\"ModifyQuerySet\",\"baseVersion\":0,\"newVersion\":1,"
        message = message "\"modifications\":[" modifications "]}"
        if (!cx_live_send(message)) {
            return 0
        }
        CX_LIVE_QUERY_SET_VERSION = 1
    }

    # A completed handshake is the signal that the deployment is healthy again,
    # so a later hiccup starts from the short delay rather than the long one.
    CX_LIVE_BACKOFF_MS = CX_LIVE_INITIAL_BACKOFF_MS
    CX_LIVE_NEXT_CONNECT_MS = 0
    return 1
}

function cx_live_ensure_connection(    ) {
    if (CX_LIVE_SOCKET >= 0) {
        return 1
    }
    if (convex_now_ms() < CX_LIVE_NEXT_CONNECT_MS) {
        return 0
    }
    return cx_live_connect()
}

function convex_subscribe(tag, path, arguments,    mark, node, query_id, charge, message) {
    if (CX_URL == "") {
        return cx_fail("ConfigError", "the client is not open")
    }
    if (path !~ /^[^ \t\r\n:]+:[^ \t\r\n:]+$/) {
        return cx_fail("ClientError", "function path must be module:function")
    }

    mark = cx_json_mark()
    node = cx_json_parse(arguments, CX_JSON_MAX_BYTES)
    if (node < 0 || cx_json_type(node) != "object") {
        cx_json_release(mark)
        return cx_fail("ClientError", "subscription arguments must be a JSON object")
    }
    arguments = cx_json_encode(node)
    cx_json_release(mark)

    # A repeated tag replaces the old subscription. The old relay is torn down
    # first, so nothing it queued can be delivered under the new identity.
    if (tag in CX_SUB_BY_TAG) {
        convex_unsubscribe(tag)
    }

    charge = length(path) + length(arguments) + 256
    if (CX_LIVE_SUBSCRIPTION_COUNT >= CX_LIVE_MAX_SUBSCRIPTIONS ||
        CX_LIVE_ACTIVE_BYTES + charge > CX_LIVE_SUBSCRIPTION_BYTES) {
        return cx_fail("ProtocolError", "Live subscription capacity exceeded")
    }
    if (CX_LIVE_NEXT_QUERY_ID >= 4294967295) {
        return cx_fail("ProtocolError", "Live query identifiers are exhausted")
    }

    query_id = CX_LIVE_NEXT_QUERY_ID++
    CX_SUB_PATH[query_id] = path
    CX_SUB_ARGS[query_id] = arguments
    CX_SUB_TAG[query_id] = tag
    CX_SUB_BYTES[query_id] = charge
    CX_SUB_SIGNATURE[query_id] = ""
    CX_SUB_BY_TAG[tag] = query_id
    CX_LIVE_SUBSCRIPTION_COUNT++
    CX_LIVE_ACTIVE_BYTES += charge

    if (CX_LIVE_SOCKET < 0) {
        if (!cx_live_connect()) {
            cx_live_forget(query_id)
            return cx_fail("TransportError", "Live connection failed: " CX_LIVE_LAST_CLOSE)
        }
        return 1
    }

    message = "{\"type\":\"ModifyQuerySet\",\"baseVersion\":" CX_LIVE_QUERY_SET_VERSION
    message = message ",\"newVersion\":" (CX_LIVE_QUERY_SET_VERSION + 1)
    message = message ",\"modifications\":[" cx_live_add_modification(query_id) "]}"
    if (!cx_live_send(message)) {
        cx_live_forget(query_id)
        return cx_fail("TransportError", "Live subscribe failed: " CX_LIVE_LAST_CLOSE)
    }
    CX_LIVE_QUERY_SET_VERSION++
    return 1
}

function cx_live_forget(query_id,    tag) {
    tag = CX_SUB_TAG[query_id]
    if (query_id in CX_SUB_PATH) {
        CX_LIVE_ACTIVE_BYTES -= CX_SUB_BYTES[query_id]
        CX_LIVE_SUBSCRIPTION_COUNT--
    }
    delete CX_SUB_PATH[query_id]
    delete CX_SUB_ARGS[query_id]
    delete CX_SUB_TAG[query_id]
    delete CX_SUB_BYTES[query_id]
    delete CX_SUB_SIGNATURE[query_id]
    if (tag != "" && CX_SUB_BY_TAG[tag] == query_id) {
        delete CX_SUB_BY_TAG[tag]
    }
    cx_queue_purge(tag)
}

function convex_unsubscribe(tag,    query_id, message) {
    if (!(tag in CX_SUB_BY_TAG)) {
        return 1
    }
    query_id = CX_SUB_BY_TAG[tag]
    if (CX_LIVE_SOCKET >= 0) {
        message = "{\"type\":\"ModifyQuerySet\",\"baseVersion\":" CX_LIVE_QUERY_SET_VERSION
        message = message ",\"newVersion\":" (CX_LIVE_QUERY_SET_VERSION + 1)
        message = message ",\"modifications\":[{\"type\":\"Remove\",\"queryId\":" query_id "}]}"
        if (cx_live_send(message)) {
            CX_LIVE_QUERY_SET_VERSION++
        }
        # A failed Remove already retired the socket, which is an equally valid
        # barrier: the retired generation can no longer publish anything.
    }
    # Forget the subscription and purge its queued deliveries before the caller
    # is told the unsubscribe succeeded.
    cx_live_forget(query_id)
    return 1
}

# Test-only fault injection, reachable from the conformance adapter alone.
function convex_debug_disconnect() {
    if (CX_LIVE_SOCKET < 0) {
        return cx_fail("TransportError", "Live is not connected")
    }
    convex_close(CX_LIVE_SOCKET)
    CX_LIVE_SOCKET = -1
    CX_LIVE_GENERATION++
    CX_LIVE_QUERY_SET_VERSION = 0
    CX_LIVE_REMOTE_QUERY_SET = 0
    CX_LIVE_REMOTE_IDENTITY = 0
    CX_LIVE_REMOTE_TIMESTAMP = CX_LIVE_INITIAL_TIMESTAMP
    CX_LIVE_LAST_CLOSE = "DebugDisconnect"
    # Anything still queued belongs to the connection being dropped, so the
    # acknowledgement is a real barrier for the controller.
    cx_queue_clear()
    CX_LIVE_NEXT_CONNECT_MS = convex_now_ms() + CX_LIVE_INITIAL_BACKOFF_MS
    CX_LIVE_BACKOFF_MS = CX_LIVE_INITIAL_BACKOFF_MS * 2
    return 1
}

function convex_close_live(budget_ms,    query_id, tag) {
    if (CX_LIVE_SOCKET >= 0) {
        # Best effort, strictly bounded: a peer that never answers must not be
        # able to delay shutdown.
        convex_ws_send(CX_LIVE_SOCKET, 8, CX_CHR[3] CX_CHR[232], budget_ms)
        convex_close(CX_LIVE_SOCKET)
        CX_LIVE_SOCKET = -1
    }
    for (query_id in CX_SUB_PATH) {
        tag = CX_SUB_TAG[query_id]
        delete CX_SUB_PATH[query_id]
        delete CX_SUB_ARGS[query_id]
        delete CX_SUB_TAG[query_id]
        delete CX_SUB_BYTES[query_id]
        delete CX_SUB_SIGNATURE[query_id]
        delete CX_SUB_BY_TAG[tag]
    }
    CX_LIVE_SUBSCRIPTION_COUNT = 0
    CX_LIVE_ACTIVE_BYTES = 0
    CX_LIVE_GENERATION++
    cx_queue_clear()
    return 1
}

# ---------------------------------------------------------------------------
# Live: bounded delivery queue
#
# The client owns this queue, so it is explicitly bounded in both directions.
# When a consumer stops draining, the newest deliveries win and the oldest are
# dropped; memory never grows with the deployment's update rate.
# ---------------------------------------------------------------------------

function cx_queue_clear(    position) {
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        delete CX_QUEUE_TAG[position]
        delete CX_QUEUE_VALUE[position]
        delete CX_QUEUE_LOGS[position]
        delete CX_QUEUE_ERROR_NAME[position]
        delete CX_QUEUE_ERROR_MESSAGE[position]
        delete CX_QUEUE_ERROR_DATA[position]
        delete CX_QUEUE_SIZE[position]
    }
    CX_QUEUE_HEAD = 1
    CX_QUEUE_TAIL = 0
    CX_QUEUE_BYTES = 0
}

function cx_queue_purge(tag,    position, keep) {
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        if (CX_QUEUE_TAG[position] == tag) {
            CX_QUEUE_BYTES -= CX_QUEUE_SIZE[position]
            CX_QUEUE_TAG[position] = ""
            CX_QUEUE_SIZE[position] = 0
            CX_QUEUE_VALUE[position] = ""
            CX_QUEUE_LOGS[position] = ""
            CX_QUEUE_ERROR_NAME[position] = ""
            CX_QUEUE_ERROR_MESSAGE[position] = ""
            CX_QUEUE_ERROR_DATA[position] = ""
        }
    }
    keep = 0
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        if (CX_QUEUE_TAG[position] != "") {
            keep = 1
        }
    }
    if (!keep) {
        cx_queue_clear()
    }
}

function cx_queue_count(    position, count) {
    count = 0
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        if (CX_QUEUE_TAG[position] != "") {
            count++
        }
    }
    return count
}

function cx_queue_drop_oldest(    position) {
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        if (CX_QUEUE_TAG[position] != "") {
            CX_QUEUE_BYTES -= CX_QUEUE_SIZE[position]
            CX_QUEUE_TAG[position] = ""
            CX_QUEUE_SIZE[position] = 0
            CX_QUEUE_VALUE[position] = ""
            CX_QUEUE_LOGS[position] = ""
            CX_QUEUE_ERROR_NAME[position] = ""
            CX_QUEUE_ERROR_MESSAGE[position] = ""
            CX_QUEUE_ERROR_DATA[position] = ""
            CX_QUEUE_DROPPED++
            return 1
        }
    }
    return 0
}

function cx_queue_push(tag, value, logs, error_name, error_message, error_data,    position, size) {
    size = length(tag) + length(value) + length(logs) + length(error_name) + \
        length(error_message) + length(error_data) + 128
    if (size > CX_LIVE_QUEUE_BYTES) {
        # One delivery larger than the whole budget is refused rather than
        # emptying the queue for it.
        CX_QUEUE_DROPPED++
        return 0
    }
    position = ++CX_QUEUE_TAIL
    CX_QUEUE_TAG[position] = tag
    CX_QUEUE_VALUE[position] = value
    CX_QUEUE_LOGS[position] = logs
    CX_QUEUE_ERROR_NAME[position] = error_name
    CX_QUEUE_ERROR_MESSAGE[position] = error_message
    CX_QUEUE_ERROR_DATA[position] = error_data
    CX_QUEUE_SIZE[position] = size
    CX_QUEUE_BYTES += size
    while (cx_queue_count() > CX_LIVE_QUEUE_COUNT || CX_QUEUE_BYTES > CX_LIVE_QUEUE_BYTES) {
        if (!cx_queue_drop_oldest()) {
            break
        }
    }
    return 1
}

function convex_next_update(update,    position) {
    delete update
    for (position = CX_QUEUE_HEAD; position <= CX_QUEUE_TAIL; position++) {
        if (CX_QUEUE_TAG[position] == "") {
            continue
        }
        update["tag"] = CX_QUEUE_TAG[position]
        update["value"] = CX_QUEUE_VALUE[position]
        update["logs"] = CX_QUEUE_LOGS[position]
        update["errorName"] = CX_QUEUE_ERROR_NAME[position]
        update["errorMessage"] = CX_QUEUE_ERROR_MESSAGE[position]
        update["errorData"] = CX_QUEUE_ERROR_DATA[position]
        CX_QUEUE_BYTES -= CX_QUEUE_SIZE[position]
        CX_QUEUE_TAG[position] = ""
        CX_QUEUE_SIZE[position] = 0
        CX_QUEUE_HEAD = position + 1
        if (CX_QUEUE_HEAD > CX_QUEUE_TAIL) {
            cx_queue_clear()
        }
        return 1
    }
    return 0
}

function convex_dropped_updates() {
    return CX_QUEUE_DROPPED + 0
}

# A repeated identical value is suppressed. That matters after a reconnect: the
# deployment rehydrates every restored query, and the controller must observe
# the post-mutation value rather than an echo of what it already had.
function cx_live_publish_value(query_id, value, logs,    signature) {
    signature = "V" value
    if (CX_SUB_SIGNATURE[query_id] == signature) {
        return 0
    }
    CX_SUB_SIGNATURE[query_id] = signature
    return cx_queue_push(CX_SUB_TAG[query_id], value, logs, "", "", "")
}

function cx_live_publish_failure(query_id, message, data, logs,    signature) {
    signature = "F" message SUBSEP data
    if (CX_SUB_SIGNATURE[query_id] == signature) {
        return 0
    }
    CX_SUB_SIGNATURE[query_id] = signature
    return cx_queue_push(CX_SUB_TAG[query_id], "", logs, "FunctionError", message, data)
}

function cx_live_publish_error(query_id, name, message,    signature) {
    signature = "T" name SUBSEP message
    if (CX_SUB_SIGNATURE[query_id] == signature) {
        return 0
    }
    CX_SUB_SIGNATURE[query_id] = signature
    return cx_queue_push(CX_SUB_TAG[query_id], "", "[]", name, message, "null")
}

# ---------------------------------------------------------------------------
# Live: server messages
# ---------------------------------------------------------------------------

function cx_live_version(node, target,    query_set, identity, timestamp) {
    if (node < 0 || cx_json_type(node) != "object") {
        return 0
    }
    query_set = cx_json_find(node, "querySet")
    identity = cx_json_find(node, "identity")
    timestamp = cx_json_find(node, "ts")
    if (query_set < 0 || cx_json_type(query_set) != "number" ||
        identity < 0 || cx_json_type(identity) != "number" ||
        timestamp < 0 || cx_json_type(timestamp) != "string") {
        return 0
    }
    if (!convex_integral(cx_json_text(query_set)) || !convex_integral(cx_json_text(identity)) ||
        cx_json_text(query_set) + 0 < 0 || cx_json_text(query_set) + 0 > 4294967295 ||
        cx_json_text(identity) + 0 < 0 || cx_json_text(identity) + 0 > 4294967295) {
        return 0
    }
    if (convex_ts_cmp(cx_json_text(timestamp), CX_LIVE_INITIAL_TIMESTAMP) == -2) {
        return 0
    }
    target["querySet"] = cx_json_text(query_set) + 0
    target["identity"] = cx_json_text(identity) + 0
    target["ts"] = cx_json_text(timestamp)
    return 1
}

function cx_live_handle_message(text,    mark, root, kind, message) {
    mark = cx_json_mark()
    root = cx_json_parse(text, CX_JSON_MAX_BYTES)
    if (root < 0 || cx_json_type(root) != "object") {
        cx_json_release(mark)
        cx_live_retire("ProtocolError", "Live message is not a JSON object", 1)
        return 0
    }
    kind = cx_json_find(root, "type")
    if (kind < 0 || cx_json_type(kind) != "string") {
        cx_json_release(mark)
        cx_live_retire("ProtocolError", "Live message has no type", 1)
        return 0
    }
    kind = cx_json_text(kind)

    if (kind == "Transition") {
        message = cx_live_transition(root)
        cx_json_release(mark)
        return message
    }
    if (kind == "Ping" || kind == "MutationResponse" || kind == "ActionResponse") {
        cx_json_release(mark)
        return 1
    }
    if (kind == "FatalError" || kind == "AuthError") {
        message = cx_json_find(root, "error")
        message = (message >= 0 && cx_json_type(message) == "string") ? \
            cx_json_text(message) : kind
        cx_json_release(mark)
        cx_live_retire("ProtocolError", "Live server reported " kind ": " message, 1)
        return 0
    }
    cx_json_release(mark)
    cx_live_retire("ProtocolError", "unsupported Live server message: " kind, 1)
    return 0
}

# A Transition is validated in full before any part of it is published. Half of
# a rejected transition must never reach a subscriber.
function cx_live_transition(root,    start, end, start_version, end_version, modifications, position, change, kind, query_id, count, order) {
    if (!cx_live_version(cx_json_find(root, "startVersion"), start_version) ||
        !cx_live_version(cx_json_find(root, "endVersion"), end_version)) {
        cx_live_retire("ProtocolError", "Live transition has an invalid state version", 1)
        return 0
    }
    if (start_version["querySet"] != CX_LIVE_REMOTE_QUERY_SET ||
        start_version["identity"] != CX_LIVE_REMOTE_IDENTITY ||
        start_version["ts"] != CX_LIVE_REMOTE_TIMESTAMP) {
        cx_live_retire("ProtocolError", "Live transition does not continue the local state", 1)
        return 0
    }
    if (convex_ts_cmp(end_version["ts"], start_version["ts"]) < 0) {
        cx_live_retire("ProtocolError", "Live timestamp moved backwards", 1)
        return 0
    }
    if (end_version["querySet"] < start_version["querySet"] ||
        end_version["identity"] < start_version["identity"]) {
        cx_live_retire("ProtocolError", "Live state version counter moved backwards", 1)
        return 0
    }
    modifications = cx_json_find(root, "modifications")
    if (modifications < 0 || cx_json_type(modifications) != "array") {
        cx_live_retire("ProtocolError", "Live transition has no modifications array", 1)
        return 0
    }

    # Stage the whole transition before committing it. Like the pinned client,
    # repeated changes for one query are coalesced with the final change winning.
    delete CX_CHANGE_KIND
    delete CX_CHANGE_VALUE
    delete CX_CHANGE_LOGS
    delete CX_CHANGE_MESSAGE
    delete CX_CHANGE_DATA
    delete CX_CHANGE_ORDER
    count = 0
    for (position = 1; position <= cx_json_count(modifications); position++) {
        change = cx_json_child(modifications, position)
        if (cx_json_type(change) != "object") {
            cx_live_retire("ProtocolError", "Live modification is not an object", 1)
            return 0
        }
        kind = cx_json_find(change, "type")
        query_id = cx_json_find(change, "queryId")
        if (kind < 0 || cx_json_type(kind) != "string" ||
            query_id < 0 || cx_json_type(query_id) != "number" ||
            !convex_integral(cx_json_text(query_id)) || cx_json_text(query_id) + 0 < 0 ||
            cx_json_text(query_id) + 0 > 4294967295) {
            cx_live_retire("ProtocolError", "Live modification is malformed", 1)
            return 0
        }
        kind = cx_json_text(kind)
        query_id = cx_json_text(query_id) + 0
        # Updates for a locally retired query may still be in flight behind the
        # Remove. Validate them, but do not relay them to a new subscription.
        if (!cx_live_change(change, kind, query_id)) {
            return 0
        }
        if (query_id in CX_SUB_PATH) {
            if (!(query_id in CX_CHANGE_KIND)) {
                CX_CHANGE_ORDER[++count] = query_id
            }
            CX_CHANGE_KIND[query_id] = kind
        }
    }

    CX_LIVE_REMOTE_QUERY_SET = end_version["querySet"]
    CX_LIVE_REMOTE_IDENTITY = end_version["identity"]
    CX_LIVE_REMOTE_TIMESTAMP = end_version["ts"]
    if (convex_ts_cmp(end_version["ts"], CX_LIVE_MAX_TIMESTAMP) > 0) {
        CX_LIVE_MAX_TIMESTAMP = end_version["ts"]
    }

    for (order = 1; order <= count; order++) {
        query_id = CX_CHANGE_ORDER[order]
        if (CX_CHANGE_KIND[query_id] == "QueryUpdated") {
            cx_live_publish_value(query_id, CX_CHANGE_VALUE[query_id], CX_CHANGE_LOGS[query_id])
        } else if (CX_CHANGE_KIND[query_id] == "QueryFailed") {
            cx_live_publish_failure(query_id, CX_CHANGE_MESSAGE[query_id],
                CX_CHANGE_DATA[query_id], CX_CHANGE_LOGS[query_id])
        }
        delete CX_CHANGE_ORDER[order]
    }

    # A valid server transition proves the connection works, so the transport
    # backoff starts again from the shortest delay.
    CX_LIVE_BACKOFF_MS = CX_LIVE_INITIAL_BACKOFF_MS
    return 1
}

function cx_live_change(change, kind, query_id,    value, logs, message, data) {
    logs = cx_logs_text(cx_json_find(change, "logLines"))
    if (logs == "") {
        cx_live_retire("ProtocolError", "Live logLines must be an array of strings", 1)
        return 0
    }
    if (kind == "QueryUpdated") {
        value = cx_json_find(change, "value")
        if (value < 0) {
            cx_live_retire("ProtocolError", "QueryUpdated has no value", 1)
            return 0
        }
        CX_CHANGE_VALUE[query_id] = cx_json_encode(value)
        CX_CHANGE_LOGS[query_id] = logs
        return 1
    }
    if (kind == "QueryFailed") {
        message = cx_json_find(change, "errorMessage")
        data = cx_json_find(change, "errorData")
        if (message < 0 || cx_json_type(message) != "string") {
            cx_live_retire("ProtocolError", "QueryFailed has no error message", 1)
            return 0
        }
        CX_CHANGE_MESSAGE[query_id] = cx_json_text(message)
        CX_CHANGE_DATA[query_id] = data >= 0 ? cx_json_encode(data) : "null"
        CX_CHANGE_LOGS[query_id] = logs
        return 1
    }
    if (kind == "QueryRemoved") {
        return 1
    }
    cx_live_retire("ProtocolError", "unsupported Live modification: " kind, 1)
    return 0
}

# One step of the owner loop: connect when it is time to, otherwise read at
# most one WebSocket message. The caller decides how long to spend here, so the
# adapter can interleave controller commands without a second thread.
function convex_live_pump(budget_ms,    deadline, frame, status, wait) {
    deadline = convex_now_ms() + budget_ms
    for (;;) {
        if (CX_LIVE_SOCKET < 0) {
            if (CX_LIVE_SUBSCRIPTION_COUNT == 0) {
                return 1
            }
            if (!cx_live_ensure_connection()) {
                # Waiting out a reconnect backoff. Sleep the shorter of the
                # remaining budget and the delay so the owner never spins.
                wait = CX_LIVE_NEXT_CONNECT_MS - convex_now_ms()
                if (wait > cx_remaining(deadline)) {
                    wait = cx_remaining(deadline)
                }
                convex_sleep(wait)
                return 1
            }
        }
        status = convex_ws_recv(CX_LIVE_SOCKET, cx_remaining(deadline), frame)
        if (status == CX_IO_TIMEOUT) {
            return 1
        }
        if (status == CX_IO_EOF) {
            cx_live_retire("TransportError", "the deployment closed the WebSocket", 1)
            return 0
        }
        if (status == CX_IO_ERROR) {
            cx_live_retire(frame["class"] == "protocol" ? "ProtocolError" : "TransportError",
                frame["error"], 1)
            return 0
        }
        if (frame["kind"] == "text") {
            if (!convex_utf8_valid(frame["payload"])) {
                cx_live_retire("ProtocolError", "Live text message is not valid UTF-8", 1)
                return 0
            }
            if (!cx_live_handle_message(frame["payload"])) {
                return 0
            }
        } else if (frame["kind"] == "ping") {
            if (convex_ws_send(CX_LIVE_SOCKET, 10, frame["payload"], CX_LIVE_WRITE_MS) != CX_IO_OK) {
                cx_live_retire("TransportError", "pong write failed: " convex_last_error(), 1)
                return 0
            }
        } else if (frame["kind"] == "close") {
            if (frame["payload"] != "" && !convex_utf8_valid(frame["payload"])) {
                cx_live_retire("ProtocolError", "WebSocket close reason is not valid UTF-8", 1)
                return 0
            }
            cx_live_retire("TransportError", "the deployment closed the WebSocket", 1)
            return 0
        } else if (frame["kind"] == "binary") {
            cx_live_retire("ProtocolError", "binary Live messages are unsupported", 1)
            return 0
        }
        if (cx_remaining(deadline) <= 0) {
            return 1
        }
    }
}

# Convenience for the example: pump the owner until this subscription produces
# an update or the deadline passes.
function convex_wait_update(tag, timeout_ms, update,    deadline) {
    deadline = convex_now_ms() + timeout_ms
    for (;;) {
        while (convex_next_update(update)) {
            if (update["tag"] == tag) {
                return 1
            }
        }
        if (cx_remaining(deadline) <= 0) {
            return cx_fail("TransportError", "timed out waiting for a Live update")
        }
        convex_live_pump(cx_remaining(deadline) > 250 ? 250 : cx_remaining(deadline))
    }
}
