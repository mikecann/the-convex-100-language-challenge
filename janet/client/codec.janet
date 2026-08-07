# Byte-level codecs the Convex protocols need.
#
# Janet strings are byte strings, not sequences of characters, so nothing here
# may assume the runtime already validated text. UTF-8 is checked explicitly at
# every boundary where bytes become protocol values.
#
# The arithmetic below deliberately uses multiplication, division, and modulo
# rather than shift operators. Janet's bitwise operators are defined over its
# integer range, and 32-bit masks sit right on the edge of it; plain arithmetic
# on values under 2^24 has no such edge and reads the same to a newcomer.

(import ./errors :as fail)

(def- base64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(def- hex-alphabet "0123456789abcdef")

# Byte values used by the base64 grammar, written numerically so nothing here
# depends on how a particular Janet release spells a character literal.
(def- byte-pad 0x3D)   # =
(def- byte-plus 0x2B)  # +
(def- byte-slash 0x2F) # /
(def- byte-zero 0x30)  # 0
(def- byte-nine 0x39)  # 9
(def- byte-upper-a 0x41) # A
(def- byte-upper-z 0x5A) # Z
(def- byte-lower-a 0x61) # a
(def- byte-lower-z 0x7A) # z

(defn utf8-count
  "Count the code points in `bytes`, or return nil when it is not valid UTF-8.

  This rejects the encodings that let a permissive decoder disagree with a
  strict one: overlong forms, UTF-16 surrogates, and anything above U+10FFFF."
  [bytes]
  (def total (length bytes))
  (var index 0)
  (var points 0)
  (var valid true)
  (while (and valid (< index total))
    (def lead (get bytes index))
    (def remaining (- total index))
    (cond
      (< lead 0x80)
      (do (set index (+ index 1)) (set points (+ points 1)))

      (and (>= lead 0xC2) (<= lead 0xDF) (>= remaining 2)
           (= 0x80 (band 0xC0 (get bytes (+ index 1)))))
      (do (set index (+ index 2)) (set points (+ points 1)))

      (and (>= lead 0xE0) (<= lead 0xEF) (>= remaining 3)
           (= 0x80 (band 0xC0 (get bytes (+ index 1))))
           (= 0x80 (band 0xC0 (get bytes (+ index 2))))
           # E0 A0..BF rejects the overlong three-byte forms.
           (or (not= lead 0xE0) (>= (get bytes (+ index 1)) 0xA0))
           # ED 80..9F rejects the UTF-16 surrogate range.
           (or (not= lead 0xED) (< (get bytes (+ index 1)) 0xA0)))
      (do (set index (+ index 3)) (set points (+ points 1)))

      (and (>= lead 0xF0) (<= lead 0xF4) (>= remaining 4)
           (= 0x80 (band 0xC0 (get bytes (+ index 1))))
           (= 0x80 (band 0xC0 (get bytes (+ index 2))))
           (= 0x80 (band 0xC0 (get bytes (+ index 3))))
           # F0 90..BF rejects overlong four-byte forms.
           (or (not= lead 0xF0) (>= (get bytes (+ index 1)) 0x90))
           # F4 80..8F stops at U+10FFFF.
           (or (not= lead 0xF4) (< (get bytes (+ index 1)) 0x90)))
      (do (set index (+ index 4)) (set points (+ points 1)))

      (set valid false)))
  (when valid points))

(defn utf8-valid?
  "Is `bytes` well-formed UTF-8?"
  [bytes]
  (not (nil? (utf8-count bytes))))

(defn encode-utf8
  "Append one code point to `out` as UTF-8, rejecting surrogates and overflow."
  [out point]
  (cond
    (or (< point 0) (> point 0x10FFFF) (and (>= point 0xD800) (<= point 0xDFFF)))
    (fail/protocol "code point is not encodable as UTF-8")

    (< point 0x80)
    (buffer/push-byte out point)

    (< point 0x800)
    (do (buffer/push-byte out (+ 0xC0 (math/floor (/ point 64))))
        (buffer/push-byte out (+ 0x80 (mod point 64))))

    (< point 0x10000)
    (do (buffer/push-byte out (+ 0xE0 (math/floor (/ point 4096))))
        (buffer/push-byte out (+ 0x80 (mod (math/floor (/ point 64)) 64)))
        (buffer/push-byte out (+ 0x80 (mod point 64))))

    (do (buffer/push-byte out (+ 0xF0 (math/floor (/ point 262144))))
        (buffer/push-byte out (+ 0x80 (mod (math/floor (/ point 4096)) 64)))
        (buffer/push-byte out (+ 0x80 (mod (math/floor (/ point 64)) 64)))
        (buffer/push-byte out (+ 0x80 (mod point 64)))))
  out)

(defn hex-encode
  "Lowercase hexadecimal text for `bytes`."
  [bytes]
  (def out (buffer/new (* 2 (length bytes))))
  (var index 0)
  (while (< index (length bytes))
    (def byte (get bytes index))
    (buffer/push-byte out (get hex-alphabet (math/floor (/ byte 16))))
    (buffer/push-byte out (get hex-alphabet (mod byte 16)))
    (set index (+ index 1)))
  (string out))

(defn base64-encode
  "Standard base64 with padding."
  [bytes]
  (def total (length bytes))
  (def out (buffer/new (* 4 (+ 1 (math/floor (/ total 3))))))
  (var index 0)
  (while (< index total)
    (def remaining (- total index))
    (def b0 (get bytes index))
    (def b1 (if (> remaining 1) (get bytes (+ index 1)) 0))
    (def b2 (if (> remaining 2) (get bytes (+ index 2)) 0))
    (def packed (+ (* b0 65536) (* b1 256) b2))
    (buffer/push-byte out (get base64-alphabet (math/floor (/ packed 262144))))
    (buffer/push-byte out (get base64-alphabet (mod (math/floor (/ packed 4096)) 64)))
    # Padding replaces the characters that would describe absent input bytes.
    (buffer/push-byte out
                      (if (> remaining 1)
                        (get base64-alphabet (mod (math/floor (/ packed 64)) 64))
                        byte-pad))
    (buffer/push-byte out
                      (if (> remaining 2)
                        (get base64-alphabet (mod packed 64))
                        byte-pad))
    (set index (+ index 3)))
  (string out))

(defn- base64-value [byte]
  (cond
    (and (>= byte byte-upper-a) (<= byte byte-upper-z)) (- byte byte-upper-a)
    (and (>= byte byte-lower-a) (<= byte byte-lower-z)) (+ 26 (- byte byte-lower-a))
    (and (>= byte byte-zero) (<= byte byte-nine)) (+ 52 (- byte byte-zero))
    (= byte byte-plus) 62
    (= byte byte-slash) 63
    nil))

(defn base64-decode
  "Strict standard base64. Returns nil rather than guessing at malformed input.

  Strictness matters here because Convex sync timestamps are opaque base64 and
  a lenient decoder would silently accept two spellings of the same value."
  [text]
  (def total (length text))
  (if (or (= total 0) (not= 0 (mod total 4)))
    nil
    (do
      (def out (buffer/new (* 3 (/ total 4))))
      (var index 0)
      (var ok true)
      (while (and ok (< index total))
        (def raw (map (fn [offset] (get text (+ index offset))) [0 1 2 3]))
        (def padding (cond
                       (and (= (get raw 2) byte-pad) (= (get raw 3) byte-pad)) 2
                       (= (get raw 3) byte-pad) 1
                       0))
        # Padding is only legal in the final quantum.
        (when (and (> padding 0) (not= index (- total 4))) (set ok false))
        (when ok
          (def values (map (fn [offset]
                             (if (< offset (- 4 padding))
                               (base64-value (get raw offset))
                               0))
                           [0 1 2 3]))
          (if (some nil? values)
            (set ok false)
            (do
              (def packed (+ (* (get values 0) 262144)
                             (* (get values 1) 4096)
                             (* (get values 2) 64)
                             (get values 3)))
              # Bits that padding says are absent must have been transmitted as
              # zero, otherwise two encodings would decode to the same bytes.
              (when (and (>= padding 1) (not= 0 (mod packed 256))) (set ok false))
              (when (and (>= padding 2) (not= 0 (mod packed 65536))) (set ok false))
              (when ok
                (buffer/push-byte out (math/floor (/ packed 65536)))
                (when (< padding 2)
                  (buffer/push-byte out (mod (math/floor (/ packed 256)) 256)))
                (when (< padding 1)
                  (buffer/push-byte out (mod packed 256)))))))
        (set index (+ index 4)))
      (when ok (string out)))))

(defn compare-timestamps
  "Order two Convex sync timestamps.

  The wire value is a base64 little-endian unsigned 64-bit integer, so both
  comparing the encoded text and scanning the bytes forwards get the ordering
  wrong. Returns -1, 0, or 1."
  [left right]
  (def left-bytes (base64-decode left))
  (def right-bytes (base64-decode right))
  (unless (and left-bytes right-bytes
               (= 8 (length left-bytes))
               (= 8 (length right-bytes)))
    (fail/protocol "sync timestamp is not eight base64 encoded bytes"))
  (var index 7)
  (var result 0)
  (while (and (= result 0) (>= index 0))
    (def a (get left-bytes index))
    (def b (get right-bytes index))
    (cond
      (> a b) (set result 1)
      (< a b) (set result -1))
    (set index (- index 1)))
  result)

(defn valid-timestamp?
  "Is `value` a well-formed Convex sync timestamp?"
  [value]
  (and (string? value)
       (let [decoded (base64-decode value)]
         (and decoded (= 8 (length decoded))))))
