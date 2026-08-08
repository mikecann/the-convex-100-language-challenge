// main.v - a short tour of the native Verilog Convex client: an HTTP
// query, a Live subscription started before a mutation so the initial
// snapshot cannot be missed, an idempotent mutation, and the resulting
// Live update. Every printed line is checked against the value Convex
// actually returned; this program exits non-zero if any of them
// disagree.
//
// Like every other program in this client, the whole design elaborates
// as one circuit: this module's own convex_transport instance (the
// clocked request/acknowledge bus - see client/convex_transport.v) for
// stdout/stderr/getenv/exit, plus client/convex.v's `conv` instance,
// which is the sole caller of everything below it (HTTP framing, JSON,
// TLS, WebSocket, /api/sync) on this program's behalf.
`timescale 1ns / 1ps
`include "client/convex_opcodes.vh"
`include "client/convex_chars.vh"

module main;

  localparam KIND_OBJECT = 6;

  convex_transport transport ();
  convex #(.MAX_SUBS(1)) conv ();
  convex_buffer #(.MAXLEN(4096), .MAXTOK(256)) parsed ();
  convex_buffer #(.MAXLEN(256)) args ();

  string room;
  string url;
  string args_str;

  // === small I/O helpers, matching client/tests/conformance/adapter.v's
  // own identical shape for the same reason: this module's only route
  // to stdout, stderr, the environment and a real process exit code is
  // through this instance's own transport opcodes. ===

  task automatic print_line(input string s);
    integer i, r;
    begin
      for (i = 0; i < s.len(); i = i + 1) begin
        transport.xport_call(`CMD_STDOUT_WRITE_BYTE, s[i], 0, r);
      end
      transport.xport_call(`CMD_STDOUT_WRITE_BYTE, `LF, 0, r);
      transport.xport_call(`CMD_STDOUT_FLUSH, 0, 0, r);
    end
  endtask

  task automatic fatal(input string msg);
    integer i, r;
    begin
      for (i = 0; i < msg.len(); i = i + 1) begin
        transport.xport_call(`CMD_STDERR_WRITE_BYTE, msg[i], 0, r);
      end
      transport.xport_call(`CMD_STDERR_WRITE_BYTE, `LF, 0, r);
      transport.xport_call(`CMD_EXIT, 1, 0, r);
    end
  endtask

  string env_scratch;

  task automatic getenv(input string name, output bit found);
    integer i, r, lookup_len;
    byte eb;
    begin : main_getenv
      found = 1'b0;
      env_scratch = "";
      transport.xport_call(`CMD_GETENV_RESET, 0, 0, r);
      for (i = 0; i < name.len(); i = i + 1) begin
        transport.xport_call(`CMD_GETENV_PUSH, name[i], 0, r);
      end
      transport.xport_call(`CMD_GETENV_LOOKUP, 0, 0, lookup_len);
      if (lookup_len < 0) disable main_getenv;
      found = 1'b1;
      for (i = 0; i < lookup_len; i = i + 1) begin
        transport.xport_call(`CMD_GETENV_BYTE, i, 0, r);
        eb = r[7:0];
        env_scratch = {env_scratch, eb};
      end
    end
  endtask

  // Extracts a demo state's "count" field from an already-parsed buffer
  // at obj_tok - the demo module's own JSON-safe profile may represent
  // it as either an integer or an integral float (the literal 0.0, for
  // example); tok_as_int already implements exactly that acceptance
  // rule (see convex_buffer.v's own header), so this only has to find
  // the field and fail loudly when it is missing or not integral.
  task automatic count_of(
    input  integer obj_tok,
    output integer value
  );
    integer t;
    bit found, num_ok;
    begin
      parsed.json_object_get(obj_tok, "count", t, found);
      if (!found) fatal("demo state was missing count");
      parsed.tok_as_int(t, value, num_ok);
      if (!num_ok) fatal("demo count was not an integral number in range");
    end
  endtask

  // Parses conv.value_json (the raw envelope value from the most recent
  // call) into `parsed` and returns its root token, failing loudly if it
  // is not valid JSON. A task, not a function: it calls parsed.reset and
  // parsed.parse_json, both tasks, and a Verilog function may only call
  // another function (see convex_buffer.v's own header comment).
  task automatic parse_conv_value(output integer root_tok);
    begin
      parsed.reset;
      parsed.put_str(conv.value_json);
      parsed.parse_json;
      root_tok = parsed.json_root();
    end
  endtask

  // Waits (polling client/convex_sync.v's own pump on this one
  // subscription) until an actual new value or error arrives, or ten
  // seconds pass without one, then decodes its count. Shared by both
  // waits below: the initial snapshot and the post-mutation update.
  // Waits for a version STRICTLY AFTER whatever this subscription already
  // had when this task was called, not for version zero specifically -
  // the initial snapshot (called with baseline 0) and the post-mutation
  // update (called again with baseline already 1, since the first call
  // already advanced it) are both "wait for the next new value", and a
  // baseline captured fresh on every call is what makes that the same
  // check both times, rather than a hardcoded ==0 that would only ever
  // wait on the very first call.
  task automatic wait_for_live_update(output integer result_count);
    integer idx, attempts, baseline_version;
    bit got;
    integer root_tok;
    string err_scratch, value_scratch;
    begin
      idx = conv.sync.find_sub_by_tag("example");
      if (idx < 0) fatal("subscription was not registered");
      baseline_version = conv.sync.sub_version[idx];
      attempts = 0;
      while (conv.sync.sub_version[idx] == baseline_version) begin
        conv.sync.pump(100, got);
        attempts = attempts + 1;
        if (attempts >= 100) fatal("timed out waiting for a Live update");
      end
      if (conv.sync.sub_is_error[idx]) begin
        // Extracted into a plain local first, not concatenated directly
        // from the hierarchical array element - see this client's own
        // string[index]/function-result-inside-{...} caution applied
        // conservatively to an array-of-strings element read too.
        err_scratch = conv.sync.sub_error_msg[idx];
        fatal({"live update failed: ", err_scratch});
      end
      value_scratch = conv.sync.sub_value_json[idx];
      parsed.reset;
      parsed.put_str(value_scratch);
      parsed.parse_json;
      if (!parsed.json_ok()) fatal("live value was not valid JSON");
      root_tok = parsed.json_root();
      count_of(root_tok, result_count);
    end
  endtask

  integer before_count, after_count, live_count;
  bit have_url, cfg_ok, sub_ok, call_ok, is_fn_err;
  integer exit_r;
  integer plusarg_got;
  integer applied_tok, state_tok, root_tok;
  bit found;
  string run_id;

  initial begin
    // Configure the deployment: the client reads the URL from
    // CONVEX_URL, same as this project's other native clients, and
    // accepts a room name via the `+room=` plusarg (set by this image's
    // entrypoint wrapper from the verifier's first positional argument;
    // see verilog/Dockerfile) - Icarus's real command-line passthrough
    // mechanism for a compiled design, unlike GHDL's standalone
    // executables (see vhdl/examples/basics/main.vhdl's own comment on
    // why it uses an EXAMPLE_ROOM env var instead).
    getenv("CONVEX_URL", have_url);
    if (!have_url || env_scratch.len() == 0) fatal("CONVEX_URL is required");
    url = env_scratch;

    room = "verilog-basic-example";
    plusarg_got = $value$plusargs("room=%s", room);

    conv.configure(url, cfg_ok);
    if (!cfg_ok) fatal("CONVEX_URL is not a valid deployment URL");

    // Query the counter through Convex's documented HTTP endpoint.
    args.reset;
    args.put_byte("{");
    args.json_put_string("room");
    args.put_byte(":");
    args.json_put_string(room);
    args.put_byte("}");
    args_str = "";
    begin : build_args
      integer ai;
      byte ac;
      for (ai = 0; ai < args.length(); ai = ai + 1) begin
        ac = args.get_byte(ai);
        args_str = {args_str, ac};
      end
    end

    conv.call("query", "demo:state", args_str, call_ok, is_fn_err);
    if (!call_ok || is_fn_err) fatal("query failed");
    parse_conv_value(root_tok);
    if (!parsed.json_ok() || parsed.json_kind(root_tok) != KIND_OBJECT) begin
      fatal("query response was not valid JSON");
    end
    count_of(root_tok, before_count);
    print_line($sformatf("current count: %0d", before_count));

    // Start Live before the mutation so the initial snapshot cannot be
    // missed: subscribing after the mutation could race the server and
    // deliver the post-mutation value as if it were the starting point.
    conv.sync.add_subscription("example", "demo:state", args_str, sub_ok);
    if (!sub_ok) fatal("subscribe failed");

    // Waits for the actual initial Live value from the bounded event
    // stream, rather than assuming the first pump call already has it.
    wait_for_live_update(live_count);
    if (live_count != before_count) fatal("live initial count did not match the query count");
    print_line($sformatf("live initial count: %0d", before_count));

    // Apply the mutation with a stable idempotency key (runId), so
    // retrying this example against the same room is always safe: a
    // second run with the same room and runId reports applied=false
    // and the unchanged count instead of incrementing twice.
    run_id = {room, "-once"};
    args.reset;
    args.put_byte("{");
    args.json_put_string("room");
    args.put_byte(":");
    args.json_put_string(room);
    args.put_byte(",");
    args.json_put_string("language");
    args.put_byte(":");
    args.json_put_string("Verilog");
    args.put_byte(",");
    args.json_put_string("runId");
    args.put_byte(":");
    args.json_put_string(run_id);
    args.put_byte("}");
    args_str = "";
    begin : build_mutation_args
      integer ai;
      byte ac;
      for (ai = 0; ai < args.length(); ai = ai + 1) begin
        ac = args.get_byte(ai);
        args_str = {args_str, ac};
      end
    end

    conv.call("mutation", "demo:increment", args_str, call_ok, is_fn_err);
    if (!call_ok || is_fn_err) fatal("mutation failed");
    parse_conv_value(root_tok);
    if (!parsed.json_ok() || parsed.json_kind(root_tok) != KIND_OBJECT) begin
      fatal("mutation response was not valid JSON");
    end
    parsed.json_object_get(root_tok, "applied", applied_tok, found);
    if (!found || !parsed.json_bool_value(applied_tok)) fatal("mutation was not applied");
    parsed.json_object_get(root_tok, "state", state_tok, found);
    if (!found) fatal("mutation response was missing state");
    count_of(state_tok, after_count);
    if (after_count != before_count + 1) fatal("mutation count did not advance by exactly one");
    print_line("mutation applied: true");
    print_line($sformatf("mutation count: %0d", after_count));

    // Waits for the actual resulting Live value before printing the
    // verification line.
    wait_for_live_update(live_count);
    if (live_count != after_count) fatal("live updated count did not match the mutation count");
    print_line($sformatf("live updated count: %0d", after_count));
    print_line($sformatf("verified count: %0d -> %0d", before_count, after_count));

    conv.sync.remove_subscription("example", sub_ok);
    transport.xport_call(`CMD_EXIT, 0, 0, exit_r);
  end

endmodule
