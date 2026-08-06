## NDJSON adapter used only by the shared black-box controller.
## Stdout or the accepted TCP stream is reserved for protocol events.  Human
## diagnostics go to stderr so the canonical example remains clean.

import std/[json, locks, net, os, strutils, tables]
import ../../convex

const
  adapterProtocolVersion = 1
  maxAdapterEventBytes = 2 * 1024 * 1024 + 64 * 1024

var outputLock: Lock
var controller: Socket
var activeRelays: Table[string, uint64]

type
  AdapterSubscription = object
    subscription: LiveSubscription
    generation: uint64

  RelayArgs = object
    subscriptionId: string
    generation: uint64
    updates: ptr Channel[LiveUpdate]

proc writeEncoded(encoded: string) {.gcsafe.} =
  if encoded.len > maxAdapterEventBytes:
    stderr.writeLine("adapter event exceeds bounded output budget")
    return
  acquire(outputLock)
  defer: release(outputLock)
  if not controller.isNil:
    controller.send(encoded)
  else:
    stdout.write(encoded)
    stdout.flushFile()

proc emit(node: JsonNode) =
  writeEncoded($node & "\n")

proc activateRelay(subscriptionId: string; generation: uint64) =
  acquire(outputLock)
  activeRelays[subscriptionId] = generation
  release(outputLock)

proc invalidateRelay(subscriptionId: string; generation: uint64) =
  acquire(outputLock)
  if activeRelays.hasKey(subscriptionId) and activeRelays[subscriptionId] == generation:
    activeRelays.del(subscriptionId)
  release(outputLock)

proc emitRelay(subscriptionId: string; generation: uint64; node: JsonNode) =
  let encoded = $node & "\n"
  if encoded.len > maxAdapterEventBytes:
    return
  acquire(outputLock)
  defer: release(outputLock)
  if not activeRelays.hasKey(subscriptionId) or activeRelays[subscriptionId] != generation:
    return
  if not controller.isNil:
    controller.send(encoded)
  else:
    stdout.write(encoded)
    stdout.flushFile()

proc wakeRelay(subscription: LiveSubscription) =
  ## The adapter owns the relay lifetime.  Send its private marker directly so
  ## a blocked relay wakes even if the Live worker is already stopping.
  let marker = LiveUpdate(isError: true, errorName: "__closed__")
  if not subscription.updates[].trySend(marker):
    discard subscription.updates[].tryRecv()
    discard subscription.updates[].trySend(marker)

proc relayUpdates(args: RelayArgs) {.thread, gcsafe.} =
  ## The owner sends a closed marker before retiring a subscription.  The
  ## relay can therefore block efficiently without ever closing a channel
  ## underneath a parked receiver.
  while true:
    try:
      let update = args.updates[].recv()
      if update.isError and update.errorName == "__closed__":
        break
      var eventOut = %*{
        "type": "subscription",
        "subscriptionId": args.subscriptionId
      }
      if update.isError:
        var errorOut = %*{
          "name": update.errorName,
          "message": update.errorMessage
        }
        if update.errorData.len > 0:
          errorOut["data"] = parseJson(update.errorData)
        eventOut["error"] = errorOut
      else:
        eventOut["value"] = parseJson(update.value)
      if update.logs.len > 0:
        let logs = parseJson(update.logs)
        if logs.kind == JArray and logs.len > 0:
          eventOut["logs"] = logs
      emitRelay(args.subscriptionId, args.generation, eventOut)
    except CatchableError:
      break

proc failureEvent(id, subscriptionId, name, message: string; data = "";
    logs = ""): JsonNode =
  result = newJObject()
  if subscriptionId.len == 0:
    result["id"] = %id
    result["type"] = %"error"
  else:
    result["type"] = %"subscription"
    result["subscriptionId"] = %subscriptionId
  var errorOut = %*{"name": name, "message": message}
  if data.len > 0:
    errorOut["data"] = parseJson(data)
  result["error"] = errorOut
  if logs.len > 0:
    let parsedLogs = parseJson(logs)
    if parsedLogs.kind == JArray and parsedLogs.len > 0:
      result["logs"] = parsedLogs

proc emitFailure(id, subscriptionId: string; error: ref CatchableError) =
  var name = "Error"
  var data = ""
  var logs = ""
  if error of FunctionError:
    name = "FunctionError"
    let functionError = cast[ref FunctionError](error)
    if functionError.hasData:
      data = $functionError.data
    if functionError.logs.len > 0:
      logs = $(%functionError.logs)
  elif error of ProtocolError:
    name = "ProtocolError"
  elif error of TransportError:
    name = "TransportError"
  emit(failureEvent(id, subscriptionId, name, error.msg, data, logs))

iterator commandLines(): string =
  if controller.isNil:
    for line in stdin.lines:
      yield line
  else:
    while true:
      let line = controller.recvLine()
      if line.len == 0:
        break
      yield line

proc ensureClient(client: var Client): Client =
  if client.isNil:
    let deployment = getEnv("CONVEX_URL")
    if deployment.len == 0:
      raise newException(TransportError, "CONVEX_URL is required")
    client = newClient(deployment, getEnv("CONVEX_AUTH_TOKEN"))
  return client

proc main() =
  initLock(outputLock)
  activeRelays = initTable[string, uint64]()
  var client: Client
  var subscriptions = initTable[string, AdapterSubscription]()
  var nextGeneration: uint64 = 0

  for line in commandLines():
    if line.strip.len == 0:
      continue
    var command: JsonNode
    try:
      command = parseJson(line)
      if command.kind != JObject:
        raise newException(ValueError, "adapter command must be an object")
    except CatchableError as error:
      emitFailure("", "", newException(ProtocolError,
        "malformed adapter command: " & error.msg))
      continue

    let id = if command.hasKey("id"): command["id"].getStr else: ""
    let operation = if command.hasKey("op"): command["op"].getStr else: ""
    try:
      case operation
      of "hello":
        if not command.hasKey("protocolVersion") or
            command["protocolVersion"].getInt != adapterProtocolVersion:
          raise newException(ProtocolError, "unsupported adapter protocol version")
        emit(%*{
          "protocolVersion": adapterProtocolVersion,
          "id": id,
          "type": "ready",
          "language": "nim",
          "implementation": "native-nim-2.2.4",
          "runtime": NimVersion
        })
      of "query", "mutation", "action":
        let activeClient = ensureClient(client)
        let args = if command.hasKey("args"): command["args"] else: newJObject()
        let answer = case operation
          of "query": activeClient.query(command["path"].getStr, args)
          of "mutation": activeClient.mutation(command["path"].getStr, args)
          else: activeClient.action(command["path"].getStr, args)
        var eventOut = %*{"id": id, "type": "result", "value": answer.value}
        if answer.logs.len > 0:
          eventOut["logs"] = %answer.logs
        emit(eventOut)
      of "setAuth":
        let activeClient = ensureClient(client)
        activeClient.setAuth(if command.hasKey("token"): command["token"].getStr else: "")
        emit(%*{"id": id, "type": "ack"})
      of "subscribe":
        if not command.hasKey("subscriptionId"):
          raise newException(ProtocolError, "subscriptionId is required")
        let subscriptionId = command["subscriptionId"].getStr
        if subscriptions.hasKey(subscriptionId):
          let old = subscriptions[subscriptionId]
          invalidateRelay(subscriptionId, old.generation)
          old.subscription.close()
          wakeRelay(old.subscription)
          subscriptions.del(subscriptionId)
        let activeClient = ensureClient(client)
        let args = if command.hasKey("args"): command["args"] else: newJObject()
        let subscription = activeClient.subscribe(command["path"].getStr, args)
        nextGeneration.inc
        let generation = nextGeneration
        subscriptions[subscriptionId] = AdapterSubscription(
          subscription: subscription, generation: generation)
        activateRelay(subscriptionId, generation)
        emit(%*{"id": id, "type": "ack"})
        var relay: Thread[RelayArgs]
        createThread(relay, relayUpdates, RelayArgs(subscriptionId: subscriptionId,
          generation: generation, updates: subscription.updates))
      of "unsubscribe":
        if command.hasKey("subscriptionId"):
          let subscriptionId = command["subscriptionId"].getStr
          if subscriptions.hasKey(subscriptionId):
            let current = subscriptions[subscriptionId]
            invalidateRelay(subscriptionId, current.generation)
            current.subscription.close()
            wakeRelay(current.subscription)
            subscriptions.del(subscriptionId)
        emit(%*{"id": id, "type": "ack"})
      of "debugDisconnect":
        when defined(convexadapter):
          let message = ensureClient(client).debugDisconnectForAdapter()
          if message.len > 0:
            raise newException(TransportError, message)
          emit(%*{"id": id, "type": "ack"})
        else:
          raise newException(ProtocolError, "debugDisconnect is adapter-only")
      of "close":
        for subscription in subscriptions.values:
          wakeRelay(subscription.subscription)
        if not client.isNil:
          client.close()
        emit(%*{"id": id, "type": "closed"})
        break
      else:
        raise newException(ProtocolError, "unknown adapter operation: " & operation)
    except FunctionError as error:
      emitFailure(id, "", error)
    except ProtocolError as error:
      emitFailure(id, "", error)
    except TransportError as error:
      emitFailure(id, "", error)
    except CatchableError as error:
      emitFailure(id, "", error)

  for subscription in subscriptions.values:
    subscription.subscription.close()
  if not client.isNil:
    client.close()

let listenAddress = getEnv("ADAPTER_LISTEN")
if listenAddress.len > 0:
  let pieces = listenAddress.rsplit(":", maxsplit = 1)
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(parseInt(pieces[^1])), if pieces.len > 1: pieces[0] else: "0.0.0.0")
  server.listen()
  var accepted: owned(Socket)
  server.accept(accepted)
  controller = accepted
  main()
  controller.close()
  server.close()
else:
  main()
