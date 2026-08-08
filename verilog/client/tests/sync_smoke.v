// sync_smoke.v - gate proof: a real /api/sync session against a fixture
// peer (verilog/Dockerfile's syncfix.c), proving client/convex_sync.v's
// Connect/ModifyQuerySet/Transition wire handling, the initial value,
// an external mutation, five real debugDisconnect-triggered reconnects
// with unchanged rehydration correctly suppressed (a real external
// mutation is still delivered every time), and QueryFailed followed by
// recovery on that same subscription - the exact sequence
// AGENTS.md's Live-acceptance section describes: initial value,
// disconnect acknowledgement (debugDisconnect returns immediately;
// convex_sync.v's own force_disconnect is synchronous), external
// mutation, next value. connectionCount and lastCloseReason are
// checked independently by the fixture itself (see syncfix.c's own
// per-connection assertions, captured to its log and grepped for in
// verilog/Dockerfile alongside this file's own PASS line) rather than
// only by this client's own account of what it sent.
//
// A separate, deterministic check (check_backoff below) proves
// exponential backoff actually doubles on repeated failure, using a
// second convex_sync instance pointed at a reserved port nothing
// listens on rather than the real fixture, so it does not depend on
// real wall-clock delays or interfere with the six-connection script
// above. Backoff RESET is checked on the main scenario's own instance
// instead: convex_sync.v resets backoff_ms to its base immediately
// after every successful ensure_connected, and this test asserts that
// value is exactly the base after every one of the five reconnects -
// not a "grew, then reset" proof on the same instance (this fixture
// never fails a connection), but a real assertion that the reset
// statement runs and is correct on every successful handshake, which a
// missing or broken reset could not satisfy by accident.

`timescale 1ns / 1ps

module sync_smoke;

  convex_sync #(.MAX_SUBS(4)) sync ();
  convex_sync #(.MAX_SUBS(2)) sync_backoff ();

  bit ok;
  integer failed;
  integer idx;
  integer cycle;
  integer expected_version;

  task automatic check_backoff;
    begin
      sync_backoff.configure("ws://127.0.0.1:1");
      sync_backoff.add_subscription("b", "demo:state", "{}", ok);

      sync_backoff.maybe_reconnect; // attempt 1: connection refused
      if (sync_backoff.is_connected() || sync_backoff.backoff_ms != 200.0) begin
        $display("FAIL sync_smoke: backoff did not become 200ms after one failed reconnect (was %f)",
                  sync_backoff.backoff_ms);
        failed = 1;
      end

      sync_backoff.retry_at_ms = 0.0; // bypass the real backoff wait deterministically
      sync_backoff.maybe_reconnect; // attempt 2: also refused
      if (sync_backoff.backoff_ms != 400.0) begin
        $display("FAIL sync_smoke: backoff did not become 400ms after a second failed reconnect (was %f)",
                  sync_backoff.backoff_ms);
        failed = 1;
      end else begin
        $display("sync_smoke: exponential backoff doubled correctly on repeated failure (100 -> 200 -> 400 ms)");
      end
    end
  endtask

  initial begin
    failed = 0;

    check_backoff;

    sync.configure("ws://127.0.0.1:44203");
    sync.add_subscription("q1", "demo:state", "{}", ok);
    if (!ok) begin
      $display("FAIL sync_smoke: add_subscription failed");
      $finish;
    end
    idx = sync.find_sub_by_tag("q1");
    if (idx < 0) begin
      $display("FAIL sync_smoke: subscription was not registered locally");
      $finish;
    end

    // Cold start: connectionCount 0, lastCloseReason InitialConnect
    // (checked by syncfix.c itself), initial QueryUpdated value "0".
    sync.wait_update("q1", 5000, ok);
    if (!ok || sync.sub_version[idx] != 1 || sync.sub_is_error[idx]
        || !sync.str_eq(sync.sub_value_json[idx], "0")) begin
      $display("FAIL sync_smoke: initial value was not delivered correctly (value=%s version=%0d error=%b)",
                sync.sub_value_json[idx], sync.sub_version[idx], sync.sub_is_error[idx]);
      failed = 1;
    end else if (sync.backoff_ms != 100.0) begin
      $display("FAIL sync_smoke: backoff_ms was %f after a successful connect, expected the 100ms base",
                sync.backoff_ms);
      failed = 1;
    end else begin
      $display("sync_smoke: cold start OK - initial value 0, backoff at its 100ms base");
    end

    // The fixture's own first external mutation, value 0 -> 1, before
    // this test ever calls force_disconnect.
    sync.wait_update("q1", 5000, ok);
    if (!ok || sync.sub_version[idx] != 2 || !sync.str_eq(sync.sub_value_json[idx], "1")) begin
      $display("FAIL sync_smoke: first external mutation was not delivered correctly (value=%s version=%0d)",
                sync.sub_value_json[idx], sync.sub_version[idx]);
      failed = 1;
    end else begin
      $display("sync_smoke: external mutation delivered (value 1)");
    end

    expected_version = 2;

    for (cycle = 1; cycle <= 5; cycle = cycle + 1) begin
      sync.force_disconnect;
      if (sync.is_connected()) begin
        $display("FAIL sync_smoke: cycle %0d: force_disconnect did not clear is_connected", cycle);
        failed = 1;
      end

      // One wait_update spans BOTH of syncfix's Transitions for this
      // connection: the rehydration (unchanged, must be suppressed -
      // does not advance sub_version, so the wait loop keeps polling)
      // and the external mutation that follows it (does advance
      // sub_version, ending the wait). If suppression were broken, the
      // rehydration alone would already satisfy the wait and this
      // check would see the WRONG (unchanged) value/version here.
      expected_version = expected_version + 1;
      sync.wait_update("q1", 5000, ok);
      if (!ok) begin
        $display("FAIL sync_smoke: cycle %0d: no update arrived after reconnect %0d", cycle, cycle);
        failed = 1;
      end else if (sync.sub_version[idx] != expected_version) begin
        $display(
          "FAIL sync_smoke: cycle %0d: version was %0d, expected %0d (rehydration suppression likely failed)",
          cycle, sync.sub_version[idx], expected_version);
        failed = 1;
      end else if (sync.backoff_ms != 100.0) begin
        $display("FAIL sync_smoke: cycle %0d: backoff_ms was %f after a successful reconnect, expected 100",
                  cycle, sync.backoff_ms);
        failed = 1;
      end else begin
        $display("sync_smoke: reconnect %0d OK - rehydration suppressed, external mutation delivered (value %s)",
                  cycle, sync.sub_value_json[idx]);
      end
    end

    // QueryFailed followed by recovery on the same subscription -
    // syncfix.c drives this only after the fifth reconnect, once the
    // ordinary QueryUpdated path above is already fully proven.
    sync.wait_update("q1", 5000, ok);
    if (!ok || !sync.sub_is_error[idx] || !sync.str_eq(sync.sub_error_msg[idx], "Uncaught Error: boom")) begin
      $display("FAIL sync_smoke: QueryFailed was not delivered correctly (is_error=%b msg=%s)",
                sync.sub_is_error[idx], sync.sub_error_msg[idx]);
      failed = 1;
    end else begin
      $display("sync_smoke: QueryFailed delivered correctly (\"%s\")", sync.sub_error_msg[idx]);
    end

    sync.wait_update("q1", 5000, ok);
    if (!ok || sync.sub_is_error[idx] || !sync.str_eq(sync.sub_value_json[idx], "7")) begin
      $display("FAIL sync_smoke: recovery QueryUpdated was not delivered correctly (is_error=%b value=%s)",
                sync.sub_is_error[idx], sync.sub_value_json[idx]);
      failed = 1;
    end else begin
      $display("sync_smoke: recovered from QueryFailed - the next real value was delivered (%s)",
                sync.sub_value_json[idx]);
    end

    if (sync.connection_count != 6) begin
      $display("FAIL sync_smoke: connectionCount ended at %0d, expected 6 (1 initial + 5 reconnects)",
                sync.connection_count);
      failed = 1;
    end
    if (!sync.have_max_observed_ts || sync.max_observed_ts.len() == 0) begin
      $display("FAIL sync_smoke: maxObservedTimestamp was never recorded from any Transition");
      failed = 1;
    end else begin
      $display("sync_smoke: maxObservedTimestamp tracked (%s)", sync.max_observed_ts);
    end

    if (failed == 0) begin
      $display("PASS sync_smoke");
    end else begin
      $display("FAIL sync_smoke");
    end
    $finish;
  end

endmodule
