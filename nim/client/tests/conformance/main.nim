## NDJSON adapter used only by the shared black-box controller.
## Stdout or the accepted TCP stream is reserved for protocol events. Human
## diagnostics go to stderr so the canonical example remains clean.

import std/[atomics, json, net, os, posix, strutils, tables, times]
import ../../convex
import ./adapter_output
import ./adapter_protocol

const
  maxAdapterSubscriptions = 16
  relayShutdownDeadlineSeconds = 2.0

type
  CommandLine = object
    value: string
    oversized: bool

  AdapterSubscription = object
    subscription: LiveSubscription
    generation: uint64
    relay: ptr Thread[RelayArgs]
    relayDone: ptr Atomic[bool]

  RelayArgs = object
    subscriptionId: string
    generation: uint64
    updates: ptr LiveMailbox
    closed: ptr Atomic[bool]
    done: ptr Atomic[bool]
    output: OutputProducer

proc sharedAtomic(initial: bool): ptr Atomic[bool] =
  result = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  result[].store(initial)

proc enqueueNode(output: OutputProducer; node: JsonNode; id = "";
    subscriptionId = ""; generation: uint64 = 0; relayData = false): bool {.gcsafe.} =
  let encoded = $node & "\n"
  let outcome = output.enqueueEvent(encoded, subscriptionId, generation, relayData)
  if outcome == outputAccepted:
    return true
  if outcome in {outputClosed, outputFailed}:
    return false

  # Oversized or over-budget values become a small valid protocol error. The
  # output owner reserves control capacity separately from subscription data,
  # so the error can still make progress after a stopped-reader flood.
  let message = if outcome == outputTooLarge:
    "adapter event exceeds encoded output limit"
  else:
    "adapter output budget exhausted"
  let fallback = failureEvent(id, subscriptionId, "TransportError", message)
  result = output.enqueueEvent($fallback & "\n", subscriptionId, generation,
    false) == outputAccepted
  if not result:
    output.failOutput()

proc emitFailure(output: OutputProducer; id, subscriptionId: string;
    error: ref CatchableError): bool =
  var name = "Error"
  var data: JsonNode
  var logs: JsonNode
  if error of FunctionError:
    name = "FunctionError"
    let functionError = cast[ref FunctionError](error)
    if functionError.hasData:
      data = functionError.data
    if functionError.logs.len > 0:
      logs = %functionError.logs
  elif error of AdapterValidationError or error of ProtocolError:
    name = "ProtocolError"
  elif error of TransportError:
    name = "TransportError"
  result = enqueueNode(output,
    failureEvent(id, subscriptionId, name, error.msg, data, logs), id,
    subscriptionId)

proc relayUpdates(args: RelayArgs) {.thread.} =
  # Copy thread arguments once. Nim's thread trampoline owns the argument
  # storage, so a long-lived relay must not repeatedly dereference that storage
  # across reconnects and allocations.
  let subscriptionId = args.subscriptionId
  let generation = args.generation
  let updates = args.updates
  let closed = args.closed
  let done = args.done
  let output = args.output
  while true:
    var received = recvLiveFrame(updates, closed)
    if not received.available:
      break
    let update = liveUpdateFromFrame(received.frame)
    releaseLiveFrame(received.frame)
    try:
      var eventOut = %*{
        "type": "subscription",
        "subscriptionId": subscriptionId
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
      let logs = validatedLogs(update.logs)
      if not logs.isNil:
        eventOut["logs"] = logs
      if not enqueueNode(output, eventOut,
          subscriptionId = subscriptionId,
          generation = generation, relayData = true):
        break
    except CatchableError as error:
      let eventOut = failureEvent("", subscriptionId, "ProtocolError",
        "invalid Live relay payload: " & error.msg)
      if not enqueueNode(output, eventOut,
          subscriptionId = subscriptionId,
          generation = generation):
        break
  drainLiveMailbox(updates)
  done[].store(true)

proc stopSubscription(current: var AdapterSubscription): string =
  try:
    current.subscription.close()
  except CatchableError as error:
    result = error.msg
  let deadline = epochTime() + relayShutdownDeadlineSeconds
  while epochTime() < deadline and not current.relayDone[].load:
    sleep(1)
  if current.relayDone[].load:
    joinThread(current.relay[])
    deallocShared(current.relay)
    current.relay = nil
    # A timed-out owner can still hold the mailbox pointers. Only release
    # shared storage after close's owner acknowledgement is a real barrier.
    if result.len == 0:
      current.subscription.releaseAdapterSubscription()
  elif result.len == 0:
    result = "adapter relay did not stop before deadline"

proc stopSubscription(subscriptionId: string; current: var AdapterSubscription;
    output: OutputProducer): string =
  let outcome = output.invalidateRelay(subscriptionId, current.generation)
  if outcome != outputAccepted:
    result = "could not reserve relay invalidation barrier"
  let closeError = stopSubscription(current)
  if result.len == 0:
    result = closeError

iterator commandLines(controller: Socket; output: AdapterOutput): CommandLine =
  ## Read NDJSON incrementally. stdio.readLine and Socket.recvLine allocate the
  ## whole line before schema validation, which lets an untrusted controller
  ## bypass the declared command budget.
  let inputDescriptor = if controller.isNil: cint(0)
    else: cint(controller.getFd)
  var buffered = ""
  var discardingOversized = false
  var reachedEof = false
  while not reachedEof and not output.failed():
    var descriptor = TPollfd(fd: inputDescriptor, events: POLLIN)
    let ready = poll(addr descriptor, Tnfds(1), 100)
    if ready < 0:
      if errno == EINTR:
        continue
      break
    if ready == 0:
      continue
    var chunk = newString(8 * 1024)
    let count = posix.read(inputDescriptor, chunk[0].addr, chunk.len)
    if count < 0:
      if errno in {EINTR, EAGAIN, EWOULDBLOCK}:
        continue
      break
    if count == 0:
      reachedEof = true
      break
    chunk.setLen(int(count))
    var cursor = 0
    while cursor < chunk.len:
      let newline = chunk.find('\n', cursor)
      let finish = if newline < 0: chunk.len else: newline
      let piece = chunk[cursor ..< finish]
      if not discardingOversized:
        if piece.len > maxAdapterCommandBytes - buffered.len:
          buffered.setLen(0)
          discardingOversized = true
        else:
          buffered.add(piece)
      if newline >= 0:
        if discardingOversized:
          yield CommandLine(oversized: true)
        else:
          if buffered.endsWith("\r"):
            buffered.setLen(buffered.len - 1)
          yield CommandLine(value: buffered)
        buffered.setLen(0)
        discardingOversized = false
        cursor = newline + 1
      else:
        cursor = chunk.len
  if discardingOversized:
    yield CommandLine(oversized: true)
  elif buffered.len > 0:
    yield CommandLine(value: buffered)

proc ensureClient(client: var Client): Client =
  if client.isNil:
    let deployment = getEnv("CONVEX_URL")
    if deployment.len == 0:
      raise newException(TransportError, "CONVEX_URL is required")
    client = newClient(deployment, getEnv("CONVEX_AUTH_TOKEN"))
  result = client

proc runAdapter(controller: Socket; outputDescriptor: cint; socketOutput: bool) =
  let output = newAdapterOutput(outputDescriptor, socketOutput)
  let producer = output.producer
  var client: Client
  var subscriptions = initTable[string, AdapterSubscription]()
  var nextGeneration: uint64 = 0
  var closeReceived = false

  for input in commandLines(controller, output):
    if input.oversized:
      if not emitFailure(producer, "", "", commandInputLimitError()):
        break
      continue
    let line = input.value
    if line.strip.len == 0:
      continue
    var command: AdapterCommand
    try:
      command = parseAdapterCommand(line)
    except AdapterValidationError as error:
      if not emitFailure(producer, error.commandId, "", error):
        break
      continue

    try:
      case command.operation
      of "hello":
        if not enqueueNode(producer, %*{
            "protocolVersion": adapterProtocolVersion,
            "id": command.id,
            "type": "ready",
            "language": "nim",
            "implementation": "native-nim-2.2.4",
            "runtime": NimVersion
          }, command.id):
          break
      of "query", "mutation", "action":
        let activeClient = ensureClient(client)
        let answer = case command.operation
          of "query": activeClient.query(command.node["path"].getStr,
            command.node["args"])
          of "mutation": activeClient.mutation(command.node["path"].getStr,
            command.node["args"])
          else: activeClient.action(command.node["path"].getStr,
            command.node["args"])
        var eventOut = %*{
          "id": command.id,
          "type": "result",
          "value": answer.value
        }
        if answer.logs.len > 0:
          eventOut["logs"] = %answer.logs
        if not enqueueNode(producer, eventOut, command.id):
          break
      of "setAuth":
        ensureClient(client).setAuth(command.node["token"].getStr)
        if not enqueueNode(producer,
            %*{"id": command.id, "type": "ack"}, command.id):
          break
      of "subscribe":
        let subscriptionId = command.subscriptionId
        if subscriptions.hasKey(subscriptionId):
          var old = subscriptions[subscriptionId]
          subscriptions.del(subscriptionId)
          let stopError = stopSubscription(subscriptionId, old, producer)
          if stopError.len > 0:
            raise newException(TransportError, stopError)
        elif subscriptions.len >= maxAdapterSubscriptions:
          raise newException(TransportError,
            "adapter subscription limit reached")

        # Client.subscribe returns only after the owner has written Add. This
        # makes the adapter acknowledgement a real activation barrier.
        let subscription = ensureClient(client).subscribe(
          command.node["path"].getStr, command.node["args"])
        subscription.markAdapterRelay()
        nextGeneration.inc
        let generation = nextGeneration
        let relayDone = sharedAtomic(false)
        if producer.activateRelay(subscriptionId, generation) != outputAccepted:
          subscription.close()
          subscription.releaseAdapterSubscription()
          raise newException(TransportError,
            "could not reserve relay activation barrier")
        if not enqueueNode(producer,
            %*{"id": command.id, "type": "ack"}, command.id):
          subscription.close()
          subscription.releaseAdapterSubscription()
          raise newException(TransportError,
            "could not reserve subscribe acknowledgement")
        let relay = cast[ptr Thread[RelayArgs]](
          allocShared0(sizeof(Thread[RelayArgs])))
        createThread(relay[], relayUpdates, RelayArgs(
          subscriptionId: subscriptionId, generation: generation,
          updates: subscription.updates, closed: subscription.closed,
          done: relayDone, output: producer))
        subscriptions[subscriptionId] = AdapterSubscription(
          subscription: subscription, generation: generation,
          relay: relay, relayDone: relayDone)
      of "unsubscribe":
        let subscriptionId = command.subscriptionId
        if subscriptions.hasKey(subscriptionId):
          var current = subscriptions[subscriptionId]
          subscriptions.del(subscriptionId)
          let stopError = stopSubscription(subscriptionId, current, producer)
          if stopError.len > 0:
            raise newException(TransportError, stopError)
        if not enqueueNode(producer,
            %*{"id": command.id, "type": "ack"}, command.id):
          break
      of "debugDisconnect":
        when defined(convexadapter):
          let message = ensureClient(client).debugDisconnectForAdapter()
          if message.len > 0:
            raise newException(TransportError, message)
          if not enqueueNode(producer,
              %*{"id": command.id, "type": "ack"}, command.id):
            break
        else:
          raise newException(ProtocolError,
            "debugDisconnect is adapter-only")
      of "close":
        var closeError = ""
        for subscriptionId, stored in subscriptions.mpairs:
          let error = stopSubscription(subscriptionId, stored, producer)
          if closeError.len == 0:
            closeError = error
        subscriptions.clear()
        if not client.isNil:
          try:
            client.close()
          except CatchableError as error:
            if closeError.len == 0:
              closeError = error.msg
        if closeError.len > 0:
          discard emitFailure(producer, command.id, "",
            newException(TransportError, closeError))
        else:
          discard enqueueNode(producer,
            %*{"id": command.id, "type": "closed"}, command.id)
        closeReceived = true
        break
      else:
        raise newException(ProtocolError, "unknown adapter operation")
    except CatchableError as error:
      if not emitFailure(producer, command.id, "", error):
        break

  if not closeReceived:
    for subscriptionId, stored in subscriptions.mpairs:
      discard stopSubscription(subscriptionId, stored, producer)
    subscriptions.clear()
    if not client.isNil:
      try:
        client.close()
      except CatchableError:
        discard
  if not output.close():
    stderr.writeLine("adapter output owner did not stop before deadline")
    quit(1)

let listenAddress = getEnv("ADAPTER_LISTEN")
if listenAddress.len > 0:
  let pieces = listenAddress.rsplit(":", maxsplit = 1)
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(parseInt(pieces[^1])),
    if pieces.len > 1: pieces[0] else: "0.0.0.0")
  server.listen()
  let (_, boundPort) = server.getLocalAddr()
  # TCP mode has no stdout readiness message because stdout belongs to NDJSON.
  # A controller test can wait on this stderr barrier without guessing sleeps.
  stderr.writeLine("adapter-listening:" & $int(boundPort))
  stderr.flushFile()
  var accepted: owned(Socket)
  server.accept(accepted)
  runAdapter(accepted, cint(accepted.getFd), true)
  accepted.close()
  server.close()
else:
  runAdapter(nil, cint(1), false)
