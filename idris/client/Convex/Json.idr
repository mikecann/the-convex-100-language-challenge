||| A strict JSON reader and writer for Convex payloads.
|||
||| Parsing and rendering both work directly on the byte buffers owned by the
||| transport shim. That is deliberate: RefC's `Char` is not a reliable Unicode
||| scalar, so unpacking a payload into a character list and packing it back
||| would corrupt anything outside ASCII. Working in bytes keeps a Convex value
||| byte-identical from the socket to the socket.
|||
||| A parsed number keeps its original token. Convex sends Float64 values whose
||| shortest round-trip form the runtime's own double printer may not reproduce,
||| and re-emitting the received token means an echoed value comes back exactly
||| as it was sent.
module Convex.Json

import Data.List
import Data.Maybe
import Data.String

import Convex.Prim

||| A JSON number: the literal token as it appeared or will appear on the wire,
||| plus its numeric value for comparisons and decoding.
public export
record JsonNumber where
  constructor MkJsonNumber
  numberText : String
  numberValue : Double

public export
data Json
  = JNull
  | JBool Bool
  | JNumber JsonNumber
  | JString String
  | JArray (List Json)
  | JObject (List (String, Json))

-- Structural equality is defined as plain, directly-recursive top-level
-- functions rather than inside the `Eq Json` implementation itself. Two
-- earlier shapes both defeated Idris2's termination checker: routing through
-- a generic higher-order combinator (`eqBy : (a -> a -> Bool) -> List a ->
-- List a -> Bool`) hides that each step is applied to a structurally smaller
-- Json value, and even a directly-recursive helper placed in a `mutual`
-- block with the interface implementation fails, because a recursive call
-- written as `==` inside that block still desugars to a call through the
-- `Eq Json` interface dictionary rather than a direct self-call, which the
-- size-change analysis cannot follow. Named functions calling each other
-- directly by name are ordinary structural recursion, which the checker
-- handles without difficulty; the interface implementation below is then
-- just a non-recursive alias for `jsonEq`. jsonEq, jsonArrayEq, and
-- jsonObjectSubset call each other, so they need `mutual` to see each
-- other's types regardless of declaration order; the `Eq Json` alias stays
-- outside this block since it is what must NOT be part of the cycle.
mutual
  jsonEq : Json -> Json -> Bool
  jsonEq JNull JNull = True
  jsonEq (JBool left) (JBool right) = left == right
  jsonEq (JNumber left) (JNumber right) = numberValue left == numberValue right
  jsonEq (JString left) (JString right) = left == right
  jsonEq (JArray left) (JArray right) = jsonArrayEq left right
  -- Objects are unordered, so equality compares membership rather than the
  -- order Convex happened to serialise the fields in.
  jsonEq (JObject left) (JObject right) =
    length left == length right && jsonObjectSubset left right
  jsonEq _ _ = False

  jsonArrayEq : List Json -> List Json -> Bool
  jsonArrayEq [] [] = True
  jsonArrayEq (x :: xs) (y :: ys) = jsonEq x y && jsonArrayEq xs ys
  jsonArrayEq _ _ = False

  ||| True when every (key, value) pair on the left has a matching value at
  ||| the same key on the right. Combined with the length check above (so
  ||| the right side cannot have extra keys), this gives full set equality
  ||| for the unordered field list.
  jsonObjectSubset : List (String, Json) -> List (String, Json) -> Bool
  jsonObjectSubset [] _ = True
  jsonObjectSubset ((key, value) :: rest) right =
    case lookup key right of
         Just other => jsonEq value other && jsonObjectSubset rest right
         Nothing => False

public export
Eq Json where
  (==) = jsonEq

--------------------------------------------------------------------------------
-- Construction and accessors
--------------------------------------------------------------------------------

infinity : Double
infinity = 1.0 / 0.0

||| JSON has no NaN or infinity, so a non-finite double can never be encoded.
export
finiteDouble : Double -> Bool
finiteDouble value = value == value && value /= infinity && value /= -infinity

export
jsonDouble : Double -> Maybe Json
jsonDouble value =
  if finiteDouble value
     then Just (JNumber (MkJsonNumber (show value) value))
     else Nothing

export
jsonInt : Int -> Json
jsonInt value = JNumber (MkJsonNumber (show value) (cast value))

export
field : String -> Json -> Maybe Json
field name (JObject entries) = lookup name entries
field _ _ = Nothing

export
asString : Json -> Maybe String
asString (JString text) = Just text
asString _ = Nothing

export
asBool : Json -> Maybe Bool
asBool (JBool value) = Just value
asBool _ = Nothing

export
asArray : Json -> Maybe (List Json)
asArray (JArray items) = Just items
asArray _ = Nothing

export
asObject : Json -> Maybe (List (String, Json))
asObject (JObject entries) = Just entries
asObject _ = Nothing

export
isObject : Json -> Bool
isObject value = isJust (asObject value)

||| Convex often reports an integral value in decimal form such as `0.0`, so a
||| whole number is anything finite, exactly integral, and inside the range a
||| 64-bit `Int` can hold without rounding.
export
wholeNumber : Json -> Maybe Int
wholeNumber (JNumber number) =
  let value = numberValue number in
  if not (finiteDouble value)
     then Nothing
     else if value < -9007199254740992.0 || value > 9007199254740992.0
             then Nothing
             else let rounded : Int
                      rounded = cast value in
                  if cast {to = Double} rounded == value
                     then Just rounded
                     else Nothing
wholeNumber _ = Nothing

||| Every entry of a JSON array of strings, or `Nothing` if any entry is not a
||| string. Convex log lines must satisfy this before they are forwarded.
export
stringList : Json -> Maybe (List String)
stringList (JArray items) = traverse asString items
stringList _ = Nothing

--------------------------------------------------------------------------------
-- Byte helpers
--------------------------------------------------------------------------------

quoteByte : Int
quoteByte = 34

backslashByte : Int
backslashByte = 92

slashByte : Int
slashByte = 47

openBrace : Int
openBrace = 123

closeBrace : Int
closeBrace = 125

openBracket : Int
openBracket = 91

closeBracket : Int
closeBracket = 93

colonByte : Int
colonByte = 58

commaByte : Int
commaByte = 44

minusByte : Int
minusByte = 45

plusByte : Int
plusByte = 43

dotByte : Int
dotByte = 46

zeroByte : Int
zeroByte = 48

nineByte : Int
nineByte = 57

isDigitByte : Int -> Bool
isDigitByte value = value >= zeroByte && value <= nineByte

isSpaceByte : Int -> Bool
isSpaceByte value = value == 32 || value == 9 || value == 10 || value == 13

hexValue : Int -> Maybe Int
hexValue value =
  if isDigitByte value
     then Just (value - zeroByte)
     else if value >= 97 && value <= 102
             then Just (value - 87)
             else if value >= 65 && value <= 70
                     then Just (value - 55)
                     else Nothing

hexDigitByte : Int -> Int
hexDigitByte value = if value < 10 then zeroByte + value else 87 + value

||| The two-character JSON escapes, mapped from the byte after the backslash to
||| the byte it stands for.
simpleEscape : Int -> Maybe Int
simpleEscape marker =
  lookup marker
    [ (quoteByte, quoteByte)
    , (backslashByte, backslashByte)
    , (slashByte, slashByte)
    , (98, 8)    -- \b
    , (102, 12)  -- \f
    , (110, 10)  -- \n
    , (114, 13)  -- \r
    , (116, 9)   -- \t
    ]

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

||| The maximum nesting the parser accepts. Convex demonstration payloads are
||| shallow; a bound keeps a hostile or corrupted frame from exhausting the
||| stack before the byte budget notices.
maximumDepth : Int
maximumDepth = 64

byteAt : Int -> Int -> Int -> IO Int
byteAt buffer limit index =
  if index < 0 || index >= limit
     then pure (-1)
     else bufGet buffer index

covering
skipSpace : Int -> Int -> Int -> IO Int
skipSpace buffer limit index =
  do current <- byteAt buffer limit index
     if isSpaceByte current
        then skipSpace buffer limit (index + 1)
        else pure index

covering
matchBytes : Int -> Int -> Int -> List Int -> IO Bool
matchBytes _ _ _ [] = pure True
matchBytes buffer limit index (expected :: rest) =
  do current <- byteAt buffer limit index
     if current == expected
        then matchBytes buffer limit (index + 1) rest
        else pure False

||| Write one Unicode scalar to the unescape scratch buffer as UTF-8.
putCodePoint : Int -> Int -> Int -> IO (Either String Int)
putCodePoint scratch at code =
  if code < 0x80
     then do ignore $ bufSet scratch at code
             pure (Right (at + 1))
     else if code < 0x800
             then do ignore $ bufSet scratch at (0xC0 + div code 64)
                     ignore $ bufSet scratch (at + 1) (0x80 + mod code 64)
                     pure (Right (at + 2))
             else if code < 0x10000
                     then do ignore $ bufSet scratch at (0xE0 + div code 4096)
                             ignore $ bufSet scratch (at + 1) (0x80 + mod (div code 64) 64)
                             ignore $ bufSet scratch (at + 2) (0x80 + mod code 64)
                             pure (Right (at + 3))
                     else if code <= 0x10FFFF
                             then do
                               ignore $ bufSet scratch at (0xF0 + div code 262144)
                               ignore $ bufSet scratch (at + 1)
                                          (0x80 + mod (div code 4096) 64)
                               ignore $ bufSet scratch (at + 2)
                                          (0x80 + mod (div code 64) 64)
                               ignore $ bufSet scratch (at + 3) (0x80 + mod code 64)
                               pure (Right (at + 4))
                             else pure (Left "JSON escape is outside Unicode")

covering
readHex4 : Int -> Int -> Int -> IO (Either String Int)
readHex4 buffer limit index = go 0 0
  where
    covering
    go : Int -> Int -> IO (Either String Int)
    go taken accumulated =
      if taken == 4
         then pure (Right accumulated)
         else do digit <- byteAt buffer limit (index + taken)
                 case hexValue digit of
                      Nothing => pure (Left "JSON \\u escape is not four hex digits")
                      Just value => go (taken + 1) (accumulated * 16 + value)

||| Copy the literal run `[start, stop)` from one buffer to another, returning
||| the next free index in the destination. Both the unescaping reader and the
||| escaping writer use it so a run of ordinary bytes never crosses the FFI one
||| byte at a time.
flushRun : (source : Int) -> (destination : Int) -> (start : Int) -> (stop : Int)
        -> (written : Int) -> IO Int
flushRun source destination start stop written =
  if stop <= start
     then pure written
     else do ignore $ bufCopy destination written source start (stop - start)
             pure (written + (stop - start))

mutual
  ||| Parse a string literal starting just after its opening quote. Literal runs
  ||| are bulk-copied and only escapes are handled a byte at a time.
  covering
  parseStringBody : Int -> Int -> Int -> Int -> Int -> Int
                 -> IO (Either String (String, Int))
  parseStringBody buffer limit scratch index written runStart =
    do current <- byteAt buffer limit index
       if current < 0
          then pure (Left "JSON string is unterminated")
          else if current == quoteByte
                  then do stop <- flushRun buffer scratch runStart index written
                          decoded <- bufTakeText scratch 0 stop
                          case decoded of
                               Nothing => pure (Left "JSON string is not valid UTF-8")
                               Just text => pure (Right (text, index + 1))
                  else if current < 32
                          then pure (Left "JSON string contains a raw control byte")
                          else if current == backslashByte
                                  then do
                                    stop <- flushRun buffer scratch runStart index written
                                    parseEscape buffer limit scratch (index + 1) stop
                                  else parseStringBody buffer limit scratch (index + 1)
                                                       written runStart

  covering
  parseEscape : Int -> Int -> Int -> Int -> Int -> IO (Either String (String, Int))
  parseEscape buffer limit scratch at written =
    do marker <- byteAt buffer limit at
       case simpleEscape marker of
            Just replacement =>
              do ignore $ bufSet scratch written replacement
                 parseStringBody buffer limit scratch (at + 1) (written + 1) (at + 1)
            Nothing =>
              if marker /= 117
                 then pure (Left "JSON string has an unknown escape")
                 else do lead <- readHex4 buffer limit (at + 1)
                         case lead of
                              Left problem => pure (Left problem)
                              Right code =>
                                parseUnicodeEscape buffer limit scratch (at + 5)
                                                   written code

  covering
  parseUnicodeEscape : Int -> Int -> Int -> Int -> Int -> Int
                    -> IO (Either String (String, Int))
  parseUnicodeEscape buffer limit scratch at written lead =
    if lead >= 0xDC00 && lead <= 0xDFFF
       then pure (Left "JSON string has an unpaired low surrogate")
       else if lead < 0xD800 || lead > 0xDBFF
               then do placed <- putCodePoint scratch written lead
                       case placed of
                            Left problem => pure (Left problem)
                            Right next => parseStringBody buffer limit scratch at next at
               else do escape <- byteAt buffer limit at
                       marker <- byteAt buffer limit (at + 1)
                       if escape /= backslashByte || marker /= 117
                          then pure (Left "JSON string has an unpaired high surrogate")
                          else do trail <- readHex4 buffer limit (at + 2)
                                  case trail of
                                       Left problem => pure (Left problem)
                                       Right low => combine buffer limit scratch at written
                                                            lead low
    where
      covering
      combine : Int -> Int -> Int -> Int -> Int -> Int -> Int
             -> IO (Either String (String, Int))
      combine source stop target position out high low =
        if low < 0xDC00 || low > 0xDFFF
           then pure (Left "JSON surrogate pair is invalid")
           else do
             let code = 0x10000 + (high - 0xD800) * 1024 + (low - 0xDC00)
             placed <- putCodePoint target out code
             case placed of
                  Left problem => pure (Left problem)
                  Right next =>
                    parseStringBody source stop target (position + 6) next (position + 6)

||| Scan one JSON number token and reject the forms JSON does not allow:
||| a leading plus, a leading zero, a bare decimal point, and any exponent
||| without digits.
covering
scanNumber : Int -> Int -> Int -> IO (Either String Int)
scanNumber buffer limit index =
  do first <- byteAt buffer limit index
     let afterSign = if first == minusByte then index + 1 else index
     lead <- byteAt buffer limit afterSign
     if not (isDigitByte lead)
        then pure (Left "JSON number has no digits")
        else do intEnd <- digits (afterSign + 1)
                if lead == zeroByte && intEnd > afterSign + 1
                   then pure (Left "JSON number has a leading zero")
                   else do afterFraction <- fraction intEnd
                           case afterFraction of
                                Left problem => pure (Left problem)
                                Right position => exponent position
  where
    covering
    digits : Int -> IO Int
    digits at =
      do current <- byteAt buffer limit at
         if isDigitByte current
            then digits (at + 1)
            else pure at

    covering
    fraction : Int -> IO (Either String Int)
    fraction at =
      do current <- byteAt buffer limit at
         if current /= dotByte
            then pure (Right at)
            else do next <- byteAt buffer limit (at + 1)
                    if not (isDigitByte next)
                       then pure (Left "JSON number has no fractional digits")
                       else do stop <- digits (at + 2)
                               pure (Right stop)

    covering
    exponent : Int -> IO (Either String Int)
    exponent at =
      do current <- byteAt buffer limit at
         if current /= 101 && current /= 69
            then pure (Right at)
            else do signed <- byteAt buffer limit (at + 1)
                    let start = if signed == plusByte || signed == minusByte
                                   then at + 2
                                   else at + 1
                    lead <- byteAt buffer limit start
                    if not (isDigitByte lead)
                       then pure (Left "JSON number has no exponent digits")
                       else do stop <- digits (start + 1)
                               pure (Right stop)

||| What a value starts with. Classifying first keeps the dispatch a single
||| total case expression instead of a long chain inside a do block.
data JsonHead
  = HeadString
  | HeadObject
  | HeadArray
  | HeadTrue
  | HeadFalse
  | HeadNull
  | HeadNumber
  | HeadUnknown

classify : Int -> JsonHead
classify current =
  if current == quoteByte then HeadString
  else if current == openBrace then HeadObject
  else if current == openBracket then HeadArray
  else if current == 116 then HeadTrue
  else if current == 102 then HeadFalse
  else if current == 110 then HeadNull
  else if current == minusByte || isDigitByte current then HeadNumber
  else HeadUnknown

mutual
  covering
  parseValue : Int -> Int -> Int -> Int -> Int -> IO (Either String (Json, Int))
  parseValue buffer limit scratch depth index =
    if depth > maximumDepth
       then pure (Left "JSON nesting is too deep")
       else do at <- skipSpace buffer limit index
               current <- byteAt buffer limit at
               case classify current of
                    HeadString =>
                      do parsed <- parseStringBody buffer limit scratch (at + 1) 0 (at + 1)
                         case parsed of
                              Left problem => pure (Left problem)
                              Right (text, next) => pure (Right (JString text, next))
                    HeadObject => parseObject buffer limit scratch depth (at + 1) []
                    HeadArray => parseArray buffer limit scratch depth (at + 1) []
                    HeadTrue => literal buffer limit at [116, 114, 117, 101] (JBool True) 4
                    HeadFalse =>
                      literal buffer limit at [102, 97, 108, 115, 101] (JBool False) 5
                    HeadNull => literal buffer limit at [110, 117, 108, 108] JNull 4
                    HeadNumber => number buffer limit at
                    HeadUnknown => pure (Left "JSON value is not recognised")

  covering
  literal : Int -> Int -> Int -> List Int -> Json -> Int
         -> IO (Either String (Json, Int))
  literal buffer limit at expected value width =
    do matched <- matchBytes buffer limit at expected
       pure (if matched
                then Right (value, at + width)
                else Left "JSON value is not recognised")

  covering
  number : Int -> Int -> Int -> IO (Either String (Json, Int))
  number buffer limit at =
    do scanned <- scanNumber buffer limit at
       case scanned of
            Left problem => pure (Left problem)
            Right stop =>
              do token <- bufTakeText buffer at (stop - at)
                 case token of
                      Nothing => pure (Left "JSON number is malformed")
                      Just text =>
                        pure (Right (JNumber (MkJsonNumber text (cast text)), stop))

  covering
  parseArray : Int -> Int -> Int -> Int -> Int -> List Json
            -> IO (Either String (Json, Int))
  parseArray buffer limit scratch depth index acc =
    do at <- skipSpace buffer limit index
       current <- byteAt buffer limit at
       if current == closeBracket && null acc
          then pure (Right (JArray [], at + 1))
          else do parsed <- parseValue buffer limit scratch (depth + 1) at
                  case parsed of
                       Left problem => pure (Left problem)
                       Right (value, next) =>
                         do after <- skipSpace buffer limit next
                            separator <- byteAt buffer limit after
                            if separator == commaByte
                               then parseArray buffer limit scratch depth (after + 1)
                                               (value :: acc)
                               else if separator == closeBracket
                                       then pure (Right (JArray (reverse (value :: acc)),
                                                         after + 1))
                                       else pure (Left "JSON array is malformed")

  covering
  parseObject : Int -> Int -> Int -> Int -> Int -> List (String, Json)
             -> IO (Either String (Json, Int))
  parseObject buffer limit scratch depth index acc =
    do at <- skipSpace buffer limit index
       current <- byteAt buffer limit at
       if current == closeBrace && null acc
          then pure (Right (JObject [], at + 1))
          else if current /= quoteByte
                  then pure (Left "JSON object key must be a string")
                  else do parsed <- parseStringBody buffer limit scratch (at + 1) 0 (at + 1)
                          case parsed of
                               Left problem => pure (Left problem)
                               Right (key, afterKey) =>
                                 objectEntry buffer limit scratch depth acc key afterKey

  covering
  objectEntry : Int -> Int -> Int -> Int -> List (String, Json) -> String -> Int
             -> IO (Either String (Json, Int))
  objectEntry buffer limit scratch depth acc key afterKey =
    if isJust (lookup key acc)
       then pure (Left "JSON object has a duplicate key")
       else do beforeColon <- skipSpace buffer limit afterKey
               colon <- byteAt buffer limit beforeColon
               if colon /= colonByte
                  then pure (Left "JSON object is missing a colon")
                  else do parsed <- parseValue buffer limit scratch (depth + 1)
                                               (beforeColon + 1)
                          case parsed of
                               Left problem => pure (Left problem)
                               Right (value, next) =>
                                 objectTail buffer limit scratch depth
                                            ((key, value) :: acc) next

  covering
  objectTail : Int -> Int -> Int -> Int -> List (String, Json) -> Int
            -> IO (Either String (Json, Int))
  objectTail buffer limit scratch depth acc next =
    do after <- skipSpace buffer limit next
       separator <- byteAt buffer limit after
       if separator == commaByte
          then parseObject buffer limit scratch depth (after + 1) acc
          else if separator == closeBrace
                  then pure (Right (JObject (reverse acc), after + 1))
                  else pure (Left "JSON object is malformed")

||| Parse exactly one JSON document from a buffer slice. Trailing content other
||| than whitespace is rejected, so a truncated or doubled frame cannot be
||| mistaken for a valid message.
export covering
parseJsonSlice : Int -> Int -> Int -> IO (Either String Json)
parseJsonSlice buffer offset length =
  do scratch <- bufNew (length + 8)
     if scratch < 0
        then pure (Left "JSON parser could not allocate scratch space")
        else do
          -- The parser indexes the shared buffer directly, so the limit is the
          -- absolute end of the slice rather than its length.
          result <- parseValue buffer (offset + length) scratch 0 offset
          outcome <- case result of
                          Left problem => pure (Left problem)
                          Right (value, next) =>
                            do rest <- skipSpace buffer (offset + length) next
                               pure (if rest == offset + length
                                        then Right value
                                        else Left "JSON document has trailing content")
          bufFree scratch
          pure outcome

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

||| A worst-case encoded size. Every payload byte can expand to the six-byte
||| `\u00xx` form, and each value contributes a bounded amount of punctuation.
export covering
renderBound : Json -> IO Int
renderBound JNull = pure 8
renderBound (JBool _) = pure 8
renderBound (JNumber value) =
  do size <- textSize (numberText value)
     pure (size + 8)
renderBound (JString text) =
  do size <- textSize text
     pure (size * 6 + 8)
renderBound (JArray items) =
  do sizes <- traverse renderBound items
     pure (sum sizes + cast (length items) + 8)
renderBound (JObject entries) =
  do sizes <- traverse entryBound entries
     pure (sum sizes + 8)
  where
    covering
    entryBound : (String, Json) -> IO Int
    entryBound (key, value) =
      do keySize <- textSize key
         valueSize <- renderBound value
         pure (keySize * 6 + valueSize + 8)

putRawText : Int -> Int -> String -> IO Int
putRawText target at text =
  do written <- bufPutText target at text
     pure (if written < 0 then -1 else at + written)

writeShortEscape : Int -> Int -> Int -> IO Int
writeShortEscape target out byte =
  do let mnemonic = if byte == 8 then 98
                    else if byte == 9 then 116
                    else if byte == 10 then 110
                    else if byte == 12 then 102
                    else if byte == 13 then 114
                    else 0
     ignore $ bufSet target out backslashByte
     if mnemonic /= 0
        then do ignore $ bufSet target (out + 1) mnemonic
                pure (out + 2)
        else do ignore $ bufSet target (out + 1) 117
                ignore $ bufSet target (out + 2) zeroByte
                ignore $ bufSet target (out + 3) zeroByte
                ignore $ bufSet target (out + 4) (hexDigitByte (div byte 16))
                ignore $ bufSet target (out + 5) (hexDigitByte (mod byte 16))
                pure (out + 6)

||| Copy a string into the output with JSON escaping. The source is staged in
||| scratch so the scan works on encoded bytes rather than on `Char` values.
export covering
putEscaped : Int -> Int -> Int -> String -> IO (Either String Int)
putEscaped target at scratch text =
  do size <- textSize text
     capacity <- bufCapacity scratch
     if size > capacity
        then pure (Left "JSON string does not fit the render scratch buffer")
        else do ignore $ bufPutText scratch 0 text
                ignore $ bufSet target at quoteByte
                copied <- go size 0 (at + 1) 0
                case copied of
                     Left problem => pure (Left problem)
                     Right stop =>
                       do ignore $ bufSet target stop quoteByte
                          pure (Right (stop + 1))
  where
    covering
    go : Int -> Int -> Int -> Int -> IO (Either String Int)
    go size index out runStart =
      if index >= size
         then do stop <- flushRun scratch target runStart index out
                 pure (Right stop)
         else do current <- bufGet scratch index
                 if current == quoteByte || current == backslashByte
                    then do stop <- flushRun scratch target runStart index out
                            ignore $ bufSet target stop backslashByte
                            ignore $ bufSet target (stop + 1) current
                            go size (index + 1) (stop + 2) (index + 1)
                    else if current >= 32
                            then go size (index + 1) out runStart
                            else do stop <- flushRun scratch target runStart index out
                                    next <- writeShortEscape target stop current
                                    go size (index + 1) next (index + 1)

||| Render a value into `target` starting at `at`, returning the next free
||| index. `scratch` must be at least as large as the longest string rendered.
export covering
renderInto : Int -> Int -> Int -> Json -> IO (Either String Int)
renderInto target at _ JNull =
  do next <- putRawText target at "null"
     pure (if next < 0 then Left "JSON output overflowed" else Right next)
renderInto target at _ (JBool value) =
  do next <- putRawText target at (if value then "true" else "false")
     pure (if next < 0 then Left "JSON output overflowed" else Right next)
renderInto target at _ (JNumber value) =
  if not (finiteDouble (numberValue value))
     then pure (Left "JSON cannot encode a non-finite number")
     else do next <- putRawText target at (numberText value)
             pure (if next < 0 then Left "JSON output overflowed" else Right next)
renderInto target at scratch (JString text) = putEscaped target at scratch text
renderInto target at scratch (JArray items) =
  do ignore $ bufSet target at openBracket
     stop <- go items (at + 1) True
     case stop of
          Left problem => pure (Left problem)
          Right out => do ignore $ bufSet target out closeBracket
                          pure (Right (out + 1))
  where
    covering
    go : List Json -> Int -> Bool -> IO (Either String Int)
    go [] out _ = pure (Right out)
    go (item :: rest) out first =
      do separated <- if first
                         then pure out
                         else do ignore $ bufSet target out commaByte
                                 pure (out + 1)
         rendered <- renderInto target separated scratch item
         case rendered of
              Left problem => pure (Left problem)
              Right next => go rest next False
renderInto target at scratch (JObject entries) =
  do ignore $ bufSet target at openBrace
     stop <- go entries (at + 1) True
     case stop of
          Left problem => pure (Left problem)
          Right out => do ignore $ bufSet target out closeBrace
                          pure (Right (out + 1))
  where
    covering
    go : List (String, Json) -> Int -> Bool -> IO (Either String Int)
    go [] out _ = pure (Right out)
    go ((key, value) :: rest) out first =
      do separated <- if first
                         then pure out
                         else do ignore $ bufSet target out commaByte
                                 pure (out + 1)
         keyed <- putEscaped target separated scratch key
         case keyed of
              Left problem => pure (Left problem)
              Right afterKey =>
                do ignore $ bufSet target afterKey colonByte
                   rendered <- renderInto target (afterKey + 1) scratch value
                   case rendered of
                        Left problem => pure (Left problem)
                        Right next => go rest next False

||| Render a value to an Idris string. Used for command payloads and NDJSON
||| events, where the encoded form is needed as a whole before it is queued.
export covering
renderJson : Json -> IO (Either String String)
renderJson value =
  do bound <- renderBound value
     target <- bufNew (bound + 16)
     scratch <- bufNew (bound + 16)
     if target < 0 || scratch < 0
        then do when (target >= 0) (bufFree target)
                when (scratch >= 0) (bufFree scratch)
                pure (Left "JSON renderer could not allocate output space")
        else do rendered <- renderInto target 0 scratch value
                outcome <- case rendered of
                                Left problem => pure (Left problem)
                                Right stop =>
                                  do text <- bufTakeText target 0 stop
                                     pure (maybe (Left "JSON output was not valid UTF-8")
                                                 Right text)
                bufFree target
                bufFree scratch
                pure outcome

||| Parse a whole Idris string as JSON. Convenience for the adapter's NDJSON
||| lines and for tests; the transport paths parse buffers directly.
export covering
parseJsonText : String -> IO (Either String Json)
parseJsonText text =
  do size <- textSize text
     buffer <- bufNew (size + 8)
     if buffer < 0
        then pure (Left "JSON parser could not allocate input space")
        else do ignore $ bufPutText buffer 0 text
                result <- parseJsonSlice buffer 0 size
                bufFree buffer
                pure result
