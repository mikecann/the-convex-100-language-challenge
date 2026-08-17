# Verilog

Verilog is a hardware description language for describing, simulating, and
synthesising digital circuits. It became IEEE 1364 in 1995, and the Verilog
language is now part of the active
[IEEE 1800 SystemVerilog standard](https://standards.ieee.org/ieee/1800/7743/).
It remains a familiar tool in chip and FPGA work, which makes using it as a
networked Convex client delightfully odd. This implementation runs the design
with [Icarus Verilog](https://steveicarus.github.io/iverilog/) rather than
turning it into physical hardware.

This project is educational and unofficial. It is not a production Convex SDK
and is not published as a package.

## Getting Started

Start with the [canonical basic example](examples/basics/main.v). From the
repository root, run:

```sh
./run verify-example verilog
```

That command builds and runs the exact example in Docker against a unique demo
room. It checks the initial HTTP query, the initial Live value, the mutation,
and the resulting Live update. It does not run the full conformance suite.

## Interesting Parts

### The client is a module instance, never `new`ed

Verilog has no classes, so this client's "objects" are literal circuit
instances: dropping a `convex` module into your design gives you a handle you
call tasks on through plain dot access, the same way you'd wire up any other
hardware block.

```verilog
convex conv ();                 // an instance, not `new Client(url)`
bit configured_ok, call_ok, function_error;

conv.configure(deployment_url, configured_ok);
if (!configured_ok) $fatal(1, "CONVEX_URL is not a valid deployment URL");

conv.call("query", "demo:state", args_json, call_ok, function_error);
// TypeScript: const state = await client.query(api.demo.state, { room })
$display("%0d", count);
```

The whole client — HTTP framing, JSON parsing, even the WebSocket handshake —
lives inside that one instantiated hierarchy.

### JSON gets welded together one byte at a time

There's no object-literal syntax in Verilog, so call arguments go into a
`convex_buffer` instance as a stream of individual byte and string writes
instead of a value you build in one expression.

```verilog
args.reset;
args.put_byte("{");
args.json_put_string("room");   // handles quoting/escaping for you
args.put_byte(":");
args.json_put_string(room);
args.put_byte("}");
// TypeScript: JSON.stringify({ room })
```

### Subscriptions live in a hierarchical array, woken by a blocking pump

Instead of a hook that reruns your component, a Live subscription here is a
slot in an array inside the embedded `sync` instance, addressed by index. One
process advances it by explicitly pumping the WebSocket until that slot's
version counter moves.

```verilog
conv.sync.add_subscription("counter", "demo:state", args_json, subscribe_ok);
idx = conv.sync.find_sub_by_tag("counter");
previous_version = conv.sync.sub_version[idx];

// TypeScript: useQuery(api.demo.state, { room }) reruns your component for you
while (conv.sync.sub_version[idx] == previous_version) begin
  conv.sync.pump(100, got_message);
end
```

### Success is a pair of bits, never a thrown exception

Hardware description has no exception mechanism, so `call()` reports its
outcome through two separate output bits: one for whether the round trip
happened at all, another for whether the Convex function itself threw.

```verilog
conv.call("mutation", "demo:increment", args_str, call_ok, is_fn_err);
if (!call_ok) $fatal(1, "transport or HTTP failure");
if (call_ok && is_fn_err) $fatal(1, conv.error_message);
// TypeScript: try { await client.mutation(...) } catch (e) { ... }
```

## Status

| Capability | Evidence-backed status |
| --- | --- |
| HTTP query, mutation, and action | Verified on local and hosted profiles |
| Live queries | Verified on local and hosted profiles |

The manifest classifies this as a native client. The small C VPI module supplies
ordinary transport primitives such as sockets, TLS, randomness, time, and
process I/O. JSON, HTTP framing, the WebSocket handshake and frames, and Convex
Live behaviour are implemented in Verilog itself.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.v -->
```verilog
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
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The design runs under pinned Icarus Verilog 11.0. `iverilog` compiles the
sources to VVP bytecode, while the final images contain only the separate
`vvp` runtime and the required VPI plugins. The Icarus documentation explains
both the [VVP runtime](https://steveicarus.github.io/iverilog/targets/tgt-vvp.html)
and how a simulator loads
[VPI modules](https://steveicarus.github.io/iverilog/usage/vpi.html).

`client/convex_transport.v` is the boundary between the simulated design and
`client/native.c`. It presents a clocked request/acknowledge interface. The C
side registers just two Verilog system functions and performs the operations
that HDL cannot perform alone, including TCP, verified TLS, randomness, and
wall-clock reads.

Above that boundary, the implementation is intentionally Verilog all the way
up: bounded byte buffers and JSON tokens, HTTP/1.1 framing, pure-Verilog SHA-1
and base64 for the WebSocket handshake, WebSocket framing, and the Convex Live
state machine. One sync process owns reads, writes, reconnects, and query-set
changes, which avoids concurrent access to the socket.

The Docker-local tests cover the JSON codec, TCP and TLS transport, HTTP,
WebSockets, reconnects, structured errors, adapter modes, and bounded memory.
The recorded capability award comes from the repository's separate local and
hosted conformance runs, not merely from compilation or fixtures.

## Known Issues

1. Live tracks `endVersion.ts` but does not validate full
   `startVersion`/`endVersion` continuity.
2. JSON decoding rejects UTF-16 surrogate pairs, so emoji and other astral
   characters in user data do not decode.
3. Live delivery is a bounded latest-value mailbox. A slow consumer can skip
   intermediate values, although it still receives the newest state.
4. Pinned Icarus 11.0 cannot pass the buffer shapes this client needs into
   tasks, and mishandles quote and backslash escapes in string literals. The
   implementation therefore keeps buffers as module state and writes those
   characters as explicit byte constants.
