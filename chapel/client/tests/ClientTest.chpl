module ChapelConvexClientTest {
  use Time;
  use Convex;
  use ConvexTransport;
  use ConvexTransportTest;

  proc main() {
    assert(webSocketSendSequenceSelfTest(),
           "WebSocket continuation call sequence changed");
    assert(jsonIsObject("{\"room\":\"fixture\"}"));
    assert(!jsonIsObject("[]"));

    const (decimalOk, decimal) = jsonIntegralField("{\"count\":1.0}", "count");
    assert(decimalOk && decimal == 1);
    assert(!jsonIntegralField("{\"count\":1.5}", "count")[0]);
    assert(!jsonIntegralField("{\"count\":\"1\"}", "count")[0]);
    assert(!jsonIntegralField("{\"count\":9223372036854775808}", "count")[0]);
    const (minimumOk, minimum) = jsonIntegralField(
      "{\"count\":-9223372036854775808}", "count"
    );
    assert(minimumOk && minimum == min(int(64)));
    assert(jsonIntegralField("{\"count\":0.0}", "count") == (true, 0));
    assert(jsonIntegralField("{\"count\":-0.0}", "count") == (true, 0));
    const (preciseOk, precise) = jsonIntegralField(
      "{\"count\":9007199254740993}", "count"
    );
    assert(preciseOk && precise == 9007199254740993:int(64));
    var numericZeros = "0";
    for 1..21 do numericZeros += numericZeros;
    const adversarialNumeric = "{\"count\":0." + numericZeros + "}";
    const numericStarted = monotonicMillis();
    const (adversarialOk, adversarialValue) = jsonIntegralField(
      adversarialNumeric, "count"
    );
    assert(adversarialOk && adversarialValue == 0);
    assert(monotonicMillis() - numericStarted < 1000,
           "near-2 MiB exact decimal normalization was not linear-time");

    assert(validateAdapterCommand(
      "{\"id\":\"hello\",\"protocolVersion\":1,\"op\":\"hello\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"hello\",\"protocolVersion\":1,\"op\":\"hello\",\"extra\":true}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"   \",\"op\":\"close\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"　\",\"op\":\"close\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"bad\\u0000id\",\"op\":\"close\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"id\",\"op\":\"clo\\u0000se\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"id\",\"op\":\"setAuth\",\"token\":\"a\\u0000b\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"id\",\"op\":\"setAuth\",\"token\":\"a\\r\\nInjected: yes\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"id\",\"op\":\"query\",\"path\":\"a\\u0000:b\",\"args\":{}}"
    ).ok);
    assert(!jsonString("{\"message\":\"a\\u0000b\"}", "message")[0]);
    for injected in ["line\rbreak", "line\nbreak", "nul\x00break",
                     "control\x01break", "delete\x7fbreak"] do
      assert(!validHttpFieldValue(injected));
    assert(validHttpFieldValue("token\tvalue"));
    var headerClient = new owned Client("http://127.0.0.1:1");
    assert(headerClient.setAuth("Bearer\r\nInjected: yes").kind ==
           FailureKind.Protocol);
    assert(!httpPost("http://127.0.0.1:1", "bad\r\nHeader: yes", "", "{}",
                     monotonicMillis() + 10).ok);
    var injectedSocket = new owned WebSocket();
    assert(injectedSocket.connect("ws://127.0.0.1:1", "bad\nHeader: yes",
                                  monotonicMillis() + 10).numBytes > 0);
    var astral128 = "";
    for 1..128 do astral128 += "😀";
    assert(validateAdapterCommand(
      "{\"id\":" + jsonQuote(astral128) + ",\"op\":\"close\"}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":" + jsonQuote(astral128 + "😀") +
      ",\"op\":\"close\"}"
    ).ok);
    assert(validateAdapterCommand(
      "{\"id\":\"x\",\"op\":\"unsubscribe\",\"subscriptionId\":" +
      jsonQuote(astral128) + "}"
    ).ok);
    assert(!validateAdapterCommand(
      "{\"id\":\"x\",\"op\":\"unsubscribe\",\"subscriptionId\":" +
      jsonQuote(astral128 + "😀") + "}"
    ).ok);
    const invalidCommands = [
      "{\"id\":\"x\",\"op\":\"hello\",\"protocolVersion\":\"1\"}",
      "{\"id\":\"x\",\"op\":\"hello\",\"protocolVersion\":1,\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"query\",\"path\":3,\"args\":{}}",
      "{\"id\":\"x\",\"op\":\"query\"," +
        "\"path\":\"a:b\",\"args\":{},\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"mutation\",\"path\":\"a:b\",\"args\":[]}",
      "{\"id\":\"x\",\"op\":\"mutation\"," +
        "\"path\":\"a:b\",\"args\":{},\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"action\",\"path\":4,\"args\":{}}",
      "{\"id\":\"x\",\"op\":\"action\"," +
        "\"path\":\"a:b\",\"args\":{},\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"subscribe\"," +
        "\"subscriptionId\":1,\"path\":\"a:b\",\"args\":{}}",
      "{\"id\":\"x\",\"op\":\"subscribe\",\"subscriptionId\":\"s\"," +
        "\"path\":\"a:b\",\"args\":{},\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"unsubscribe\",\"subscriptionId\":1}",
      "{\"id\":\"x\",\"op\":\"unsubscribe\"," +
        "\"subscriptionId\":\"s\",\"extra\":0}",
      "{\"id\":\"x\",\"op\":\"setAuth\",\"token\":null}",
      "{\"id\":\"x\",\"op\":\"setAuth\",\"token\":\"t\",\"extra\":0}",
      "{\"id\":1,\"op\":\"debugDisconnect\"}",
      "{\"id\":\"x\",\"op\":\"debugDisconnect\",\"extra\":0}",
      "{\"id\":1,\"op\":\"close\"}",
      "{\"id\":\"x\",\"op\":\"close\",\"extra\":0}"
    ];
    for invalid in invalidCommands do
      assert(!validateAdapterCommand(invalid).ok);
    assert(jsonStringArray("{\"logLines\":[\"one\",\"two\"]}",
                           "logLines")[0] == 1);
    assert(jsonStringArray("{\"logLines\":[1]}", "logLines")[0] < 0);

    const (timestampOk, timestampOrder) = timestampCompare(
      "/wAAAAAAAAA=", "AAEAAAAAAAA="
    );
    assert(timestampOk && timestampOrder < 0); // little-endian 255 < 256

    var subscription = new shared Subscription(
      7:uint(32), "demo:state", "{}"
    );
    for value in 0..<20 do subscription.push(new liveUpdate(
      available=true, hasValue=true, valueJson=value:string
    ));
    // The mailbox retains the newest sixteen states instead of growing without
    // bound or blocking the sole Live protocol owner.
    const first = subscription.next(0.01);
    assert(first.available && first.valueJson == "4");
    for expected in 5..19 {
      const update = subscription.next(0.01);
      assert(update.available && update.valueJson == expected:string);
    }
    assert(!subscription.next(0.001).available);

    // Reproduce the Live-owner/consumer handoff instead of testing the queue
    // only from one task. The delayed publisher guarantees next() is already
    // waiting when a complete record, including its strings, crosses tasks.
    var concurrent = new shared Subscription(
      8:uint(32), "demo:state", "{}"
    );
    var producerReady: sync bool;
    var publishNow: sync bool;
    var producerDone: sync bool;
    const retainedProducer = concurrent;
    begin with (in retainedProducer) {
      producerReady.writeEF(true);
      publishNow.readFE();
      retainedProducer.push(new liveUpdate(
        available=true, hasValue=true,
        valueJson="{\"count\":42,\"label\":\"café\"}",
        logsJson="[\"published\"]"
      ));
      producerDone.writeEF(true);
    }
    producerReady.readFE();
    begin {
      sleep(0.01);
      publishNow.writeEF(true);
    }
    const publishStarted = monotonicMillis();
    const published = concurrent.next(1.0);
    const publishElapsed = monotonicMillis() - publishStarted;
    producerDone.readFE();
    assert(published.available && published.hasValue);
    assert(published.valueJson ==
      "{\"count\":42,\"label\":\"café\"}");
    assert(published.logsJson == "[\"published\"]");
    assert(publishElapsed < 250, "cross-task publication was not prompt");

    // A task blocked in next() retains the shared Subscription and observes a
    // terminal close promptly. Client teardown can therefore release its own
    // reference without racing an unmanaged relay pointer.
    var closing = new shared Subscription(
      9:uint(32), "demo:state", "{}"
    );
    var waiterReady: sync bool;
    var waiterDone: sync liveUpdate;
    const retainedWaiter = closing;
    begin with (in retainedWaiter) {
      waiterReady.writeEF(true);
      waiterDone.writeEF(retainedWaiter.next(1.0));
    }
    waiterReady.readFE();
    sleep(0.01);
    const closeStarted = monotonicMillis();
    assert(!closing.close().isPresent);
    const terminal = waiterDone.readFE();
    const closeElapsed = monotonicMillis() - closeStarted;
    assert(terminal.closed && !terminal.available);
    assert(closeElapsed < 250, "mailbox close did not unblock promptly");

    // Hydration acknowledgements belong only to the exact generation included
    // in the reconnect snapshot. A subscription installed after the snapshot
    // stays pending for the normal incremental Add path.
    var manager = new shared LiveManager("ws://fixture.invalid", "test");
    var before = new shared Subscription(10:uint(32), "demo:before", "{}");
    before.active.write(true);
    before.addGeneration.write(1);
    before.addPending.write(true);
    manager.slots[0] = before;
    assert(manager.reserveBytes(before.retainedCost));
    var sentIds: [0..<64] uint(32);
    var sentGenerations: [0..<64] uint(64);
    var sentCount = 0;
    manager.modifyAll(0, sentIds, sentGenerations, sentCount);
    var after = new shared Subscription(11:uint(32), "demo:after", "{}");
    after.active.write(true);
    after.addGeneration.write(1);
    after.addPending.write(true);
    manager.slots[1] = after;
    assert(manager.reserveBytes(after.retainedCost));
    manager.acknowledgeHydration(sentIds, sentGenerations, sentCount);
    assert(before.addAcknowledged.read() == 1);
    assert(after.addAcknowledged.read() == 0 && after.addPending.read());

    // A locally written Add is not yet an established subscription. Dial and
    // reconnect noise stays private until the server has produced a result.
    manager.publishFailure(
      new convexFailure(kind=FailureKind.Transport,
                        message="pre-establishment dial failed"), true
    );
    assert(!before.next(0.01).available);
    before.established.write(true);
    manager.publishFailure(
      new convexFailure(kind=FailureKind.Transport,
                        message="post-establishment reconnect failed"), true
    );
    const establishedFailure = before.next(0.1);
    assert(establishedFailure.failure.kind == FailureKind.Transport);

    // Retired slots are reusable. This runs more than the simultaneous limit
    // without a socket and also proves retained path/argument accounting drops
    // back to the two subscriptions above after each removal.
    var socket: owned WebSocket? = nil;
    var querySetVersion: uint(32) = 0;
    const baselineRetained = manager.handle.retainedBytes.read();
    for cycle in 0..<80 {
      var recycled = new shared Subscription(
        (100 + cycle):uint(32), "demo:recycled", "{}"
      );
      recycled.active.write(true);
      recycled.removeGeneration.write(1);
      recycled.removePending.write(true);
      manager.slots[2] = recycled;
      assert(manager.reserveBytes(recycled.retainedCost));
      assert(manager.processRemovals(socket, querySetVersion));
      assert(manager.slots[2] == nil);
      assert(manager.handle.retainedBytes.read() == baselineRetained);
    }

    // Distinct near-max payloads across many subscriptions share one global
    // budget. Pressure produces bounded protocol updates instead of allowing
    // 64 independent 4 MiB mailboxes to approach 256 MiB.
    var pressureText = "x";
    for 1..20 do pressureText += pressureText;
    var pressured: [0..<40] shared Subscription?;
    for entryIndex in pressured.domain {
      const queryId = (1000 + entryIndex):uint(32);
      var entry = new shared Subscription(
        queryId, "demo:pressure" + entryIndex:string, "{}"
      );
      entry.handle = manager.handle;
      assert(manager.reserveBytes(entry.retainedCost));
      pressured[entryIndex] = entry;
      entry.push(new liveUpdate(
        available=true, hasValue=true,
        valueJson=jsonQuote(pressureText + entryIndex:string)
      ));
    }
    assert(manager.handle.retainedBytes.read() <= 32 * 1024 * 1024);
    var pressureFailures = 0;
    for entry in pressured do if entry != nil {
      const update = entry!.next(0.01);
      if update.failure.isPresent then pressureFailures += 1;
      assert(manager.releaseBytes(entry!.retainedCost));
    }
    assert(pressureFailures > 0);
    for entryIndex in pressured.domain do pressured[entryIndex] = nil;
    assert(manager.releaseBytes(before.retainedCost));
    assert(manager.releaseBytes(after.retainedCost));
    manager.slots[0] = nil;
    manager.slots[1] = nil;
    assert(manager.handle.retainedBytes.read() == 0);
    assert(!manager.handle.accountingUnderflow.read());
    assert(!manager.releaseBytes(1));
    assert(manager.handle.accountingUnderflow.read());
    assert(manager.handle.retainedBytes.read() == 0);
    manager.handle.stopped.write(true);
    manager.stopped.write(true);

    // The Client lifecycle lock publishes exactly one shared Live owner when
    // two callers subscribe together, and removes that owner before close can
    // race a later snapshot. Loopback refusal keeps this deterministic and
    // independent of a Convex deployment.
    var lifecycleClient = new shared Client("http://127.0.0.1:1");
    var lifecycleGo: sync bool;
    var subscribeDoneA: sync bool;
    var subscribeDoneB: sync bool;
    const retainedClientA = lifecycleClient;
    begin with (in retainedClientA) {
      lifecycleGo.readFF();
      retainedClientA.subscribe("demo:a", "{}", 0.05);
      subscribeDoneA.writeEF(true);
    }
    const retainedClientB = lifecycleClient;
    begin with (in retainedClientB) {
      lifecycleGo.readFF();
      retainedClientB.subscribe("demo:b", "{}", 0.05);
      subscribeDoneB.writeEF(true);
    }
    lifecycleGo.writeEF(true);
    subscribeDoneA.readFE();
    subscribeDoneB.readFE();
    assert(lifecycleClient.live != nil);
    assert(!lifecycleClient.close(1.0).isPresent);
    assert(lifecycleClient.live == nil);

    var closingClient = new shared Client("http://127.0.0.1:1");
    var closeRaceGo: sync bool;
    var closeRaceSubscribed: sync bool;
    var closeRaceClosed: sync bool;
    const retainedClosingSubscriber = closingClient;
    begin with (in retainedClosingSubscriber) {
      closeRaceGo.readFF();
      retainedClosingSubscriber.subscribe("demo:race", "{}", 0.05);
      closeRaceSubscribed.writeEF(true);
    }
    const retainedClosingOwner = closingClient;
    begin with (in retainedClosingOwner) {
      closeRaceGo.readFF();
      retainedClosingOwner.close(1.0);
      closeRaceClosed.writeEF(true);
    }
    closeRaceGo.writeEF(true);
    closeRaceSubscribed.readFE();
    closeRaceClosed.readFE();
    assert(closingClient.live == nil && closingClient.closed.read());

    writeln("chapel client tests passed");
  }
}
