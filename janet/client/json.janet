# A strict, bounded JSON reader and writer.
#
# This client parses JSON itself for two reasons that matter to Convex rather
# than to Janet. First, Janet tables cannot hold nil, so a permissive decoder
# has to pick between "the key was absent" and "the key was JSON null" — and the
# adapter protocol treats those as different messages. A dedicated `null`
# sentinel keeps them distinct all the way through the client. Second, every
# limit here (bytes, nesting depth, node count) is a defence against a hostile
# peer, and those limits belong next to the protocol that needs them.
#
# Numbers decode to Janet's ordinary numbers. Convex may send an integral value
# as `0` or as `0.0`; both arrive as the same Janet number, which is exactly the
# behaviour the shared example contract asks for.

(import ./codec :as codec)
(import ./errors :as fail)

(def null
  "The JSON value `null`, distinct from an absent key and from Janet's nil."
  :convex/json-null)

(defn null?
  "Is this value JSON null?"
  [value]
  (= value null))

(def max-depth
  "Nesting limit. Deep input is a cheap way to exhaust a recursive parser."
  64)

(def max-nodes
  "Total value limit. Dense flat input is the other cheap exhaustion attack."
  200000)

(def max-bytes
  "Largest document this client will parse."
  (* 2 1024 1024))

#
# Decoding
#

(defn- whitespace? [byte]
  (or (= byte 0x20) (= byte 0x09) (= byte 0x0A) (= byte 0x0D)))

(defn- decoder [text]
  @{:text text :length (length text) :at 0 :nodes 0})

(defn- peek-byte [state]
  (when (< (get state :at) (get state :length))
    (get (get state :text) (get state :at))))

(defn- advance [state]
  (put state :at (+ 1 (get state :at))))

(defn- skip-whitespace [state]
  (while (let [byte (peek-byte state)] (and byte (whitespace? byte)))
    (advance state)))

(defn- expect [state byte message]
  (unless (= byte (peek-byte state)) (fail/protocol message))
  (advance state))

(defn- count-node [state]
  (put state :nodes (+ 1 (get state :nodes)))
  (when (> (get state :nodes) max-nodes)
    (fail/protocol "JSON document has too many values")))

(defn- hex-digit [byte]
  (cond
    (nil? byte) nil
    (and (>= byte 0x30) (<= byte 0x39)) (- byte 0x30)
    (and (>= byte 0x41) (<= byte 0x46)) (+ 10 (- byte 0x41))
    (and (>= byte 0x61) (<= byte 0x66)) (+ 10 (- byte 0x61))
    nil))

(defn- read-hex4 [state]
  (var value 0)
  (repeat 4
    (def digit (hex-digit (peek-byte state)))
    (unless digit (fail/protocol "JSON \\u escape needs four hexadecimal digits"))
    (set value (+ (* value 16) digit))
    (advance state))
  value)

(defn- read-escape [state out]
  (advance state) # consume the backslash
  (def byte (peek-byte state))
  (cond
    (nil? byte) (fail/protocol "JSON string ended inside an escape")
    (= byte 0x22) (do (buffer/push-byte out 0x22) (advance state)) # \"
    (= byte 0x5C) (do (buffer/push-byte out 0x5C) (advance state)) # backslash
    (= byte 0x2F) (do (buffer/push-byte out 0x2F) (advance state)) # /
    (= byte 0x62) (do (buffer/push-byte out 0x08) (advance state)) # \b
    (= byte 0x66) (do (buffer/push-byte out 0x0C) (advance state)) # \f
    (= byte 0x6E) (do (buffer/push-byte out 0x0A) (advance state)) # \n
    (= byte 0x72) (do (buffer/push-byte out 0x0D) (advance state)) # \r
    (= byte 0x74) (do (buffer/push-byte out 0x09) (advance state)) # \t
    (= byte 0x75)
    (do
      (advance state)
      (def high (read-hex4 state))
      (cond
        # A high surrogate is only legal as the first half of a real pair.
        (and (>= high 0xD800) (<= high 0xDBFF))
        (do
          (unless (and (= 0x5C (peek-byte state))
                       (= 0x75 (get (get state :text) (+ 1 (get state :at)))))
            (fail/protocol "JSON \\u surrogate is missing its pair"))
          (advance state)
          (advance state)
          (def low (read-hex4 state))
          (unless (and (>= low 0xDC00) (<= low 0xDFFF))
            (fail/protocol "JSON \\u surrogate pair is malformed"))
          (codec/encode-utf8 out (+ 0x10000
                                    (* 0x400 (- high 0xD800))
                                    (- low 0xDC00))))

        (and (>= high 0xDC00) (<= high 0xDFFF))
        (fail/protocol "JSON \\u escape is an unpaired low surrogate")

        (codec/encode-utf8 out high)))
    (fail/protocol "JSON string has an unknown escape")))

(defn- read-string [state]
  (expect state 0x22 "expected a JSON string")
  (def out (buffer/new 16))
  (var done false)
  (while (not done)
    (def byte (peek-byte state))
    (cond
      (nil? byte) (fail/protocol "JSON string was not terminated")
      (= byte 0x22) (do (advance state) (set done true))
      (= byte 0x5C) (read-escape state out)
      # RFC 8259 forbids unescaped control characters inside strings.
      (< byte 0x20) (fail/protocol "JSON string contains a raw control character")
      (do (buffer/push-byte out byte) (advance state))))
  (string out))

(defn- digit? [byte]
  (and byte (>= byte 0x30) (<= byte 0x39)))

(defn- read-number [state]
  (def start (get state :at))
  (when (= 0x2D (peek-byte state)) (advance state))
  # JSON forbids a leading zero on a multi-digit integer part.
  (cond
    (= 0x30 (peek-byte state)) (advance state)
    (digit? (peek-byte state)) (while (digit? (peek-byte state)) (advance state))
    (fail/protocol "JSON number has no integer part"))
  (when (= 0x2E (peek-byte state))
    (advance state)
    (unless (digit? (peek-byte state)) (fail/protocol "JSON number has no fraction digits"))
    (while (digit? (peek-byte state)) (advance state)))
  (def exponent (peek-byte state))
  (when (or (= exponent 0x65) (= exponent 0x45))
    (advance state)
    (def sign (peek-byte state))
    (when (or (= sign 0x2B) (= sign 0x2D)) (advance state))
    (unless (digit? (peek-byte state)) (fail/protocol "JSON number has no exponent digits"))
    (while (digit? (peek-byte state)) (advance state)))
  (def text (string/slice (get state :text) start (get state :at)))
  # The grammar above already rejected everything Janet's scanner would accept
  # but JSON would not, such as hexadecimal and underscore separators.
  (def value (scan-number text))
  (unless (and (number? value)
               (not (nan? value))
               (not= value math/inf)
               (not= value math/-inf))
    (fail/protocol "JSON number is not finite"))
  value)

(defn- literal [state text value]
  (def at (get state :at))
  (def stop (+ at (length text)))
  (unless (and (<= stop (get state :length))
               (= text (string/slice (get state :text) at stop)))
    (fail/protocol "JSON document has an unknown literal"))
  (put state :at stop)
  value)

# Forward declaration: the reader is mutually recursive with the container
# readers below, so the binding has to exist before they are compiled.
(var read-value nil)

(defn- read-array [state depth]
  (expect state 0x5B "expected a JSON array")
  (def out @[])
  (skip-whitespace state)
  (if (= 0x5D (peek-byte state))
    (do (advance state) out)
    (do
      (var done false)
      (while (not done)
        (array/push out (read-value state (+ depth 1)))
        (skip-whitespace state)
        (def byte (peek-byte state))
        (cond
          (= byte 0x2C) (do (advance state) (skip-whitespace state))
          (= byte 0x5D) (do (advance state) (set done true))
          (fail/protocol "JSON array is missing a comma or bracket")))
      out)))

(defn- read-object [state depth]
  (expect state 0x7B "expected a JSON object")
  (def out @{})
  (skip-whitespace state)
  (if (= 0x7D (peek-byte state))
    (do (advance state) out)
    (do
      (var done false)
      (while (not done)
        (skip-whitespace state)
        (def key (read-string state))
        # Duplicate keys mean two readers can legitimately disagree about the
        # document, so this client refuses them instead of picking a winner.
        (when (has-key? out key) (fail/protocol "JSON object has a duplicate key"))
        (skip-whitespace state)
        (expect state 0x3A "JSON object member is missing its colon")
        (put out key (read-value state (+ depth 1)))
        (skip-whitespace state)
        (def byte (peek-byte state))
        (cond
          (= byte 0x2C) (do (advance state) (skip-whitespace state))
          (= byte 0x7D) (do (advance state) (set done true))
          (fail/protocol "JSON object is missing a comma or brace")))
      out)))

(set read-value
  (fn read-value [state depth]
    (when (> depth max-depth) (fail/protocol "JSON document is nested too deeply"))
    (count-node state)
    (skip-whitespace state)
    (def byte (peek-byte state))
    (cond
      (nil? byte) (fail/protocol "JSON document ended early")
      (= byte 0x7B) (read-object state depth)
      (= byte 0x5B) (read-array state depth)
      (= byte 0x22) (read-string state)
      (= byte 0x74) (literal state "true" true)
      (= byte 0x66) (literal state "false" false)
      (= byte 0x6E) (literal state "null" null)
      (or (= byte 0x2D) (digit? byte)) (read-number state)
      (fail/protocol "JSON document has an unexpected character"))))

(defn decode
  "Decode one complete JSON document.

  Objects become tables keyed by string, arrays become arrays, `null` becomes
  the `null` sentinel, and anything malformed raises a ProtocolError."
  [text]
  (when (> (length text) max-bytes)
    (fail/protocol "JSON document exceeds the 2 MiB limit"))
  (unless (codec/utf8-valid? text)
    (fail/protocol "JSON document is not valid UTF-8"))
  (def state (decoder text))
  (def value (read-value state 0))
  (skip-whitespace state)
  (unless (= (get state :at) (get state :length))
    (fail/protocol "JSON document has trailing content"))
  value)

(defn decode-object
  "Decode a JSON document that must be an object."
  [text context]
  (def value (try (decode text)
                  ([problem] (fail/protocol (string context ": " (fail/message-of problem))))))
  (unless (dictionary? value) (fail/protocol (string context " is not a JSON object")))
  value)

#
# Encoding
#

(defn- encode-string [out text]
  (unless (codec/utf8-valid? text)
    (fail/protocol "cannot encode a string that is not valid UTF-8"))
  (buffer/push-byte out 0x22)
  (var index 0)
  (while (< index (length text))
    (def byte (get text index))
    (cond
      (= byte 0x22) (buffer/push-string out `\"`)
      (= byte 0x5C) (buffer/push-string out `\\`)
      (= byte 0x08) (buffer/push-string out `\b`)
      (= byte 0x0C) (buffer/push-string out `\f`)
      (= byte 0x0A) (buffer/push-string out `\n`)
      (= byte 0x0D) (buffer/push-string out `\r`)
      (= byte 0x09) (buffer/push-string out `\t`)
      (< byte 0x20) (buffer/push-string out (string/format `\u%04x` byte))
      (buffer/push-byte out byte))
    (set index (+ index 1)))
  (buffer/push-byte out 0x22))

(defn- encode-number [out value]
  (unless (and (number? value)
               (not (nan? value))
               (not= value math/inf)
               (not= value math/-inf))
    (fail/protocol "cannot encode a non-finite number as JSON"))
  # Janet prints the shortest representation that reads back as the same double,
  # which is exactly what JSON wants. An integral value prints without a
  # fractional part, so `1` stays `1` rather than becoming `1.0`.
  (buffer/push-string out (string value)))

(defn- key-text [key]
  (cond
    (string? key) key
    (buffer? key) (string key)
    (keyword? key) (string key)
    (fail/protocol "JSON object keys must be strings or keywords")))

# Forward declaration, for the same reason as `read-value` above.
(var encode-value nil)

(set encode-value
  (fn encode-value [out value depth]
    (when (> depth max-depth) (fail/protocol "cannot encode a value nested too deeply"))
    (cond
      (null? value) (buffer/push-string out "null")
      (= value true) (buffer/push-string out "true")
      (= value false) (buffer/push-string out "false")
      (number? value) (encode-number out value)
      (or (string? value) (buffer? value)) (encode-string out value)

      (indexed? value)
      (do
        (buffer/push-byte out 0x5B)
        (var index 0)
        (while (< index (length value))
          (when (> index 0) (buffer/push-byte out 0x2C))
          (encode-value out (get value index) (+ depth 1))
          (set index (+ index 1)))
        (buffer/push-byte out 0x5D))

      (dictionary? value)
      (do
        (buffer/push-byte out 0x7B)
        (var first true)
        # Sorting is not required by JSON, but a deterministic key order makes
        # adapter transcripts and test fixtures comparable line for line.
        (def names (sort (map key-text (keys value)) compare<))
        # A table holding both :type and "type" would otherwise emit one JSON
        # key twice, which is exactly the ambiguity `decode` refuses to read.
        (unless (= (length names) (length (distinct names)))
          (fail/protocol "value has two keys with the same JSON name"))
        (each key names
          (unless first (buffer/push-byte out 0x2C))
          (set first false)
          (encode-string out key)
          (buffer/push-byte out 0x3A)
          (def item (if (has-key? value key) (get value key) (get value (keyword key))))
          (encode-value out item (+ depth 1)))
        (buffer/push-byte out 0x7D))

      # Reaching here means a Janet value with no JSON meaning, such as a
      # function or a bare keyword. Guessing at it would corrupt the protocol.
      (fail/protocol "value has no JSON representation"))))

(defn encode
  "Encode a Janet value as compact JSON text."
  [value]
  (def out (buffer/new 64))
  (encode-value out value 0)
  (string out))

(defn json-safe?
  "Can this value round-trip through `encode` without raising?"
  [value]
  (def result (try (do (encode value) true) ([_] false)))
  result)
