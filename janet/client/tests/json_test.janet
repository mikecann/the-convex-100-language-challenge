# JSON regressions.
#
# The two behaviours worth guarding here are the ones Convex actually depends
# on: `null` staying distinguishable from an absent key, and an integral value
# arriving as `0.0` still being the number zero.

(import ./check :as check)
(import ../json :as json)

(check/check= (json/decode "0") 0 "a bare number decodes")
(check/check= (json/decode "0.0") 0 "an integral decimal is the same number as its integer")
(check/check= (json/decode "1.0") 1 "1.0 and 1 are the same Convex count")
(check/check= (json/decode "-0.5") -0.5 "a genuine fraction stays fractional")
(check/check= (json/decode "1e3") 1000 "exponents decode")
(check/check= (json/decode "\"text\"") "text" "a bare string decodes")
(check/check= (json/decode "true") true "true decodes")
(check/check= (json/decode "[]") @[] "an empty array decodes")
(check/check= (json/decode "{}") @{} "an empty object decodes")

# `null` has to survive as a value, because `demo:state` returns
# `lastLanguage: null` and the shared conformance test compares it exactly.
(check/check (json/null? (json/decode "null")) "null decodes to the null sentinel")
(def with-null (json/decode `{"a":null}`))
(check/check (has-key? with-null "a") "a null member is present")
(check/check (json/null? (get with-null "a")) "a null member holds the null sentinel")
(check/check= (json/encode with-null) `{"a":null}` "a null member re-encodes as null")
(check/check= (json/encode @{"a" 1}) `{"a":1}` "an absent key simply does not appear")

# Strictness. Each of these is a shape some parser accepts and Convex does not.
(each bad ["" "  " "{" "[1," "[1,]" `{"a":1,}` "01" "1." ".5" "+1" "nul" "tru"
           `{"a":1}{"b":2}` "[1] [2]" `{a:1}` "'text'" "NaN" "Infinity"
           `{"a":1,"a":2}` "\"\x01\"" "1e" "1e+"]
  (check/check-raises "ProtocolError" (fn [] (json/decode bad))
                      (string "refuses malformed JSON: " (describe bad))))

# Escapes, including the surrogate pairs that carry astral characters.
(check/check= (json/decode `"\u0041"`) "A" "a \\u escape decodes")
(check/check= (json/decode `"\ud83d\ude00"`) "😀"
              "a surrogate pair decodes to one astral character")
(check/check-raises "ProtocolError" (fn [] (json/decode `"\ud83d"`))
                    "a lone high surrogate is refused")
(check/check-raises "ProtocolError" (fn [] (json/decode `"\ude00"`))
                    "a lone low surrogate is refused")
(check/check-raises "ProtocolError" (fn [] (json/decode `"\q"`))
                    "an unknown escape is refused")
(check/check= (json/decode `"a\/b\\c\"d\nе"`) "a/b\\c\"d\nе" "the standard escapes decode")

# Bytes that are not UTF-8 must be refused before any structure is trusted.
(check/check-raises "ProtocolError"
                    (fn [] (json/decode (string `"` (string/from-bytes 0xFF) `"`)))
                    "invalid UTF-8 is refused")

# Bounds. Depth and node count are the two cheap ways to exhaust a parser.
(check/check-raises "ProtocolError"
                    (fn [] (json/decode (string (string/repeat "[" 200)
                                                (string/repeat "]" 200))))
                    "excessive nesting is refused")
(check/check-raises "ProtocolError"
                    (fn [] (json/decode (string/repeat "x" (+ 1 json/max-bytes))))
                    "an oversized document is refused before parsing")

# Encoding rejects everything it cannot represent, rather than guessing.
(check/check-raises "ProtocolError" (fn [] (json/encode math/inf)) "infinity is not JSON")
(check/check-raises "ProtocolError" (fn [] (json/encode (- math/inf math/inf))) "NaN is not JSON")
(check/check-raises "ProtocolError" (fn [] (json/encode :other)) "a bare keyword is not JSON")
(check/check-raises "ProtocolError" (fn [] (json/encode print)) "a function is not JSON")
(check/check-raises "ProtocolError"
                    (fn [] (json/encode @{"a" 1 :a 2}))
                    "two keys with the same JSON name are refused")

# Keyword keys exist so adapter events can be written naturally in Janet.
(check/check= (json/encode @{:type "ack" :id "one"}) `{"id":"one","type":"ack"}`
              "keyword keys encode as strings in a stable order")

# A control character has to be escaped on the way out or the document breaks.
(check/check= (json/encode (string/from-bytes 0x22 0x5C 0x0A 0x01))
              `"\"\\\n\u0001"`
              "control characters and delimiters are escaped")

(def deep-round-trip
  {"unicode" "Hello, 世界 👋"
   "nested" {"booleans" [true false] "number" 42.5 "nil" json/null}})
(check/check= (json/decode (json/encode deep-round-trip))
              @{"unicode" "Hello, 世界 👋"
                "nested" @{"booleans" @[true false] "number" 42.5 "nil" json/null}}
              "the shared conformance value survives a round trip")

(check/check-raises "ProtocolError"
                    (fn [] (json/decode-object "[]" "response"))
                    "a document that must be an object refuses an array")

(check/report "janet json")
