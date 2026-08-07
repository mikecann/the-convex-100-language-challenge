module ChapelConvexFixtureTest {
  use Convex;
  use ConvexTransport;

  proc requireValue(result: callResult, expected: int(64)) {
    assert(result.ok, result.failure.message);
    const (valid, value) = jsonIntegralField(result.valueJson, "count");
    assert(valid && value == expected);
  }

  proc nextValue(subscription: borrowed Subscription,
                 expected: int(64)): liveUpdate {
    // The first caller subscribes before the Live reconnect loop has even
    // dialed once, so this budget must outlast the whole hostile pre-Add
    // gauntlet (nine dial attempts, several of which deliberately stall,
    // each with its own up-to-25s fixture-teardown margin -- see the
    // matching comments in hostile_peer.py) ahead of the first real
    // hydration, not just one round's own margin. This is generous test
    // patience for a loaded/virtualized host, not a claim about how fast
    // delivery must be.
    const deadline = monotonicMillis() + 40000;
    while monotonicMillis() < deadline {
      const update = subscription.next(0.25);
      if !update.available then continue;
      if update.failure.isPresent {
        // AGENTS.md's Live-acceptance contract requires exactly this: a
        // TransportError must not permanently strand an otherwise valid
        // subscription, and a later valid value must still arrive. A
        // reconnect racing the fixture's own connection teardown under a
        // loaded/virtualized host can legitimately surface one of these
        // in transit (see the margin comments on debugDisconnect and in
        // hostile_peer.py) -- that is the documented recovery path, not a
        // bug, so only Transport-kind failures are passed through here.
        // A Function or Protocol failure still fails hard below: those
        // indicate a real decode or application-logic defect, not
        // reconnect timing.
        assert(update.failure.kind == FailureKind.Transport,
               "a stale Live failure preceded the expected value: " +
               update.failure.message);
        continue;
      }
      const (valid, value) = jsonIntegralField(update.valueJson, "count");
      if valid {
        assert(value == expected, "duplicate hydration escaped suppression");
        return update;
      }
    }
    halt("fixture did not deliver count ", expected);
    return new liveUpdate();
  }

  proc main(args: [] string) {
    assert(args.size == 5,
           "HTTP, TLS, slow, and short-write WebSocket URLs are required");
    var client = new owned Client(args[1]);

    requireValue(client.query(
      "fixture:http", "{\"case\":\"bounded\"}", 1.0
    ), 1);
    requireValue(client.query(
      "fixture:http", "{\"case\":\"chunked\"}", 1.0
    ), 2);
    assert(!client.query(
      "fixture:http", "{\"case\":\"oversized\"}", 1.0
    ).ok);
    assert(!client.query(
      "fixture:http", "{\"case\":\"dribbled_status\"}", 0.1
    ).ok);
    assert(!client.query(
      "fixture:http", "{\"case\":\"malformed_envelope\"}", 1.0
    ).ok);
    assert(!client.query(
      "fixture:http", "{\"case\":\"invalid_logs\"}", 1.0
    ).ok);
    assert(!client.query(
      "fixture:http", "{\"case\":\"non_2xx\"}", 1.0
    ).ok);
    assert(client.query(
      "fixture:http", "{\"case\":\"missing_error_message\"}", 1.0
    ).failure.kind == FailureKind.Protocol);
    assert(client.query(
      "fixture:http", "{\"case\":\"wrong_error_message\"}", 1.0
    ).failure.kind == FailureKind.Protocol);
    assert(!client.query(
      "fixture:http", "{\"case\":\"invalid_utf8\"}", 1.0
    ).ok);
    assert(!client.setAuth("opaque-ONE_~!$&'*+.^`|").isPresent);
    requireValue(client.query(
      "fixture:http", "{\"case\":\"auth_first\"}", 1.0
    ), 4);
    assert(!client.setAuth("replacement-TWO").isPresent);
    requireValue(client.query(
      "fixture:http", "{\"case\":\"auth_replaced\"}", 1.0
    ), 4);
    assert(!client.setAuth("").isPresent);
    requireValue(client.query(
      "fixture:http", "{\"case\":\"auth_empty\"}", 1.0
    ), 4);
    var tlsClient = new owned Client(args[2]);
    requireValue(tlsClient.query(
      "fixture:http", "{\"case\":\"tls\"}", 0.5
    ), 9);
    tlsClient.close();

    var slowSocket = new owned WebSocket();
    assert(slowSocket.connect(args[3], "chapel-0.1.0",
                              monotonicMillis() + 1000).numBytes == 0);
    var slowPayload = "x";
    for 1..23 do slowPayload += slowPayload;
    const slowSendStarted = monotonicMillis();
    const slowSendError = slowSocket.send(
      slowPayload, monotonicMillis() + 100
    );
    assert(slowSendError.numBytes > 0,
           "slow WebSocket peer did not expire the send deadline");
    assert(monotonicMillis() - slowSendStarted < 500,
           "slow WebSocket send exceeded its cumulative deadline");
    slowSocket.close(monotonicMillis() + 250);

    var shortWriteSocket = new owned WebSocket();
    assert(shortWriteSocket.connect(args[4], "chapel-0.1.0",
                                    monotonicMillis() + 1000).numBytes == 0);
    var exactPayload = "short-write:";
    var exactBody = "x";
    for 1..23 do exactBody += exactBody;
    exactPayload += exactBody;
    assert(shortWriteSocket.send(
      exactPayload, monotonicMillis() + 5000
    ).numBytes == 0, "short-write WebSocket send failed");
    // The fixture peer paces its own reads with a fixed per-chunk sleep
    // (independent of the receive window) while it assembles the 8 MiB
    // payload, which puts an ~1.0-1.1s floor under how soon it can reply
    // regardless of how fast the send completes. Measured completion is
    // ~1.0-1.1s; this budget keeps roughly 2x margin over that floor
    // instead of racing it.
    const exactReply = shortWriteSocket.receive(monotonicMillis() + 3000);
    assert(exactReply.status == 1 && exactReply.message == "{\"exact\":true}",
           "short-write peer did not decode one exact text message");
    shortWriteSocket.close(monotonicMillis() + 250);
    requireValue(client.query(
      "fixture:http", "{\"case\":\"recovery\"}", 1.0
    ), 3);

    const (subscription, failure) = client.subscribe(
      "fixture:live", "{\"room\":\"fixture\"}", 12.0
    );
    assert(!failure.isPresent && subscription != nil, failure.message);
    const initial = nextValue(subscription!, 0);
    const (hasLabel, labelValue) = jsonString(initial.valueJson, "label");
    assert(hasLabel && labelValue == "café");

    for expected in 1..5 {
      // Same generous, loaded-host margin as nextValue() above: retiring
      // the old connection and scheduling the reconnect goes through the
      // same fixture round-trip that showed multi-second scheduling
      // delays elsewhere in this file, so this is fixture-adjacent test
      // patience, not a claim about debugDisconnect's real-world latency.
      assert(!client.debugDisconnect(25.0).isPresent);
      nextValue(subscription!, expected);
    }

    var sawQueryFailure = false;
    const failureDeadline = monotonicMillis() + 3000;
    while monotonicMillis() < failureDeadline {
      const update = subscription!.next(0.25);
      if update.failure.kind == FailureKind.Function {
        assert(update.failure.message == "fixture query failed");
        sawQueryFailure = true;
        break;
      }
    }
    assert(sawQueryFailure);
    nextValue(subscription!, 6);
    var attachedCloseGo: sync bool;
    var subscriptionCloseDone: sync convexFailure;
    var clientCloseDone: sync convexFailure;
    const retainedAttached = subscription;
    const clientBorrow = client.borrow();
    begin with (in retainedAttached) {
      attachedCloseGo.readFF();
      subscriptionCloseDone.writeEF(retainedAttached!.close(2.0));
    }
    begin {
      attachedCloseGo.readFF();
      clientCloseDone.writeEF(clientBorrow.close(2.0));
    }
    const closeStarted = monotonicMillis();
    attachedCloseGo.writeEF(true);
    assert(!subscriptionCloseDone.readFE().isPresent);
    assert(!clientCloseDone.readFE().isPresent);
    assert(client.live == nil, "Client retained the stopped Live owner");
    assert(monotonicMillis() - closeStarted < 500,
           "hostile peer exceeded the cumulative close deadline");
    writeln("chapel hostile peer fixtures passed");
  }
}
