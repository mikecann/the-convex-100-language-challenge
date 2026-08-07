' Wire-shape coverage for the adapter's events. The shared controller
' validates every emitted line against _shared/schemas/adapter.schema.json, so
' these checks prove the exact serialization here rather than discovering a
' shape mismatch during shared conformance.

#include once "adapter_core.bi"
#include once "testing.bi"

dim as ConvexFault fault
dim as string reason

' Every event must be a single line of valid JSON.
function IsSingleJsonLine(byref textLine as string) as boolean
  if instr(textLine, chr(10)) > 0 orelse instr(textLine, chr(13)) > 0 then
    return false
  end if
  dim as string why
  dim as JsonValue ptr node = JsonParse(textLine, why)
  if node = 0 then
    return false
  end if
  dim as boolean isObject = (node->kind = JSON_OBJECT)
  JsonFree(node)
  return isObject
end function

function HasMember(byref textLine as string, byref memberKey as string) as boolean
  dim as string why
  dim as JsonValue ptr node = JsonParse(textLine, why)
  if node = 0 then
    return false
  end if
  dim as boolean present = (JsonMember(node, memberKey) <> 0)
  JsonFree(node)
  return present
end function

function RepeatText(byref value as string, byval count as long) as string
  dim as StrBuf repeated
  for index as long = 1 to count
    repeated.Append(value)
  next
  return repeated.Take()
end function

function ShapeIsValid(byref commandText as string) as boolean
  dim as string parseReason
  ' COMMAND is a FreeBASIC built-in (command-line argument access), so the
  ' parsed value is named commandValue rather than command.
  dim as JsonValue ptr commandValue = JsonParse(commandText, parseReason)
  if commandValue = 0 then
    return false
  end if
  dim as string operation
  if not JsonStringField(commandValue, "op", operation) then
    JsonFree(commandValue)
    return false
  end if
  dim as boolean valid = CommandShapeValid(commandValue, operation, parseReason)
  JsonFree(commandValue)
  return valid
end function

' --- ready ----------------------------------------------------------------
dim as string ready = RenderReady("hello-1", "FreeBASIC 1.10.1")
Check(IsSingleJsonLine(ready), "ready is one JSON object on one line")
CheckEqual(ready, "{""protocolVersion"":1,""id"":""hello-1"",""type"":""ready""," & _
  """language"":""freebasic"",""implementation"":""native-freebasic-0.1.0""," & _
  """runtime"":""FreeBASIC 1.10.1""}", "ready reports version, language, provenance, runtime")
Check(len(AdapterRuntimeName()) > 0, "the runtime name is populated from the compiler")

' --- result ---------------------------------------------------------------
dim as JsonValue ptr value = JsonParse("{""count"":0,""lastLanguage"":null}", reason)
dim as JsonValue ptr logs = JsonParse("[""demo:echo received""]", reason)
dim as string resultLine = RenderResult("query-2", value, logs)
Check(IsSingleJsonLine(resultLine), "result is one JSON object on one line")
CheckEqual(resultLine, "{""id"":""query-2"",""type"":""result""," & _
  """value"":{""count"":0,""lastLanguage"":null},""logs"":[""demo:echo received""]}", _
  "result carries the value and log lines verbatim")
JsonFree(logs)

' A JSON null value is a value, not an absence, and must still be sent.
dim as JsonValue ptr nullValue = JsonNew(JSON_NULL)
CheckEqual(RenderResult("query-3", nullValue, 0), _
  "{""id"":""query-3"",""type"":""result"",""value"":null,""logs"":[]}", _
  "a null result value is transmitted as null with empty logs")
JsonFree(nullValue)
JsonFree(value)

' --- errors ---------------------------------------------------------------
FaultClear(fault)
FaultSet(fault, FAULT_FUNCTION, "Intentional conformance failure")
fault.hasData = true
fault.dataJson = "{""code"":""CLIENT_EXPECTED"",""message"":""nope""}"
dim as string errorLine = RenderError("failure-4", fault)
Check(IsSingleJsonLine(errorLine), "error is one JSON object on one line")
CheckEqual(errorLine, "{""id"":""failure-4"",""type"":""error"",""error"":" & _
  "{""name"":""FunctionError"",""message"":""Intentional conformance failure""," & _
  """data"":{""code"":""CLIENT_EXPECTED"",""message"":""nope""}}}", _
  "a structured function error carries its data through")

FaultClear(fault)
FaultSet(fault, FAULT_PROTOCOL, "adapter command is missing op")
dim as string plainError = RenderError("cmd-5", fault)
Check(not HasMember(plainError, "data"), _
  "an absent errorData is omitted rather than serialized as null")
Check(HasMember(plainError, "id"), "a known command id is echoed back")

' The schema forbids an empty id, so an unattributable failure omits it.
dim as string anonymousError = RenderError("", fault)
Check(IsSingleJsonLine(anonymousError), "an anonymous error is still one JSON line")
Check(not HasMember(anonymousError, "id"), "an absent id is omitted entirely")
CheckEqual(anonymousError, "{""type"":""error"",""error"":{""name"":""ProtocolError""," & _
  """message"":""adapter command is missing op""}}", "the anonymous error shape is exact")

' --- ack and closed -------------------------------------------------------
CheckEqual(RenderAck("sub-6"), "{""id"":""sub-6"",""type"":""ack""}", _
  "ack is minimal")
CheckEqual(RenderClosed("close-7"), "{""id"":""close-7"",""type"":""closed""}", _
  "closed is minimal")

' --- subscription events --------------------------------------------------
dim as JsonValue ptr liveValue = JsonParse("{""count"":1}", reason)
dim as string subscriptionLine = RenderSubscriptionValue("client-initial", liveValue, 0)
Check(IsSingleJsonLine(subscriptionLine), "a subscription event is one JSON line")
Check(not HasMember(subscriptionLine, "id"), _
  "a subscription event carries no command id")
CheckEqual(subscriptionLine, "{""type"":""subscription""," & _
  """subscriptionId"":""client-initial"",""value"":{""count"":1},""logs"":[]}", _
  "the subscription value shape is exact")
JsonFree(liveValue)

FaultClear(fault)
FaultSet(fault, FAULT_FUNCTION, "Increment the room to repair this reactive query")
fault.hasData = true
fault.dataJson = "{""code"":""ROOM_EMPTY""}"
dim as string subscriptionError = RenderSubscriptionError("client-repair", fault)
Check(not HasMember(subscriptionError, "value"), _
  "a failed subscription event carries no value")
CheckEqual(subscriptionError, "{""type"":""subscription""," & _
  """subscriptionId"":""client-repair"",""error"":{""name"":""FunctionError""," & _
  """message"":""Increment the room to repair this reactive query""," & _
  """data"":{""code"":""ROOM_EMPTY""}}}", "the subscription error shape is exact")

FaultClear(fault)
FaultSet(fault, FAULT_TRANSPORT, "server closed the Live WebSocket")
Check(not HasMember(RenderSubscriptionError("client-drop", fault), "data"), _
  "a transport failure event omits data")

' --- command ids ----------------------------------------------------------
Check(not ValidCommandId(""), "an empty command id is rejected")
Check(ValidCommandId("a"), "a one byte command id is accepted")
Check(not ValidCommandId("   "), "a blank command id is rejected")
Check(not ValidCommandId(chr(9, 10, 13)), "a control-whitespace command id is rejected")
Check(ValidCommandId(string(ADAPTER_MAX_ID_CODEPOINTS, "x")), _
  "a 128 code point command id is accepted")
Check(not ValidCommandId(string(ADAPTER_MAX_ID_CODEPOINTS + 1, "x")), _
  "a 129 code point command id is rejected")
dim as string astral = chr(&hf0, &h9f, &h98, &h80)
Check(ValidCommandId(RepeatText(astral, ADAPTER_MAX_ID_CODEPOINTS)), _
  "128 astral Unicode code points are accepted despite using more bytes")
Check(not ValidCommandId(RepeatText(astral, ADAPTER_MAX_ID_CODEPOINTS + 1)), _
  "129 astral Unicode code points are rejected")

' Every operation rejects additional properties before command-specific work.
Check(ShapeIsValid("{""id"":""h"",""op"":""hello"",""protocolVersion"":1}"), _
  "the exact hello command shape is accepted")
Check(not ShapeIsValid("{""id"":""h"",""op"":""hello"",""protocolVersion"":1," & _
  """extra"":true}"), "hello rejects additional properties")
Check(not ShapeIsValid("{""id"":""c"",""op"":""close"",""path"":""demo:state""}"), _
  "control commands reject operation fields they do not own")
Check(ShapeIsValid("{""id"":""q"",""op"":""query"",""path"":""demo:state""," & _
  """args"":{}}"), "the exact query command shape is accepted")

' Model a relay paused after dequeue but before it reaches the output gate.
' Replacement and unsubscribe invalidate this captured generation before ack.
dim as ulongint pausedGeneration = AdapterBeginGenerationFixture()
Check(AdapterGenerationCurrentForTest(pausedGeneration), _
  "a dequeued event starts with the current relay generation")
AdapterInvalidateGenerationFixture()
Check(not AdapterGenerationCurrentForTest(pausedGeneration), _
  "an invalidated relay cannot publish its already-dequeued event")

' --- escaping -------------------------------------------------------------
FaultClear(fault)
FaultSet(fault, FAULT_PROTOCOL, "quote "" backslash \ newline" & chr(10) & "end")
dim as string escaped = RenderError("escape-8", fault)
Check(IsSingleJsonLine(escaped), "a message with control characters stays on one line")
Check(instr(escaped, "\n") > 0, "a newline in a message is escaped rather than emitted raw")

end TestSummary("freebasic adapter")
