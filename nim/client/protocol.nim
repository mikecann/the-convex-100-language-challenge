## Small, transport-independent protocol helpers.  Keeping these separate lets
## deterministic decoding regressions compile without the TLS/WebSocket stack.

import std/[base64, json, math]

proc timestampBytes*(value: string): string =
  try:
    result = decode(value)
  except CatchableError as error:
    raise newException(ValueError, "invalid timestamp: " & error.msg)
  if result.len != 8:
    raise newException(ValueError, "timestamp must decode to exactly 8 bytes")

proc compareTimestamps*(left, right: string): int =
  ## Convex timestamps are little-endian uint64 values encoded as base64.
  let leftBytes = timestampBytes(left)
  let rightBytes = timestampBytes(right)
  for index in countdown(7, 0):
    if leftBytes[index].uint8 > rightBytes[index].uint8:
      return 1
    if leftBytes[index].uint8 < rightBytes[index].uint8:
      return -1
  return 0

proc integralCount*(node: JsonNode): float =
  ## Accept 0.0 and 1.0, but reject strings, fractions, NaN, and overflow.
  if node.kind notin {JInt, JFloat}:
    raise newException(ValueError, "count must be a JSON number")
  let value = node.getFloat
  if value != value or value != floor(value) or
      abs(value) > 9_007_199_254_740_991.0:
    raise newException(ValueError, "count must be finite and integral")
  return value
