import std/[json, strutils, unittest]
import ./adapter_protocol

proc invalidEvent(line: string): JsonNode =
  try:
    discard parseAdapterCommand(line)
    raise newException(ValueError, "command unexpectedly validated")
  except AdapterValidationError as error:
    result = failureEvent(error.commandId, "", "ProtocolError", error.msg)

suite "Nim adapter command schema":
  test "malformed roots omit an unavailable id":
    for line in ["{", "[]", "null", "42"]:
      let event = invalidEvent(line)
      check event["type"].getStr == "error"
      check not event.hasKey("id")

  test "wrong, null, empty, and overlong ids are never coerced":
    for line in [
        "{\"id\":7,\"op\":\"close\"}",
        "{\"id\":null,\"op\":\"close\"}",
        "{\"id\":\"\",\"op\":\"close\"}",
        $(%*{"id": repeat("x", 129), "op": "close"})
      ]:
      check not invalidEvent(line).hasKey("id")

  test "valid ids survive other schema failures":
    for line in [
        "{\"id\":\"bad-op\",\"op\":9}",
        "{\"id\":\"extra\",\"op\":\"close\",\"extra\":true}",
        "{\"id\":\"null-token\",\"op\":\"setAuth\",\"token\":null}",
        "{\"id\":\"args\",\"op\":\"query\",\"path\":\"a:b\",\"args\":[]}",
        "{\"id\":\"version\",\"op\":\"hello\",\"protocolVersion\":1.0}"
      ]:
      let event = invalidEvent(line)
      check event["id"].getStr.len > 0
      check event["error"]["name"].getStr == "ProtocolError"

  test "subscription ids have the declared bound":
    let event = invalidEvent($(%*{
      "id": "request",
      "op": "subscribe",
      "subscriptionId": repeat("s", 129),
      "path": "demo:state",
      "args": newJObject()
    }))
    check event["id"].getStr == "request"
    check not event.hasKey("subscriptionId")

  test "a malformed command does not poison the next valid command":
    discard invalidEvent("{\"id\":\"bad\",\"op\":\"close\",\"extra\":0}")
    let command = parseAdapterCommand(
      "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}")
    check command.id == "hello"
    check command.operation == "hello"

  test "serialized optional fields are omitted and explicit null is retained":
    let missing = failureEvent("", "", "ProtocolError", "bad command")
    check not missing.hasKey("id")
    check not missing.hasKey("subscriptionId")
    check not missing.hasKey("logs")
    check not missing["error"].hasKey("data")
    let explicitNull = failureEvent("call", "", "FunctionError", "failed",
      newJNull(), %(@["one log"]))
    check explicitNull["id"].getStr == "call"
    check explicitNull["error"].hasKey("data")
    check explicitNull["error"]["data"].kind == JNull
    check explicitNull["logs"][0].getStr == "one log"

  test "encoded logLines must be an array of strings":
    expect AdapterValidationError:
      discard validatedLogs("null")
    expect AdapterValidationError:
      discard validatedLogs("[1]")
    check validatedLogs("[]").isNil
    check validatedLogs("[\"ok\"]")[0].getStr == "ok"
