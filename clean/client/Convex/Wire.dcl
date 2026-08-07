definition module Convex.Wire

from StdMaybe import :: Maybe(..)

// A hand-written JSON value type, parser, and printer. Clean's standard
// distribution has no JSON support, so this is the one place the wire format
// Convex's HTTP and Live endpoints both speak is implemented, and every
// higher module (HTTP, WS, Live, Client) builds and inspects `JSON` values
// through this module alone.
//
// `String` in Clean is an unboxed array of 8-bit `Char`, which is exactly a
// byte buffer; this module treats JSON text as bytes throughout rather than
// decoding to Unicode codepoints, and only escapes the ASCII control
// characters, the quote, and the backslash that the JSON grammar requires.
// A valid UTF-8 multi-byte sequence already appears in the source text as
// plain bytes >= 0x80 and is copied through unescaped, which is legal JSON.

:: JSON
	= JNull
	| JBool Bool
	| JInt Int
	| JReal Real
	| JString String
	| JArray [JSON]
	| JObject [(String, JSON)]

// Renders a JSON value as compact text (no inserted whitespace).
encodeJSON :: !JSON -> String

// Parses one JSON value from the whole string. Trailing whitespace after the
// value is tolerated; anything else left over, or a malformed document,
// yields `Nothing`.
parseJSON :: !String -> Maybe JSON

// Looks up a field in a JObject by key. `Nothing` both when the value is not
// an object and when the key is absent.
jsonLookup :: !String !JSON -> Maybe JSON

jsonAsString :: !JSON -> Maybe String
jsonAsBool :: !JSON -> Maybe Bool
jsonAsArray :: !JSON -> Maybe [JSON]
jsonAsObject :: !JSON -> Maybe [(String, JSON)]

// Accepts a whole number carried as either `JInt` or a `JReal` that is
// finite, mathematically integral, and inside a 64-bit range (Convex's JSON
// profile may represent a whole count as `0.0`). Fractional, non-finite, or
// out-of-range values are rejected rather than silently truncated.
jsonAsWholeInt :: !JSON -> Maybe Int

// Appends a trailing NUL byte, for the modules that hand a Clean `String` to
// a C function expecting a NUL-terminated string over the `ccall` FFI.
toCString :: !String -> String
