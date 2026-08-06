-- | Byte strings, and the few scans that would be slow one byte at a time.
-- |
-- | HTTP framing, WebSocket framing, and JSON are all defined on bytes, not on
-- | characters, so the client works on `Bytes` and only produces a `String`
-- | once a complete, validated region has been read. PureScript has no binary
-- | pattern matching, so the primitives below stand in for Erlang's bit syntax.
-- |
-- | Every accessor is total. Reads outside the string answer -1 and slices are
-- | clamped, so a truncated frame from a hostile peer is an ordinary decoding
-- | decision rather than an exception inside a socket loop.
module Convex.Bytes
  ( Bytes
  , Chunks
  , empty
  , size
  , isEmpty
  , append
  , concatPair
  , fromString
  , toStringOrEmpty
  , isValidUtf8
  , toStringChecked
  , byteAt
  , slice
  , drop
  , take
  , startsWith
  , indexOfByte
  , indexOfBytes
  , emptyChunks
  , pushChunk
  , pushString
  , chunksSize
  , chunksToBytes
  , singleByte
  , uint16BE
  , uint64BE
  , uint64LE
  , readUint16BE
  , readUint64BE
  , readUint64LE
  , xorRepeating
  , base64Encode
  , base64Decode
  , sha1
  , codepointToBytes
  , jsonStringStop
  , skipWhitespace
  ) where

import Convex.Prelude

-- | An immutable byte string.
foreign import data Bytes :: Type

-- | A reversed accumulator of byte strings. Building output by pushing chunks
-- | and flattening once avoids copying a growing buffer for every append,
-- | which matters for JSON encoding and for frame reassembly.
foreign import data Chunks :: Type

foreign import empty :: Bytes

foreign import size :: Bytes -> Int

isEmpty :: Bytes -> Boolean
isEmpty bytes = size bytes == 0

foreign import append :: Bytes -> Bytes -> Bytes

concatPair :: Bytes -> Bytes -> Bytes
concatPair = append

-- | UTF-8 encode. PureScript strings are already UTF-8 binaries on this
-- | backend, so this is a representation change rather than a conversion.
foreign import fromString :: String -> Bytes

-- | Decode as UTF-8, answering the empty string when the bytes are not valid.
-- | Callers that must tell "invalid" from "empty" apart use `toStringChecked`.
foreign import toStringOrEmpty :: Bytes -> String

foreign import isValidUtf8 :: Bytes -> Boolean

toStringChecked :: Bytes -> Maybe String
toStringChecked bytes =
  if isValidUtf8 bytes then Just (toStringOrEmpty bytes) else Nothing

-- | The byte at an offset, or -1 when the offset is outside the string.
foreign import byteAt :: Bytes -> Int -> Int

-- | Clamped substring by offset and length.
foreign import slice :: Bytes -> Int -> Int -> Bytes

drop :: Int -> Bytes -> Bytes
drop count bytes = slice bytes count (size bytes)

take :: Int -> Bytes -> Bytes
take count bytes = slice bytes 0 count

startsWith :: Bytes -> Bytes -> Boolean
startsWith bytes prefix = slice bytes 0 (size prefix) == prefix

-- | Offset of the next occurrence of one byte at or after `from`, or -1.
foreign import indexOfByte :: Bytes -> Int -> Int -> Int

-- | Offset of the next occurrence of a byte string at or after `from`, or -1.
foreign import indexOfBytes :: Bytes -> Bytes -> Int -> Int

foreign import emptyChunks :: Chunks

foreign import pushChunk :: Bytes -> Chunks -> Chunks

pushString :: String -> Chunks -> Chunks
pushString text chunks = pushChunk (fromString text) chunks

foreign import chunksSize :: Chunks -> Int

-- | Flatten in push order. The accumulator is reversed internally, so callers
-- | push in the order the bytes should appear.
foreign import chunksToBytes :: Chunks -> Bytes

-- | A one-byte string. Values outside 0..255 are masked, because every caller
-- | has already bounded the value and a partial byte is not representable.
foreign import singleByte :: Int -> Bytes

foreign import uint16BE :: Int -> Bytes
foreign import uint64BE :: Int -> Bytes

-- | Little-endian, which is how Convex spells the sync protocol's timestamps.
foreign import uint64LE :: Int -> Bytes

-- | Fixed-width big-endian reads, or -1 when the string is too short. The
-- | decoded values are unsigned, so -1 is unambiguous.
foreign import readUint16BE :: Bytes -> Int -> Int
foreign import readUint64BE :: Bytes -> Int -> Int
foreign import readUint64LE :: Bytes -> Int -> Int

-- | Exclusive-or with a repeating key, which is WebSocket client masking. The
-- | rule itself lives in `Convex.Ws`; this is the bulk operation, so a large
-- | frame is masked once instead of one immutable copy per byte.
foreign import xorRepeating :: Bytes -> Bytes -> Bytes

foreign import base64Encode :: Bytes -> String

-- | Decode, answering an empty string when the text is not valid base64.
-- | Callers check the decoded length, which is fixed for every use here.
foreign import base64Decode :: String -> Bytes

foreign import sha1 :: Bytes -> Bytes

-- | UTF-8 encode one Unicode scalar value, or the empty string when the value
-- | is a surrogate or out of range. JSON `\u` escapes reach this after the
-- | decoder has recombined any surrogate pair.
foreign import codepointToBytes :: Int -> Bytes

-- | Offset of the next byte inside a JSON string that needs a decision: a
-- | quote, a backslash, or a control character below 0x20. Returns the size of
-- | the string when the rest is ordinary text. Scanning in Erlang keeps the
-- | common case — a long run of plain characters — a single pass.
foreign import jsonStringStop :: Bytes -> Int -> Int

-- | Offset of the next byte that is not JSON whitespace.
foreign import skipWhitespace :: Bytes -> Int -> Int
