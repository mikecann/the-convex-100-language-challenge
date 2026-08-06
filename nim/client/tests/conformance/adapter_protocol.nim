## Strict NDJSON command validation and schema-safe event construction.
##
## Keeping this separate from the executable makes malformed-input recovery
## testable without starting HTTP, Live, or a controller socket.

import std/[json, strutils]

const
  adapterProtocolVersion* = 1
  maxAdapterIdBytes* = 128
  maxAdapterCommandBytes* = 2 * 1024 * 1024 + 64 * 1024

type
  AdapterValidationError* = object of CatchableError
    commandId*: string

  AdapterCommand* = object
    node*: JsonNode
    id*: string
    operation*: string
    subscriptionId*: string

proc validationError(message: string; commandId = ""): ref AdapterValidationError =
  result = newException(AdapterValidationError, message)
  result.commandId = commandId

proc commandInputLimitError*(): ref AdapterValidationError =
  validationError("adapter command exceeds the input byte limit")

proc validId(node: JsonNode): bool =
  not node.isNil and node.kind == JString and node.getStr.len in 1 .. maxAdapterIdBytes

proc requireOnly(node: JsonNode; allowed: openArray[string]; commandId: string) =
  for key, _ in node.pairs:
    var found = false
    for candidate in allowed:
      if key == candidate:
        found = true
        break
    if not found:
      raise validationError("unexpected adapter command field: " & key, commandId)

proc requireString(node: JsonNode; key, commandId: string;
    minimum = 0; maximum = high(int)): string =
  if not node.hasKey(key) or node[key].kind != JString:
    raise validationError(key & " must be a string", commandId)
  result = node[key].getStr
  if result.len < minimum or result.len > maximum:
    raise validationError(key & " length is out of range", commandId)

proc requireArgs(node: JsonNode; commandId: string) =
  if not node.hasKey("args") or node["args"].kind != JObject:
    raise validationError("args must be an object", commandId)

proc parseAdapterCommand*(line: string): AdapterCommand =
  if line.len > maxAdapterCommandBytes:
    raise commandInputLimitError()
  let node = try:
    parseJson(line)
  except CatchableError as error:
    raise validationError("malformed adapter command: " & error.msg)
  if node.kind != JObject:
    raise validationError("adapter command must be an object")

  var commandId = ""
  if node.hasKey("id") and validId(node["id"]):
    commandId = node["id"].getStr
  if not node.hasKey("id") or not validId(node["id"]):
    raise validationError("id must be a 1 to 128 byte string")
  let operation = requireString(node, "op", commandId, minimum = 1)

  case operation
  of "hello":
    requireOnly(node, ["protocolVersion", "id", "op"], commandId)
    if not node.hasKey("protocolVersion") or
        node["protocolVersion"].kind != JInt or
        node["protocolVersion"].getInt != adapterProtocolVersion:
      raise validationError("unsupported adapter protocol version", commandId)
  of "query", "mutation", "action":
    requireOnly(node, ["id", "op", "path", "args"], commandId)
    discard requireString(node, "path", commandId, minimum = 3)
    requireArgs(node, commandId)
  of "setAuth":
    requireOnly(node, ["id", "op", "token"], commandId)
    discard requireString(node, "token", commandId)
  of "subscribe":
    requireOnly(node, ["id", "op", "subscriptionId", "path", "args"], commandId)
    result.subscriptionId = requireString(node, "subscriptionId", commandId,
      minimum = 1, maximum = maxAdapterIdBytes)
    discard requireString(node, "path", commandId, minimum = 1)
    requireArgs(node, commandId)
  of "unsubscribe":
    requireOnly(node, ["id", "op", "subscriptionId", "path", "args"], commandId)
    result.subscriptionId = requireString(node, "subscriptionId", commandId,
      minimum = 1, maximum = maxAdapterIdBytes)
    if node.hasKey("path"):
      discard requireString(node, "path", commandId)
    if node.hasKey("args") and node["args"].kind != JObject:
      raise validationError("args must be an object", commandId)
  of "close", "debugDisconnect":
    requireOnly(node, ["id", "op"], commandId)
  else:
    raise validationError("unknown adapter operation: " & operation, commandId)

  result.node = node
  result.id = commandId
  result.operation = operation

proc validatedLogs*(encoded: string): JsonNode =
  if encoded.len == 0:
    return nil
  result = try:
    parseJson(encoded)
  except CatchableError as error:
    raise validationError("invalid encoded logLines: " & error.msg)
  if result.kind != JArray:
    raise validationError("logLines must be an array")
  for line in result.getElems:
    if line.kind != JString:
      raise validationError("logLines must contain strings")
  if result.len == 0:
    result = nil

proc failureEvent*(id, subscriptionId, name, message: string;
    data: JsonNode = nil; logs: JsonNode = nil): JsonNode =
  result = newJObject()
  if subscriptionId.len > 0:
    result["type"] = %"subscription"
    result["subscriptionId"] = %subscriptionId
  else:
    result["type"] = %"error"
    if id.len > 0:
      result["id"] = %id
  var errorOut = %*{"name": name, "message": message}
  if not data.isNil:
    errorOut["data"] = data
  result["error"] = errorOut
  if not logs.isNil:
    result["logs"] = logs
