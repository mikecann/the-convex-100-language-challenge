||| Build identity for the demonstration client.
|||
||| The runtime string is a constant rather than something read at run time,
||| because a RefC executable carries no compiler to ask. The Docker build
||| asserts that the pinned compiler actually reports this version, so the
||| adapter's `ready` event cannot drift away from what produced the binary.
module Convex.Build

||| The roster language identifier the adapter reports.
export
languageId : String
languageId = "idris"

||| Sent as the `Convex-Client` header on HTTP and on the sync handshake.
export
clientVersion : String
clientVersion = "idris-convex-0.1.0"

||| Provenance reported by the adapter's `ready` event.
export
implementationName : String
implementationName = "native-idris2-refc"

||| The exact toolchain the Dockerfile pins and verifies.
export
runtimeVersion : String
runtimeVersion = "Idris 2 0.7.0 (refc backend)"
