module: convex

// -------------------------------------------------------------------------
// Language-local unit coverage for the WebSocket framing layer and the
// Live sync state machine.
//
// convex-sync.dylan is a single-owner reactor with no real concurrency
// primitive backing it (see that file's header comment), so -- exactly
// like the ALGOL 60 reference client's live-test.alg -- this suite tests
// the sync state machine's own logic directly, by constructing
// <sync-manager>/<subscription> fixtures and feeding them hand-built
// Transition messages, rather than by running a live fixture server
// concurrently with the client under test in one process. What a real
// WebSocket peer is needed for (framing, masking, the handshake's
// Sec-WebSocket-Accept check) is proven separately below against a real
// public echo server.
// -------------------------------------------------------------------------

define variable *failures* :: <integer> = 0;

define function check (label :: <byte-string>, ok? :: <boolean>) => ()
  if (ok?)
    format-out("ok - %s\n", label);
  else
    *failures* := *failures* + 1;
    format-out("FAIL - %s\n", label);
  end if;
end function;

define function test-base64-and-utf8 () => ()
  check("base64 encodes the empty input", base64-encode(as(<byte-vector>, #[])) = "");
  check("base64 encodes one byte with double padding", base64-encode(as(<byte-vector>, #[102])) = "Zg==");
  check("base64 encodes two bytes with single padding", base64-encode(as(<byte-vector>, #[102, 111])) = "Zm8=");
  check("base64 encodes three bytes with no padding", base64-encode(as(<byte-vector>, #[102, 111, 111])) = "Zm9v");
  check("base64 encodes four bytes across two groups",
        base64-encode(as(<byte-vector>, #[102, 111, 111, 98])) = "Zm9vYg==");

  check("valid-utf8? accepts plain ASCII", valid-utf8?(string-to-bytes("hello")));
  check("valid-utf8? accepts a two-byte sequence", valid-utf8?(as(<byte-vector>, #[#xC3, #xA9])));
  check("valid-utf8? rejects a truncated sequence", ~valid-utf8?(as(<byte-vector>, #[#xC3])));
  check("valid-utf8? rejects a bad continuation byte", ~valid-utf8?(as(<byte-vector>, #[#xC3, #x28])));
end function;

define function test-ws-handshake-and-echo () => ()
  // A real handshake (including the Sec-WebSocket-Accept check) and a
  // real masked-request/unmasked-response round trip, against a public
  // echo server -- this client does not skip Sec-WebSocket-Accept
  // verification the way a from-scratch implementation without easy
  // access to SHA-1 might have to (see convex-native.dylan's cx-sha1).
  let url = parse-convex-url("https://ws.postman-echo.com");
  let conn = cx-connect-tls(url.url-host, url.url-port, cx-now-ms() + 8000);
  check("could connect to the public echo server", conn & #t);
  if (conn)
    let handshook? = ws-handshake(conn, url.url-host, "/raw", cx-now-ms() + 5000);
    check("WebSocket handshake succeeds with a verified Sec-WebSocket-Accept", handshook?);
    if (handshook?)
      let reader = ws-open-reader(conn);
      let sent? = ws-send-text(conn, "hello-dylan", cx-now-ms() + 5000);
      check("ws-send-text succeeds", sent?);
      let (kind, payload) = ws-recv-message(reader, cx-now-ms() + 5000);
      check("the echoed message is a text frame", kind = #"text");
      check("the echoed text matches exactly", payload = "hello-dylan");
      ws-send-close(conn, cx-now-ms() + 2000);
    end if;
    cx-close(conn);
  end if;
end function;

define function test-timestamp-encoding () => ()
  check("the zero timestamp encodes to the documented sentinel", ts-to-base64(0) = $ts-zero);
  check("a nonzero timestamp round-trips through base64",
        base64-to-ts(ts-to-base64(1234567890123)) = 1234567890123);
  check("a large (>2^53) timestamp round-trips exactly",
        base64-to-ts(ts-to-base64(9007199254740993)) = 9007199254740993);
  check("non-base64 input is rejected rather than misparsed", ~base64-to-ts("not-base64!!"));
end function;

// -- fixture helpers for the sync state machine tests below --

define function fixture-mgr () => (mgr :: <sync-manager>)
  sync-manager-new(parse-convex-url("http://127.0.0.1:1"))
end function;

define function fixture-transition
    (start-qs :: <integer>, start-id :: <integer>, start-ts :: <byte-string>,
     end-qs :: <integer>, end-id :: <integer>, end-ts :: <byte-string>,
     modifications :: <sequence>)
 => (msg :: <string-table>)
  let start-v = make-json-object();
  json-object-set!(start-v, "querySet", start-qs);
  json-object-set!(start-v, "identity", start-id);
  json-object-set!(start-v, "ts", start-ts);
  let end-v = make-json-object();
  json-object-set!(end-v, "querySet", end-qs);
  json-object-set!(end-v, "identity", end-id);
  json-object-set!(end-v, "ts", end-ts);
  let obj = make-json-object();
  json-object-set!(obj, "type", "Transition");
  json-object-set!(obj, "startVersion", start-v);
  json-object-set!(obj, "endVersion", end-v);
  json-object-set!(obj, "modifications", modifications);
  obj
end function;

define function fixture-query-updated (query-id :: <integer>, value :: <object>) => (mod :: <string-table>)
  let mod = make-json-object();
  json-object-set!(mod, "type", "QueryUpdated");
  json-object-set!(mod, "queryId", query-id);
  json-object-set!(mod, "value", value);
  mod
end function;

define function fixture-query-failed (query-id :: <integer>, message :: <byte-string>) => (mod :: <string-table>)
  let mod = make-json-object();
  json-object-set!(mod, "type", "QueryFailed");
  json-object-set!(mod, "queryId", query-id);
  json-object-set!(mod, "errorMessage", message);
  mod
end function;

define function attach-subscription (mgr :: <sync-manager>, query-id :: <integer>) => (sub :: <subscription>)
  let args = make-json-object();
  let sub = make(<subscription>, query-id: query-id, path: "demo:state", args: args);
  element(mgr.sm-subscriptions, query-id) := sub;
  sub
end function;

define function test-transition-application () => ()
  let mgr = fixture-mgr();
  let sub = attach-subscription(mgr, 0);

  // Add, then an initial QueryUpdated.
  let value0 = make-json-object();
  json-object-set!(value0, "count", 0);
  let t1 = fixture-transition(0, 0, $ts-zero, 1, 0, ts-to-base64(1), vector(fixture-query-updated(0, value0)));
  let (ok1, err1) = apply-transition(mgr, t1);
  check("a well-formed Transition applies cleanly", ok1);
  check("the initial value is queued for delivery", sub.sub-queue.size = 1);
  let delivered0 = pop(sub.sub-queue);
  check("the initial delivered value matches the server's", json-values-equal?(delivered0.upd-value, value0));
  check("remote query-set version advances", mgr.sm-remote-query-set = 1);

  // An external update: a different value with a matching startVersion.
  let value1 = make-json-object();
  json-object-set!(value1, "count", 1);
  let t2 = fixture-transition(1, 0, ts-to-base64(1), 2, 0, ts-to-base64(2), vector(fixture-query-updated(0, value1)));
  let (ok2, _err2) = apply-transition(mgr, t2);
  check("a second well-formed Transition applies", ok2);
  check("the updated value is queued", sub.sub-queue.size = 1);
  let delivered1 = pop(sub.sub-queue);
  check("the updated delivered value matches", json-values-equal?(delivered1.upd-value, value1));

  // A Transition whose startVersion does not match local state is rejected.
  let bad-t = fixture-transition(99, 0, $ts-zero, 100, 0, ts-to-base64(1), #[]);
  let (ok3, err3) = apply-transition(mgr, bad-t);
  check("a Transition with a stale startVersion is rejected", ~ok3);
  check("the rejection names the version mismatch", err3 = "Transition start version does not match local version");
end function;

define function test-query-failed-then-recovery () => ()
  let mgr = fixture-mgr();
  let sub = attach-subscription(mgr, 5);

  let t-fail = fixture-transition(0, 0, $ts-zero, 1, 0, ts-to-base64(1),
                                    vector(fixture-query-failed(5, "room must be nonzero")));
  let (ok1, _e1) = apply-transition(mgr, t-fail);
  check("QueryFailed applies", ok1);
  let failed-update = pop(sub.sub-queue);
  check("a QueryFailed modification is delivered as an error", failed-update.upd-kind = #"error");
  check("the error carries the server's message", failed-update.upd-error.err-message = "room must be nonzero");
  check("a query-level failure is reported as FunctionError", failed-update.upd-error.err-name = "FunctionError");

  let recovered-value = make-json-object();
  json-object-set!(recovered-value, "count", 3);
  let t-recover = fixture-transition(1, 0, ts-to-base64(1), 2, 0, ts-to-base64(2),
                                       vector(fixture-query-updated(5, recovered-value)));
  let (ok2, _e2) = apply-transition(mgr, t-recover);
  check("the same subscription recovers on the next Transition", ok2);
  let recovered-update = pop(sub.sub-queue);
  check("recovery delivers a value, not another error", recovered-update.upd-kind = #"value");
end function;

define function test-rehydration-suppression () => ()
  let mgr = fixture-mgr();
  let sub = attach-subscription(mgr, 7);
  let value = make-json-object();
  json-object-set!(value, "count", 2);
  sub.sub-last-value := value;
  sub.sub-rehydrating? := #t;

  // The same value again after a reconnect must be suppressed...
  let t-same = fixture-transition(0, 0, $ts-zero, 1, 0, ts-to-base64(1),
                                    vector(fixture-query-updated(7, value)));
  apply-transition(mgr, t-same);
  check("an unchanged value after rehydration is not queued for delivery", sub.sub-queue.size = 0);
  check("rehydrating clears after the first post-reconnect Transition, suppressed or not",
        ~sub.sub-rehydrating?);

  // ...but a genuinely different one must still be delivered.
  let sub2 = attach-subscription(mgr, 8);
  sub2.sub-last-value := value;
  sub2.sub-rehydrating? := #t;
  let changed-value = make-json-object();
  json-object-set!(changed-value, "count", 3);
  let t-changed = fixture-transition(1, 0, ts-to-base64(1), 2, 0, ts-to-base64(2),
                                       vector(fixture-query-updated(8, changed-value)));
  apply-transition(mgr, t-changed);
  check("a changed value after rehydration is delivered, not suppressed", sub2.sub-queue.size = 1);
end function;

define function test-backoff-and-debug-disconnect () => ()
  let mgr = fixture-mgr();
  check("backoff starts at 100ms", mgr.sm-backoff-ms = 100);
  sync-schedule-retry(mgr, #f);
  check("the first organic retry doubles the backoff for next time", mgr.sm-backoff-ms = 200);
  for (i from 0 below 10)
    sync-schedule-retry(mgr, #f);
  end for;
  check("backoff is clamped at the documented 15s ceiling", mgr.sm-backoff-ms = 15000);

  // debugDisconnect on a manager with no live connection is a hard error.
  check("debugDisconnect fails cleanly with nothing connected", ~sync-debug-disconnect(mgr));

  // Simulate an established connection (a real socket is not needed to
  // test the bookkeeping debugDisconnect is responsible for).
  mgr.sm-connected? := #t;
  mgr.sm-conn := make(<connection>, fd: -1);
  mgr.sm-connection-count := 3;
  let sub = attach-subscription(mgr, 0);
  sub.sub-last-value := "seen";
  let disconnected? = sync-debug-disconnect(mgr);
  check("debugDisconnect succeeds while connected", disconnected?);
  check("the connection is retired before returning", ~mgr.sm-connected?);
  check("connectionCount is incremented", mgr.sm-connection-count = 4);
  check("lastCloseReason is the literal DebugDisconnect", mgr.sm-last-close-reason = "DebugDisconnect");
  check("reconnect is scheduled at a fixed short delay, not exponential backoff",
        mgr.sm-reconnect-at-ms - cx-now-ms() <= 100 & mgr.sm-reconnect-at-ms - cx-now-ms() >= 0);
  check("every active subscription is flagged for rehydration on reconnect", sub.sub-rehydrating?);
end function;

define function test-error-does-not-strand-subscription () => ()
  // After a structured error is published, the same subscription must
  // still be able to receive a later valid value -- i.e. an error never
  // permanently strands it.
  let mgr = fixture-mgr();
  let sub = attach-subscription(mgr, 0);
  sub.sub-established? := #t;
  sync-publish-error-all(mgr, "ProtocolError", "received a malformed Live message", #t);
  let errored = pop(sub.sub-queue);
  check("a published transport/protocol error reaches the subscription", errored.upd-kind = #"error");

  // Reconnect bookkeeping, then a fresh, valid Transition.
  sync-disconnect(mgr, "ProtocolError: test");
  let value = make-json-object();
  json-object-set!(value, "count", 9);
  let t = fixture-transition(0, 0, $ts-zero, 1, 0, ts-to-base64(1), vector(fixture-query-updated(0, value)));
  let (ok?, _e) = apply-transition(mgr, t);
  check("the subscription can still receive a valid value after the error", ok? & sub.sub-queue.size = 1);
end function;

define function test-connect-and-modify-messages () => ()
  let mgr = fixture-mgr();
  let connect-text = build-connect-message(mgr);
  let (connect-obj, ok1) = json-parse(connect-text);
  check("the Connect message is valid JSON", ok1);
  check("Connect carries the session id", json-object-ref(connect-obj, "sessionId") = mgr.sm-session-id);
  check("Connect starts at connectionCount 0", json-object-ref(connect-obj, "connectionCount") = 0);
  check("Connect starts with lastCloseReason InitialConnect",
        json-object-ref(connect-obj, "lastCloseReason") = "InitialConnect");
  check("Connect omits maxObservedTimestamp before any Transition has been seen",
        ~json-object-has-key?(connect-obj, "maxObservedTimestamp"));

  let sub = attach-subscription(mgr, 3);
  sub.sub-path := "demo:state";
  let modify-text = build-modify-message(mgr, vector(sub), #[]);
  let (modify-obj, ok2) = json-parse(modify-text);
  check("the ModifyQuerySet message is valid JSON", ok2);
  check("ModifyQuerySet starts the version at baseVersion 0", json-object-ref(modify-obj, "baseVersion") = 0);
  check("ModifyQuerySet bumps to newVersion 1", json-object-ref(modify-obj, "newVersion") = 1);
  let mods = json-object-ref(modify-obj, "modifications");
  check("exactly one modification is present", mods.size = 1);
  check("the modification is an Add", json-object-ref(mods[0], "type") = "Add");
  check("the Add carries the query's udfPath", json-object-ref(mods[0], "udfPath") = "demo:state");
  let args-array = json-object-ref(mods[0], "args");
  check("Add's args is a one-element array (unlike the HTTP call's bare object)", args-array.size = 1);
end function;

define function main () => ()
  test-base64-and-utf8();
  test-ws-handshake-and-echo();
  test-timestamp-encoding();
  test-transition-application();
  test-query-failed-then-recovery();
  test-rehydration-suppression();
  test-backoff-and-debug-disconnect();
  test-error-does-not-strand-subscription();
  test-connect-and-modify-messages();
  force-out();
  if (*failures* > 0)
    format-err(concatenate(integer-to-string(*failures*), " live-test check(s) failed\n"));
    force-err();
    c-exit(1);
  end if;
end function;

main();
