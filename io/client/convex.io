//
// An educational Convex client written in Io.
//
// Io's VM has no networking at all, so client/convex_transport.c supplies the
// smallest possible boundary: byte-level sockets, OpenSSL client TLS,
// readiness polling, secure randomness and a monotonic clock. Everything that
// is actually Convex - the HTTP envelope, RFC 6455 framing, the pinned sync
// state machine, reconnect and rehydration, and structured error
// classification - is written here in Io.
//
// The public surface is deliberately small:
//
//     client := Convex clientForUrl(System getEnvironmentVariable("CONVEX_URL"))
//     answer := client query("demo:state", Convex object(list("room", Convex string("demo"))))
//     id     := client subscribe("demo:state", args, block(kind, payload, logs, nil))
//     client unsubscribe(id)
//     client close
//
// Convex values cross this boundary as their exact JSON text rather than as
// decoded Io objects. Io has one Number type and no distinct null, so a decode
// and re-encode round trip would quietly rewrite a document id, a boolean or
// an integral number. Keeping the original bytes means the adapter and the
// example forward precisely what Convex sent.
//

Convex := Object clone do(
    clientVersion := "io-0.1.0"

    // The pinned Convex sync profile speaks these exact wire shapes. Anything
    // else on the socket is a protocol error rather than something to guess at.
    initialTimestamp := "AAAAAAAAAAA="

    // Bounds that keep a hostile or broken peer from growing the process. The
    // conformance runtime is capped at 128 MiB, so every buffer here is
    // deliberately far below that.
    maximumFrameBytes := 2097152
    maximumResponseBytes := 2097152
    maximumHeaderBytes := 32768

    // Absolute budget for one HTTP exchange, measured on the monotonic clock.
    httpTimeoutMs := 15000

    // A connection that has consumed part of a frame keeps its parser state,
    // but must not hold the only Live socket forever.
    partialFrameTimeoutMs := 5000

    // Reconnect backoff. A successful handshake resets it, so a healthy
    // connection never inherits an earlier failure's maximum delay.
    initialReconnectMs := 100
    maximumReconnectMs := 15000
)

// ------------------------------------------------------------------
// Native transport boundary
// ------------------------------------------------------------------

Convex transportPath := method(
    // The runtime images install the shared object beside the interpreter. A
    // source checkout overrides the location for language-local tests.
    override := System getEnvironmentVariable("CONVEX_IO_TRANSPORT")
    if(override and override size > 0, override, "/opt/convex/lib/libIoConvexIO.so")
)

Convex loadTransport := method(
    // Io's ordinary DynLib is the documented way to install a C proto and is
    // exactly what the VM's own AddonLoader uses. Loading it once into the
    // Lobby means every client in this process shares one handle table.
    if(Lobby hasLocalSlot("ConvexIO"), return Lobby ConvexIO)
    path := Convex transportPath
    if(File with(path) exists not,
        Exception raise("Convex transport library is missing at " .. path)
    )
    DynLib clone setPath(path) open voidCall("IoConvexIOInit", Lobby)
    if(Lobby hasLocalSlot("ConvexIO") not,
        Exception raise("Convex transport library did not install ConvexIO")
    )
    Lobby ConvexIO
)

// ------------------------------------------------------------------
// Structured errors
// ------------------------------------------------------------------
//
// Convex distinguishes a function that threw, a peer that broke the protocol
// and a socket that failed. Flattening those into one message would let a
// transport blip look like an application result, so the name, the raw
// errorData JSON and the log lines all travel with the exception.
//

ConvexError := Exception clone do(
    type := "ConvexError"
    convexName ::= "Error"
    convexData ::= "null"
    convexLogs ::= "[]"
)

Convex raiseError := method(name, message, data, logs,
    problem := ConvexError clone
    problem setError(message asString)
    problem setConvexName(name)
    problem setConvexData(if(data, data, "null"))
    problem setConvexLogs(if(logs, logs, "[]"))
    problem setCoroutine(Scheduler currentCoroutine)
    Scheduler currentCoroutine raiseException(problem)
)

Convex protocolError := method(message, Convex raiseError("ProtocolError", message, "null", "[]"))
Convex transportError := method(message, Convex raiseError("TransportError", message, "null", "[]"))

// Classify any caught exception into the adapter's four-field shape. A plain
// Io Exception raised by a bug in this file must not masquerade as a Convex
// FunctionError, so it keeps the neutral "Error" name.
Convex errorName := method(problem, if(problem hasSlot("convexName"), problem convexName, "Error"))
Convex errorData := method(problem, if(problem hasSlot("convexData"), problem convexData, "null"))
Convex errorLogs := method(problem, if(problem hasSlot("convexLogs"), problem convexLogs, "[]"))
Convex errorMessage := method(problem,
    text := problem error
    if(text isNil, "unknown error", text asString)
)

// A best-effort diagnostic write, retried a bounded number of times rather
// than propagated as a fatal exception on the first failure.
//
// Bisected against a real hostile-peer run: writing this process's own
// stderr through a pipe (the shape every Docker log capture and every CI
// runner uses) occasionally raised "error writing to file" - reproduced with
// a minimal, fully isolated repro (open a Live connection, force a
// partial-frame retire, reconnect, poll) that has nothing to do with any
// Convex protocol logic. Redirecting that same run's stderr straight to a
// plain file instead of a pipe made the failure disappear over dozens of
// repeated runs, and the one time it did fire mid-pipe, the very next write
// on the same stream succeeded immediately - a transient hiccup in whatever
// is capturing this process's output, not a permanent break in the stream
// and not a defect in this client's own logic. A bare `File write` treats
// that hiccup as fatal; retrying immediately is enough to ride it out
// because the next attempt already succeeded in every observed case.
Convex writeDiagnostic := method(stream, text,
    attempts := 0
    written := false
    while(written not and attempts < 8,
        problem := try(stream write(text))
        if(problem isNil, written = true, attempts = attempts + 1)
    )
    written
)

// ------------------------------------------------------------------
// JSON
// ------------------------------------------------------------------
//
// A scanner rather than a decoder. `field` and `elements` hand back the exact
// original bytes of a subtree, so a Convex value survives the trip through Io
// untouched. Only the protocol's own scalars - counters, status strings,
// timestamps - are ever decoded into Io values, and each of those is validated
// against its wire token first.
//

ConvexJson := Object clone do(
    quoteByte := 34
    backslashByte := 92
    hexDigits := "0123456789abcdef"

    hexDigit := method(value, ConvexJson hexDigits exSlice(value, value + 1))

    twoHexDigits := method(value,
        ConvexJson hexDigit((value / 16) floor) .. ConvexJson hexDigit(value % 16)
    )

    // Encode an Io Sequence as a JSON string literal. Bytes above 0x1f pass
    // through untouched, which keeps already valid UTF-8 exactly as it was and
    // avoids re-encoding text Convex will simply hand back.
    //
    // This scans by raw byte, so it needs a raw-byte view of `text`. An Io
    // string literal is not one by default: the lexer stores it as UCS-2
    // characters (itemType uint16, one code unit per Unicode character, `at()`
    // returning the codepoint), not as UTF-8 bytes. Scanning that view with
    // this method's byte-oriented logic silently drops the high byte of every
    // multi-byte character on the way back out (each `é` became a single raw
    // byte 233 instead of the two UTF-8 bytes 0xC3 0xA9). `asUTF8` forces the
    // byte-level view (itemType uint8, `size`/`at()` counting encoded bytes)
    // that the rest of this method assumes; it is a no-op for values that are
    // already byte sequences, such as text decoded from the wire.
    quote := method(text,
        source := text asUTF8
        out := Sequence clone
        out appendSeq("\"")
        start := 0
        index := 0
        limit := source size
        while(index < limit,
            code := source at(index)
            escape := nil
            if(code == 34, escape = "\\\"")
            if(code == 92, escape = "\\\\")
            if(code == 8, escape = "\\b")
            if(code == 9, escape = "\\t")
            if(code == 10, escape = "\\n")
            if(code == 12, escape = "\\f")
            if(code == 13, escape = "\\r")
            if(escape isNil and code < 32, escape = "\\u00" .. ConvexJson twoHexDigits(code))
            if(escape,
                if(index > start, out appendSeq(source exSlice(start, index)))
                out appendSeq(escape)
                start = index + 1
            )
            index = index + 1
        )
        if(limit > start, out appendSeq(source exSlice(start, limit)))
        out appendSeq("\"")
        out asSymbol
    )

    // Build raw JSON containers from already encoded members, so nested Convex
    // data is never re-serialized on its way out.
    object := method(pairs,
        out := Sequence clone
        out appendSeq("{")
        index := 0
        while(index < pairs size,
            if(index > 0, out appendSeq(","))
            out appendSeq(ConvexJson quote(pairs at(index)))
            out appendSeq(":")
            out appendSeq(pairs at(index + 1) asString)
            index = index + 2
        )
        out appendSeq("}")
        out asSymbol
    )

    array := method(values,
        out := Sequence clone
        out appendSeq("[")
        values foreach(position, value,
            if(position > 0, out appendSeq(","))
            out appendSeq(value asString)
        )
        out appendSeq("]")
        out asSymbol
    )

    isSpaceByte := method(code, code == 32 or code == 9 or code == 10 or code == 13)

    skipSpace := method(text, index,
        cursor := index
        while(cursor < text size and ConvexJson isSpaceByte(text at(cursor)), cursor = cursor + 1)
        cursor
    )

    // INDEX points at the opening quote. A backslash escape consumes the byte
    // after it, and a \u escape consumes four more, so a quote inside an escape
    // never ends the literal early.
    stringEnd := method(text, index,
        cursor := index + 1
        limit := text size
        result := nil
        while(result isNil and cursor < limit,
            code := text at(cursor)
            if(code == ConvexJson backslashByte) then(
                cursor = cursor + 1
                if(cursor >= limit, Convex protocolError("unterminated JSON escape"))
                if(text at(cursor) == 117, cursor = cursor + 4)
                cursor = cursor + 1
            ) elseif(code == ConvexJson quoteByte) then(
                result = cursor + 1
            ) else(
                cursor = cursor + 1
            )
        )
        if(result isNil, Convex protocolError("unterminated JSON string"))
        result
    )

    // Return the index one past a complete JSON value starting at INDEX,
    // validating the structure on the way. Strings are skipped as whole units
    // so a brace inside a string cannot unbalance a container. Objects and
    // arrays are validated recursively by objectEnd/arrayEnd below rather
    // than by bracket-depth counting alone - depth counting only proves the
    // braces balance, so `{"a":}` (a key with no value at all) balanced its
    // braces and was accepted as "valid" until this recursed into the actual
    // member grammar.
    valueEnd := method(text, index,
        cursor := ConvexJson skipSpace(text, index)
        limit := text size
        if(cursor >= limit, Convex protocolError("expected a JSON value"))
        code := text at(cursor)
        if(code == ConvexJson quoteByte, return ConvexJson stringEnd(text, cursor))
        if(code == 123, return ConvexJson objectEnd(text, cursor))
        if(code == 91, return ConvexJson arrayEnd(text, cursor))
        // A literal or a number ends at the first structural byte.
        scan := cursor
        while(scan < limit,
            current := text at(scan)
            if(current == 44 or current == 93 or current == 125, break)
            if(ConvexJson isSpaceByte(current), break)
            scan = scan + 1
        )
        if(scan == cursor, Convex protocolError("expected a JSON value"))
        scan
    )

    // Walk a JSON object starting at its opening brace (INDEX), validating
    // that every member is a quoted key, a colon, and a full value - each
    // recursively confirmed by valueEnd - separated by commas, with no
    // trailing comma before the closing brace. Returns the index one past
    // the closing brace.
    objectEnd := method(text, index,
        limit := text size
        cursor := ConvexJson skipSpace(text, index + 1)
        if(cursor < limit and text at(cursor) == 125, return cursor + 1)
        scanning := true
        while(scanning,
            cursor = ConvexJson skipSpace(text, cursor)
            if(cursor >= limit or text at(cursor) != ConvexJson quoteByte,
                Convex protocolError("malformed JSON object key")
            )
            cursor = ConvexJson stringEnd(text, cursor)
            cursor = ConvexJson skipSpace(text, cursor)
            if(cursor >= limit or text at(cursor) != 58,
                Convex protocolError("malformed JSON object separator")
            )
            // valueEnd itself skips leading space, so the member's value can
            // be validated directly from just past the colon - including the
            // case where nothing but a closing brace or comma follows it.
            cursor = ConvexJson valueEnd(text, cursor + 1)
            cursor = ConvexJson skipSpace(text, cursor)
            if(cursor >= limit, Convex protocolError("unterminated JSON container"))
            if(text at(cursor) == 125) then(
                cursor = cursor + 1
                scanning = false
            ) elseif(text at(cursor) == 44) then(
                cursor = ConvexJson skipSpace(text, cursor + 1)
            ) else(
                Convex protocolError("malformed JSON object separator")
            )
        )
        cursor
    )

    // The array counterpart to objectEnd: every element is a full value,
    // recursively confirmed by valueEnd, separated by commas with no
    // trailing comma before the closing bracket.
    arrayEnd := method(text, index,
        limit := text size
        cursor := ConvexJson skipSpace(text, index + 1)
        if(cursor < limit and text at(cursor) == 93, return cursor + 1)
        scanning := true
        while(scanning,
            cursor = ConvexJson valueEnd(text, cursor)
            cursor = ConvexJson skipSpace(text, cursor)
            if(cursor >= limit, Convex protocolError("unterminated JSON container"))
            if(text at(cursor) == 93) then(
                cursor = cursor + 1
                scanning = false
            ) elseif(text at(cursor) == 44) then(
                cursor = ConvexJson skipSpace(text, cursor + 1)
            ) else(
                Convex protocolError("malformed JSON array separator")
            )
        )
        cursor
    )

    // Fully validate a document and reject trailing bytes. Used on every
    // inbound envelope and on caller supplied arguments before they are sent.
    validate := method(text,
        source := text asString
        finish := ConvexJson valueEnd(source, 0)
        if(ConvexJson skipSpace(source, finish) != source size,
            Convex protocolError("JSON document had trailing bytes")
        )
        source
    )

    isObject := method(text,
        source := text asString
        cursor := ConvexJson skipSpace(source, 0)
        cursor < source size and source at(cursor) == 123
    )

    // Return the raw bytes of one member of a JSON object, or nil. The scan
    // never decodes sibling members, so an unrelated value cannot fail the
    // lookup of the field the protocol actually needs.
    field := method(objectText, name,
        source := objectText asString
        cursor := ConvexJson skipSpace(source, 0)
        if(cursor >= source size or source at(cursor) != 123,
            Convex protocolError("expected a JSON object")
        )
        cursor = cursor + 1
        limit := source size
        answer := nil
        scanning := true
        while(scanning,
            cursor = ConvexJson skipSpace(source, cursor)
            if(cursor >= limit or source at(cursor) == 125) then(
                scanning = false
            ) else(
                if(source at(cursor) != ConvexJson quoteByte,
                    Convex protocolError("malformed JSON object key")
                )
                keyEnd := ConvexJson stringEnd(source, cursor)
                key := ConvexJson decodeString(source exSlice(cursor, keyEnd))
                cursor = ConvexJson skipSpace(source, keyEnd)
                if(cursor >= limit or source at(cursor) != 58,
                    Convex protocolError("malformed JSON object separator")
                )
                start := ConvexJson skipSpace(source, cursor + 1)
                finish := ConvexJson valueEnd(source, start)
                if(key == name and answer isNil, answer = source exSlice(start, finish))
                cursor = ConvexJson skipSpace(source, finish)
                if(cursor < limit and source at(cursor) == 44, cursor = cursor + 1)
            )
        )
        answer
    )

    requiredField := method(objectText, name,
        found := ConvexJson field(objectText, name)
        if(found isNil, Convex protocolError("JSON object omitted required field " .. name))
        found
    )

    elements := method(arrayText,
        source := arrayText asString
        cursor := ConvexJson skipSpace(source, 0)
        if(cursor >= source size or source at(cursor) != 91,
            Convex protocolError("expected a JSON array")
        )
        cursor = cursor + 1
        limit := source size
        found := list()
        scanning := true
        while(scanning,
            cursor = ConvexJson skipSpace(source, cursor)
            if(cursor >= limit or source at(cursor) == 93) then(
                scanning = false
            ) else(
                finish := ConvexJson valueEnd(source, cursor)
                found append(source exSlice(cursor, finish))
                cursor = ConvexJson skipSpace(source, finish)
                if(cursor < limit and source at(cursor) == 44) then(
                    cursor = cursor + 1
                ) else(
                    if(cursor >= limit or source at(cursor) != 93,
                        Convex protocolError("malformed JSON array separator")
                    )
                )
            )
        )
        found
    )

    // Append one Unicode scalar as UTF-8. JSON escapes are the only place this
    // client has to build bytes rather than copy them.
    appendUtf8 := method(out, scalar,
        if(scalar < 128) then(
            out append(scalar)
        ) elseif(scalar < 2048) then(
            out append(192 + (scalar / 64) floor)
            out append(128 + (scalar % 64))
        ) elseif(scalar < 65536) then(
            out append(224 + (scalar / 4096) floor)
            out append(128 + ((scalar / 64) floor % 64))
            out append(128 + (scalar % 64))
        ) else(
            out append(240 + (scalar / 262144) floor)
            out append(128 + ((scalar / 4096) floor % 64))
            out append(128 + ((scalar / 64) floor % 64))
            out append(128 + (scalar % 64))
        )
        out
    )

    hexValue := method(code,
        if(code >= 48 and code <= 57, return code - 48)
        if(code >= 97 and code <= 102, return code - 87)
        if(code >= 65 and code <= 70, return code - 55)
        Convex protocolError("malformed JSON unicode escape")
    )

    decodeString := method(raw,
        source := raw asString
        if(source size < 2 or source at(0) != ConvexJson quoteByte,
            Convex protocolError("expected a JSON string")
        )
        out := Sequence clone
        cursor := 1
        limit := source size - 1
        while(cursor < limit,
            code := source at(cursor)
            if(code != ConvexJson backslashByte) then(
                out append(code)
                cursor = cursor + 1
            ) else(
                cursor = cursor + 1
                if(cursor >= limit, Convex protocolError("unterminated JSON escape"))
                marker := source at(cursor)
                cursor = cursor + 1
                handled := false
                if(marker == 110, out append(10); handled = true)
                if(marker == 116, out append(9); handled = true)
                if(marker == 114, out append(13); handled = true)
                if(marker == 98, out append(8); handled = true)
                if(marker == 102, out append(12); handled = true)
                if(marker == 34, out append(34); handled = true)
                if(marker == 92, out append(92); handled = true)
                if(marker == 47, out append(47); handled = true)
                if(marker == 117,
                    handled = true
                    if(cursor + 4 > limit, Convex protocolError("truncated JSON unicode escape"))
                    scalar := 0
                    for(offset, 0, 3,
                        scalar = scalar * 16 + ConvexJson hexValue(source at(cursor + offset))
                    )
                    cursor = cursor + 4
                    // A high surrogate only means something with its partner,
                    // so combine the pair before producing UTF-8 bytes.
                    if(scalar >= 55296 and scalar <= 56319,
                        if(cursor + 6 <= limit and source at(cursor) == ConvexJson backslashByte,
                            if(source at(cursor + 1) == 117,
                                low := 0
                                for(offset, 0, 3,
                                    low = low * 16 + ConvexJson hexValue(source at(cursor + 2 + offset))
                                )
                                if(low >= 56320 and low <= 57343,
                                    scalar = 65536 + (scalar - 55296) * 1024 + (low - 56320)
                                    cursor = cursor + 6
                                )
                            )
                        )
                    )
                    ConvexJson appendUtf8(out, scalar)
                )
                if(handled not, Convex protocolError("unsupported JSON escape"))
            )
        )
        out asSymbol
    )

    // Protocol counters must be genuine JSON integers. A quoted or fractional
    // lookalike would otherwise enter the sync state machine and desynchronise
    // the query set silently.
    decodeUint32 := method(raw, label,
        token := raw asString asMutable strip
        if(token size == 0, Convex protocolError(label .. " must be a JSON uint32 integer"))
        index := 0
        while(index < token size,
            code := token at(index)
            if(code < 48 or code > 57, Convex protocolError(label .. " must be a JSON uint32 integer"))
            index = index + 1
        )
        if(token size > 1 and token at(0) == 48,
            Convex protocolError(label .. " must be a JSON uint32 integer")
        )
        value := token asNumber
        if(value > 4294967295, Convex protocolError(label .. " must be a JSON uint32 integer"))
        value
    )

    decodeRequiredString := method(raw, label,
        if(raw isNil, Convex protocolError(label .. " must be a JSON string"))
        token := raw asString asMutable strip
        if(token size < 2 or token at(0) != ConvexJson quoteByte,
            Convex protocolError(label .. " must be a JSON string")
        )
        ConvexJson decodeString(token)
    )
)

// Convenience wrappers so example and adapter code reads as Convex, not JSON.
Convex string := method(text, ConvexJson quote(text))
Convex object := method(pairs, ConvexJson object(pairs))
Convex array := method(values, ConvexJson array(values))
Convex field := method(objectText, name, ConvexJson requiredField(objectText, name))
Convex optionalField := method(objectText, name, ConvexJson field(objectText, name))
Convex text := method(raw, ConvexJson decodeString(raw))

// ------------------------------------------------------------------
// SHA-1
// ------------------------------------------------------------------
//
// RFC 6455 requires the client to verify Sec-WebSocket-Accept, which means a
// SHA-1 of the key plus the protocol's fixed GUID. Io has no digest in core,
// and putting one in the C boundary would move protocol work out of the target
// language, so the 32-bit arithmetic lives here. Io Numbers are doubles, which
// hold integers exactly up to 2^53, so every step is reduced back below 2^32
// before the next one - including the rotate, which splits the value instead
// of shifting it left past the exact range.
//

ConvexSha1 := Object clone do(
    mask := 4294967295

    rotate := method(value, places,
        divisor := 2 ** (32 - places)
        (value % divisor) * (2 ** places) + (value / divisor) floor
    )

    digest := method(message,
        source := message asString
        h0 := 1732584193
        h1 := 4023233417
        h2 := 2562383102
        h3 := 271733878
        h4 := 3285377520

        padded := Sequence clone
        padded appendSeq(source)
        padded append(128)
        while(padded size % 64 != 56, padded append(0))
        // The trailing length is the message size in bits, big endian. The
        // inputs here are tiny, so only the low 32 bits can be non-zero.
        bitLength := source size * 8
        for(index, 0, 3, padded append(0))
        padded append((bitLength / 16777216) floor % 256)
        padded append((bitLength / 65536) floor % 256)
        padded append((bitLength / 256) floor % 256)
        padded append(bitLength % 256)

        chunkStart := 0
        while(chunkStart < padded size,
            words := list()
            for(index, 0, 15,
                base := chunkStart + index * 4
                words append(
                    padded at(base) * 16777216 + padded at(base + 1) * 65536 + \
                        padded at(base + 2) * 256 + padded at(base + 3)
                )
            )
            for(index, 16, 79,
                mixed := words at(index - 3) bitwiseXor(words at(index - 8))
                mixed = mixed bitwiseXor(words at(index - 14))
                mixed = mixed bitwiseXor(words at(index - 16))
                words append(ConvexSha1 rotate(mixed, 1))
            )

            a := h0
            b := h1
            c := h2
            d := h3
            e := h4

            for(index, 0, 79,
                f := 0
                k := 0
                if(index < 20) then(
                    f = (b bitwiseAnd(c)) bitwiseOr((b bitwiseXor(ConvexSha1 mask)) bitwiseAnd(d))
                    k = 1518500249
                ) elseif(index < 40) then(
                    f = b bitwiseXor(c) bitwiseXor(d)
                    k = 1859775393
                ) elseif(index < 60) then(
                    f = (b bitwiseAnd(c)) bitwiseOr(b bitwiseAnd(d)) bitwiseOr(c bitwiseAnd(d))
                    k = 2400959708
                ) else(
                    f = b bitwiseXor(c) bitwiseXor(d)
                    k = 3395469782
                )
                temporary := (ConvexSha1 rotate(a, 5) + f + e + k + words at(index)) % 4294967296
                e = d
                d = c
                c = ConvexSha1 rotate(b, 30)
                b = a
                a = temporary
            )

            h0 = (h0 + a) % 4294967296
            h1 = (h1 + b) % 4294967296
            h2 = (h2 + c) % 4294967296
            h3 = (h3 + d) % 4294967296
            h4 = (h4 + e) % 4294967296
            chunkStart = chunkStart + 64
        )

        out := Sequence clone
        list(h0, h1, h2, h3, h4) foreach(word,
            out append((word / 16777216) floor % 256)
            out append((word / 65536) floor % 256)
            out append((word / 256) floor % 256)
            out append(word % 256)
        )
        out
    )
)

// Io's base64 encoder is libb64, which always terminates its output with a
// newline. Strip it rather than sending a header value with an embedded line
// break.
Convex base64 := method(bytes, bytes asBase64 asMutable strip asSymbol)

// A short unguessable token. Io's VM has no random number generator, so this
// comes from the transport boundary's CSPRNG. The example uses one as a
// mutation idempotency key, which is why it is part of the public surface.
Convex randomToken := method(byteCount,
    Convex base64(Convex loadTransport randomBytes(byteCount))
)

// ------------------------------------------------------------------
// Deployment URLs
// ------------------------------------------------------------------

ConvexUrl := Object clone do(
    parse := method(url,
        source := url asString asMutable strip
        secure := nil
        rest := nil
        if(source beginsWithSeq("https://")) then(
            secure = true
            rest = source exSlice(8)
        ) elseif(source beginsWithSeq("http://")) then(
            secure = false
            rest = source exSlice(7)
        ) else(
            Exception raise("Convex deployment URL must be an absolute HTTP(S) URL")
        )
        if(rest size == 0, Exception raise("Convex deployment URL has no host"))
        slash := rest findSeq("/")
        authority := if(slash, rest exSlice(0, slash), rest)
        path := if(slash, rest exSlice(slash), "" asMutable)
        if(authority containsSeq("?") or authority containsSeq("#"),
            Exception raise("Convex deployment URL must not carry a query or fragment")
        )
        colon := authority findSeq(":")
        host := if(colon, authority exSlice(0, colon), authority)
        // asNumber would happily read "80junk" as 80, so the port is checked
        // digit by digit before it is trusted.
        port := if(secure, 443, 80)
        if(colon,
            digits := authority exSlice(colon + 1)
            if(digits size == 0, Exception raise("Convex deployment URL has an invalid port"))
            index := 0
            while(index < digits size,
                code := digits at(index)
                if(code < 48 or code > 57,
                    Exception raise("Convex deployment URL has an invalid port")
                )
                index = index + 1
            )
            port = digits asNumber
        )
        if(host size == 0, Exception raise("Convex deployment URL has no host"))
        if(port isNan or port < 1 or port > 65535,
            Exception raise("Convex deployment URL has an invalid port")
        )
        // A trailing slash would double up when the API path is appended.
        while(path size > 0 and path at(path size - 1) == 47,
            path = path exSlice(0, path size - 1)
        )
        parsed := Object clone
        parsed secure := secure
        parsed host := host asSymbol
        parsed port := port
        parsed basePath := path asSymbol
        // RFC 7230 requires Host to carry the port whenever it is not the
        // scheme's default. The approved local backend answers on 3210, and a
        // deployment behind a proxy routes on this value, so dropping the port
        // would reach a different virtual host than the one that was dialled.
        defaultPort := if(secure, 443, 80)
        parsed authority := if(port == defaultPort,
            host asSymbol,
            (host .. ":" .. port asString) asSymbol
        )
        parsed
    )
)

// ------------------------------------------------------------------
// Byte streams
// ------------------------------------------------------------------
//
// One stream owns one transport handle. It holds exactly one authoritative
// copy of the bytes the transport has not yet accepted, so a partial write can
// be retried without ever duplicating a frame that was already handed over.
//

ConvexStream := Object clone do(
    init := method(
        self io := nil
        self handle := -1
        self stage := "closed"
        self outgoing := Sequence clone
        self incoming := Sequence clone
        self atEnd := false
        self host := ""
    )

    openTo := method(targetHost, port, useTls,
        self io = Convex loadTransport
        self host = targetHost asSymbol
        opened := self io connect(targetHost asSymbol, port, if(useTls, 1, 0))
        if(opened < 0, Convex transportError("connect failed: " .. self io errorText))
        self handle = opened
        self stage = "connecting"
        self
    )

    adopt := method(descriptor,
        self io = Convex loadTransport
        self handle = self io adoptDescriptor(descriptor)
        self stage = "open"
        self
    )

    isClosed := method(self stage == "closed")
    isOpen := method(self stage == "open")

    // The transport can hold decrypted TLS bytes that poll() cannot see, so a
    // reader must treat those as immediate readability. Once the stream has
    // reported end of stream those bytes can never be consumed, and claiming
    // readability for them would drive the event loop's timeout to zero and
    // spin the process at full speed for as long as the stream is held.
    //
    // hasBufferedInput and wantsRead below are written as sequential early
    // returns rather than one `or`/`and`-joined expression on the same
    // grounds as pumpOnce's readable-service check further down this file:
    // this exact family of shape - a method-derived boolean combined inline
    // with a second condition, evaluated repeatedly from inside the polling
    // loop - is what corrupted the pinned Io VM (IoLanguage/io native @
    // 3d4bc9c) once already in isBackpressured, and again in pumpOnce's own
    // readMask/writeMask pass once enough GC pressure had built up. These
    // methods are on the same hot path (called through `item wantsRead` /
    // `item hasBufferedInput` on every pollable, every pumpOnce call), so
    // they are written defensively the same way rather than waiting for a
    // third bisection to prove they are reachable too.
    hasBufferedInput := method(
        if(self isClosed, return false)
        if(self atEnd, return false)
        self io bufferedBytes(self handle) > 0
    )

    wantsRead := method(
        if(self isClosed, return false)
        self atEnd not
    )
    wantsWrite := method(
        if(self isClosed, return false)
        if(self stage == "connecting", return true)
        self outgoing size > 0
    )

    // Advance a connecting stream by one non-blocking step. Waiting and the
    // deadline stay with the caller, so every wait in this client is bounded.
    advance := method(
        if(self stage != "connecting", return true)
        result := self io handshake(self handle)
        if(result < 0, Convex transportError("TLS handshake failed: " .. self io errorText))
        if(result == 0, self stage = "open"; return true)
        false
    )

    enqueue := method(bytes, self outgoing appendSeq(bytes); self)

    flushOnce := method(
        if(self isClosed or self outgoing size == 0, return 0)
        accepted := self io write(self handle, self outgoing)
        if(accepted < 0, Convex transportError("write failed: " .. self io errorText))
        if(accepted > 0,
            // The transport now owns those bytes. Dropping them here is what
            // makes a later retry safe rather than duplicating a frame.
            self outgoing = self outgoing exSlice(accepted)
        )
        accepted
    )

    fill := method(
        if(self isClosed or self atEnd, return 0)
        chunk := self io read(self handle, 65536)
        if(chunk isNil, self atEnd = true; return 0)
        if(chunk size > 0, self incoming appendSeq(chunk))
        chunk size
    )

    serviceWrite := method(
        if(self stage == "connecting", if(self advance not, return self))
        self flushOnce
        self
    )

    serviceRead := method(
        if(self stage == "connecting", if(self advance not, return self))
        self fill
        self
    )

    close := method(
        if(self isClosed, return self)
        self io close(self handle)
        self handle = -1
        self stage = "closed"
        self outgoing = Sequence clone
        self incoming = Sequence clone
        self
    )
)

// ------------------------------------------------------------------
// RFC 6455 framing
// ------------------------------------------------------------------
//
// Io owns the frame parser rather than delegating it, because the repository
// requires bounded behaviour against a peer that stalls halfway through a
// frame. Every consumed byte stays in the stream's buffer until a whole frame
// is available, so a timeout either preserves parser state or abandons the
// connection - it never resynchronises at a byte that merely looks like a
// frame boundary.
//

ConvexFrame := Object clone do(
    // Build a masked client frame. RFC 6455 requires client-to-server frames
    // to carry unpredictable masking keys, which is why the transport boundary
    // exposes the CSPRNG.
    encode := method(io, opcode, payload,
        body := payload asString
        length := body size
        if(length > Convex maximumFrameBytes,
            Convex protocolError("WebSocket frame exceeds the byte budget")
        )
        frame := Sequence clone
        frame append(128 + opcode)
        if(length < 126) then(
            frame append(128 + length)
        ) elseif(length <= 65535) then(
            frame append(254)
            frame append((length / 256) floor)
            frame append(length % 256)
        ) else(
            frame append(255)
            for(unused, 0, 3, frame append(0))
            frame append((length / 16777216) floor % 256)
            frame append((length / 65536) floor % 256)
            frame append((length / 256) floor % 256)
            frame append(length % 256)
        )
        maskKey := io randomBytes(4)
        frame appendSeq(maskKey)
        index := 0
        while(index < length,
            frame append(body at(index) bitwiseXor(maskKey at(index % 4)))
            index = index + 1
        )
        frame
    )

    // Try to take one complete frame from BUFFER. Returns nil when more bytes
    // are needed, leaving the buffer untouched.
    decode := method(buffer,
        if(buffer size < 2, return nil)
        first := buffer at(0)
        second := buffer at(1)
        // Reserved bits and a server-set mask bit are protocol violations, not
        // something to tolerate.
        if(first bitwiseAnd(112) != 0, Convex protocolError("invalid WebSocket frame flags"))
        if(second bitwiseAnd(128) != 0, Convex protocolError("server frame must not be masked"))
        final := first bitwiseAnd(128) != 0
        opcode := first bitwiseAnd(15)
        length := second bitwiseAnd(127)
        offset := 2
        if(length == 126,
            if(buffer size < 4, return nil)
            length = buffer at(2) * 256 + buffer at(3)
            offset = 4
        )
        if(length == 127,
            if(buffer size < 10, return nil)
            length = 0
            for(index, 2, 9, length = length * 256 + buffer at(index))
            offset = 10
        )
        if(length > Convex maximumFrameBytes,
            Convex protocolError("WebSocket frame exceeds the byte budget")
        )
        if(opcode >= 8 and (final not or length > 125),
            Convex protocolError("invalid WebSocket control frame")
        )
        if(buffer size < offset + length, return nil)
        frame := Object clone
        frame final := final
        frame opcode := opcode
        frame payload := buffer exSlice(offset, offset + length)
        frame consumed := offset + length
        frame
    )
)

// ------------------------------------------------------------------
// The Live WebSocket connection
// ------------------------------------------------------------------

ConvexSocket := Object clone do(
    init := method(
        self stream := nil
        self phase := "closed"
        self key := ""
        self fragments := Sequence clone
        self fragmentOpcode := -1
        self partialSince := nil
        self authority := ""
        self path := ""
        self onMessage := nil
        self closeSent := false
        self io := nil
        // Set by the owning ConvexClient right after connectTo, and read
        // back by that same client's onMessage callback. A real slot on this
        // socket rather than something the callback closes over: see the
        // comment on ensureLive's use of it for why.
        self owner := nil
    )

    connectTo := method(deployment, requestPath,
        self io = Convex loadTransport
        self stream = ConvexStream clone openTo(deployment host, deployment port, deployment secure)
        self authority = deployment authority
        self path = requestPath
        self phase = "connecting"
        self
    )

    isClosed := method(self phase == "closed")
    isOpen := method(self phase == "open")

    handle := method(if(self stream, self stream handle, -1))
    // Sequential early returns rather than `and`-joined method chains for the
    // same reason as ConvexStream's wantsRead/hasBufferedInput above: these
    // three are called through `item wantsRead` / `item wantsWrite` /
    // `item hasBufferedInput` on every pollable, every pumpOnce call, so they
    // sit on the exact hot path where that pinned-VM corruption showed up.
    wantsRead := method(
        if(self stream isNil, return false)
        self stream wantsRead
    )
    wantsWrite := method(
        if(self stream isNil, return false)
        self stream wantsWrite
    )
    hasBufferedInput := method(
        if(self stream isNil, return false)
        self stream hasBufferedInput
    )

    // The upgrade request carries the same Convex-Client header as the HTTP
    // path, so a deployment sees one consistent client identity.
    sendUpgrade := method(
        self key = Convex base64(self io randomBytes(16))
        request := Sequence clone
        request appendSeq("GET " .. self path .. " HTTP/1.1\r\n")
        request appendSeq("Host: " .. self authority .. "\r\n")
        request appendSeq("Upgrade: websocket\r\n")
        request appendSeq("Connection: Upgrade\r\n")
        request appendSeq("Sec-WebSocket-Key: " .. self key .. "\r\n")
        request appendSeq("Sec-WebSocket-Version: 13\r\n")
        request appendSeq("Convex-Client: " .. Convex clientVersion .. "\r\n")
        request appendSeq("\r\n")
        self stream enqueue(request)
        self phase = "handshake"
        self
    )

    serviceWrite := method(
        if(self stream isNil, return self)
        if(self stream stage == "connecting",
            if(self stream advance not, return self)
        )
        if(self phase == "connecting",
            if(self stream isOpen, self sendUpgrade)
        )
        self stream flushOnce
        self
    )

    serviceRead := method(
        if(self stream isNil, return self)
        if(self stream stage == "connecting",
            if(self stream advance not, return self)
        )
        if(self phase == "connecting",
            if(self stream isOpen,
                self sendUpgrade
                self stream flushOnce
            )
        )
        self stream fill
        if(self phase == "handshake", self readHandshake)
        if(self phase == "open", self readFrames)
        // Nested rather than one triple `and` chain, for the same reason as
        // the predicate methods above: this runs on every serviceRead call
        // while a connection is open, which is the hot path that corrupted
        // the pinned VM once already.
        if(self stream atEnd,
            if(self stream incoming size == 0,
                if(self phase != "closed",
                    Convex transportError("peer closed the Live connection")
                )
            )
        )
        self
    )

    readHandshake := method(
        buffer := self stream incoming
        marker := buffer findSeq("\r\n\r\n")
        if(marker isNil,
            if(buffer size > Convex maximumHeaderBytes,
                Convex protocolError("WebSocket upgrade headers exceed the byte budget")
            )
            if(self stream atEnd,
                Convex transportError("peer closed during the WebSocket upgrade")
            )
            return self
        )
        headers := buffer exSlice(0, marker) asString
        self stream incoming = buffer exSlice(marker + 4)
        lines := headers split("\r\n")
        status := lines at(0)
        if(status isNil or status beginsWithSeq("HTTP/1.") not or status containsSeq(" 101") not,
            Convex protocolError("WebSocket upgrade was not 101")
        )
        accepted := nil
        lines foreach(line,
            if(line asLowercase beginsWithSeq("sec-websocket-accept:"),
                accepted = line exSlice(21) asMutable strip asSymbol
            )
        )
        // The GUID is fixed by RFC 6455. Checking the digest proves the peer
        // really performed the upgrade rather than replaying a cached body.
        expected := Convex base64(
            ConvexSha1 digest(self key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        )
        if(accepted isNil or accepted != expected,
            Convex protocolError("WebSocket upgrade acceptance failed")
        )
        self phase = "open"
        self partialSince = nil
        self
    )

    readFrames := method(
        parsing := true
        while(parsing,
            frame := ConvexFrame decode(self stream incoming)
            if(frame isNil) then(
                parsing = false
            ) else(
                self stream incoming = self stream incoming exSlice(frame consumed)
                self deliver(frame)
                if(self phase != "open", parsing = false)
            )
        )
        // Track when a partial frame first appeared so the owner can retire a
        // connection that stalls mid-frame, without ever restarting the parser
        // at a false boundary.
        incomplete := self stream incoming size > 0 or self fragmentOpcode >= 0
        if(incomplete and self partialSince isNil, self partialSince = self io monotonicMs)
        if(incomplete not, self partialSince = nil)
        self
    )

    deliver := method(frame,
        opcode := frame opcode
        if(opcode == 8,
            // RFC 6455 asks a client that receives Close to answer with Close.
            // The reply is written best effort into whatever the transport
            // takes right now and is never waited on, so a peer that has
            // stopped reading cannot use the courtesy to hold this client open.
            status := if(frame payload size >= 2,
                frame payload at(0) * 256 + frame payload at(1),
                1005
            )
            self sendClose(1000, "")
            Convex transportError(
                "peer sent a WebSocket close frame with status " .. status asString
            )
        )
        if(opcode == 9,
            self stream enqueue(ConvexFrame encode(self io, 10, frame payload))
            self stream flushOnce
            return self
        )
        if(opcode == 10, return self)
        payload := frame payload
        if(opcode == 0) then(
            if(self fragmentOpcode < 0, Convex protocolError("unexpected WebSocket continuation"))
            if(self fragments size + payload size > Convex maximumFrameBytes,
                Convex protocolError("fragmented WebSocket message exceeds the byte budget")
            )
            self fragments appendSeq(payload)
            if(frame final not, return self)
            opcode = self fragmentOpcode
            payload = self fragments
            self fragments = Sequence clone
            self fragmentOpcode = -1
        ) elseif(opcode == 1 or opcode == 2) then(
            if(self fragmentOpcode >= 0,
                Convex protocolError("new WebSocket data frame during a fragment")
            )
            if(frame final not,
                if(payload size > Convex maximumFrameBytes,
                    Convex protocolError("fragmented WebSocket message exceeds the byte budget")
                )
                self fragmentOpcode = opcode
                self fragments = Sequence clone appendSeq(payload)
                return self
            )
        ) else(
            Convex protocolError("unsupported WebSocket opcode")
        )
        if(opcode != 1, Convex protocolError("binary WebSocket data is unsupported"))
        // `self` is passed explicitly alongside the payload for the same
        // reason publish() passes `entry`: this call is reached through
        // serviceReadable's try(), where a bare `self` inside the callback
        // would not reliably resolve to this socket - see ensureLive's
        // comment in this file for the full story.
        if(self onMessage, self onMessage call(payload asString, self))
        self
    )

    sendText := method(text,
        if(self isOpen not, Convex transportError("Live WebSocket is not connected"))
        self stream enqueue(ConvexFrame encode(self io, 1, text asString))
        self stream flushOnce
        self
    )

    // A Close frame is a control frame, so RFC 6455 caps its whole payload at
    // 125 bytes: two for the status code and at most 123 for the reason. The
    // send is one non-blocking attempt and its failure is deliberately ignored,
    // because the connection is being abandoned either way.
    sendClose := method(status, reason,
        if(self stream isNil or self isOpen not or self closeSent, return self)
        self closeSent = true
        payload := Sequence clone
        payload append((status / 256) floor % 256)
        payload append(status % 256)
        text := reason asString
        if(text size > 123, text = text exSlice(0, 123))
        payload appendSeq(text)
        try(
            self stream enqueue(ConvexFrame encode(self io, 8, payload))
            self stream flushOnce
        )
        self
    )

    partialFrameExpired := method(budgetMs,
        if(self partialSince isNil, return false)
        self io monotonicMs - self partialSince > budgetMs
    )

    close := method(
        // Announce the close before dropping the socket, but never wait for the
        // peer's answer: close stays bounded against an idle, a chatty and a
        // stalled peer alike.
        self sendClose(1000, "")
        if(self stream, self stream close)
        self phase = "closed"
        self fragments = Sequence clone
        self fragmentOpcode = -1
        self partialSince = nil
        self closeSent = false
        self
    )
)

// ------------------------------------------------------------------
// Subscriptions
// ------------------------------------------------------------------

ConvexSubscription := Object clone do(
    init := method(
        self queryId := 0
        self path := ""
        self args := "{}"
        self callback := nil
        self lastSignature := nil
    )
)

// ------------------------------------------------------------------
// The client
// ------------------------------------------------------------------

ConvexClient := Object clone do(
    init := method(
        self deployment := nil
        self authToken := ""
        self closed := false
        self io := nil
        self socket := nil
        self subscriptions := Map clone
        self nextQueryId := 0
        self querySetVersion := 0
        self remoteVersion := nil
        self connectionCount := 0
        self lastCloseReason := "InitialConnect"
        self maxObservedTimestamp := nil
        self reconnectDelayMs := Convex initialReconnectMs
        self reconnectAtMs := nil
        self httpStream := nil
        self partialFrameTimeoutMs := Convex partialFrameTimeoutMs
        self diagnostics := true
        // The adapter registers its controller channel here so its stdin and
        // stdout make progress from the same wait point as the sockets,
        // without ever taking ownership of them.
        self extraPollables := list()
    )

    // ---------- lifecycle ----------

    openWith := method(url,
        self io = Convex loadTransport
        self deployment = ConvexUrl parse(url)
        self remoteVersion = self zeroVersion
        self
    )

    setAuth := method(token,
        if(self closed, Exception raise("client is closed"))
        self authToken = if(token isNil, "", token asString)
        self
    )

    close := method(
        if(self closed, return self)
        self closed = true
        self reconnectAtMs = nil
        if(self socket, self socket close; self socket = nil)
        if(self httpStream, self httpStream close; self httpStream = nil)
        self subscriptions = Map clone
        self
    )

    zeroVersion := method(
        Convex object(list(
            "querySet", "0",
            "identity", "0",
            "ts", Convex string(Convex initialTimestamp)
        ))
    )

    warn := method(text,
        if(self diagnostics, Convex writeDiagnostic(File standardError, "convex-io: " .. text .. "\n"))
        self
    )

    // ---------- the event loop ----------
    //
    // One loop owns every socket this client touches. HTTP exchanges, Live
    // frames, reconnect timers and the adapter's controller channel all make
    // progress from the same wait point, so nothing else can ever touch the
    // WebSocket concurrently.

    pollables := method(
        found := list()
        if(self socket and self socket isClosed not, found append(self socket))
        if(self httpStream and self httpStream isClosed not, found append(self httpStream))
        self extraPollables foreach(item, if(item handle >= 0, found append(item)))
        found
    )

    pumpOnce := method(timeoutMs,
        self serviceReconnect
        watched := self pollables
        readMask := 0
        writeMask := 0
        immediate := false
        watched foreach(item,
            // Two pollables can legitimately share one descriptor - the
            // adapter reads and writes the same TCP connection - so the masks
            // are combined bitwise rather than summed.
            bit := 2 ** (item handle)
            if(item wantsRead, readMask = readMask bitwiseOr(bit))
            if(item wantsWrite, writeMask = writeMask bitwiseOr(bit))
            if(item hasBufferedInput, immediate = true)
        )
        budget := timeoutMs
        if(immediate, budget = 0)
        // A pending reconnect must not be starved by a long idle wait.
        if(self reconnectAtMs,
            remaining := self reconnectAtMs - self io monotonicMs
            if(remaining < budget, budget = if(remaining < 0, 0, remaining))
        )
        self io wait(readMask, writeMask, budget)
        readable := self io readyRead
        writable := self io readyWrite
        // Servicing one pollable can retire another, so re-check the
        // descriptor before deciding whether a stale bit applies to it.
        watched foreach(item,
            if(item handle >= 0,
                bit := 2 ** (item handle)
                if((writable / bit) floor % 2 == 1, self serviceWritable(item))
            )
        )
        // Written as two sequential `if` checks rather than one `or`-joined
        // condition on purpose: this is the same shape - a method-derived
        // boolean compared inline and combined with a second predicate that
        // is itself a stored-block/method call, evaluated inside nested
        // `foreach`/`if` indirection, repeated across a polling loop - that
        // ConvexAdapterOutput isBackpressured() hit on the pinned Io VM
        // (IoLanguage/io native @ 3d4bc9c): confirmed by bisection that a
        // fresh client/peer pair alone does not reproduce a failure here, but
        // running this exact `or`-joined line after the GC pressure built up
        // by the ten preceding HTTP loopback scenarios does, every time -
        // `client/tests/http_peer_test.io`'s http/deadline case, which is the
        // first scenario to poll this loop repeatedly against a frozen peer,
        // reliably broke `File standardError write()` for the rest of the
        // process afterward until this was split. Splitting the `or` into
        // two plain `if` checks avoids the shape while keeping the same
        // result: service a pollable that is either readable now or already
        // holding buffered bytes poll cannot see.
        watched foreach(item,
            if(item handle >= 0,
                bit := 2 ** (item handle)
                shouldService := false
                if((readable / bit) floor % 2 == 1, shouldService = true)
                if(shouldService not and item hasBufferedInput, shouldService = true)
                if(shouldService, self serviceReadable(item))
            )
        )
        self checkPartialFrame
        self
    )

    // Any failure while servicing the Live socket retires that connection and
    // becomes a structured subscription error, instead of escaping into an
    // unrelated caller's HTTP result.
    serviceReadable := method(item,
        if(self socket isNil not and item isIdenticalTo(self socket)) then(
            problem := try(
                wasOpen := item isOpen
                item serviceRead
                if(wasOpen not and item isOpen, self onConnected)
            )
            if(problem, self retireFrom(problem))
        ) else(
            item serviceRead
        )
        self
    )

    serviceWritable := method(item,
        if(self socket isNil not and item isIdenticalTo(self socket)) then(
            problem := try(
                wasOpen := item isOpen
                item serviceWrite
                if(wasOpen not and item isOpen, self onConnected)
            )
            if(problem, self retireFrom(problem))
        ) else(
            item serviceWrite
        )
        self
    )

    checkPartialFrame := method(
        if(self socket isNil, return self)
        if(self socket partialFrameExpired(self partialFrameTimeoutMs),
            self retire("TransportError", "partial WebSocket frame timed out")
        )
        self
    )

    // Pump until CONDITION answers true or the absolute deadline passes.
    pumpUntil := method(condition, deadlineMs,
        while(condition call not,
            remaining := deadlineMs - self io monotonicMs
            if(remaining <= 0, return false)
            self pumpOnce(if(remaining > 250, 250, remaining))
        )
        true
    )

    deadlineFor := method(budgetMs, self io monotonicMs + budgetMs)

    // ---------- HTTP ----------

    query := method(path, args, self httpCall("query", path, args))
    mutation := method(path, args, self httpCall("mutation", path, args))
    action := method(path, args, self httpCall("action", path, args))

    httpCall := method(operation, path, args,
        if(self closed, Exception raise("client is closed"))
        if(path isNil or path asString containsSeq(":") not,
            Convex protocolError("Convex function path is required")
        )
        answer := self exchange(operation, self httpBody(path, args))
        self classifyResponse(answer status, answer body)
    )

    httpBody := method(path, args,
        encoded := if(args isNil, "{}", args asString)
        if(ConvexJson isObject(encoded) not,
            Convex protocolError("Convex arguments must be a JSON object")
        )
        ConvexJson validate(encoded)
        Convex object(list(
            "path", Convex string(path),
            "args", encoded,
            "format", Convex string("json")
        ))
    )

    // Open a fresh connection per call. Convex's HTTP API is request/response,
    // and the educational value of connection pooling is small next to the
    // risk of reusing a half-closed socket.
    exchange := method(operation, body,
        // One HTTP exchange at a time. The loop that carries a request also
        // services Live, so a subscription callback can re-enter this method
        // from inside the wait below. Allowing that would hand the client's
        // single httpStream slot to the inner call, silently drop the outer
        // request's socket out of the poll set and strand it until its
        // deadline. Refusing says so immediately instead.
        if(self httpStream,
            Convex transportError("a Convex HTTP request is already in flight")
        )
        deadline := self deadlineFor(Convex httpTimeoutMs)
        stream := ConvexStream clone openTo(
            self deployment host, self deployment port, self deployment secure
        )
        self httpStream = stream
        outcome := nil
        problem := try(
            request := Sequence clone
            request appendSeq("POST " .. self deployment basePath .. "/api/" .. operation .. " HTTP/1.1\r\n")
            request appendSeq("Host: " .. self deployment authority .. "\r\n")
            request appendSeq("User-Agent: convex-io/" .. Convex clientVersion .. "\r\n")
            request appendSeq("Convex-Client: " .. Convex clientVersion .. "\r\n")
            request appendSeq("Content-Type: application/json\r\n")
            request appendSeq("Accept: application/json\r\n")
            if(self authToken size > 0,
                request appendSeq("Authorization: Bearer " .. self authToken .. "\r\n")
            )
            // Content-Length counts bytes. Io Sequences are byte sequences, so
            // a multi-byte UTF-8 argument is measured correctly here.
            request appendSeq("Content-Length: " .. (body size) asString .. "\r\n")
            request appendSeq("Connection: close\r\n")
            request appendSeq("\r\n")
            request appendSeq(body)
            stream enqueue(request)

            sent := self pumpUntil(
                block(stream isOpen and stream outgoing size == 0),
                deadline
            )
            if(sent not, Convex transportError("timed out sending the Convex request"))

            complete := self pumpUntil(block(self httpResponseComplete(stream)), deadline)
            if(complete not, Convex transportError("timed out reading the Convex response"))
            outcome = self httpResponseOf(stream)
        )
        stream close
        self httpStream = nil
        if(problem, problem pass)
        outcome
    )

    // A response is complete when its declared length has arrived, when the
    // chunked terminator has been seen, or when a Connection: close peer has
    // finished the stream. Transfer-Encoding is consulted first because RFC
    // 7230 makes it override any Content-Length a proxy also left behind.
    httpResponseComplete := method(stream,
        if(stream incoming size > Convex maximumResponseBytes,
            Convex transportError("Convex response exceeds the byte budget")
        )
        marker := stream incoming findSeq("\r\n\r\n")
        if(marker isNil,
            if(stream incoming size > Convex maximumHeaderBytes,
                Convex protocolError("Convex response headers exceed the byte budget")
            )
            if(stream atEnd,
                Convex transportError("peer closed before sending response headers")
            )
            return false
        )
        headers := stream incoming exSlice(0, marker) asString
        bodyStart := marker + 4
        if(self isChunked(headers),
            return self chunkedBodyEnd(stream incoming, bodyStart) isNil not
        )
        declared := self contentLengthOf(headers)
        if(declared,
            // Refuse an oversized body from its own declaration rather than
            // waiting to buffer it first.
            if(declared > Convex maximumResponseBytes,
                Convex transportError("Convex response exceeds the byte budget")
            )
            return stream incoming size - bodyStart >= declared
        )
        stream atEnd
    )

    headerValue := method(headers, name,
        found := nil
        headers split("\r\n") foreach(line,
            if(found isNil and line asLowercase beginsWithSeq(name .. ":"),
                found = line exSlice(name size + 1) asMutable strip asSymbol
            )
        )
        found
    )

    contentLengthOf := method(headers,
        raw := self headerValue(headers, "content-length")
        if(raw isNil, return nil)
        if(raw size == 0, Convex protocolError("Convex response had an empty Content-Length"))
        index := 0
        while(index < raw size,
            code := raw at(index)
            if(code < 48 or code > 57,
                Convex protocolError("Convex response had a malformed Content-Length")
            )
            index = index + 1
        )
        raw asNumber
    )

    isChunked := method(headers,
        raw := self headerValue(headers, "transfer-encoding")
        raw isNil not and raw asLowercase containsSeq("chunked")
    )

    // The chunk header runs from CURSOR to the next CRLF. findSeq is given an
    // absolute start index so a long body is never copied just to locate the
    // next boundary.
    chunkSizeAt := method(buffer, cursor,
        marker := buffer findSeq("\r\n", cursor)
        if(marker isNil, return nil)
        header := buffer exSlice(cursor, marker) asString
        semicolon := header findSeq(";")
        if(semicolon, header = header exSlice(0, semicolon))
        digits := header asMutable strip
        if(digits size == 0, Convex protocolError("malformed chunked response"))
        // Parse the hex length explicitly rather than trusting a locale or
        // libc dependent string-to-number conversion for the 0x form.
        value := 0
        for(index, 0, digits size - 1,
            value = value * 16 + ConvexJson hexValue(digits at(index))
        )
        if(value > Convex maximumResponseBytes,
            Convex transportError("Convex response exceeds the byte budget")
        )
        answer := Object clone
        answer size := value
        answer next := marker + 2
        answer
    )

    // Walk the chunk headers without copying the payload, so completeness can
    // be tested cheaply on every pass through the loop.
    chunkedBodyEnd := method(buffer, start,
        cursor := start
        loop(
            chunk := self chunkSizeAt(buffer, cursor)
            if(chunk isNil, return nil)
            cursor = chunk next
            if(chunk size == 0,
                trailer := buffer findSeq("\r\n", cursor)
                if(trailer isNil, return nil)
                return trailer + 2
            )
            if(cursor + chunk size + 2 > buffer size, return nil)
            cursor = cursor + chunk size + 2
        )
    )

    // The three digit status code, validated rather than merely sliced, so a
    // malformed status line cannot silently become a plausible number.
    statusCodeOf := method(statusLine,
        if(statusLine isNil or statusLine beginsWithSeq("HTTP/1.") not,
            Convex protocolError("Convex response was not HTTP/1.x")
        )
        space := statusLine findSeq(" ")
        if(space isNil, Convex protocolError("Convex response had no status code"))
        digits := statusLine exSlice(space + 1, space + 4)
        if(digits size != 3, Convex protocolError("Convex response had no status code"))
        for(index, 0, 2,
            code := digits at(index)
            if(code < 48 or code > 57,
                Convex protocolError("Convex response had no status code")
            )
        )
        digits asNumber
    )

    // Split one complete response into its status code and its body bytes.
    httpResponseOf := method(stream,
        marker := stream incoming findSeq("\r\n\r\n")
        if(marker isNil, Convex protocolError("Convex response had no header terminator"))
        headers := stream incoming exSlice(0, marker) asString
        bodyStart := marker + 4
        answer := Object clone
        answer status := self statusCodeOf(headers split("\r\n") at(0))
        if(self isChunked(headers) not,
            declared := self contentLengthOf(headers)
            answer body := if(declared,
                stream incoming exSlice(bodyStart, bodyStart + declared),
                stream incoming exSlice(bodyStart)
            )
            return answer
        )
        assembled := Sequence clone
        cursor := bodyStart
        scanning := true
        while(scanning,
            chunk := self chunkSizeAt(stream incoming, cursor)
            if(chunk isNil, Convex protocolError("truncated chunked response"))
            cursor = chunk next
            if(chunk size == 0) then(
                scanning = false
            ) else(
                if(assembled size + chunk size > Convex maximumResponseBytes,
                    Convex transportError("Convex response exceeds the byte budget")
                )
                assembled appendSeq(stream incoming exSlice(cursor, cursor + chunk size))
                cursor = cursor + chunk size + 2
            )
        )
        answer body := assembled
        answer
    )

    // Convex reports application failures with its own envelope and an HTTP
    // 200, so the envelope is authoritative wherever one is present. A body
    // that is not an envelope at all on a non-2xx status came from the network
    // path rather than from Convex breaking its protocol, and stays a
    // transport failure so a proxy outage is never read as protocol drift.
    classifyResponse := method(status, raw,
        outcome := nil
        problem := try(outcome = self classify(raw))
        if(problem isNil, return outcome)
        if(Convex errorName(problem) == "FunctionError", problem pass)
        if(status < 200 or status > 299,
            Convex transportError(
                "Convex responded with HTTP status " .. status asString .. \
                    " and no Convex envelope"
            )
        )
        problem pass
    )

    // Classify the Convex envelope on raw JSON. Decoding the whole response
    // into Io values first would let a log line or a nested value influence
    // the status check.
    classify := method(raw,
        text := raw asString
        ConvexJson validate(text)
        statusRaw := ConvexJson field(text, "status")
        if(statusRaw isNil, Convex protocolError("Convex response omitted status"))
        status := ConvexJson decodeRequiredString(statusRaw, "Convex response status")
        logs := ConvexJson field(text, "logLines")
        if(logs isNil, logs = "[]")
        if(status == "success",
            answer := Object clone
            answer value := ConvexJson requiredField(text, "value")
            answer logs := logs
            return answer
        )
        if(status == "error",
            messageRaw := ConvexJson field(text, "errorMessage")
            message := if(messageRaw isNil,
                "Convex function failed",
                ConvexJson decodeRequiredString(messageRaw, "Convex errorMessage")
            )
            data := ConvexJson field(text, "errorData")
            Convex raiseError("FunctionError", message, if(data, data, "null"), logs)
        )
        Convex protocolError("Convex response had an unknown status")
    )

    // ---------- Live ----------

    syncPath := method(self deployment basePath .. "/api/sync")

    subscribe := method(path, args, callback,
        if(self closed, Exception raise("client is closed"))
        encoded := if(args isNil, "{}", args asString)
        if(ConvexJson isObject(encoded) not,
            Convex protocolError("Convex arguments must be a JSON object")
        )
        ConvexJson validate(encoded)
        entry := ConvexSubscription clone
        entry queryId = self nextQueryId
        entry path = path asSymbol
        entry args = encoded asSymbol
        entry callback = callback
        self nextQueryId = self nextQueryId + 1
        self subscriptions atPut(entry queryId asString, entry)
        self ensureLive
        if(self socket and self socket isOpen, self modify(list(self addModification(entry))))
        entry queryId
    )

    unsubscribe := method(queryId,
        key := queryId asString
        if(self subscriptions hasKey(key) not, return self)
        // Retire the relay before Remove goes out. The adapter adds its own
        // generation barrier before it acknowledges the controller.
        self subscriptions removeAt(key)
        if(self socket and self socket isOpen,
            problem := try(
                self modify(list(Convex object(list(
                    "type", Convex string("Remove"),
                    "queryId", queryId asString
                ))))
            )
            if(problem, self warn("Remove could not be sent: " .. Convex errorMessage(problem)))
        )
        self
    )

    addModification := method(entry,
        Convex object(list(
            "type", Convex string("Add"),
            "queryId", entry queryId asString,
            "udfPath", Convex string(entry path),
            "args", Convex array(list(entry args))
        ))
    )

    modify := method(modifications,
        current := self querySetVersion
        self socket sendText(Convex object(list(
            "type", Convex string("ModifyQuerySet"),
            "baseVersion", current asString,
            "newVersion", (current + 1) asString,
            "modifications", Convex array(modifications)
        )))
        self querySetVersion = current + 1
        self
    )

    ensureLive := method(
        if(self closed, return self)
        if(self subscriptions size == 0, return self)
        if(self socket and self socket isClosed not, return self)
        self reconnectAtMs = nil
        // Neither `self` nor a captured local survives in this onMessage
        // block by the time it is actually invoked - it is created here but
        // not called until much later, from deep inside ConvexSocket's own
        // read path (deliver, itself reached through serviceRead by way of
        // serviceReadable's try(), several method calls up inside pumpOnce).
        // Three things were tried against a real run before this shape:
        // a bare `self` raised "ConvexTest does not respond to
        // 'handleLiveMessage'"; a captured local (`owner := self` before the
        // block) only moved the same failure to "does not respond to
        // 'owner'"; and even reading a slot off `self` inside the block
        // (relying on deliver's own `self` - confirmed correct there, and
        // passed to `.call()` as the receiver) still raised "does not
        // respond to 'owner'", because invoking a block through `.call()`
        // from inside a try() does not reliably hand it the caller's `self`
        // either. On the pinned Io VM (IoLanguage/io native @ 3d4bc9c) this
        // reads as the VM's handling of an escaping closure being unsound
        // in general, not as a mistake in how any one attempt referred to
        // its data. Only what a block receives as its own declared
        // parameters survives that trip reliably (confirmed by isolated
        // repro), so this passes the socket itself as a second argument -
        // deliver already does the same for onMessage - and the block reads
        // the owning client back through that argument's own `owner` slot,
        // set on the socket (a long-lived object, not a closure) right after
        // it is created.
        problem := try(
            opened := ConvexSocket clone connectTo(self deployment, self syncPath)
            opened owner = self
            opened onMessage = block(text, sourceSocket, sourceSocket owner handleLiveMessage(text))
            self socket = opened
        )
        if(problem,
            self socket = nil
            self warn("Live connection could not be opened: " .. Convex errorMessage(problem))
            self scheduleReconnect
        )
        self
    )

    serviceReconnect := method(
        if(self reconnectAtMs isNil, return self)
        if(self io monotonicMs < self reconnectAtMs, return self)
        self reconnectAtMs = nil
        self ensureLive
        self
    )

    // Only an active subscription is worth reconnecting for, so an idle client
    // simply stays disconnected until something subscribes again.
    scheduleReconnect := method(
        if(self closed or self subscriptions size == 0, return self)
        self reconnectAtMs = self io monotonicMs + self reconnectDelayMs
        self reconnectDelayMs = (self reconnectDelayMs * 2) min(Convex maximumReconnectMs)
        self
    )

    // A Live failure reaches a consumer as exactly one of the two names the
    // socket can produce. An ordinary Io Exception raised by a bug in this file
    // carries the neutral name "Error", and a caught FunctionError could only
    // have come from a consumer's own callback, so neither may be published as
    // itself: both normalize to TransportError while keeping the original name
    // inside the message so nothing is lost.
    retireFrom := method(problem,
        name := Convex errorName(problem)
        detail := Convex errorMessage(problem)
        if(name != "ProtocolError" and name != "TransportError",
            detail = name .. ": " .. detail
            name = "TransportError"
        )
        self retire(name, detail)
    )

    // Hand one event to a consumer without letting the consumer decide the fate
    // of the socket. A callback that raises - an adapter whose controller
    // channel has died, for instance - is a failure of that consumer, not of
    // the Live connection, and turning it into a retire would both misreport it
    // and recurse straight back into the same broken callback.
    //
    // `entry` is passed as a fourth argument on top of the documented
    // (kind, payload, logs) shape, purely so a callback that needs to look
    // something up can do it through that explicit argument. On the pinned
    // Io VM (IoLanguage/io native @ 3d4bc9c), a callback block invoked from
    // inside this try() does not reliably see the `self` or the outer locals
    // that were in scope when the block was written - bisected in full on
    // ConvexClient ensureLive's onMessage callback below, which raised
    // "ConvexTest does not respond to 'handleLiveMessage'" (a bare `self`)
    // and then "does not respond to 'owner'" (a captured local) before an
    // explicit argument finally worked. Io tolerates extra call arguments a
    // block does not declare, so this stays compatible with any callback
    // that only wants the original three.
    publish := method(entry, kind, payload, logs,
        if(entry callback isNil, return self)
        failure := try(entry callback call(kind, payload, logs, entry))
        if(failure,
            self warn("subscription callback raised: " .. Convex errorMessage(failure))
        )
        self
    )

    // Retire the current connection. Parser failures and unexpected peer
    // closes are subscription failures, not silent diagnostics, so every
    // active subscription is told - and each stays active so it can receive a
    // later valid value once the socket comes back.
    retire := method(name, detail,
        if(self socket, self socket close; self socket = nil)
        self connectionCount = self connectionCount + 1
        self lastCloseReason = name
        self querySetVersion = 0
        self remoteVersion = self zeroVersion
        // A rehydrated value after a reconnect is only suppressed when it
        // repeats what this subscription already published on this connection,
        // so clearing the signature would hide the deduplication the reconnect
        // test relies on. It is deliberately left in place.
        if(name != "DebugDisconnect" and name != "ClientClosed",
            self warn("Live connection retired: " .. name .. ": " .. detail)
            // Absent structured data is omitted rather than spelled as null,
            // because this payload is what the adapter forwards to the shared
            // controller and an explicit null is not the same claim as silence.
            payload := Convex object(list(
                "name", Convex string(name),
                "message", Convex string(detail)
            ))
            // Snapshot first: a callback may unsubscribe itself or subscribe
            // something new, and mutating the map underneath its own iteration
            // would skip or repeat another consumer.
            notify := list()
            self subscriptions foreach(key, entry, notify append(entry))
            notify foreach(entry, self publish(entry, "error", payload, "[]"))
        )
        if(self closed not and self subscriptions size > 0, self scheduleReconnect)
        self
    )

    // The adapter-only hook the shared controller uses to prove five real
    // reconnects. It is never part of the educational client API.
    debugDisconnect := method(
        if(self socket isNil or self socket isClosed,
            Convex transportError("Live WebSocket is not connected")
        )
        self retire("DebugDisconnect", "the adapter asked for a reconnect")
        // Acknowledge only once the old connection is gone and, when anything
        // still depends on it, the replacement is genuinely scheduled. With no
        // active subscription there is nothing to restore, so no reconnect is
        // owed and none is asserted.
        if(self socket, Convex transportError("debugDisconnect did not retire the old connection"))
        if(self subscriptions size > 0 and self reconnectAtMs isNil,
            Convex transportError("debugDisconnect did not schedule a reconnect")
        )
        self
    )

    // ---------- the sync state machine ----------

    onConnected := method(
        self reconnectDelayMs = Convex initialReconnectMs
        self querySetVersion = 0
        self remoteVersion = self zeroVersion
        fields := list(
            "type", Convex string("Connect"),
            "sessionId", Convex string(self sessionId),
            "connectionCount", self connectionCount asString,
            "lastCloseReason", Convex string(self lastCloseReason),
            "clientTs", "0"
        )
        if(self maxObservedTimestamp,
            fields append("maxObservedTimestamp")
            fields append(Convex string(self maxObservedTimestamp))
        )
        self socket sendText(Convex object(fields))
        // Every new connection resends the whole active query set, which is
        // what makes a reconnect deliver a value again rather than stall.
        additions := list()
        keys := self subscriptions keys sortInPlaceBy(
            block(left, right, left asNumber < right asNumber)
        )
        keys foreach(key, additions append(self addModification(self subscriptions at(key))))
        if(additions size > 0, self modify(additions))
        self
    )

    // The pinned profile wants exactly 32 hex characters. Sixteen CSPRNG bytes
    // give a value that is unique per connection without pulling in a UUID
    // library the VM does not have.
    sessionId := method(
        out := Sequence clone
        bytes := self io randomBytes(16)
        for(index, 0, 15,
            value := bytes at(index)
            out appendSeq(ConvexJson twoHexDigits(value))
        )
        out asSymbol
    )

    normalizeVersion := method(raw,
        querySet := ConvexJson decodeUint32(
            ConvexJson requiredField(raw, "querySet"), "state version querySet"
        )
        identity := ConvexJson decodeUint32(
            ConvexJson requiredField(raw, "identity"), "state version identity"
        )
        stamp := ConvexJson decodeRequiredString(
            ConvexJson requiredField(raw, "ts"), "state version ts"
        )
        self timestampKey(stamp)
        Convex object(list(
            "querySet", querySet asString,
            "identity", identity asString,
            "ts", Convex string(stamp)
        ))
    )

    // Convex timestamps are eight little-endian bytes in base64. Comparing the
    // reversed hex form orders them exactly like the integers would, without
    // needing the 64-bit arithmetic Io does not have.
    timestampKey := method(encoded,
        bytes := encoded asString fromBase64
        if(bytes size != 8, Convex protocolError("invalid canonical timestamp"))
        out := Sequence clone
        for(index, 7, 0, -1, out appendSeq(ConvexJson twoHexDigits(bytes at(index))))
        out asSymbol
    )

    handleLiveMessage := method(text,
        ConvexJson validate(text)
        kind := ConvexJson decodeRequiredString(
            ConvexJson requiredField(text, "type"), "Live message type"
        )
        if(kind == "Ping" or kind == "MutationResponse" or kind == "ActionResponse",
            return self
        )
        if(kind == "Transition", return self applyTransition(text))
        if(kind == "TransitionChunk", Convex protocolError("TransitionChunk is not implemented"))
        if(kind == "FatalError" or kind == "AuthError",
            detail := ConvexJson field(text, "error")
            Convex protocolError(kind .. " " .. if(detail, detail asString, ""))
        )
        Convex protocolError("unsupported Live message " .. kind)
    )

    applyTransition := method(text,
        startVersion := self normalizeVersion(ConvexJson requiredField(text, "startVersion"))
        if(startVersion != self remoteVersion,
            Convex protocolError("transition start version mismatch")
        )
        endVersion := self normalizeVersion(ConvexJson requiredField(text, "endVersion"))

        // Validate the whole transition before publishing any of it. Several
        // changes to one query coalesce to the newest value, so a consumer
        // never observes an intermediate transaction state.
        pending := Map clone
        order := list()
        ConvexJson elements(ConvexJson requiredField(text, "modifications")) foreach(modification,
            queryId := ConvexJson decodeUint32(
                ConvexJson requiredField(modification, "queryId"), "Live queryId"
            )
            kind := ConvexJson decodeRequiredString(
                ConvexJson requiredField(modification, "type"), "Live modification type"
            )
            entryKey := queryId asString
            item := nil
            if(kind == "QueryUpdated") then(
                logs := ConvexJson field(modification, "logLines")
                item = list(
                    "value",
                    ConvexJson requiredField(modification, "value"),
                    if(logs, logs, "[]")
                )
            ) elseif(kind == "QueryFailed") then(
                message := ConvexJson decodeRequiredString(
                    ConvexJson requiredField(modification, "errorMessage"),
                    "QueryFailed errorMessage"
                )
                data := ConvexJson field(modification, "errorData")
                logs := ConvexJson field(modification, "logLines")
                fields := list(
                    "name", Convex string("FunctionError"),
                    "message", Convex string(message)
                )
                if(data, fields append("data"); fields append(data))
                item = list("error", Convex object(fields), if(logs, logs, "[]"))
            ) elseif(kind == "QueryRemoved") then(
                item = nil
            ) else(
                Convex protocolError("unsupported Live modification " .. kind)
            )
            if(item and self subscriptions hasKey(entryKey),
                if(pending hasKey(entryKey) not, order append(entryKey))
                pending atPut(entryKey, item)
            )
        )

        stamp := ConvexJson decodeRequiredString(
            ConvexJson requiredField(endVersion, "ts"), "endVersion ts"
        )
        if(self maxObservedTimestamp isNil,
            self maxObservedTimestamp = stamp
        ,
            if(self timestampKey(stamp) > self timestampKey(self maxObservedTimestamp),
                self maxObservedTimestamp = stamp
            )
        )
        self remoteVersion = endVersion

        // ORDER is already a snapshot of this transition, and the map is
        // re-consulted for each entry, so a consumer that unsubscribes from
        // inside its own callback stops receiving the rest of the batch rather
        // than being delivered to out of a map it has already left.
        order foreach(entryKey,
            if(self subscriptions hasKey(entryKey),
                entry := self subscriptions at(entryKey)
                item := pending at(entryKey)
                signature := item at(0) .. "\x1f" .. item at(1) .. "\x1f" .. item at(2)
                // Suppressing an unchanged rehydration is what makes a
                // reconnect deliver exactly the next genuinely new value.
                if(signature != entry lastSignature,
                    entry lastSignature = signature
                    self publish(entry, item at(0), item at(1), item at(2))
                )
            )
        )
        self
    )
)

// ------------------------------------------------------------------
// Public entry point
// ------------------------------------------------------------------

Convex clientForUrl := method(url,
    if(url isNil or url asString size == 0, Exception raise("CONVEX_URL is required"))
    ConvexClient clone openWith(url)
)
