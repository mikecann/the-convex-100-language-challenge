"""A JSON reader and writer, because Mojo's standard library has neither.

Documents are stored as a flat arena of nodes linked by index rather than as a
recursively nested type. Convex values arrive as arbitrary JSON, and an arena
gives the parser a hard depth bound and gives callers cheap subtree access
without cloning anything.

Number tokens are kept verbatim. Convex encodes a whole count as `0` in one
response and `0.0` in another, and re-emitting the original token is what makes
an echoed value round-trip byte-for-byte instead of being normalised on the way
through this client.
"""

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUMBER = 2
comptime J_STRING = 3
comptime J_ARRAY = 4
comptime J_OBJECT = 5

# A Convex value that nests this deeply is drift, not data. The limit bounds
# parser recursion so a hostile or corrupt frame cannot exhaust the stack.
comptime MAX_DEPTH = 64


@fieldwise_init
struct Node(Copyable, Movable):
    """One JSON value. Children are indices into the owning document."""

    var kind: Int
    var text: String
    var truth: Bool
    var key: String
    var first: Int
    var last: Int
    var next: Int


struct Json(Copyable, Movable):
    """A parsed or constructed JSON document."""

    var nodes: List[Node]
    var root: Int

    fn __init__(out self):
        self.nodes = List[Node]()
        self.root = -1

    fn add(mut self, kind: Int, text: String, truth: Bool) -> Int:
        self.nodes.append(Node(kind, text, truth, String(), -1, -1, -1))
        return len(self.nodes) - 1

    fn attach(mut self, parent: Int, child: Int, key: String):
        """Append `child` to `parent`, keeping a tail pointer for O(1) appends.
        """
        self.nodes[child].key = key
        var tail = self.nodes[parent].last
        if self.nodes[parent].first < 0:
            self.nodes[parent].first = child
        else:
            self.nodes[tail].next = child
        self.nodes[parent].last = child

    fn kind(self, node: Int) -> Int:
        if node < 0 or node >= len(self.nodes):
            return -1
        return self.nodes[node].kind

    fn text(self, node: Int) -> String:
        return self.nodes[node].text

    fn truth(self, node: Int) -> Bool:
        return self.nodes[node].truth

    fn number(self, node: Int) raises -> Float64:
        return Float64(self.nodes[node].text)

    fn is_integral(self, node: Int) raises -> Bool:
        """True when a number is mathematically whole and safely in range.

        Convex may send `1` or `1.0` for the same count, so an example that
        insists on an integer token would fail against a healthy deployment.
        A fractional value still has to be rejected.
        """
        if self.kind(node) != J_NUMBER:
            return False
        var value = self.number(node)
        if value != value or value > 9.0e15 or value < -9.0e15:
            return False
        return Float64(Int(value)) == value

    fn as_int(self, node: Int) raises -> Int:
        if not self.is_integral(node):
            raise Error("ProtocolError|expected a whole number")
        return Int(self.number(node))

    fn member(self, node: Int, key: String) -> Int:
        """The value of `key`, or -1 when the object has no such member."""
        if self.kind(node) != J_OBJECT:
            return -1
        var child = self.nodes[node].first
        while child >= 0:
            if self.nodes[child].key == key:
                return child
            child = self.nodes[child].next
        return -1

    fn item(self, node: Int, index: Int) -> Int:
        var child = self.nodes[node].first
        var seen = 0
        while child >= 0:
            if seen == index:
                return child
            seen += 1
            child = self.nodes[child].next
        return -1

    fn count(self, node: Int) -> Int:
        var child = self.nodes[node].first
        var seen = 0
        while child >= 0:
            seen += 1
            child = self.nodes[child].next
        return seen

    fn dump(self, node: Int) -> String:
        """Serialize one subtree back to compact JSON."""
        var out = String()
        self._write(node, out)
        return out

    fn _write(self, node: Int, mut out: String):
        var kind = self.kind(node)
        if kind == J_NULL or kind < 0:
            out += "null"
        elif kind == J_BOOL:
            out += "true" if self.nodes[node].truth else "false"
        elif kind == J_NUMBER:
            out += self.nodes[node].text
        elif kind == J_STRING:
            out += quote(self.nodes[node].text)
        elif kind == J_ARRAY:
            out += "["
            var child = self.nodes[node].first
            while child >= 0:
                self._write(child, out)
                child = self.nodes[child].next
                if child >= 0:
                    out += ","
            out += "]"
        else:
            out += "{"
            var child = self.nodes[node].first
            while child >= 0:
                out += quote(self.nodes[child].key)
                out += ":"
                self._write(child, out)
                child = self.nodes[child].next
                if child >= 0:
                    out += ","
            out += "}"


fn quote(value: String) -> String:
    """Render a JSON string literal.

    Only the characters JSON requires are escaped. Text above U+007F is emitted
    as its own UTF-8 bytes, which keeps `"Hello, 世界 👋"` readable on the wire
    and avoids re-encoding surrogate pairs on the way out.
    """
    var out = String('"')
    var bytes = value.as_bytes()
    for i in range(len(bytes)):
        var byte = bytes[i]
        if byte == 0x22:
            out += '\\"'
        elif byte == 0x5C:
            out += "\\\\"
        elif byte == 0x0A:
            out += "\\n"
        elif byte == 0x0D:
            out += "\\r"
        elif byte == 0x09:
            out += "\\t"
        elif byte == 0x08:
            out += "\\b"
        elif byte == 0x0C:
            out += "\\f"
        elif byte < 0x20:
            out += "\\u00"
            out += hex_digit(Int(byte) >> 4)
            out += hex_digit(Int(byte) & 0xF)
        else:
            out += chr(Int(byte)) if byte < 0x80 else _raw_byte(byte)
    out += '"'
    return out


fn _raw_byte(byte: UInt8) -> String:
    """Pass a UTF-8 continuation or lead byte through unchanged.

    `chr` would re-encode a byte above 0x7F as a two-byte codepoint, corrupting
    text that is already valid UTF-8.
    """
    var one = List[UInt8]()
    one.append(byte)
    return String(unsafe_from_utf8=Span(one))


fn hex_digit(value: Int) -> String:
    if value < 10:
        return chr(48 + value)
    return chr(87 + value)


struct _Parser:
    """Byte-oriented recursive descent over one JSON document."""

    var bytes: List[UInt8]
    var position: Int

    fn __init__(out self, var bytes: List[UInt8]):
        self.bytes = bytes^
        self.position = 0

    fn at_end(self) -> Bool:
        return self.position >= len(self.bytes)

    fn current(self) -> UInt8:
        return self.bytes[self.position]

    fn skip_space(mut self):
        while not self.at_end():
            var byte = self.current()
            if byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D:
                self.position += 1
            else:
                return

    fn expect(mut self, byte: UInt8) raises:
        self.skip_space()
        if self.at_end() or self.current() != byte:
            raise Error("ProtocolError|malformed JSON")
        self.position += 1

    fn literal(mut self, word: String) raises:
        var wanted = word.as_bytes()
        if self.position + len(wanted) > len(self.bytes):
            raise Error("ProtocolError|malformed JSON")
        for i in range(len(wanted)):
            if self.bytes[self.position + i] != wanted[i]:
                raise Error("ProtocolError|malformed JSON")
        self.position += len(wanted)

    fn value(mut self, mut doc: Json, depth: Int) raises -> Int:
        if depth > MAX_DEPTH:
            raise Error("ProtocolError|JSON nested too deeply")
        self.skip_space()
        if self.at_end():
            raise Error("ProtocolError|malformed JSON")
        var byte = self.current()
        if byte == 0x7B:
            return self.object(doc, depth)
        if byte == 0x5B:
            return self.array(doc, depth)
        if byte == 0x22:
            return doc.add(J_STRING, self.string(), False)
        if byte == 0x74:
            self.literal("true")
            return doc.add(J_BOOL, String(), True)
        if byte == 0x66:
            self.literal("false")
            return doc.add(J_BOOL, String(), False)
        if byte == 0x6E:
            self.literal("null")
            return doc.add(J_NULL, String(), False)
        return doc.add(J_NUMBER, self.number(), False)

    fn object(mut self, mut doc: Json, depth: Int) raises -> Int:
        self.position += 1
        var node = doc.add(J_OBJECT, String(), False)
        self.skip_space()
        if not self.at_end() and self.current() == 0x7D:
            self.position += 1
            return node
        while True:
            self.skip_space()
            if self.at_end() or self.current() != 0x22:
                raise Error("ProtocolError|malformed JSON object key")
            var key = self.string()
            self.expect(0x3A)
            var child = self.value(doc, depth + 1)
            doc.attach(node, child, key)
            self.skip_space()
            if self.at_end():
                raise Error("ProtocolError|malformed JSON")
            if self.current() == 0x2C:
                self.position += 1
                continue
            self.expect(0x7D)
            return node

    fn array(mut self, mut doc: Json, depth: Int) raises -> Int:
        self.position += 1
        var node = doc.add(J_ARRAY, String(), False)
        self.skip_space()
        if not self.at_end() and self.current() == 0x5D:
            self.position += 1
            return node
        while True:
            var child = self.value(doc, depth + 1)
            doc.attach(node, child, String())
            self.skip_space()
            if self.at_end():
                raise Error("ProtocolError|malformed JSON")
            if self.current() == 0x2C:
                self.position += 1
                continue
            self.expect(0x5D)
            return node

    fn string(mut self) raises -> String:
        self.position += 1
        var out = List[UInt8]()
        while True:
            if self.at_end():
                raise Error("ProtocolError|unterminated JSON string")
            var byte = self.current()
            self.position += 1
            if byte == 0x22:
                break
            if byte != 0x5C:
                if byte < 0x20:
                    raise Error(
                        "ProtocolError|control character in JSON string"
                    )
                out.append(byte)
                continue
            if self.at_end():
                raise Error("ProtocolError|unterminated JSON escape")
            var escape = self.current()
            self.position += 1
            if escape == 0x22:
                out.append(0x22)
            elif escape == 0x5C:
                out.append(0x5C)
            elif escape == 0x2F:
                out.append(0x2F)
            elif escape == 0x62:
                out.append(0x08)
            elif escape == 0x66:
                out.append(0x0C)
            elif escape == 0x6E:
                out.append(0x0A)
            elif escape == 0x72:
                out.append(0x0D)
            elif escape == 0x74:
                out.append(0x09)
            elif escape == 0x75:
                self.unicode_escape(out)
            else:
                raise Error("ProtocolError|unknown JSON escape")
        return String(from_utf8=Span(out))

    fn unicode_escape(mut self, mut out: List[UInt8]) raises:
        """Decode `\\uXXXX`, joining a surrogate pair into one codepoint."""
        var first = self.hex4()
        var codepoint = first
        if first >= 0xD800 and first <= 0xDBFF:
            if (
                self.position + 1 < len(self.bytes)
                and self.bytes[self.position] == 0x5C
                and self.bytes[self.position + 1] == 0x75
            ):
                self.position += 2
                var second = self.hex4()
                if second < 0xDC00 or second > 0xDFFF:
                    raise Error("ProtocolError|unpaired JSON surrogate")
                codepoint = (
                    0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                )
            else:
                raise Error("ProtocolError|unpaired JSON surrogate")
        elif first >= 0xDC00 and first <= 0xDFFF:
            raise Error("ProtocolError|unpaired JSON surrogate")
        encode_utf8(codepoint, out)

    fn hex4(mut self) raises -> Int:
        if self.position + 4 > len(self.bytes):
            raise Error("ProtocolError|truncated JSON escape")
        var value = 0
        for _ in range(4):
            var byte = Int(self.bytes[self.position])
            self.position += 1
            if byte >= 48 and byte <= 57:
                value = value * 16 + byte - 48
            elif byte >= 97 and byte <= 102:
                value = value * 16 + byte - 87
            elif byte >= 65 and byte <= 70:
                value = value * 16 + byte - 55
            else:
                raise Error("ProtocolError|invalid JSON escape digit")
        return value

    fn number(mut self) raises -> String:
        """Capture a number token verbatim after checking its grammar."""
        var start = self.position
        if not self.at_end() and self.current() == 0x2D:
            self.position += 1
        var digits = 0
        var leading_zero = not self.at_end() and self.current() == 0x30
        while (
            not self.at_end()
            and self.current() >= 0x30
            and self.current() <= 0x39
        ):
            self.position += 1
            digits += 1
        if digits == 0 or (leading_zero and digits > 1):
            raise Error("ProtocolError|malformed JSON number")
        if not self.at_end() and self.current() == 0x2E:
            self.position += 1
            var fraction = 0
            while (
                not self.at_end()
                and self.current() >= 0x30
                and self.current() <= 0x39
            ):
                self.position += 1
                fraction += 1
            if fraction == 0:
                raise Error("ProtocolError|malformed JSON number")
        if not self.at_end() and (
            self.current() == 0x65 or self.current() == 0x45
        ):
            self.position += 1
            if not self.at_end() and (
                self.current() == 0x2B or self.current() == 0x2D
            ):
                self.position += 1
            var exponent = 0
            while (
                not self.at_end()
                and self.current() >= 0x30
                and self.current() <= 0x39
            ):
                self.position += 1
                exponent += 1
            if exponent == 0:
                raise Error("ProtocolError|malformed JSON number")
        var token = List[UInt8]()
        for i in range(start, self.position):
            token.append(self.bytes[i])
        return String(unsafe_from_utf8=Span(token))


fn encode_utf8(codepoint: Int, mut out: List[UInt8]):
    if codepoint < 0x80:
        out.append(UInt8(codepoint))
    elif codepoint < 0x800:
        out.append(UInt8(0xC0 | (codepoint >> 6)))
        out.append(UInt8(0x80 | (codepoint & 0x3F)))
    elif codepoint < 0x10000:
        out.append(UInt8(0xE0 | (codepoint >> 12)))
        out.append(UInt8(0x80 | ((codepoint >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (codepoint & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (codepoint >> 18)))
        out.append(UInt8(0x80 | ((codepoint >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((codepoint >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (codepoint & 0x3F)))


fn parse(text: String) raises -> Json:
    """Parse one complete JSON document and reject anything trailing it."""
    var bytes = List[UInt8]()
    var source = text.as_bytes()
    for i in range(len(source)):
        bytes.append(source[i])
    var parser = _Parser(bytes^)
    var doc = Json()
    doc.root = parser.value(doc, 0)
    parser.skip_space()
    if not parser.at_end():
        raise Error("ProtocolError|trailing bytes after JSON document")
    return doc^
