-- | JSON for Convex, written in PureScript rather than delegated to a library.
-- |
-- | Two Convex details drive the design. Values must survive a round trip
-- | unchanged, so objects keep their key order and an integer never silently
-- | becomes a float. And Convex may spell a whole number either way on the
-- | wire, so decoding an integer is a deliberate, range-checked step
-- | (`integralInt`) instead of a pattern match on one representation.
-- |
-- | The decoder reads a byte string through a cursor and carries its own
-- | budgets. The adapter parses input it did not produce, so a hostile
-- | document has to exhaust a counter rather than the process heap.
module Convex.Json
  ( Json(..)
  , toString
  , toBytes
  , parse
  , parseBytes
  , field
  , hasField
  , stringField
  , asString
  , asBoolean
  , asObject
  , asArray
  , onlyFields
  , integralInt
  , u32Field
  , logLines
  , codepointLength
  , maxDepth
  , maxNodes
  , maxObjectEntries
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes, Chunks)
import Convex.Bytes as Bytes

-- | A decoded JSON value. `JsonObject` keeps an ordered association list
-- | because Convex arguments and results are re-encoded and compared
-- | elsewhere, and a map would lose the order the deployment sent.
data Json
  = JsonNull
  | JsonBool Boolean
  | JsonInt Int
  | JsonNumber Number
  | JsonString String
  | JsonArray (List Json)
  | JsonObject (List (Tuple String Json))

-- | Nesting bound. Recursion on the BEAM has no fixed stack limit, so this
-- | exists to bound the work a deeply nested document can demand at all.
maxDepth :: Int
maxDepth = 64

-- | A shallow but extremely wide document can exhaust memory without ever
-- | reaching the nesting bound, so structural values are counted too.
maxNodes :: Int
maxNodes = 65536

-- | Entries in one object. Duplicate keys are rejected, and holding that check
-- | to a small bound keeps it linear enough to be safe on hostile input.
maxObjectEntries :: Int
maxObjectEntries = 256

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | Render a value as compact JSON text.
toString :: Json -> String
toString value = Bytes.toStringOrEmpty (toBytes value)

-- | Render straight to bytes, which is what both the socket writer and the
-- | queue accounting actually want.
toBytes :: Json -> Bytes
toBytes value = Bytes.chunksToBytes (render value Bytes.emptyChunks)

-- | Push the rendered form onto an accumulator. Appending to one reversed
-- | chunk list and flattening once avoids copying a growing buffer.
render :: Json -> Chunks -> Chunks
render value acc = case value of
  JsonNull -> Bytes.pushString "null" acc
  JsonBool flag -> Bytes.pushString (if flag then "true" else "false") acc
  JsonInt number -> Bytes.pushString (intToString number) acc
  JsonNumber number -> Bytes.pushString (numberToString number) acc
  JsonString text -> renderString text acc
  JsonArray items ->
    Bytes.pushString "]" (renderItems items (Bytes.pushString "[" acc))
  JsonObject entries ->
    Bytes.pushString "}" (renderEntries entries (Bytes.pushString "{" acc))

renderItems :: List Json -> Chunks -> Chunks
renderItems items acc = case items of
  Nil -> acc
  Cons only Nil -> render only acc
  Cons first rest ->
    renderItems rest (Bytes.pushString "," (render first acc))

renderEntries :: List (Tuple String Json) -> Chunks -> Chunks
renderEntries entries acc = case entries of
  Nil -> acc
  Cons (Tuple key value) Nil ->
    render value (Bytes.pushString ":" (renderString key acc))
  Cons (Tuple key value) rest ->
    renderEntries rest
      ( Bytes.pushString ","
          (render value (Bytes.pushString ":" (renderString key acc)))
      )

-- | Quote and escape a string. Non-ASCII text is emitted as raw UTF-8, which
-- | is what Convex expects and what keeps the emoji in the conformance suite
-- | readable in captured evidence.
renderString :: String -> Chunks -> Chunks
renderString text acc =
  Bytes.pushString "\""
    (escapeFrom (Bytes.fromString text) 0 (Bytes.pushString "\"" acc))

escapeFrom :: Bytes -> Int -> Chunks -> Chunks
escapeFrom bytes index acc =
  let
    stop = Bytes.jsonStringStop bytes index
    withPlain = Bytes.pushChunk (Bytes.slice bytes index (stop - index)) acc
  in
    if stop >= Bytes.size bytes then withPlain
    else escapeFrom bytes (stop + 1)
      (Bytes.pushString (escapeByte (Bytes.byteAt bytes stop)) withPlain)

escapeByte :: Int -> String
escapeByte byte =
  if byte == 0x22 then "\\\""
  else if byte == 0x5C then "\\\\"
  else if byte == 0x0A then "\\n"
  else if byte == 0x0D then "\\r"
  else if byte == 0x09 then "\\t"
  else if byte == 0x08 then "\\b"
  else if byte == 0x0C then "\\f"
  else "\\u" <> intToLowerHex byte 4

-- ---------------------------------------------------------------------------
-- Decoding
-- ---------------------------------------------------------------------------

-- | One decoding step: the value, where the cursor stopped, and how much of
-- | the structural budget has been spent.
type Step =
  { value :: Json
  , index :: Int
  , nodes :: Int
  }

-- | Decode a complete JSON document. Trailing content is an error, so a
-- | truncated or doubled NDJSON line cannot be mistaken for a valid command.
parse :: String -> Either String Json
parse text = parseBytes (Bytes.fromString text)

-- | Decode a document that is still a byte string, which is what arrives from
-- | a socket or from standard input.
parseBytes :: Bytes -> Either String Json
parseBytes bytes =
  eitherThen (parseValue bytes (Bytes.skipWhitespace bytes 0) 0 0) \step ->
    if Bytes.skipWhitespace bytes step.index == Bytes.size bytes then
      Right step.value
    else Left "trailing content after JSON value"

parseValue :: Bytes -> Int -> Int -> Int -> Either String Step
parseValue bytes index depth nodes =
  if depth > maxDepth then Left "JSON nesting is too deep"
  else if nodes > maxNodes then Left "JSON has too many structural values"
  else
    let
      byte = Bytes.byteAt bytes index
    in
      if byte < 0 then Left "unexpected end of JSON input"
      else if byte == 0x6E then literal bytes index "null" JsonNull nodes
      else if byte == 0x74 then literal bytes index "true" (JsonBool true) nodes
      else if byte == 0x66 then
        literal bytes index "false" (JsonBool false) nodes
      else if byte == 0x22 then
        eitherThen (parseString bytes (index + 1)) \text ->
          Right { value: JsonString text.text, index: text.index, nodes: nodes }
      else if byte == 0x5B then
        parseArray bytes (Bytes.skipWhitespace bytes (index + 1)) (depth + 1)
          (nodes + 1)
      else if byte == 0x7B then
        parseObject bytes (Bytes.skipWhitespace bytes (index + 1)) (depth + 1)
          (nodes + 1)
      else if isNumberStart byte then parseNumberToken bytes index nodes
      else Left "unexpected JSON byte"

literal :: Bytes -> Int -> String -> Json -> Int -> Either String Step
literal bytes index text value nodes =
  let
    expected = Bytes.fromString text
    width = Bytes.size expected
  in
    if Bytes.slice bytes index width == expected then
      Right { value: value, index: index + width, nodes: nodes }
    else Left "unexpected JSON byte"

parseArray :: Bytes -> Int -> Int -> Int -> Either String Step
parseArray bytes index depth nodes =
  if Bytes.byteAt bytes index == 0x5D then
    Right { value: JsonArray Nil, index: index + 1, nodes: nodes }
  else parseArrayItems bytes index depth nodes Nil

parseArrayItems
  :: Bytes -> Int -> Int -> Int -> List Json -> Either String Step
parseArrayItems bytes index depth nodes acc =
  eitherThen (parseValue bytes index depth nodes) \step ->
    let
      after = Bytes.skipWhitespace bytes step.index
      byte = Bytes.byteAt bytes after
      items = Cons step.value acc
    in
      if byte == 0x2C then
        parseArrayItems bytes (Bytes.skipWhitespace bytes (after + 1)) depth
          (step.nodes + 1)
          items
      else if byte == 0x5D then
        Right
          { value: JsonArray (listReverse items)
          , index: after + 1
          , nodes: step.nodes
          }
      else Left "expected , or ] in JSON array"

parseObject :: Bytes -> Int -> Int -> Int -> Either String Step
parseObject bytes index depth nodes =
  if Bytes.byteAt bytes index == 0x7D then
    Right { value: JsonObject Nil, index: index + 1, nodes: nodes }
  else parseObjectEntries bytes index depth nodes Nil

parseObjectEntries
  :: Bytes
  -> Int
  -> Int
  -> Int
  -> List (Tuple String Json)
  -> Either String Step
parseObjectEntries bytes index depth nodes acc =
  if listLength acc >= maxObjectEntries then
    Left "JSON object has too many entries"
  else if Bytes.byteAt bytes index /= 0x22 then
    Left "expected string key in JSON object"
  else
    eitherThen (parseString bytes (index + 1)) \key ->
      if listAny (\(Tuple seen _) -> seen == key.text) acc then
        Left "duplicate key in JSON object"
      else
        let
          colon = Bytes.skipWhitespace bytes key.index
        in
          if Bytes.byteAt bytes colon /= 0x3A then
            Left "expected : after JSON object key"
          else
            eitherThen
              ( parseValue bytes (Bytes.skipWhitespace bytes (colon + 1)) depth
                  nodes
              )
              \step ->
                let
                  after = Bytes.skipWhitespace bytes step.index
                  byte = Bytes.byteAt bytes after
                  entries = Cons (Tuple key.text step.value) acc
                in
                  if byte == 0x2C then
                    parseObjectEntries bytes
                      (Bytes.skipWhitespace bytes (after + 1))
                      depth
                      (step.nodes + 1)
                      entries
                  else if byte == 0x7D then
                    Right
                      { value: JsonObject (listReverse entries)
                      , index: after + 1
                      , nodes: step.nodes
                      }
                  else Left "expected , or } in JSON object"

type StringStep =
  { text :: String
  , index :: Int
  }

-- | Decode string contents up to the closing quote. Escapes are expanded into
-- | UTF-8 bytes as they are read, so the accumulator is always valid so far.
parseString :: Bytes -> Int -> Either String StringStep
parseString bytes index = go index Bytes.emptyChunks
  where
  go from acc =
    let
      stop = Bytes.jsonStringStop bytes from
      withPlain = Bytes.pushChunk (Bytes.slice bytes from (stop - from)) acc
      byte = Bytes.byteAt bytes stop
    in
      if byte < 0 then Left "unterminated JSON string"
      else if byte == 0x22 then
        case Bytes.toStringChecked (Bytes.chunksToBytes withPlain) of
          Nothing -> Left "JSON string is not valid UTF-8"
          Just text -> Right { text: text, index: stop + 1 }
      else if byte == 0x5C then parseEscape bytes (stop + 1) withPlain go
      else Left "unescaped control character in JSON string"

-- | Expand one escape and hand the cursor back to the string scanner.
parseEscape
  :: Bytes
  -> Int
  -> Chunks
  -> (Int -> Chunks -> Either String StringStep)
  -> Either String StringStep
parseEscape bytes index acc continue =
  let
    byte = Bytes.byteAt bytes index
  in
    if byte == 0x22 then continue (index + 1) (Bytes.pushString "\"" acc)
    else if byte == 0x5C then continue (index + 1) (Bytes.pushString "\\" acc)
    else if byte == 0x2F then continue (index + 1) (Bytes.pushString "/" acc)
    else if byte == 0x62 then
      continue (index + 1) (Bytes.pushChunk (Bytes.singleByte 0x08) acc)
    else if byte == 0x66 then
      continue (index + 1) (Bytes.pushChunk (Bytes.singleByte 0x0C) acc)
    else if byte == 0x6E then
      continue (index + 1) (Bytes.pushChunk (Bytes.singleByte 0x0A) acc)
    else if byte == 0x72 then
      continue (index + 1) (Bytes.pushChunk (Bytes.singleByte 0x0D) acc)
    else if byte == 0x74 then
      continue (index + 1) (Bytes.pushChunk (Bytes.singleByte 0x09) acc)
    else if byte == 0x75 then parseUnicodeEscape bytes (index + 1) acc continue
    else Left "unknown escape in JSON string"

-- | `\u` escapes carry UTF-16 code units, so an astral character such as an
-- | emoji arrives as a surrogate pair that has to be recombined before it can
-- | become a codepoint.
parseUnicodeEscape
  :: Bytes
  -> Int
  -> Chunks
  -> (Int -> Chunks -> Either String StringStep)
  -> Either String StringStep
parseUnicodeEscape bytes index acc continue =
  eitherThen (parseHex4 bytes index) \high ->
    if high.value >= 0xD800 && high.value <= 0xDBFF then
      if Bytes.slice bytes high.index 2 /= Bytes.fromString "\\u" then
        Left "unpaired high surrogate in JSON string"
      else
        eitherThen (parseHex4 bytes (high.index + 2)) \low ->
          if low.value < 0xDC00 || low.value > 0xDFFF then
            Left "invalid low surrogate in JSON string"
          else
            emit
              ( 0x10000 + (high.value - 0xD800) * 0x400 +
                  (low.value - 0xDC00)
              )
              low.index
    else if high.value >= 0xDC00 && high.value <= 0xDFFF then
      Left "unpaired low surrogate in JSON string"
    else emit high.value high.index
  where
  emit codepoint next =
    let
      encoded = Bytes.codepointToBytes codepoint
    in
      if Bytes.isEmpty encoded then
        Left "escape is not a Unicode codepoint"
      else continue next (Bytes.pushChunk encoded acc)

type HexStep =
  { value :: Int
  , index :: Int
  }

parseHex4 :: Bytes -> Int -> Either String HexStep
parseHex4 bytes index =
  eitherThen (hexDigit (Bytes.byteAt bytes index)) \a ->
    eitherThen (hexDigit (Bytes.byteAt bytes (index + 1))) \b ->
      eitherThen (hexDigit (Bytes.byteAt bytes (index + 2))) \c ->
        eitherThen (hexDigit (Bytes.byteAt bytes (index + 3))) \d ->
          Right
            { value: ((a * 16 + b) * 16 + c) * 16 + d
            , index: index + 4
            }

hexDigit :: Int -> Either String Int
hexDigit byte =
  if byte >= 0x30 && byte <= 0x39 then Right (byte - 0x30)
  else if byte >= 0x61 && byte <= 0x66 then Right (byte - 0x61 + 10)
  else if byte >= 0x41 && byte <= 0x46 then Right (byte - 0x41 + 10)
  else Left "invalid hex digit in JSON string"

isNumberStart :: Int -> Boolean
isNumberStart byte = byte == 0x2D || (byte >= 0x30 && byte <= 0x39)

isNumberByte :: Int -> Boolean
isNumberByte byte =
  isNumberStart byte
    || byte == 0x2B
    || byte == 0x2E
    || byte == 0x45
    || byte == 0x65

-- | Numbers are collected as a token and then classified. A token with a
-- | fraction or an exponent is a float; anything else stays an exact integer,
-- | because Convex document ids and counters must not drift through a double.
parseNumberToken :: Bytes -> Int -> Int -> Either String Step
parseNumberToken bytes index nodes =
  let
    stop = numberEnd bytes index
    token = Bytes.slice bytes index (stop - index)
    text = Bytes.toStringOrEmpty token
  in
    if not (validNumber token) then Left "invalid JSON number"
    else if
      stringContains text "." || stringContains text "e"
        || stringContains text "E" then
      case decodeFloatText text of
        Nothing -> Left "invalid or out of range JSON number"
        Just number ->
          Right { value: JsonNumber number, index: stop, nodes: nodes }
    else case parseInt text of
      Nothing -> Left "invalid JSON integer"
      Just number ->
        Right { value: JsonInt number, index: stop, nodes: nodes }

-- | JSON allows `1e3`, but the BEAM float parser insists on a fraction before
-- | the exponent. Inserting `.0` keeps the value identical while making the
-- | token acceptable.
decodeFloatText :: String -> Maybe Number
decodeFloatText text =
  let
    lowered = stringLowercase text
  in
    if stringContains lowered "." then parseNumber lowered
    else case stringSplitOnce lowered "e" of
      Nothing -> parseNumber lowered
      Just (Tuple mantissa exponent) ->
        parseNumber (mantissa <> ".0e" <> exponent)

numberEnd :: Bytes -> Int -> Int
numberEnd bytes index =
  if isNumberByte (Bytes.byteAt bytes index) then numberEnd bytes (index + 1)
  else index

-- | The JSON number grammar, checked before the token is handed to a parser
-- | that would otherwise accept Erlang spellings JSON does not allow.
validNumber :: Bytes -> Boolean
validNumber token =
  let
    unsigned = if Bytes.byteAt token 0 == 0x2D then 1 else 0
  in
    case integerPart token unsigned of
      Nothing -> false
      Just afterInteger -> case fractionPart token afterInteger of
        Nothing -> false
        Just afterFraction -> case exponentPart token afterFraction of
          Nothing -> false
          Just end -> end == Bytes.size token

integerPart :: Bytes -> Int -> Maybe Int
integerPart token index =
  let
    byte = Bytes.byteAt token index
  in
    if byte == 0x30 then
      if isDigit (Bytes.byteAt token (index + 1)) then Nothing
      else Just (index + 1)
    else if byte >= 0x31 && byte <= 0x39 then Just (dropDigits token (index + 1))
    else Nothing

fractionPart :: Bytes -> Int -> Maybe Int
fractionPart token index =
  if Bytes.byteAt token index /= 0x2E then Just index
  else if isDigit (Bytes.byteAt token (index + 1)) then
    Just (dropDigits token (index + 1))
  else Nothing

exponentPart :: Bytes -> Int -> Maybe Int
exponentPart token index =
  let
    byte = Bytes.byteAt token index
  in
    if byte /= 0x45 && byte /= 0x65 then Just index
    else
      let
        signed = Bytes.byteAt token (index + 1)
        start =
          if signed == 0x2B || signed == 0x2D then index + 2 else index + 1
      in
        if isDigit (Bytes.byteAt token start) then Just (dropDigits token start)
        else Nothing

dropDigits :: Bytes -> Int -> Int
dropDigits token index =
  if isDigit (Bytes.byteAt token index) then dropDigits token (index + 1)
  else index

isDigit :: Int -> Boolean
isDigit byte = byte >= 0x30 && byte <= 0x39

-- ---------------------------------------------------------------------------
-- Accessors
-- ---------------------------------------------------------------------------

-- | Look up one key of a JSON object. Absent keys and non-objects are both
-- | `Nothing`; callers that must tell them apart use `asObject` first.
field :: Json -> String -> Maybe Json
field value key = case value of
  JsonObject entries ->
    maybeMap snd (listFind (\(Tuple name _) -> name == key) entries)
  _ -> Nothing

-- | True when the object physically carries the key, even if its value is
-- | `null`. Convex treats an absent `errorData` and an explicit null
-- | differently, and the adapter has to preserve that distinction.
hasField :: Json -> String -> Boolean
hasField value key = isJust (field value key)

stringField :: Json -> String -> Maybe String
stringField value key = maybeThen (field value key) asString

asString :: Json -> Maybe String
asString value = case value of
  JsonString text -> Just text
  _ -> Nothing

asBoolean :: Json -> Maybe Boolean
asBoolean value = case value of
  JsonBool flag -> Just flag
  _ -> Nothing

asObject :: Json -> Maybe (List (Tuple String Json))
asObject value = case value of
  JsonObject entries -> Just entries
  _ -> Nothing

asArray :: Json -> Maybe (List Json)
asArray value = case value of
  JsonArray items -> Just items
  _ -> Nothing

-- | Require exactly the fields one adapter command shape permits.
onlyFields :: Json -> List String -> Boolean
onlyFields value allowed = case value of
  JsonObject entries ->
    listAll (\(Tuple name _) -> listContains name allowed) entries
  _ -> false

-- | JSON Schema measures string length in Unicode scalar values, not bytes.
codepointLength :: String -> Int
codepointLength = stringCodepointLength

-- | Decode a whole number that Convex may have spelled either way.
-- |
-- | `1` and `1.0` are the same counter value, so both are accepted. A
-- | fraction, a quoted number, or a value outside the signed 64-bit range is
-- | rejected, because silently rounding a Convex value would hide real drift.
integralInt :: Json -> Maybe Int
integralInt value = case value of
  JsonInt number -> inRange number
  JsonNumber number ->
    let
      truncated = truncateNumber number
    in
      if intToNumber truncated == number then inRange truncated else Nothing
  _ -> Nothing

inRange :: Int -> Maybe Int
inRange number =
  if number >= minSafeInt && number <= maxSafeInt then Just number else Nothing

-- | Decode an unsigned 32-bit wire field. Query identifiers and both sync
-- | version counters are u32 on the wire; BEAM integers are unbounded, so the
-- | range has to be enforced here rather than assumed.
u32Field :: Json -> String -> Maybe Int
u32Field value key =
  maybeThen (field value key) \raw ->
    maybeThen (integralInt raw) \number ->
      if number >= 0 && number <= maxUnsigned32 then Just number else Nothing

-- | Decode the optional `logLines` array Convex attaches to results and query
-- | failures. An absent array is empty; a malformed one is an error.
logLines :: Json -> Maybe (List String)
logLines value = case field value "logLines" of
  Nothing -> Just Nil
  Just (JsonArray items) -> listTraverseMaybe asString items
  Just _ -> Nothing
