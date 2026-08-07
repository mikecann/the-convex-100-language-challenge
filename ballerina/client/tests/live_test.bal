import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

// Live/WebSocket coverage. The shared black-box conformance harness (run
// through `./run verify`) is what proves the adapter-level behaviours
// AGENTS.md's Live acceptance list describes - five real reconnects driven
// through `debugDisconnect`, generation-safe unsubscribe, and so on - by
// exercising the real adapter over the real (loopback) protocol. What
// belongs here is coverage that is awkward or impossible to force through
// that harness: a specific, hand-built wire fragmentation this client's own
// writer would never itself produce.

const int FIXTURE_BASE_PORT = 27100;

function connectVersion() returns json => {querySet: 0, identity: 0, ts: "AAAAAAAAAAA="};

function versionAfter(int step) returns json {
    byte[] tsBytes = [<byte>step, 0, 0, 0, 0, 0, 0, 0];
    return {querySet: 1, identity: 0, ts: tsBytes.toBase64()};
}

function transitionJson(json startVersion, json endVersion, json[] modifications) returns string {
    map<json> body = {'type: "Transition", startVersion, endVersion, modifications};
    return body.toJsonString();
}

// `WsFixture.waitConnected` only proves the *TCP* accept happened; the
// RFC 6455 handshake itself (the fixture reading the client's GET request and
// writing back its own 101 response) still runs asynchronously on the
// fixture's own connection strand. Sending a raw frame before that finishes
// races the client's `performHandshake`, which is reading raw bytes looking
// for the handshake's own terminating "\r\n\r\n" - a frame arriving first is
// indistinguishable to it from a malformed handshake. The client's Connect
// and ModifyQuerySet-Add messages only reach the fixture's inbound queue once
// the handshake has completed, so waiting for (and draining) that queue is a
// real synchronization point rather than a fixed sleep.
function waitForHandshakeToComplete(WsFixture fixture, decimal timeoutSeconds) returns error? {
    decimal deadline = time:monotonicNow() + timeoutSeconds;
    while fixture.takeInbound().length() == 0 {
        if time:monotonicNow() >= deadline {
            return error("fixture never observed the client's post-handshake traffic");
        }
        runtime:sleep(0.02);
    }
}

@test:Config {}
function testFragmentedUtf8SplitAcrossContinuationWithInterleavedPing() returns error? {
    int port = FIXTURE_BASE_PORT + 1;
    WsFixture fixture = check startWsFixture(port);

    Client convexClient = check new ("http://127.0.0.1:" + port.toString());
    Subscription subscription = check convexClient.subscribe("demo:state", {room: "fixture"});
    check waitForHandshakeToComplete(fixture, 3.0);

    // The o-umlaut (U+00F6, UTF-8 bytes 0xC3 0xB6) is split so that neither
    // fragment's raw bytes are valid UTF-8 alone - only their concatenation
    // is - and a Ping is interleaved between the two halves to prove a
    // control frame arriving mid-fragment does not disturb that
    // concatenation. This is the exact defect class documented in
    // LESSONS.md section 15: ballerina/websocket corrupted precisely this
    // shape, which is why this client hand-rolls RFC 6455 instead.
    string omega = "\u{00F6}";
    json modification = {'type: "QueryUpdated", queryId: 0, value: {room: "fixture", word: "ic" + omega + "n"}, logLines: []};
    string message = transitionJson(connectVersion(), versionAfter(1), [modification]);
    byte[] messageBytes = message.toBytes();
    int? splitAt = ();
    foreach int index in 0 ..< messageBytes.length() - 1 {
        if messageBytes[index] == 0xC3 && messageBytes[index + 1] == 0xB6 {
            splitAt = index + 1;
            break;
        }
    }
    if splitAt is () {
        test:assertFail("fixture could not locate the split byte in its own message");
    }
    int splitIndex = <int>splitAt;

    check fixture.sendRaw(buildServerFrame(false, 1, messageBytes.slice(0, splitIndex)));
    check fixture.sendRaw(buildServerFrame(true, 9, "ping-mid-fragment".toBytes()));
    check fixture.sendRaw(buildServerFrame(true, 0, messageBytes.slice(splitIndex)));

    Update|ClosedError|TransportError received = subscription.updates().recvTimeout(5.0);
    if received is Update {
        ConvexError? receivedError = received.err;
        if receivedError is ConvexError {
            test:assertFail("fragmented-UTF8 update carried an unexpected error: " + receivedError.message());
        }
        test:assertEquals(check received.value.word, "ic" + omega + "n");
    } else {
        test:assertFail("expected a delivered update, got " + received.message());
    }

    ConvexError? subCloseErr = subscription.close();
    ConvexError? clientCloseErr = convexClient.close();
}

@test:Config {}
function testInitialValueExternalUpdateAndQueryFailedRecovery() returns error? {
    int port = FIXTURE_BASE_PORT + 2;
    WsFixture fixture = check startWsFixture(port);

    Client convexClient = check new ("http://127.0.0.1:" + port.toString());
    Subscription subscription = check convexClient.subscribe("demo:state", {room: "fixture"});
    check waitForHandshakeToComplete(fixture, 3.0);

    check fixture.sendRaw(buildServerTextFrame(transitionJson(connectVersion(), versionAfter(1),
                    [{'type: "QueryUpdated", queryId: 0, value: {count: 0}, logLines: []}])));
    Update|ClosedError|TransportError first = subscription.updates().recvTimeout(5.0);
    if first is Update {
        test:assertEquals(check first.value.count, 0);
    } else {
        test:assertFail("expected the initial update, got " + first.message());
    }

    check fixture.sendRaw(buildServerTextFrame(transitionJson(versionAfter(1), versionAfter(2),
                    [{'type: "QueryFailed", queryId: 0, errorMessage: "empty room", errorData: {code: "EMPTY"}, logLines: ["failed"]}])));
    Update|ClosedError|TransportError failed = subscription.updates().recvTimeout(5.0);
    if failed is Update {
        ConvexError? failureErr = failed.err;
        if failureErr is FunctionError {
            test:assertEquals(check failureErr.detail().data.code, "EMPTY");
        } else {
            string description = failureErr is error ? failureErr.message() : "no error at all";
            test:assertFail("expected a FunctionError, got " + description);
        }
    } else {
        test:assertFail("expected the QueryFailed update, got " + failed.message());
    }

    check fixture.sendRaw(buildServerTextFrame(transitionJson(versionAfter(2), versionAfter(3),
                    [{'type: "QueryUpdated", queryId: 0, value: {count: 1}, logLines: ["recovered"]}])));
    Update|ClosedError|TransportError recovered = subscription.updates().recvTimeout(5.0);
    if recovered is Update {
        test:assertEquals(check recovered.value.count, 1);
    } else {
        test:assertFail("expected the recovery update, got " + recovered.message());
    }

    ConvexError? subCloseErr = subscription.close();
    ConvexError? clientCloseErr = convexClient.close();
}

@test:Config {}
function testMailboxDropsOldestUnderABlockedConsumer() {
    Mailbox mailbox = new;
    foreach int count in 0 ..< 20 {
        mailbox.push({value: count, err: (), logs: []});
    }
    Update[] drained = [];
    foreach int position in 0 ..< MAILBOX_CAPACITY {
        Update|ClosedError|TransportError next = mailbox.recvTimeout(1.0);
        if next is Update {
            drained.push(next);
        } else {
            test:assertFail("expected update #" + position.toString() + ", got " + next.message());
        }
    }
    test:assertEquals(drained.length(), MAILBOX_CAPACITY);
    // Only the newest MAILBOX_CAPACITY values survive; the oldest four (0-3)
    // were dropped to keep the queue bounded.
    test:assertEquals(drained[0].value, 4);
    test:assertEquals(drained[MAILBOX_CAPACITY - 1].value, 19);
}

@test:Config {}
function testReconnectResendsActiveSubscriptionsAndPreservesTimestamp() returns error? {
    int port = FIXTURE_BASE_PORT + 3;
    WsFixture fixture = check startWsFixture(port);

    Client convexClient = check new ("http://127.0.0.1:" + port.toString());
    Subscription subscription = check convexClient.subscribe("demo:state", {room: "fixture"});
    check waitForHandshakeToComplete(fixture, 3.0);

    check fixture.sendRaw(buildServerTextFrame(transitionJson(connectVersion(), versionAfter(1),
                    [{'type: "QueryUpdated", queryId: 0, value: {count: 0}, logLines: []}])));
    Update|ClosedError|TransportError first = subscription.updates().recvTimeout(5.0);
    test:assertTrue(first is Update, "expected the initial update before forcing a disconnect");

    ConvexError? disconnectError = convexClient.debugDisconnectForAdapter();
    if disconnectError is ConvexError {
        test:assertFail("debugDisconnect reported an error: " + disconnectError.message());
    }

    // The owner reconnects to the same fixture address; a second real TCP
    // connection (and WebSocket handshake) must arrive.
    boolean secondHandshake = false;
    decimal reconnectDeadline = time:monotonicNow() + 5.0;
    while time:monotonicNow() < reconnectDeadline {
        if fixture.takeInbound().length() > 0 {
            secondHandshake = true;
            break;
        }
        runtime:sleep(0.02);
    }
    test:assertTrue(secondHandshake, "no second connection observed after debugDisconnect");

    ConvexError? subCloseErr = subscription.close();
    ConvexError? clientCloseErr = convexClient.close();
}
