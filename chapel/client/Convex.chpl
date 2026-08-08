module Convex {
  use Time;
  use ConvexTransport;

  enum FailureKind { None, Function, Protocol, Transport, Closed }

  record convexFailure {
    var kind = FailureKind.None;
    var message = "";
    var dataJson = "";
    var logsJson = "[]";

    proc isPresent do return kind != FailureKind.None;
    proc name: string {
      select kind {
        when FailureKind.Function do return "FunctionError";
        when FailureKind.Protocol do return "ProtocolError";
        when FailureKind.Transport do return "TransportError";
        when FailureKind.Closed do return "Error";
        otherwise do return "Error";
      }
    }
  }

  record callResult {
    var ok = false;
    var valueJson = "";
    var logsJson = "[]";
    var failure: convexFailure;
  }

  record liveUpdate {
    var available = false;
    var closed = false;
    var hasValue = false;
    var valueJson = "";
    var logsJson = "[]";
    var failure: convexFailure;
  }

  private param subscriptionQueueCapacity = 16;
  private param subscriptionByteBudget = 4 * 1024 * 1024;
  private param maximumSubscriptions = 64;
  private param liveAggregateBudget = 32 * 1024 * 1024;
  private const initialTimestamp = "AAAAAAAAAAA=";

  private proc protocolFailure(message: string): convexFailure {
    return new convexFailure(FailureKind.Protocol, message, "", "[]");
  }

  private proc transportFailure(message: string): convexFailure {
    return new convexFailure(FailureKind.Transport, message, "", "[]");
  }

  class LiveHandle {
    var retainedBytes: atomic int;
    var stopped: atomic bool;
    var accountingUnderflow: atomic bool;

    proc reserveBytes(cost: int): bool {
      if cost <= 0 then return true;
      const previous = retainedBytes.fetchAdd(cost);
      if previous > liveAggregateBudget - cost {
        retainedBytes.fetchSub(cost);
        return false;
      }
      return true;
    }

    proc releaseBytes(cost: int): bool {
      if cost <= 0 then return true;
      var current = retainedBytes.read();
      var result = false;
      var done = false;
      while !done {
        if current < cost {
          accountingUnderflow.write(true);
          result = false;
          done = true;
        } else if retainedBytes.compareExchange(current, current - cost) {
          result = true;
          done = true;
        }
        // compareExchange refreshes current after a racing reservation/release.
      }
      return result;
    }
  }

  class Subscription {
    const queryId: uint(32);
    const path: string;
    const argsJson: string;
    const retainedCost: int;
    var handleLock: atomic bool;
    var handle: shared LiveHandle? = nil;

    var mailboxLock: atomic bool;
    /* Each slot is the publication boundary between the sole Live owner and
       the consuming task. The ring lock protects the indices and byte budget;
       the sync slot transfers ownership of the complete update record. */
    var updates: [0..<subscriptionQueueCapacity] sync liveUpdate;
    var updateCosts: [0..<subscriptionQueueCapacity] int;
    var queueStart = 0;
    var queueCount = 0;
    var queueBytes = 0;
    var closed: atomic bool;

    var addGeneration: atomic uint(64);
    var addAcknowledged: atomic uint(64);
    var removeGeneration: atomic uint(64);
    var removeAcknowledged: atomic uint(64);
    var active: atomic bool;
    var addPending: atomic bool;
    var removePending: atomic bool;
    // Writing an Add only acknowledges local transmission. A subscription is
    // established after the server publishes its first query result.
    var established: atomic bool;

    var hasLastValue = false;
    var lastValue = "";
    var lastValueCost = 0;
    var lastWasSuccess = false;
    var rehydrating = false;

    proc init(queryId: uint(32), path: string, argsJson: string) {
      this.queryId = queryId;
      this.path = path;
      this.argsJson = argsJson;
      // Strings are UTF-8 bytes, but Chapel string/runtime metadata and
      // allocator overhead are deliberately charged conservatively too.
      this.retainedCost = 4096 + 4 * (path.numBytes + argsJson.numBytes + 32);
    }

    proc acquireMailbox() {
      while mailboxLock.testAndSet() do sleep(0.0005);
    }

    proc releaseMailbox() { mailboxLock.clear(); }

    proc snapshotHandle(): shared LiveHandle? {
      while handleLock.testAndSet() do sleep(0.0005);
      const result = handle;
      handleLock.clear();
      return result;
    }

    proc detachHandle() {
      while handleLock.testAndSet() do sleep(0.0005);
      handle = nil;
      handleLock.clear();
    }

    proc push(update: liveUpdate) {
      const localHandle = snapshotHandle();
      acquireMailbox();
      const cost = update.valueJson.numBytes + update.logsJson.numBytes +
                   update.failure.message.numBytes +
                   update.failure.dataJson.numBytes + 1024;
      var accepted = update;
      var acceptedCost = cost;
      if acceptedCost > subscriptionByteBudget {
        accepted = new liveUpdate(
          available=true,
          failure=protocolFailure(
            "Live update exceeds the 4 MiB mailbox budget"
          )
        );
        acceptedCost = accepted.failure.message.numBytes + 1024;
      }
      while queueCount > 0 &&
            (queueCount == subscriptionQueueCapacity ||
             queueBytes + acceptedCost > subscriptionByteBudget) {
        updates[queueStart].readFE();
        const droppedCost = updateCosts[queueStart];
        updateCosts[queueStart] = 0;
        queueBytes -= droppedCost;
        if localHandle != nil then localHandle!.releaseBytes(droppedCost);
        queueStart = (queueStart + 1) % subscriptionQueueCapacity;
        queueCount -= 1;
      }
      if localHandle != nil && !localHandle!.reserveBytes(acceptedCost) {
        accepted = new liveUpdate(
          available=true,
          failure=protocolFailure("Live aggregate memory budget is full")
        );
        // Every subscription's 4 KiB base charge reserves room for this
        // terminal-sized pressure signal without exceeding the global cap.
        acceptedCost = 0;
      }
      const entryIndex = (queueStart + queueCount) % subscriptionQueueCapacity;
      updateCosts[entryIndex] = acceptedCost;
      updates[entryIndex].writeEF(accepted);
      queueCount += 1;
      queueBytes += acceptedCost;
      releaseMailbox();
    }

    proc next(timeoutSeconds: real = 10.0): liveUpdate {
      const localHandle = snapshotHandle();
      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      while monotonicMillis() < deadline {
        acquireMailbox();
        if queueCount > 0 {
          const result = updates[queueStart].readFE();
          const resultCost = updateCosts[queueStart];
          updateCosts[queueStart] = 0;
          queueBytes -= resultCost;
          if localHandle != nil then localHandle!.releaseBytes(resultCost);
          queueStart = (queueStart + 1) % subscriptionQueueCapacity;
          queueCount -= 1;
          releaseMailbox();
          return result;
        }
        releaseMailbox();
        if closed.read() then return new liveUpdate(closed=true);
        sleep(0.001);
      }
      return new liveUpdate();
    }

    proc close(timeoutSeconds: real = 3.0): convexFailure {
      if closed.exchange(true) then return new convexFailure();
      const localHandle = snapshotHandle();
      if localHandle == nil then return new convexFailure();
      const generation = removeGeneration.fetchAdd(1) + 1;
      removePending.write(true);
      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      while monotonicMillis() < deadline {
        if removeAcknowledged.read() >= generation ||
           localHandle!.stopped.read() then return new convexFailure();
        sleep(0.001);
      }
      return transportFailure("timed out stopping Live subscription");
    }

    proc replaceLastValue(value: string): bool {
      const localHandle = snapshotHandle();
      if lastValueCost > 0 && localHandle != nil then
        localHandle!.releaseBytes(lastValueCost);
      lastValue = "";
      lastValueCost = 0;
      hasLastValue = false;
      const cost = value.numBytes + 1024;
      if localHandle != nil && !localHandle!.reserveBytes(cost) then
        return false;
      lastValue = value;
      lastValueCost = cost;
      hasLastValue = true;
      return true;
    }

    proc clearLastValue() {
      const localHandle = snapshotHandle();
      if lastValueCost > 0 && localHandle != nil then
        localHandle!.releaseBytes(lastValueCost);
      lastValue = "";
      lastValueCost = 0;
      hasLastValue = false;
    }

    proc drainRetainedPayloads() {
      const localHandle = snapshotHandle();
      acquireMailbox();
      while queueCount > 0 {
        updates[queueStart].readFE();
        const cost = updateCosts[queueStart];
        updateCosts[queueStart] = 0;
        queueBytes -= cost;
        if localHandle != nil then localHandle!.releaseBytes(cost);
        queueStart = (queueStart + 1) % subscriptionQueueCapacity;
        queueCount -= 1;
      }
      releaseMailbox();
      clearLastValue();
    }
  }

  class LiveManager {
    const websocketUrl: string;
    const clientVersion: string;
    var guard: atomic bool;
    // The manager and caller share each handle, so neither can free a mailbox
    // while the other task is publishing or consuming it.
    var slots: [0..<maximumSubscriptions] shared Subscription?;
    var nextQueryId: uint(32) = 0;
    const handle: shared LiveHandle;
    var started: atomic bool;
    var closing: atomic bool;
    var stopped: atomic bool;
    var debugRequested: atomic uint(64);
    var debugAcknowledged: atomic uint(64);

    proc init(websocketUrl: string, clientVersion: string) {
      this.websocketUrl = websocketUrl;
      this.clientVersion = clientVersion;
      this.handle = new shared LiveHandle();
    }

    proc acquire() {
      while guard.testAndSet() do sleep(0.0005);
    }

    proc release() { guard.clear(); }

    proc reserveBytes(cost: int): bool {
      return handle.reserveBytes(cost);
    }

    proc releaseBytes(cost: int): bool {
      return handle.releaseBytes(cost);
    }

    proc subscribe(path: string, argsJson: string,
                   timeoutSeconds: real):
                   (shared Subscription?, convexFailure) {
      acquire();
      if closing.read() || stopped.read() {
        release();
        return (nil, new convexFailure(
          FailureKind.Closed, "Convex Live owner is closing"
        ));
      }
      var slot = -1;
      for entryIndex in slots.domain do if slots[entryIndex] == nil {
        slot = entryIndex;
        break;
      }
      if slot < 0 {
        release();
        return (nil, protocolFailure(
          "at most 64 Live subscriptions are supported"
        ));
      }
      const queryId = nextQueryId;
      nextQueryId += 1;
      if path.numBytes > liveAggregateBudget ||
         argsJson.numBytes > liveAggregateBudget {
        release();
        return (nil, protocolFailure(
          "Live subscription data exceeds the 32 MiB aggregate budget"
        ));
      }
      const candidateCost = 4096 +
        4 * (path.numBytes + argsJson.numBytes + 32);
      if !reserveBytes(candidateCost) {
        release();
        return (nil, protocolFailure(
          "Live subscription data exceeds the 32 MiB aggregate budget"
        ));
      }
      var subscription = new shared Subscription(queryId, path, argsJson);
      subscription.handle = handle;
      subscription.active.write(true);
      subscription.addGeneration.write(1);
      subscription.addPending.write(true);
      slots[slot] = subscription;
      release();

      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      while monotonicMillis() < deadline {
        if subscription.addAcknowledged.read() >= 1 then
          return (subscription, new convexFailure());
        if stopped.read() then break;
        sleep(0.001);
      }
      subscription.close();
      return (nil, transportFailure("timed out starting Live subscription"));
    }

    proc debugDisconnect(timeoutSeconds: real = 3.0): convexFailure {
      const generation = debugRequested.fetchAdd(1) + 1;
      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      while monotonicMillis() < deadline {
        if debugAcknowledged.read() >= generation then
          return new convexFailure();
        if stopped.read() then break;
        sleep(0.001);
      }
      return transportFailure("timed out retiring the Live connection");
    }

    proc close(timeoutSeconds: real = 3.0): convexFailure {
      closing.write(true);
      const deadline = monotonicMillis() + (timeoutSeconds * 1000):int(64);
      while monotonicMillis() < deadline {
        if stopped.read() then return new convexFailure();
        sleep(0.001);
      }
      return transportFailure("timed out closing the Live owner");
    }

    proc deinit() {
      if !stopped.read() then close(3.0);
      for entryIndex in slots.domain do if slots[entryIndex] != nil {
        slots[entryIndex] = nil;
      }
    }

    proc hasActiveSubscriptions(): bool {
      acquire();
      var result = false;
      for subscription in slots do if subscription != nil &&
          subscription!.active.read() && !subscription!.removePending.read() {
        result = true;
        break;
      }
      release();
      return result;
    }

    proc modifyAll(baseVersion: uint(32), ref sentIds,
                   ref sentGenerations, ref sentCount: int): string {
      var modifications = "";
      acquire();
      for subscription in slots do if subscription != nil &&
          subscription!.active.read() && !subscription!.removePending.read() {
        sentIds[sentCount] = subscription!.queryId;
        sentGenerations[sentCount] = subscription!.addGeneration.read();
        sentCount += 1;
        if modifications.numBytes > 0 then modifications += ",";
        modifications += "{\"type\":\"Add\",\"queryId\":" +
          subscription!.queryId:string + ",\"udfPath\":" +
          jsonQuote(subscription!.path) + ",\"args\":[" +
          subscription!.argsJson + "]}";
      }
      release();
      return "{\"type\":\"ModifyQuerySet\",\"baseVersion\":" +
             baseVersion:string + ",\"newVersion\":" +
             (baseVersion + 1):string + ",\"modifications\":[" +
             modifications + "]}";
    }

    proc publishFailure(failure: convexFailure,
                                establishedOnly: bool) {
      acquire();
      for subscription in slots do if subscription != nil &&
          subscription!.active.read() && !subscription!.removePending.read() &&
          (!establishedOnly || subscription!.established.read()) {
        subscription!.push(new liveUpdate(available=true, failure=failure,
                                          logsJson=failure.logsJson));
        // A transient TransportError (a dial hiccup, a dropped receive)
        // does not make the already-cached lastValue stale -- the server
        // hasn't told us anything to the contrary, so the very next
        // rehydration is still expected to repeat it verbatim. Only clear
        // lastWasSuccess here for Function/Protocol failures, which do
        // represent a real break in what the subscriber was last shown.
        // Otherwise a reconnect blip that lands between two identical
        // hydrations (see AGENTS.md's "without permanently stranding"
        // Live-acceptance requirement) defeats duplicate suppression and
        // hands the subscriber a stale repeat instead of the new value.
        if failure.kind != FailureKind.Transport then
          subscription!.lastWasSuccess = false;
      }
      release();
    }

    proc acknowledgeHydration(const ref sentIds, const ref sentGenerations,
                              sentCount: int) {
      acquire();
      for sentIndex in 0..<sentCount do
        for subscription in slots do if subscription != nil &&
            subscription!.queryId == sentIds[sentIndex] &&
            subscription!.active.read() &&
            !subscription!.removePending.read() &&
            subscription!.addGeneration.read() == sentGenerations[sentIndex] {
          subscription!.rehydrating = subscription!.hasLastValue;
          subscription!.addPending.write(false);
          subscription!.addAcknowledged.write(sentGenerations[sentIndex]);
        }
      release();
    }

    proc processRemovals(ref socket: owned WebSocket?,
                                 ref querySetVersion: uint(32)): bool {
      acquire();
      var target: shared Subscription? = nil;
      for subscription in slots do if subscription != nil &&
          subscription!.removePending.read() {
        target = subscription;
        break;
      }
      release();
      if target == nil then return true;

      if socket != nil {
        const message = "{\"type\":\"ModifyQuerySet\",\"baseVersion\":" +
          querySetVersion:string + ",\"newVersion\":" +
          (querySetVersion + 1):string +
          ",\"modifications\":[{\"type\":\"Remove\",\"queryId\":" +
          target!.queryId:string + "}]}";
        const errorMessage = socket!.send(message, monotonicMillis() + 1000);
        if errorMessage.numBytes > 0 then return false;
        querySetVersion += 1;
      }
      target!.active.write(false);
      target!.removePending.write(false);
      target!.removeAcknowledged.write(target!.removeGeneration.read());
      acquire();
      for entryIndex in slots.domain do if slots[entryIndex] != nil &&
          slots[entryIndex]!.queryId == target!.queryId {
        slots[entryIndex]!.drainRetainedPayloads();
        releaseBytes(slots[entryIndex]!.retainedCost);
        slots[entryIndex]!.detachHandle();
        slots[entryIndex] = nil;
        break;
      }
      release();
      return true;
    }

    proc processAdds(ref socket: owned WebSocket?,
                             ref querySetVersion: uint(32)): bool {
      if socket == nil then return true;
      acquire();
      var target: shared Subscription? = nil;
      for subscription in slots do if subscription != nil &&
          subscription!.active.read() && subscription!.addPending.read() &&
          !subscription!.removePending.read() {
        target = subscription;
        break;
      }
      release();
      if target == nil then return true;
      const message = "{\"type\":\"ModifyQuerySet\",\"baseVersion\":" +
        querySetVersion:string + ",\"newVersion\":" +
        (querySetVersion + 1):string +
        ",\"modifications\":[{\"type\":\"Add\",\"queryId\":" +
        target!.queryId:string + ",\"udfPath\":" + jsonQuote(target!.path) +
        ",\"args\":[" + target!.argsJson + "]}]}";
      const errorMessage = socket!.send(message, monotonicMillis() + 1000);
      if errorMessage.numBytes > 0 then return false;
      querySetVersion += 1;
      target!.addPending.write(false);
      target!.addAcknowledged.write(target!.addGeneration.read());
      return true;
    }

    proc stateVersion(raw: string): (bool, uint(32), uint(32), string) {
      const (hasQuerySet, querySet) = jsonUInt32(raw, "querySet");
      const (hasIdentity, identity) = jsonUInt32(raw, "identity");
      const (hasTimestamp, timestamp) = jsonString(raw, "ts");
      return (hasQuerySet && hasIdentity && hasTimestamp,
              querySet, identity, timestamp);
    }

    proc handleTransition(raw: string,
                          ref remoteQuerySet: uint(32),
                          ref remoteIdentity: uint(32),
                          ref remoteTimestamp: string,
                          ref maxObservedTimestamp: string): convexFailure {
      const (hasStart, startRaw) = jsonRaw(raw, "startVersion");
      const (hasEnd, endRaw) = jsonRaw(raw, "endVersion");
      if !hasStart || !hasEnd then
        return protocolFailure("Transition omitted a state version");
      const (validStart, startQuerySet, startIdentity, startTimestamp) =
        stateVersion(startRaw);
      const (validEnd, endQuerySet, endIdentity, endTimestamp) =
        stateVersion(endRaw);
      if !validStart || !validEnd then
        return protocolFailure(
          "Transition contained an invalid state version"
        );
      if startQuerySet != remoteQuerySet || startIdentity != remoteIdentity ||
         startTimestamp != remoteTimestamp then
        return protocolFailure(
          "Transition start version does not match local state"
        );
      const (timestampValid, comparison) = timestampCompare(
        endTimestamp,
        if maxObservedTimestamp.numBytes > 0 then maxObservedTimestamp
        else initialTimestamp
      );
      if !timestampValid then
        return protocolFailure("Transition timestamp is invalid");

      const count = jsonArrayLength(raw, "modifications");
      if count < 0 || count > maximumSubscriptions then
        return protocolFailure(
          "Transition modifications are missing or too large"
        );
      var stagedIds: [0..<maximumSubscriptions] uint(32);
      var stagedKinds: [0..<maximumSubscriptions] int;
      var stagedUpdates: [0..<maximumSubscriptions] liveUpdate;
      for entryIndex in 0..<count {
        const (hasModification, modification) =
          jsonArrayRaw(raw, "modifications", entryIndex);
        const (hasType, modificationType) = jsonString(modification, "type");
        const (hasQueryId, queryId) = jsonUInt32(modification, "queryId");
        if !hasModification || !hasType || !hasQueryId then
          return protocolFailure("Transition modification is malformed");
        stagedIds[entryIndex] = queryId;
        if modificationType == "QueryUpdated" {
          const (hasValue, value) = jsonRaw(modification, "value");
          if !hasValue then
            return protocolFailure("QueryUpdated omitted value");
          const (logsStatus, logs) = jsonStringArray(modification, "logLines");
          if logsStatus < 0 then
            return protocolFailure(
              "QueryUpdated logLines is not a string array"
            );
          stagedKinds[entryIndex] = 1;
          stagedUpdates[entryIndex] = new liveUpdate(
            available=true, hasValue=true, valueJson=value,
            logsJson=if logsStatus == 1 then logs else "[]"
          );
        } else if modificationType == "QueryFailed" {
          const (hasMessage, message) =
            jsonString(modification, "errorMessage");
          const (hasData, data) = jsonRaw(modification, "errorData");
          const (logsStatus, logs) = jsonStringArray(modification, "logLines");
          if !hasMessage then
            return protocolFailure("QueryFailed omitted errorMessage");
          if logsStatus < 0 then
            return protocolFailure(
              "QueryFailed logLines is not a string array"
            );
          const failure = new convexFailure(
            FailureKind.Function, message, if hasData then data else "",
            if logsStatus == 1 then logs else "[]"
          );
          stagedKinds[entryIndex] = 2;
          stagedUpdates[entryIndex] = new liveUpdate(
            available=true, logsJson=failure.logsJson, failure=failure
          );
        } else if modificationType == "QueryRemoved" {
          stagedKinds[entryIndex] = 3;
        } else {
          return protocolFailure("unknown Transition modification " +
                                 modificationType);
        }
      }

      /* Commit the version before publishing any value. A reader can therefore
         never observe half of a Convex transition. */
      remoteQuerySet = endQuerySet;
      remoteIdentity = endIdentity;
      remoteTimestamp = endTimestamp;
      if maxObservedTimestamp.numBytes == 0 || comparison > 0 then
        maxObservedTimestamp = endTimestamp;

      acquire();
      for stagedIndex in 0..<count {
        for subscription in slots do if subscription != nil &&
            subscription!.queryId == stagedIds[stagedIndex] &&
            subscription!.active.read() &&
            !subscription!.removePending.read() {
          if stagedKinds[stagedIndex] == 1 || stagedKinds[stagedIndex] == 2 then
            subscription!.established.write(true);
          if stagedKinds[stagedIndex] == 1 {
            const suppress = subscription!.rehydrating &&
              subscription!.lastWasSuccess &&
              jsonEqual(subscription!.lastValue,
                        stagedUpdates[stagedIndex].valueJson);
            subscription!.rehydrating = false;
            const retained = subscription!.replaceLastValue(
              stagedUpdates[stagedIndex].valueJson
            );
            subscription!.lastWasSuccess = true;
            if !retained {
              subscription!.lastWasSuccess = false;
              subscription!.push(new liveUpdate(
                available=true,
                failure=protocolFailure("Live aggregate memory budget is full")
              ));
            } else if !suppress then
              subscription!.push(stagedUpdates[stagedIndex]);
          } else if stagedKinds[stagedIndex] == 2 {
            subscription!.rehydrating = false;
            subscription!.lastWasSuccess = false;
            subscription!.push(stagedUpdates[stagedIndex]);
          } else {
            subscription!.clearLastValue();
            subscription!.lastWasSuccess = false;
            subscription!.rehydrating = false;
          }
        }
      }
      release();
      return new convexFailure();
    }

    proc retire(ref socket: owned WebSocket?, reason: string,
                        publishTransport: bool,
                        ref connectionCount: uint(32),
                        ref lastCloseReason: string,
                        ref querySetVersion: uint(32),
                        ref remoteQuerySet: uint(32),
                        ref remoteIdentity: uint(32),
                        ref remoteTimestamp: string) {
      if socket != nil {
        socket!.close(monotonicMillis() + 250);
        socket = nil;
        connectionCount += 1;
      }
      if publishTransport then publishFailure(transportFailure(reason), true);
      lastCloseReason = reason;
      querySetVersion = 0;
      remoteQuerySet = 0;
      remoteIdentity = 0;
      remoteTimestamp = initialTimestamp;
    }

    proc run() {
      var socket: owned WebSocket? = nil;
      var querySetVersion: uint(32) = 0;
      var remoteQuerySet: uint(32) = 0;
      var remoteIdentity: uint(32) = 0;
      var remoteTimestamp = initialTimestamp;
      var maxObservedTimestamp = "";
      var connectionCount: uint(32) = 0;
      var lastCloseReason = "InitialConnect";
      var nextBackoff: int(64) = 100;
      var reconnectAt: int(64) = 0;
      var handledDebug: uint(64) = 0;

      while !closing.read() {
        const requestedDebug = debugRequested.read();
        if requestedDebug > handledDebug {
          retire(socket, "DebugDisconnect", false, connectionCount,
                 lastCloseReason, querySetVersion, remoteQuerySet,
                 remoteIdentity, remoteTimestamp);
          handledDebug = requestedDebug;
          debugAcknowledged.write(handledDebug);
          reconnectAt = monotonicMillis();
        }

        if socket == nil && hasActiveSubscriptions() &&
           monotonicMillis() >= reconnectAt {
          var candidate = new owned WebSocket();
          const connectError = candidate.connect(websocketUrl, clientVersion,
                                                 monotonicMillis() + 1000);
          if connectError.numBytes > 0 {
            publishFailure(
              transportFailure("Live dial: " + connectError), true
            );
            reconnectAt = monotonicMillis() + nextBackoff;
            nextBackoff = min(nextBackoff * 2, 15000);
          } else {
            socket = candidate;
            const connect = "{\"type\":\"Connect\",\"sessionId\":" +
              jsonQuote(randomUUID()) + ",\"connectionCount\":" +
              connectionCount:string + ",\"lastCloseReason\":" +
              jsonQuote(lastCloseReason) +
              (if maxObservedTimestamp.numBytes > 0 then
                 ",\"maxObservedTimestamp\":" + jsonQuote(maxObservedTimestamp)
               else "") + ",\"clientTs\":0}";
            var sentIds: [0..<maximumSubscriptions] uint(32);
            var sentGenerations: [0..<maximumSubscriptions] uint(64);
            var sentCount = 0;
            var sendError = socket!.send(connect, monotonicMillis() + 1000);
            if sendError.numBytes == 0 {
              const hydration = modifyAll(0, sentIds, sentGenerations,
                                          sentCount);
              if jsonArrayLength(hydration, "modifications") > 0 {
                sendError = socket!.send(hydration, monotonicMillis() + 1000);
                if sendError.numBytes == 0 then querySetVersion = 1;
              }
            }
            if sendError.numBytes > 0 {
              retire(socket, "Live handshake: " + sendError, false,
                     connectionCount, lastCloseReason, querySetVersion,
                     remoteQuerySet, remoteIdentity, remoteTimestamp);
              reconnectAt = monotonicMillis() + nextBackoff;
              nextBackoff = min(nextBackoff * 2, 15000);
            } else {
              acknowledgeHydration(sentIds, sentGenerations, sentCount);
              /* A completed TLS/WebSocket handshake is healthy traffic. */
              nextBackoff = 100;
            }
          }
        }

        if !processRemovals(socket, querySetVersion) ||
           !processAdds(socket, querySetVersion) {
          retire(socket, "Live write failed", true, connectionCount,
                 lastCloseReason, querySetVersion, remoteQuerySet,
                 remoteIdentity, remoteTimestamp);
          reconnectAt = monotonicMillis() + nextBackoff;
          nextBackoff = min(nextBackoff * 2, 15000);
          continue;
        }

        if socket != nil {
          const incoming = socket!.receive(monotonicMillis() + 25);
          if incoming.status < 0 {
            retire(socket, "Live receive: " + incoming.errorMessage, true,
                   connectionCount, lastCloseReason, querySetVersion,
                   remoteQuerySet, remoteIdentity, remoteTimestamp);
            reconnectAt = monotonicMillis() + nextBackoff;
            nextBackoff = min(nextBackoff * 2, 15000);
          } else if incoming.status == 1 {
            const (hasType, messageType) =
              jsonString(incoming.message, "type");
            var failure: convexFailure;
            if !hasType then
              failure = protocolFailure("Live message omitted type");
            else if messageType == "Transition" then
              failure = handleTransition(incoming.message, remoteQuerySet,
                                         remoteIdentity, remoteTimestamp,
                                         maxObservedTimestamp);
            else if messageType == "TransitionChunk" {
              failure = protocolFailure(
                "TransitionChunk is not supported by this pinned profile"
              );
            } else if messageType == "FatalError" ||
                      messageType == "AuthError" {
              const (hasError, detail) = jsonString(incoming.message, "error");
              failure = protocolFailure(
                if hasError then detail else messageType
              );
            } else if messageType == "Ping" ||
                      messageType == "MutationResponse" ||
                      messageType == "ActionResponse" {
              /* Keepalive/mutation-and-action traffic this Live-only pinned
                 profile does not otherwise act on. Every sibling client in
                 this repo treats these three types as valid, silently
                 accepted traffic rather than a protocol error -- Ping in
                 particular is the server's periodic idle-connection
                 heartbeat, and rejecting it would force an unwarranted
                 disconnect/reconnect on every long-lived subscription. */
            } else {
              failure = protocolFailure("unknown Live message " + messageType);
            }
            if failure.isPresent {
              publishFailure(failure, false);
              retire(socket, failure.message, false, connectionCount,
                     lastCloseReason, querySetVersion, remoteQuerySet,
                     remoteIdentity, remoteTimestamp);
              reconnectAt = monotonicMillis() + nextBackoff;
              nextBackoff = min(nextBackoff * 2, 15000);
            } else {
              nextBackoff = 100;
            }
          }
        } else {
          sleep(0.005);
        }
      }

      retire(socket, "ClientClose", false, connectionCount, lastCloseReason,
             querySetVersion, remoteQuerySet, remoteIdentity, remoteTimestamp);
      acquire();
      for subscription in slots do if subscription != nil {
        subscription!.active.write(false);
        subscription!.closed.write(true);
        subscription!.removeAcknowledged.write(
          subscription!.removeGeneration.read()
        );
        subscription!.drainRetainedPayloads();
        releaseBytes(subscription!.retainedCost);
        subscription!.detachHandle();
      }
      for entryIndex in slots.domain do slots[entryIndex] = nil;
      handle.stopped.write(true);
      release();
      stopped.write(true);
    }
  }

  private proc startLiveManager(in manager: shared LiveManager) {
    if !manager.started.exchange(true) then
      begin with (in manager) manager.run();
  }

  class Client {
    const deploymentUrl: string;
    const websocketUrl: string;
    const clientVersion: string;
    var authLock: atomic bool;
    var lifecycleLock: atomic bool;
    var authToken = "";
    var closed: atomic bool;
    var live: shared LiveManager? = nil;

    proc init(deploymentUrl: string, clientVersion = "chapel-0.1.0") {
      const (validHttp, normalizedHttp) = deploymentURL(deploymentUrl, false);
      const (validWebSocket, normalizedWebSocket) =
        deploymentURL(deploymentUrl, true);
      if !validHttp || !validWebSocket ||
         !validHttpFieldValue(clientVersion) then
        halt(
          "Convex URL or client version is invalid"
        );
      this.deploymentUrl = normalizedHttp;
      this.websocketUrl = normalizedWebSocket;
      this.clientVersion = clientVersion;
    }

    proc acquireAuth() {
      while authLock.testAndSet() do sleep(0.0005);
    }

    proc releaseAuth() { authLock.clear(); }

    proc acquireLifecycle() {
      while lifecycleLock.testAndSet() do sleep(0.0005);
    }

    proc releaseLifecycle() { lifecycleLock.clear(); }

    proc isClosed(): bool {
      acquireLifecycle();
      const result = closed.read();
      releaseLifecycle();
      return result;
    }

    proc setAuth(token: string): convexFailure {
      if isClosed() then
        return new convexFailure(
          FailureKind.Closed, "Convex client is closed"
        );
      if !validHttpFieldValue(token) then
        return protocolFailure(
          "authentication token is not a valid HTTP field value"
        );
      acquireAuth();
      authToken = token;
      releaseAuth();
      return new convexFailure();
    }

    proc query(path: string, argsJson = "{}", timeoutSeconds: real = 30.0) {
      return call("query", path, argsJson, timeoutSeconds);
    }

    proc mutation(path: string, argsJson = "{}", timeoutSeconds: real = 30.0) {
      return call("mutation", path, argsJson, timeoutSeconds);
    }

    proc action(path: string, argsJson = "{}", timeoutSeconds: real = 30.0) {
      return call("action", path, argsJson, timeoutSeconds);
    }

    proc call(operation: string, path: string, argsJson: string,
                      timeoutSeconds: real): callResult {
      if isClosed() then return new callResult(
        failure=new convexFailure(
          FailureKind.Closed, "Convex client is closed"
        )
      );
      if path.numBytes == 0 || !jsonIsObject(argsJson) then
        return new callResult(
          failure=protocolFailure(
            "function path and object arguments are required"
          )
        );
      acquireAuth();
      const token = authToken;
      releaseAuth();
      const request = "{\"path\":" + jsonQuote(path) + ",\"args\":" +
                      argsJson + ",\"format\":\"json\"}";
      const transport = httpPost(
        deploymentUrl + "/api/" + operation, clientVersion, token, request,
        monotonicMillis() + (timeoutSeconds * 1000):int(64)
      );
      if !transport.ok then return new callResult(
        failure=transportFailure(operation + ": " + transport.errorMessage)
      );
      const (hasStatus, status) = jsonString(transport.body, "status");
      if !hasStatus then return new callResult(
        failure=protocolFailure("HTTP response omitted status")
      );
      const (logsStatus, logs) = jsonStringArray(transport.body, "logLines");
      if logsStatus < 0 then return new callResult(
        failure=protocolFailure("HTTP logLines is not a string array")
      );
      if status == "success" {
        const (hasValue, value) = jsonRaw(transport.body, "value");
        if !hasValue then return new callResult(
          failure=protocolFailure("success response omitted value")
        );
        return new callResult(true, value,
                              if logsStatus == 1 then logs else "[]");
      }
      if status == "error" {
        const (hasMessage, message) =
          jsonString(transport.body, "errorMessage");
        if !hasMessage then return new callResult(
          failure=protocolFailure("error response omitted string errorMessage")
        );
        const (hasData, data) = jsonRaw(transport.body, "errorData");
        const failure = new convexFailure(
          FailureKind.Function, message,
          if hasData then data else "",
          if logsStatus == 1 then logs else "[]"
        );
        return new callResult(failure=failure);
      }
      return new callResult(
        failure=protocolFailure("HTTP response has unknown status")
      );
    }

    proc subscribe(path: string, argsJson = "{}",
                       timeoutSeconds: real = 10.0):
                       (shared Subscription?, convexFailure) {
      acquireLifecycle();
      if closed.read() {
        releaseLifecycle();
        return (
        nil, new convexFailure(FailureKind.Closed, "Convex client is closed")
        );
      }
      if path.numBytes == 0 || !jsonIsObject(argsJson) {
        releaseLifecycle();
        return (
        nil, protocolFailure("Live query requires path and object arguments")
        );
      }
      if live == nil {
        var manager = new shared LiveManager(websocketUrl, clientVersion);
        live = manager;
        startLiveManager(manager);
      }
      const manager = live;
      releaseLifecycle();
      return manager!.subscribe(path, argsJson, timeoutSeconds);
    }

    proc debugDisconnect(timeoutSeconds: real = 3.0): convexFailure {
      acquireLifecycle();
      const manager = live;
      releaseLifecycle();
      if manager == nil then
        return protocolFailure("no active Live connection");
      return manager!.debugDisconnect(timeoutSeconds);
    }

    proc close(timeoutSeconds: real = 3.0): convexFailure {
      acquireLifecycle();
      if closed.read() {
        releaseLifecycle();
        return new convexFailure();
      }
      closed.write(true);
      const manager = live;
      live = nil;
      releaseLifecycle();
      if manager != nil then return manager!.close(timeoutSeconds);
      return new convexFailure();
    }

    proc deinit() {
      if !closed.read() then close(3.0);
    }
  }
}
