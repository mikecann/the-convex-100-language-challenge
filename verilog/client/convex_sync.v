// convex_sync.v - the client side of the pinned `convex-rs-0.10.4-
// unversioned-sync` realtime profile: one WebSocket connection to
// `/api/sync` carrying `Connect` and `ModifyQuerySet` client messages
// and `Transition` server messages. Built on convex_websocket.v (the
// same connection also completes the RFC 6455 upgrade) the way that
// module is built on convex_http.v.
//
// This module owns its `ws` sub-instance's socket exclusively: every
// task below that touches the connection - ensure_connected,
// force_disconnect, maybe_reconnect, pump - runs to completion before
// returning, and nothing else in this client ever reaches `ws` directly
// (add_subscription/remove_subscription only ever send an extra
// ModifyQuerySet, through the same tasks pump uses). A future
// conformance adapter must preserve that: route every command through
// this module's own tasks rather than reaching ws.hs.transport itself,
// the same "one owner" rule mumps/client/convex.m documents for its
// own livePump/liveMaybeReconnect and delphi-object-pascal/client/
// ConvexSync.pas documents for its own Poll/EnsureConnected.
//
// Wire message shapes (Connect, ModifyQuerySet Add/Remove, Transition
// QueryUpdated/QueryFailed/QueryRemoved) and the rehydration-
// suppression and backoff-reset rules below are cross-checked against
// two already-merged peer implementations of this exact protocol,
// mumps/client/convex.m (liveConnect/liveTransition/liveMaybeReconnect)
// and delphi-object-pascal/client/ConvexSync.pas - not guessed.
//
// Deliberate scope limit: Convex's real Transition also carries a
// startVersion/endVersion pair the mumps client validates for strict
// continuity (each Transition's startVersion must equal the local
// state's last endVersion, endVersion.ts must not move backwards,
// etc.) and rejects a Transition that fails that check as a
// ProtocolError. This module does not implement that continuity check
// - only endVersion.ts itself, for maxObservedTimestamp. AGENTS.md's
// Live-acceptance section requires carrying maxObservedTimestamp
// correctly; it does not require rejecting a state-version
// discontinuity, and the fixture peer in client/tests/sync_smoke.v
// never sends an invalid one. A future hardening pass could add it by
// following mumps/client/convex.m's liveVersion/liveTransition exactly.
//
// Also deliberately out of scope here: the bounded-under-a-stopped-
// reader pending-event queue AGENTS.md's "Conformance executable"
// section describes. That queue belongs to the NDJSON adapter (this
// module's future caller), which is what actually owns a slow or
// stopped consumer to buffer against; this module's own per-
// subscription state is a single latest-value slot per queryId (the
// same "latest value wins, with a version counter" shape mumps'
// subValue/subVersion and delphi's SignatureUnchanged both use), not a
// growing queue.
`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"

module convex_sync #(
  parameter MAX_SUBS = 8,
  parameter BACKOFF_BASE_MS = 100,
  parameter BACKOFF_MAX_MS = 5000
);

  // convex_buffer.v's own KIND_* localparams, redeclared here since (per
  // that file's own header) "a localparam is not meant to be a public
  // constant" - the same convention client/tests/http_smoke.v and
  // client/tests/json_test.v already use for the identical constants.
  localparam JK_NULL   = 1;
  localparam JK_NUMBER = 3;
  localparam JK_STRING = 4;
  localparam JK_ARRAY  = 5;
  localparam JK_OBJECT = 6;

  convex_websocket #(.FRAME_CAP(65536), .MSG_CAP(1048576)) ws ();
  convex_base64 #(.MAXLEN(16)) ts_new_dec ();
  convex_base64 #(.MAXLEN(16)) ts_max_dec ();

  string sync_url;
  bit    connected;
  string session_id;
  string session_id_scratch; // loop-accumulated: see this file's own concatenation rule below
  integer connection_count;
  string last_close_reason;
  integer query_set_version;
  integer next_query_id;
  real backoff_ms;
  real retry_at_ms;
  string max_observed_ts;
  bit have_max_observed_ts;

  // Every loop-accumulated string in this file (a self-referential
  // `x = {x, ...}` built one byte at a time) targets one of these
  // module-level scratch variables, never a task-local or output-port
  // `string` - Icarus 11.0 aborts at run time (vthread.cc:212) on that
  // combination, exactly as documented in convex_http.v's and
  // convex_websocket.v's own header comments; every append below also
  // extracts its source byte into a plain local first, never
  // concatenating a `string[index]` select or a function-call result
  // directly inside `{...}` - the same two workarounds, applied
  // proactively rather than rediscovered.
  string raw_scratch;
  string decoded_scratch;

  bit     sub_active               [0:MAX_SUBS-1];
  string  sub_tag                  [0:MAX_SUBS-1];
  integer sub_query_id             [0:MAX_SUBS-1];
  string  sub_path                 [0:MAX_SUBS-1];
  string  sub_args_json            [0:MAX_SUBS-1];
  bit     sub_has_value            [0:MAX_SUBS-1];
  bit     sub_is_error             [0:MAX_SUBS-1];
  string  sub_value_json           [0:MAX_SUBS-1];
  string  sub_error_msg            [0:MAX_SUBS-1];
  // Raw (un-decoded) JSON span of a QueryFailed modification's own
  // "errorData" member, when the server sent one - the same structured
  // payload demo:fail/demo:requiresNonzero attach a "code" field to over
  // HTTP (see client/convex.v's identical errorData handling for the
  // one-shot call path). Absent from this module until this comment was
  // added: only errorMessage was captured, which happened to be enough
  // for this file's own sync_smoke.v fixture (it never asserts
  // errorData) but not for AGENTS.md's structured-error requirement -
  // cross-checked against delphi-object-pascal/client/ConvexSync.pas's
  // and mumps/client/convex.m's identical extraction of this field.
  bit     sub_has_error_data        [0:MAX_SUBS-1];
  string  sub_error_data_json       [0:MAX_SUBS-1];
  integer sub_version              [0:MAX_SUBS-1];
  bit     sub_awaiting_rehydration [0:MAX_SUBS-1];

  integer i_init;

  initial begin
    sync_url = "";
    connected = 1'b0;
    session_id = "";
    connection_count = 0;
    last_close_reason = "InitialConnect";
    query_set_version = 0;
    next_query_id = 1;
    backoff_ms = BACKOFF_BASE_MS;
    retry_at_ms = 0.0;
    max_observed_ts = "";
    have_max_observed_ts = 1'b0;
    for (i_init = 0; i_init < MAX_SUBS; i_init = i_init + 1) begin
      sub_active[i_init] = 1'b0;
    end
  end

  task automatic configure(input string url);
    begin
      sync_url = url;
    end
  endtask

  function automatic bit is_connected;
    return connected;
  endfunction

  // === small local helpers ============================================

  function automatic byte hex_char(input [3:0] nibble);
    begin
      if (nibble < 10) hex_char = "0" + nibble;
      else hex_char = "a" + (nibble - 4'd10);
    end
  endfunction

  // Byte-by-byte string equality - never a bare `a == b` on two
  // `string`s, whose support this project has not proven on this
  // toolchain (see convex_buffer.v's tok_eq_str for the same choice
  // applied to a decoded token instead of two plain strings).
  function automatic bit str_eq(input string a, input string b);
    integer i;
    bit eq;
    begin
      eq = (a.len() == b.len());
      if (eq) begin
        for (i = 0; i < a.len(); i = i + 1) begin
          if (a[i] != b[i]) eq = 1'b0;
        end
      end
      str_eq = eq;
    end
  endfunction

  function automatic integer find_sub_by_tag(input string tag);
    integer i, result;
    begin
      result = -1;
      for (i = 0; i < MAX_SUBS; i = i + 1) begin
        if (sub_active[i] && str_eq(sub_tag[i], tag)) result = i;
      end
      find_sub_by_tag = result;
    end
  endfunction

  function automatic integer find_sub_by_query_id(input integer qid);
    integer i, result;
    begin
      result = -1;
      for (i = 0; i < MAX_SUBS; i = i + 1) begin
        if (sub_active[i] && sub_query_id[i] == qid) result = i;
      end
      find_sub_by_query_id = result;
    end
  endfunction

  // A syntactically UUID-shaped session id (8-4-4-4-12 lowercase hex).
  // The server only needs this to parse as a UUID, not to come from a
  // cryptographically secure generator (matching delphi's own
  // FreshSessionId comment) - CMD_RANDOM_BYTE is still used anyway,
  // since it is already available and no weaker source is any simpler
  // to reach through this client's byte-at-a-time transport.
  task automatic generate_session_id;
    integer i, r;
    reg [7:0] rb [0:15];
    reg [3:0] hi, lo;
    byte hc;
    begin
      for (i = 0; i < 16; i = i + 1) begin
        ws.hs.transport.xport_call(`CMD_RANDOM_BYTE, 0, 0, r);
        rb[i] = r[7:0];
      end
      session_id_scratch = "";
      for (i = 0; i < 16; i = i + 1) begin
        hi = rb[i][7:4];
        lo = rb[i][3:0];
        hc = hex_char(hi);
        session_id_scratch = {session_id_scratch, hc};
        hc = hex_char(lo);
        session_id_scratch = {session_id_scratch, hc};
        if (i == 3 || i == 5 || i == 7 || i == 9) begin
          hc = "-";
          session_id_scratch = {session_id_scratch, hc};
        end
      end
      session_id = session_id_scratch;
    end
  endtask

  // Copies ws.msg's raw source bytes for tok (no escape decoding -
  // this is used for a JSON VALUE, which may be an object, array,
  // number or bool, not only a string) into raw_scratch.
  task automatic capture_raw_span(input integer tok);
    integer i, start, stop;
    byte c;
    begin
      start = ws.msg.tok_span_start(tok);
      stop = ws.msg.tok_span_stop(tok);
      raw_scratch = "";
      for (i = start; i < stop; i = i + 1) begin
        c = ws.msg.get_byte(i);
        raw_scratch = {raw_scratch, c};
      end
    end
  endtask

  // Copies ws.msg's escape-DECODED text for a STRING tok (an error
  // message or a timestamp) into decoded_scratch.
  task automatic capture_decoded_string(input integer tok);
    byte b;
    bit done;
    begin
      ws.msg.decode_str_start(tok);
      decoded_scratch = "";
      done = 1'b0;
      while (!done) begin
        ws.msg.decode_str_next(b, done);
        if (!done) decoded_scratch = {decoded_scratch, b};
      end
    end
  endtask

  // Updates max_observed_ts when candidate (base64 of an 8-byte
  // little-endian integer, per the sync protocol) is strictly greater
  // in magnitude - compared from the last decoded byte backwards, the
  // most significant byte in a little-endian encoding, matching
  // mumps/client/convex.m's tsCmp (its own comment there records the
  // empirical confirmation that this protocol's timestamps really are
  // little-endian, not big-endian). A malformed candidate (not exactly
  // 8 decoded bytes) is ignored rather than corrupting the tracked max.
  task automatic update_max_observed_ts(input string candidate);
    integer i;
    reg [7:0] a, b;
    integer cmp;
    begin : main
      if (!have_max_observed_ts) begin
        max_observed_ts = candidate;
        have_max_observed_ts = 1'b1;
        disable main;
      end

      ts_new_dec.reset;
      for (i = 0; i < candidate.len(); i = i + 1) ts_new_dec.put_byte(candidate[i]);
      ts_new_dec.decode;
      ts_max_dec.reset;
      for (i = 0; i < max_observed_ts.len(); i = i + 1) ts_max_dec.put_byte(max_observed_ts[i]);
      ts_max_dec.decode;
      if (ts_new_dec.length() != 8 || ts_max_dec.length() != 8) disable main;

      cmp = 0;
      for (i = 7; i >= 0; i = i - 1) begin
        if (cmp == 0) begin
          a = ts_new_dec.get_byte(i);
          b = ts_max_dec.get_byte(i);
          if (a > b) cmp = 1;
          else if (a < b) cmp = -1;
        end
      end
      if (cmp > 0) max_observed_ts = candidate;
    end
  endtask

  // === outbound wire messages =========================================

  task automatic build_connect_message;
    begin
      ws.send_payload.reset;
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("Connect");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("sessionId");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string(session_id);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("connectionCount");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(connection_count);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("lastCloseReason");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string(last_close_reason);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("clientTs");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(0);
      if (have_max_observed_ts) begin
        ws.send_payload.put_byte(",");
        ws.send_payload.json_put_string("maxObservedTimestamp");
        ws.send_payload.put_byte(":");
        ws.send_payload.json_put_string(max_observed_ts);
      end
      ws.send_payload.put_byte("}");
    end
  endtask

  // Appends one Add modification object (no wrapping array/braces) to
  // ws.send_payload - a private helper for send_add/rebuild_query_set
  // below, both of which own the surrounding ModifyQuerySet envelope.
  task automatic append_add_modification(
    input integer query_id,
    input string path,
    input string args_json
  );
    begin
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("Add");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("queryId");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(query_id);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("udfPath");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string(path);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("args");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_byte("[");
      ws.send_payload.put_str(args_json);
      ws.send_payload.put_byte("]");
      ws.send_payload.put_byte("}");
    end
  endtask

  task automatic send_modify_query_set_single_add(
    input integer query_id,
    input string path,
    input string args_json,
    output bit ok
  );
    integer base_version;
    begin
      base_version = query_set_version;
      query_set_version = query_set_version + 1;
      ws.send_payload.reset;
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("ModifyQuerySet");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("baseVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(base_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("newVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(query_set_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("modifications");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_byte("[");
      append_add_modification(query_id, path, args_json);
      ws.send_payload.put_byte("]");
      ws.send_payload.put_byte("}");
      ws.send_frame(1'b1, 1, ok); // opcode 1 = TEXT; see ws_smoke.v's own comment on this convention
    end
  endtask

  task automatic send_modify_query_set_single_remove(input integer query_id, output bit ok);
    integer base_version;
    begin
      base_version = query_set_version;
      query_set_version = query_set_version + 1;
      ws.send_payload.reset;
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("ModifyQuerySet");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("baseVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(base_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("newVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(query_set_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("modifications");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_byte("[");
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("Remove");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("queryId");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(query_id);
      ws.send_payload.put_byte("}");
      ws.send_payload.put_byte("]");
      ws.send_payload.put_byte("}");
      ws.send_frame(1'b1, 1, ok);
    end
  endtask

  // Resends every active subscription as one ModifyQuerySet - called
  // once right after a fresh Connect, whether this is the very first
  // connection or a reconnect, so the server's query set (which has no
  // memory of any previous connection) matches what this client
  // believes is active. Arms sub_awaiting_rehydration for exactly the
  // subscriptions that previously delivered a real value (not an
  // error, not still pending) - the same condition
  // mumps/client/convex.m's liveConnect documents on its own
  // subAwaitingRehydration line.
  task automatic rebuild_query_set(output bit ok);
    integer i;
    bit any, first;
    integer base_version;
    begin : main
      ok = 1'b1;
      any = 1'b0;
      for (i = 0; i < MAX_SUBS; i = i + 1) if (sub_active[i]) any = 1'b1;
      if (!any) disable main;

      base_version = query_set_version;
      query_set_version = query_set_version + 1;
      ws.send_payload.reset;
      ws.send_payload.put_byte("{");
      ws.send_payload.json_put_string("type");
      ws.send_payload.put_byte(":");
      ws.send_payload.json_put_string("ModifyQuerySet");
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("baseVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(base_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("newVersion");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_int(query_set_version);
      ws.send_payload.put_byte(",");
      ws.send_payload.json_put_string("modifications");
      ws.send_payload.put_byte(":");
      ws.send_payload.put_byte("[");
      first = 1'b1;
      for (i = 0; i < MAX_SUBS; i = i + 1) begin
        if (sub_active[i]) begin
          if (!first) ws.send_payload.put_byte(",");
          append_add_modification(sub_query_id[i], sub_path[i], sub_args_json[i]);
          first = 1'b0;
          sub_awaiting_rehydration[i] = sub_has_value[i] && !sub_is_error[i];
        end
      end
      ws.send_payload.put_byte("]");
      ws.send_payload.put_byte("}");
      ws.send_frame(1'b1, 1, ok);
    end
  endtask

  // === connection lifecycle ============================================

  task automatic ensure_connected(output bit ok);
    bit wsok;
    begin : main
      ok = 1'b0;
      if (connected) begin
        ok = 1'b1;
        disable main;
      end
      if (session_id.len() == 0) generate_session_id;

      ws.connect(sync_url, "/api/sync", wsok);
      if (!wsok) begin
        last_close_reason = "connect failed";
        disable main;
      end
      connected = 1'b1;
      query_set_version = 0;

      build_connect_message;
      ws.send_frame(1'b1, 1, wsok);
      if (!wsok) begin
        connected = 1'b0;
        last_close_reason = "connect message failed";
        disable main;
      end

      // A successful handshake resets backoff: a healthy connection
      // must not inherit a stale maximum delay from an earlier run of
      // failures (mumps/client/convex.m's liveConnect documents the
      // identical rule).
      backoff_ms = BACKOFF_BASE_MS;
      retry_at_ms = 0.0;

      connection_count = connection_count + 1;

      rebuild_query_set(wsok);
      ok = 1'b1;
    end
  endtask

  // Adapter-facing debugDisconnect test hook: sever the transport
  // immediately so the next maybe_reconnect performs a real reconnect.
  // Safe to call whether or not a connection is currently open.
  task automatic force_disconnect;
    begin
      if (connected) ws.close;
      connected = 1'b0;
      last_close_reason = "debugDisconnect";
      retry_at_ms = 0.0; // immediate retry allowed
    end
  endtask

  // Reconnect-on-drop with exponential backoff, only attempted when at
  // least one subscription actually wants a connection and the backoff
  // window has elapsed - mumps/client/convex.m's liveMaybeReconnect
  // documents the identical rule and the identical reason a fresh
  // add_subscription with no connection goes straight through
  // ensure_connected instead of waiting on this schedule.
  task automatic maybe_reconnect;
    real now;
    integer r;
    bit any_subs, ok;
    integer i;
    begin : main
      if (connected) disable main;
      any_subs = 1'b0;
      for (i = 0; i < MAX_SUBS; i = i + 1) if (sub_active[i]) any_subs = 1'b1;
      if (!any_subs) disable main;

      ws.hs.transport.xport_call(`CMD_NOP, 0, 0, r);
      now = ws.hs.transport.now_ms();
      if (now < retry_at_ms) disable main;

      ensure_connected(ok);
      if (ok) disable main;

      ws.hs.transport.xport_call(`CMD_NOP, 0, 0, r);
      now = ws.hs.transport.now_ms();
      retry_at_ms = now + backoff_ms;
      backoff_ms = backoff_ms * 2.0;
      if (backoff_ms > BACKOFF_MAX_MS) backoff_ms = BACKOFF_MAX_MS;
    end
  endtask

  // === subscriptions ====================================================

  task automatic add_subscription(
    input string tag,
    input string path,
    input string args_json,
    output bit ok
  );
    integer idx, i, qid;
    bit wsok;
    begin : main
      ok = 1'b0;
      idx = -1;
      for (i = 0; i < MAX_SUBS; i = i + 1) begin
        if (!sub_active[i] && idx < 0) idx = i;
      end
      if (idx < 0) disable main; // subscription table full

      qid = next_query_id;
      next_query_id = next_query_id + 1;
      sub_active[idx] = 1'b1;
      sub_tag[idx] = tag;
      sub_query_id[idx] = qid;
      sub_path[idx] = path;
      sub_args_json[idx] = args_json;
      sub_has_value[idx] = 1'b0;
      sub_is_error[idx] = 1'b0;
      sub_value_json[idx] = "";
      sub_error_msg[idx] = "";
      sub_has_error_data[idx] = 1'b0;
      sub_error_data_json[idx] = "";
      sub_version[idx] = 0;
      sub_awaiting_rehydration[idx] = 1'b0;

      if (!connected) begin
        ok = 1'b1; // registered locally; the next ensure_connected replays it
        disable main;
      end

      send_modify_query_set_single_add(qid, path, args_json, wsok);
      ok = wsok;
    end
  endtask

  task automatic remove_subscription(input string tag, output bit ok);
    integer idx, qid;
    bit wsok;
    begin : main
      ok = 1'b1;
      idx = find_sub_by_tag(tag);
      if (idx < 0) disable main;
      qid = sub_query_id[idx];
      if (connected) send_modify_query_set_single_remove(qid, wsok);
      sub_active[idx] = 1'b0;
      sub_tag[idx] = "";
      sub_path[idx] = "";
      sub_args_json[idx] = "";
      sub_value_json[idx] = "";
      sub_error_msg[idx] = "";
      sub_has_error_data[idx] = 1'b0;
      sub_error_data_json[idx] = "";
      sub_has_value[idx] = 1'b0;
      sub_is_error[idx] = 1'b0;
      sub_awaiting_rehydration[idx] = 1'b0;
    end
  endtask

  // === inbound wire messages ===========================================

  // Applies one already-located Transition modification object. An
  // unrecognised queryId (already removed locally, or stale) is
  // silently ignored, matching every peer client's identical choice.
  task automatic dispatch_one_modification(input integer mod_tok);
    integer type_tok, qid_tok, val_tok, errmsg_tok, errdata_tok;
    bit found, is_updated, is_failed, is_removed, has_errdata;
    integer qid, idx;
    bit suppress;
    begin : main
      ws.msg.json_object_get(mod_tok, "type", type_tok, found);
      if (!found || ws.msg.json_kind(type_tok) != JK_STRING) disable main;
      ws.msg.json_object_get(mod_tok, "queryId", qid_tok, found);
      if (!found || ws.msg.json_kind(qid_tok) != JK_NUMBER) disable main;
      ws.msg.tok_as_int(qid_tok, qid, found);
      if (!found) disable main;

      idx = find_sub_by_query_id(qid);
      if (idx < 0) disable main;

      ws.msg.tok_eq_str(type_tok, "QueryUpdated", is_updated);
      ws.msg.tok_eq_str(type_tok, "QueryFailed", is_failed);
      ws.msg.tok_eq_str(type_tok, "QueryRemoved", is_removed);

      if (is_updated) begin
        ws.msg.json_object_get(mod_tok, "value", val_tok, found);
        if (!found) disable main;
        capture_raw_span(val_tok);
        // A reconnect resends the whole active query set, and the
        // server's reply is an ordinary Transition even when nothing
        // changed. Deliver an event only when the value differs from
        // what this subscription last reported, so a same-value
        // rehydration after debugDisconnect never masquerades as a
        // real change (mumps/client/convex.m's liveTransition and
        // delphi's DispatchModification both document this identical
        // rule, applied here by comparing raw_scratch against the
        // exact source bytes this subscription last stored).
        suppress = sub_awaiting_rehydration[idx] && str_eq(sub_value_json[idx], raw_scratch);
        sub_awaiting_rehydration[idx] = 1'b0;
        if (!suppress) begin
          sub_value_json[idx] = raw_scratch;
          sub_has_value[idx] = 1'b1;
          sub_is_error[idx] = 1'b0;
          sub_error_msg[idx] = "";
          sub_has_error_data[idx] = 1'b0;
          sub_error_data_json[idx] = "";
          sub_version[idx] = sub_version[idx] + 1;
        end
      end else if (is_failed) begin
        ws.msg.json_object_get(mod_tok, "errorMessage", errmsg_tok, found);
        if (!found || ws.msg.json_kind(errmsg_tok) != JK_STRING) disable main;
        capture_decoded_string(errmsg_tok);
        // An error is never suppressed: the caller must still learn
        // that a reconnect reproduced a failing query. errorData is
        // optional on the wire (a QueryFailed from an unstructured
        // throw carries none) - captured as a raw JSON span, the same
        // "copy the exact source bytes" choice capture_raw_span makes
        // for an ordinary value, so a caller re-keying it (e.g. into an
        // adapter event's own "data" field) never re-encodes it.
        ws.msg.json_object_get(mod_tok, "errorData", errdata_tok, has_errdata);
        if (has_errdata) capture_raw_span(errdata_tok);
        sub_awaiting_rehydration[idx] = 1'b0;
        sub_error_msg[idx] = decoded_scratch;
        sub_has_error_data[idx] = has_errdata;
        if (has_errdata) sub_error_data_json[idx] = raw_scratch;
        else sub_error_data_json[idx] = "";
        sub_has_value[idx] = 1'b1;
        sub_is_error[idx] = 1'b1;
        sub_value_json[idx] = "";
        sub_version[idx] = sub_version[idx] + 1;
      end
      // QueryRemoved needs no event: a caller that unsubscribed already
      // stopped expecting updates for this queryId.
    end
  endtask

  task automatic handle_transition(input integer root_tok);
    integer endver_tok, ts_tok, mods_tok, mod_tok;
    bit found;
    integer n, i;
    begin : main
      ws.msg.json_object_get(root_tok, "endVersion", endver_tok, found);
      if (found && ws.msg.json_kind(endver_tok) == JK_OBJECT) begin
        ws.msg.json_object_get(endver_tok, "ts", ts_tok, found);
        if (found && ws.msg.json_kind(ts_tok) == JK_STRING) begin
          capture_decoded_string(ts_tok);
          update_max_observed_ts(decoded_scratch);
        end
      end

      ws.msg.json_object_get(root_tok, "modifications", mods_tok, found);
      if (!found || ws.msg.json_kind(mods_tok) != JK_ARRAY) disable main;
      n = ws.msg.json_child_count(mods_tok);
      for (i = 0; i < n; i = i + 1) begin
        mod_tok = ws.msg.json_array_nth(mods_tok, i);
        dispatch_one_modification(mod_tok);
      end
    end
  endtask

  // Parses and dispatches whatever text message receive_message most
  // recently placed in ws.msg. fatal is set when the server sent a
  // FatalError (the caller must then treat the connection as gone).
  // Ping, AuthError, MutationResponse, ActionResponse and
  // TransitionChunk need no handling: this client never authenticates
  // or mutates over the sync socket (every mutation this project's
  // Live-capable clients issue goes over HTTP instead), and its test
  // payloads stay far below the size that would trigger chunking.
  task automatic handle_server_message(output bit fatal);
    integer root_tok, type_tok;
    bit found, is_transition, is_fatal;
    begin : main
      fatal = 1'b0;
      ws.msg.parse_json;
      if (!ws.msg.json_ok()) disable main;
      root_tok = ws.msg.json_root();
      if (ws.msg.json_kind(root_tok) != JK_OBJECT) disable main;

      ws.msg.json_object_get(root_tok, "type", type_tok, found);
      if (!found || ws.msg.json_kind(type_tok) != JK_STRING) disable main;

      ws.msg.tok_eq_str(type_tok, "Transition", is_transition);
      if (is_transition) begin
        handle_transition(root_tok);
        disable main;
      end

      ws.msg.tok_eq_str(type_tok, "FatalError", is_fatal);
      if (is_fatal) fatal = 1'b1;
    end
  endtask

  // === the single pump tick ============================================
  //
  // Gives a dropped connection a chance to reconnect, then receives and
  // dispatches at most one message with a bounded wait. A plain timeout
  // (nothing arrived yet, connection still fine) is not reported as a
  // problem: it simply leaves got_message false for the caller's next
  // pump to try again - the same three-way "ok / timeout / retired"
  // outcome mumps/client/convex.m's livePump documents, collapsed here
  // into got_message plus is_connected() rather than a third return
  // value, since nothing in this client needs to tell "timeout" and
  // "retired" apart from outside this task.
  task automatic pump(input integer timeout_ms, output bit got_message);
    bit rok, fatal;
    begin : main
      got_message = 1'b0;
      maybe_reconnect;
      if (!connected) disable main;

      ws.set_frame_timeout_ms(timeout_ms);
      ws.receive_message(rok);
      if (rok) begin
        handle_server_message(fatal);
        if (fatal) begin
          connected = 1'b0;
          last_close_reason = "FatalError";
        end
        got_message = 1'b1;
        disable main;
      end

      if (ws.close_received) begin
        // convex_websocket.v's receive_message already answered with
        // our own Close frame before returning here.
        connected = 1'b0;
        last_close_reason = "peer close";
        disable main;
      end
      if (ws.last_read_error != -1) begin
        // Not a plain "nothing arrived yet" timeout on the first byte
        // of a new frame: abandon the connection rather than risk
        // resuming at a false frame boundary (AGENTS.md's own rule).
        connected = 1'b0;
        last_close_reason = "transport error";
      end
    end
  endtask

  // Blocks (polling in short slices so reconnect/backoff still gets
  // serviced) until tag's subscription has published a new value or
  // error, or timeout_ms elapses.
  task automatic wait_update(input string tag, input integer timeout_ms, output bit ok);
    integer idx, start_version, r;
    real deadline, now;
    bit got;
    begin : main
      ok = 1'b0;
      idx = find_sub_by_tag(tag);
      if (idx < 0) disable main;
      start_version = sub_version[idx];

      ws.hs.transport.xport_call(`CMD_NOP, 0, 0, r);
      deadline = ws.hs.transport.now_ms() + timeout_ms;

      while (sub_version[idx] == start_version) begin
        pump(200, got);
        ws.hs.transport.xport_call(`CMD_NOP, 0, 0, r);
        now = ws.hs.transport.now_ms();
        if (now >= deadline) disable main;
      end
      ok = 1'b1;
    end
  endtask

endmodule
