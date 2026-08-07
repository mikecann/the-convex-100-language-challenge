module ChapelConvexAdapter {
  use IO;
  use Time;
  use Convex;
  use ConvexTransport;

  private param maxRecords = 16;
  private param maxOutputBytes = 8 * 1024 * 1024;
  private param maximumAdapterSubscriptions = 64;
  config param adapterGenerationSelfTest = false;
  config param adapterCloseBudgetSelfTest = false;
  private var relayDequeued: sync bool;
  private var relayResume: sync bool;
  private var relayTaskDone: sync bool;
  private var closeBudgetWriterStopped: atomic bool;
  private var closeBudgetOwnerStopped: atomic bool;

  private proc errorObject(const ref failure: convexFailure): string {
    return "{\"name\":" + jsonQuote(failure.name) + ",\"message\":" +
      jsonQuote(failure.message) +
      (if failure.dataJson.numBytes > 0 then
         ",\"data\":" + failure.dataJson else "") + "}";
  }

  private proc errorEvent(id: string, failure: convexFailure): string {
    return "{" + (if id.numBytes > 0 then "\"id\":" + jsonQuote(id) + ","
                  else "") + "\"type\":\"error\",\"error\":" +
                  errorObject(failure) +
                  (if failure.logsJson != "[]" then
                     ",\"logs\":" + failure.logsJson else "") + "}";
  }

  private proc retainFirstFailure(ref first: convexFailure,
                                  candidate: convexFailure) {
    if !first.isPresent && candidate.isPresent then first = candidate;
  }

  class Output {
    const fd: int;
    const readFd: int;
    var guard: atomic bool;
    var started: atomic bool;
    var closing: atomic bool;
    var stopped: atomic bool;
    var failed: atomic bool;
    var drainDeadline: atomic int(64);
    var records: [0..<maxRecords] string;
    var subscriptionIds: [0..<maxRecords] string;
    var generations: [0..<maxRecords] uint(64);
    var kinds: [0..<maxRecords] int;
    var costs: [0..<maxRecords] int;
    var queueStart = 0;
    var queueCount = 0;
    var outstanding = 0;
    var queueBytes = 0;
    var activeIds: [0..<maximumAdapterSubscriptions] string;
    var activeGenerations: [0..<maximumAdapterSubscriptions] uint(64);

    proc init(fd: int, readFd: int) {
      this.fd = fd;
      this.readFd = readFd;
    }

    proc acquire() {
      while guard.testAndSet() do sleep(0.0005);
    }
    proc release() { guard.clear(); }

    proc enqueue(kind: int, encoded: string, subscriptionId: string,
                             generation: uint(64)): bool {
      const cost = encoded.numBytes + 1024;
      acquire();
      if closing.read() || failed.read() || outstanding == maxRecords ||
         queueBytes + cost > maxOutputBytes {
        failed.write(true);
        closing.write(true);
        release();
        interruptFd(readFd);
        return false;
      }
      const entryIndex = (queueStart + queueCount) % maxRecords;
      kinds[entryIndex] = kind;
      records[entryIndex] = encoded;
      subscriptionIds[entryIndex] = subscriptionId;
      generations[entryIndex] = generation;
      costs[entryIndex] = cost;
      queueCount += 1;
      outstanding += 1;
      queueBytes += cost;
      release();
      return true;
    }

    proc event(encoded: string): bool do return enqueue(0, encoded, "", 0);
    proc relay(encoded: string, subscriptionId: string,
                   generation: uint(64)): bool {
      return enqueue(0, encoded, subscriptionId, generation);
    }
    proc activate(subscriptionId: string, generation: uint(64)): bool {
      return enqueue(1, "", subscriptionId, generation);
    }
    proc invalidate(subscriptionId: string, generation: uint(64)): bool {
      return enqueue(2, "", subscriptionId, generation);
    }

    proc setActive(id: string, generation: uint(64)) {
      for entryIndex in activeIds.domain do if activeIds[entryIndex] == id ||
          activeIds[entryIndex].numBytes == 0 {
        activeIds[entryIndex] = id;
        activeGenerations[entryIndex] = generation;
        return;
      }
    }

    proc invalidateActive(id: string, generation: uint(64)) {
      for entryIndex in activeIds.domain do if activeIds[entryIndex] == id &&
          activeGenerations[entryIndex] == generation {
        activeIds[entryIndex] = "";
        activeGenerations[entryIndex] = 0;
        return;
      }
    }

    proc isActive(id: string, generation: uint(64)): bool {
      if generation == 0 then return true;
      for entryIndex in activeIds.domain do if activeIds[entryIndex] == id &&
          activeGenerations[entryIndex] == generation then return true;
      return false;
    }

    proc setDrainDeadline(deadline: int(64)) {
      const current = drainDeadline.read();
      if current == 0 || deadline < current then drainDeadline.write(deadline);
    }

    proc run() {
      while true {
        acquire();
        if queueCount == 0 {
          const shouldStop = closing.read();
          release();
          if shouldStop then break;
          sleep(0.001);
          continue;
        }
        const entryIndex = queueStart;
        const kind = kinds[entryIndex];
        const encoded = records[entryIndex];
        const id = subscriptionIds[entryIndex];
        const generation = generations[entryIndex];
        const cost = costs[entryIndex];
        records[entryIndex] = "";
        subscriptionIds[entryIndex] = "";
        queueStart = (queueStart + 1) % maxRecords;
        queueCount -= 1;
        release();

        if kind == 1 then setActive(id, generation);
        else if kind == 2 then invalidateActive(id, generation);
        else if !failed.read() && isActive(id, generation) {
          const configuredDeadline = drainDeadline.read();
          const writeDeadline = if configuredDeadline > 0 then
            min(monotonicMillis() + 250, configuredDeadline)
          else monotonicMillis() + 250;
          const errorMessage = writeLine(fd, encoded, writeDeadline);
          if errorMessage.numBytes > 0 {
            failed.write(true);
            interruptFd(readFd);
          }
        }
        acquire();
        queueBytes -= cost;
        outstanding -= 1;
        release();
        if failed.read() then closing.write(true);
      }
      stopped.write(true);
    }

    proc close(timeoutSeconds: real = 0.25): convexFailure {
      closing.write(true);
      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      setDrainDeadline(deadline);
      while monotonicMillis() < deadline && !stopped.read() do sleep(0.001);
      if !stopped.read() then return transportFailureForAdapter(
        "timed out joining the adapter output writer"
      );
      if failed.read() then return transportFailureForAdapter(
        "adapter output writer failed"
      );
      return new convexFailure();
    }
  }

  private proc startOutput(in output: shared Output) {
    if !output.started.exchange(true) then
      begin with (in output) output.run();
  }

  record adapterSubscription {
    var id = "";
    var subscription: shared Subscription? = nil;
    var generation: uint(64) = 0;
  }

  private proc relay(subscriptionId: string, generation: uint(64),
                     subscription: borrowed Subscription,
                     output: borrowed Output) {
    while true {
      const update = subscription.next(0.1);
      if update.closed then return;
      if !update.available then continue;
      if adapterGenerationSelfTest && update.valueJson == "{\"paused\":true}" {
        relayDequeued.writeEF(true);
        relayResume.readFE();
      }
      const event = "{\"type\":\"subscription\",\"subscriptionId\":" +
        jsonQuote(subscriptionId) +
        (if update.failure.isPresent then
           ",\"error\":" + errorObject(update.failure)
         else ",\"value\":" + update.valueJson) +
        (if update.logsJson != "[]" then ",\"logs\":" + update.logsJson
         else "") + "}";
      if !output.relay(event, subscriptionId, generation) then return;
    }
  }

  proc runAdapter(readFd: int, writeFd: int): convexFailure {
    var output = new shared Output(writeFd, readFd);
    startOutput(output);
    var client: owned Client? = nil;
    var subscriptions: [0..<maximumAdapterSubscriptions] adapterSubscription;
    var nextGeneration: uint(64) = 0;
    var environmentAuthFailure: convexFailure;
    var teardownDeadline: int(64) = 0;
    var closeRequested = false;
    var closeId = "";
    var firstCloseFailure: convexFailure;
    var testOwner: shared LiveHandle? = nil;
    var testManager: shared LiveManager? = nil;
    if adapterCloseBudgetSelfTest {
      client = new owned Client("http://127.0.0.1:1");
      testManager = new shared LiveManager("ws://127.0.0.1:1", "test");
      client!.live = testManager;
      testOwner = testManager!.handle;
    }

    proc ensureClient(): bool {
      if client != nil then return true;
      const url = environment("CONVEX_URL");
      if url.numBytes == 0 then return false;
      client = new owned Client(url);
      const token = environment("CONVEX_AUTH_TOKEN");
      if token.numBytes > 0 {
        const failure = client!.setAuth(token);
        if failure.isPresent {
          environmentAuthFailure = failure;
          client = nil;
          return false;
        }
      }
      return true;
    }

    proc clientSetupFailure(message: string): convexFailure {
      if environmentAuthFailure.isPresent then return environmentAuthFailure;
      return protocolFailureForAdapter(message);
    }

    while true {
      if output.failed.read() then break;
      const (status, command, readError) = readLine(readFd, 2 * 1024 * 1024);
      if status == 0 then break;
      if status < 0 {
        if status == -2 {
          output.event(errorEvent("", protocolFailureForAdapter(readError)));
          continue;
        } else if !output.failed.read() then
          output.event(errorEvent("", transportFailureForAdapter(readError)));
        break;
      }
      const validation = validateAdapterCommand(command);
      if !validation.ok {
        output.event(errorEvent(validation.safeId,
          protocolFailureForAdapter(validation.errorMessage)));
        continue;
      }
      const (hasOperation, operation) = jsonString(command, "op");
      const (hasId, id) = jsonString(command, "id");
      if !hasOperation {
        output.event(errorEvent("", protocolFailureForAdapter(
          "adapter command omitted op")));
        continue;
      }

      if operation == "hello" {
        const (hasVersion, version) = jsonUInt32(command, "protocolVersion");
        if !hasId || !hasVersion || version != 1 {
          output.event(errorEvent(if hasId then id else "",
            protocolFailureForAdapter(
              "unsupported adapter protocol version"
            )));
        } else {
          output.event("{\"protocolVersion\":1,\"id\":" + jsonQuote(id) +
            ",\"type\":\"ready\",\"language\":\"chapel\"," +
            "\"implementation\":\"native-chapel-2.8.0\"," +
            "\"runtime\":\"chapel-2.8.0\"}");
        }
        continue;
      }

      if operation == "query" || operation == "mutation" ||
         operation == "action" {
        const (hasPath, path) = jsonString(command, "path");
        const (hasArgs, argsJson) = jsonRaw(command, "args");
        if !hasId || !hasPath || !hasArgs || !ensureClient() {
          output.event(errorEvent(if hasId then id else "",
            clientSetupFailure(
              "invalid call command or missing CONVEX_URL")));
          continue;
        }
        var result: callResult;
        if operation == "query" then result = client!.query(path, argsJson);
        else if operation == "mutation" then
          result = client!.mutation(path, argsJson);
        else result = client!.action(path, argsJson);
        if result.ok {
          output.event("{\"id\":" + jsonQuote(id) +
            ",\"type\":\"result\",\"value\":" + result.valueJson +
            ",\"logs\":" + result.logsJson + "}");
        } else output.event(errorEvent(id, result.failure));
        continue;
      }

      if operation == "setAuth" {
        const (hasToken, token) = jsonString(command, "token");
        if !hasId || !hasToken || !ensureClient() {
          output.event(errorEvent(if hasId then id else "",
            clientSetupFailure(
              "invalid setAuth command or missing CONVEX_URL")));
        } else {
          const failure = client!.setAuth(token);
          if failure.isPresent then output.event(errorEvent(id, failure));
          else output.event("{\"id\":" + jsonQuote(id) +
                            ",\"type\":\"ack\"}");
        }
        continue;
      }

      if operation == "subscribe" {
        const (hasSubscriptionId, subscriptionId) =
          jsonString(command, "subscriptionId");
        const (hasPath, path) = jsonString(command, "path");
        const (hasArgs, argsJson) = jsonRaw(command, "args");
        if !hasId || !hasSubscriptionId || !hasPath || !hasArgs ||
           (!adapterCloseBudgetSelfTest && !ensureClient()) {
          output.event(errorEvent(if hasId then id else "",
            clientSetupFailure(
              "invalid subscribe command or missing CONVEX_URL")));
          continue;
        }
        var slot = -1;
        for entryIndex in subscriptions.domain do
          if subscriptions[entryIndex].id == subscriptionId {
            const old = subscriptions[entryIndex];
            output.invalidate(old.id, old.generation);
            if old.subscription != nil then old.subscription!.close();
            subscriptions[entryIndex] = new adapterSubscription();
            slot = entryIndex;
            break;
          }
        if slot < 0 then for entryIndex in subscriptions.domain do
          if subscriptions[entryIndex].id.numBytes == 0 {
            slot = entryIndex;
            break;
          }
        if slot < 0 {
          output.event(errorEvent(id, protocolFailureForAdapter(
            "at most 64 adapter subscriptions are supported")));
          continue;
        }
        var subscription: shared Subscription? = nil;
        var failure: convexFailure;
        if adapterCloseBudgetSelfTest {
          subscription = new shared Subscription(
            slot:uint(32), path, argsJson
          );
          subscription!.handle = testOwner;
          subscription!.active.write(true);
          subscription!.addAcknowledged.write(1);
        } else {
          const (realSubscription, realFailure) =
            client!.subscribe(path, argsJson);
          subscription = realSubscription;
          failure = realFailure;
        }
        if failure.isPresent || subscription == nil {
          output.event(errorEvent(id, failure));
          continue;
        }
        nextGeneration += 1;
        subscriptions[slot] = new adapterSubscription(
          subscriptionId, subscription, nextGeneration
        );
        if adapterCloseBudgetSelfTest {
          // The close-budget build injects one blocked output after the real
          // command loop has populated all 64 table entries.
          if nextGeneration == 64 {
            var stalledValue = "x";
            for 1..20 do stalledValue += stalledValue;
            output.event(jsonQuote(stalledValue));
          }
        } else {
          output.activate(subscriptionId, nextGeneration);
          const relaySubscription = subscription;
          const relayOutput = output;
          // Explicit in-intents retain both shared objects for this
          // unstructured task after the command loop clears its table.
          begin with (in relaySubscription, in relayOutput) relay(
            subscriptionId, nextGeneration, relaySubscription!,
            relayOutput.borrow()
          );
          output.event("{\"id\":" + jsonQuote(id) +
                       ",\"type\":\"ack\"}");
        }
        continue;
      }

      if operation == "unsubscribe" {
        const (hasSubscriptionId, subscriptionId) =
          jsonString(command, "subscriptionId");
        if !hasId || !hasSubscriptionId {
          output.event(errorEvent(if hasId then id else "",
            protocolFailureForAdapter("invalid unsubscribe command")));
          continue;
        }
        for entryIndex in subscriptions.domain do
          if subscriptions[entryIndex].id == subscriptionId {
            const existing = subscriptions[entryIndex];
            /* Invalidation reaches the sole writer before the acknowledgement,
               so a relay paused after dequeue cannot cross this barrier. */
            output.invalidate(existing.id, existing.generation);
            if existing.subscription != nil then
              existing.subscription!.close();
            subscriptions[entryIndex] = new adapterSubscription();
            break;
          }
        output.event("{\"id\":" + jsonQuote(id) +
                     ",\"type\":\"ack\"}");
        continue;
      }

      if operation == "debugDisconnect" {
        if !hasId {
          output.event(errorEvent("", protocolFailureForAdapter(
            "debugDisconnect command omitted id")));
          continue;
        }
        if !ensureClient() {
          output.event(errorEvent(id, clientSetupFailure(
            "debugDisconnect requires CONVEX_URL")));
          continue;
        }
        const failure = client!.debugDisconnect();
        if failure.isPresent then output.event(errorEvent(id, failure));
        else output.event("{\"id\":" + jsonQuote(id) +
                          ",\"type\":\"ack\"}");
        continue;
      }

      if operation == "close" {
        if teardownDeadline == 0 then
          teardownDeadline = monotonicMillis() + 3000;
        output.setDrainDeadline(teardownDeadline);
        closeRequested = true;
        if hasId then closeId = id;
        if adapterCloseBudgetSelfTest {
          const retainedManager = testManager;
          begin with (in retainedManager) {
            sleep(0.2);
            retainedManager!.handle.stopped.write(true);
            retainedManager!.stopped.write(true);
          }
        }
        break;
      }

      output.event(errorEvent(if hasId then id else "",
        protocolFailureForAdapter("unknown adapter operation " + operation)));
    }

    if teardownDeadline == 0 then
      teardownDeadline = monotonicMillis() + 3000;
    output.setDrainDeadline(teardownDeadline);
    if output.failed.read() then retainFirstFailure(
      firstCloseFailure,
      transportFailureForAdapter("adapter output writer failed")
    );
    // Signal and join the Live owner first. This makes any in-flight dial see
    // closing before subscription waits can consume the shared deadline.
    if client != nil then retainFirstFailure(
      firstCloseFailure, client!.close(max(
        0.0, (teardownDeadline - monotonicMillis()):real / 1000.0
      ))
    );
    for entryIndex in subscriptions.domain do
      if subscriptions[entryIndex].id.numBytes > 0 {
        const existing = subscriptions[entryIndex];
        output.invalidate(existing.id, existing.generation);
        if existing.subscription != nil then retainFirstFailure(
          firstCloseFailure, existing.subscription!.close(max(
            0.0, (teardownDeadline - monotonicMillis()):real / 1000.0
          ))
        );
        subscriptions[entryIndex] = new adapterSubscription();
      }
    retainFirstFailure(firstCloseFailure, output.close(max(
      0.0, (teardownDeadline - monotonicMillis()):real / 1000.0
    )));

    if adapterCloseBudgetSelfTest {
      closeBudgetWriterStopped.write(output.stopped.read());
      closeBudgetOwnerStopped.write(
        testManager != nil && testManager!.stopped.read() &&
        testOwner != nil && testOwner!.stopped.read()
      );
    }

    if closeRequested {
      const terminal = if firstCloseFailure.isPresent then
        errorEvent(closeId, firstCloseFailure)
      else "{\"id\":" + jsonQuote(closeId) + ",\"type\":\"closed\"}";
      const terminalError = writeLine(writeFd, terminal, teardownDeadline);
      if terminalError.numBytes > 0 then retainFirstFailure(
        firstCloseFailure,
        transportFailureForAdapter("terminal adapter event: " + terminalError)
      );
    }
    return firstCloseFailure;
  }

  private proc protocolFailureForAdapter(message: string): convexFailure {
    return new convexFailure(FailureKind.Protocol, message);
  }

  private proc transportFailureForAdapter(message: string): convexFailure {
    return new convexFailure(FailureKind.Transport, message);
  }

  private proc runGenerationSelfTest() {
    var output = new shared Output(1, 0);
    assert(output.activate("same-id", 1));
    assert(output.relay("{\"marker\":\"before\"}", "same-id", 1));
    assert(output.invalidate("same-id", 1));
    assert(output.activate("same-id", 2));
    assert(output.relay("{\"marker\":\"stale\"}", "same-id", 1));
    assert(output.relay("{\"marker\":\"fresh\"}", "same-id", 2));
    startOutput(output);
    var paused = new shared Subscription(99:uint(32), "demo:paused", "{}");
    const pausedSubscription = paused;
    const pausedOutput = output;
    begin with (in pausedSubscription, in pausedOutput) {
      relay("paused-id", 7, pausedSubscription, pausedOutput.borrow());
      relayTaskDone.writeEF(true);
    }
    assert(output.activate("paused-id", 7));
    paused.push(new liveUpdate(
      available=true, hasValue=true, valueJson="{\"paused\":true}"
    ));
    relayDequeued.readFE();
    assert(output.invalidate("paused-id", 7));
    assert(output.event("{\"marker\":\"invalidation-ack\"}"));
    relayResume.writeEF(true);
    paused.close();
    relayTaskDone.readFE();
    assert(!output.close(1.0).isPresent);
    assert(output.stopped.read(), "shared Output owner did not stop");
  }

  proc closeBudgetOwnerDidStop(): bool do
    return closeBudgetOwnerStopped.read();

  proc closeBudgetWriterDidStop(): bool do
    return closeBudgetWriterStopped.read();

  proc main() {
    if adapterGenerationSelfTest {
      runGenerationSelfTest();
      return;
    }
    const listen = environment("ADAPTER_LISTEN");
    if listen.numBytes == 0 {
      const failure = runAdapter(0, 1);
      if failure.isPresent then try {
        stderr.writeln(errorEvent("", failure));
      } catch { }
      if failure.isPresent then exitProcess(1);
      return;
    }
    const (fd, errorMessage) = adapterAccept(listen);
    if fd < 0 {
      try {
        stderr.writeln("listen for conformance controller: ", errorMessage);
      } catch { }
      return;
    }
    const failure = runAdapter(fd, fd);
    closeFd(fd);
    if failure.isPresent then try {
      stderr.writeln(errorEvent("", failure));
    } catch { }
    if failure.isPresent then exitProcess(1);
  }
}
