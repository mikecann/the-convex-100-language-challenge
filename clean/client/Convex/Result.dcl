definition module Convex.Result

// A minimal `Ok`/error result used across this client's transport, HTTP, WS,
// and Live modules instead of Clean's exceptions, so every failure path is
// visible in a function's type and must be handled by its caller.
:: Result a = ROk a | RErr String

isROk :: !(Result a) -> Bool
resultMap :: !(a -> b) !(Result a) -> Result b
