# Convex from Verilog

This directory is a Convex client written as a simulated hardware circuit in
Verilog, run under Icarus Verilog (`iverilog`).

This is educational and unofficial. It is not a production Convex SDK, and
it is not published as a package.

## Status

The toolchain gate, a JSON codec, HTTP/1.1 framing, RFC 6455 WebSocket
framing, the `/api/sync` Live state machine, the public call facade
(`client/convex.v`), the NDJSON conformance adapter, and the canonical
example are all implemented and proven in Docker. The gate proves, inside
Docker on the pinned toolchain, that a Verilog program can drive a real TCP
connection and a real certificate- and hostname-verified TLS handshake
through a small VPI (Verilog Procedural Interface) C module.
`client/convex_buffer.v` adds a hand-written JSON encoder and decoder,
covering AGENTS.md's integral-decimal-number rule (`0.0`/`1.0` decode as
integers; fractional, quoted, non-finite and overflowing values are
rejected), proven with a language-local unit suite. `client/convex_http.v`
adds HTTP/1.1 request/response framing, proven with a real `POST
/api/query` round trip to the shared demo deployment. `client/convex_sha1.v`
and `client/convex_base64.v` add a pure-Verilog SHA-1 and base64 encoder (no
crypto library binding exists for this toolchain), proven against RFC
6455's own worked handshake example. `client/convex_websocket.v` builds RFC
6455 WebSocket framing on top of all of the above: masking, fragmentation
reassembly, interleaved control frames, one-shot (post-reassembly) UTF-8
validation, and Sec-WebSocket-Accept verification, proven against a
fixture peer that independently checks the client's own masked PONG and
CLOSE frames. `client/convex_sync.v` adds the `/api/sync` Live state
machine (the pinned `convex-rs-0.10.4-unversioned-sync` profile) on top of
that: a subscription table, the initial value and later external updates,
five real reconnects through an adapter-facing `debugDisconnect` hook with
an unchanged rehydration correctly suppressed and a genuine mutation still
delivered every time, `QueryFailed` followed by recovery on the same
subscription, `connectionCount`/`lastCloseReason`/`maxObservedTimestamp`
carried correctly, and exponential backoff that doubles on repeated
failure and resets after every successful handshake. `client/convex.v` is
the public `call()` facade (query/mutation/action, plus an embedded
`convex_sync` instance for Live), proven against the real deployment: a
successful query, a successful mutation, and a function-level failure
carrying structured `errorData`. `client/tests/conformance/adapter.v` is
the NDJSON adapter protocol v1 executable, proven over both stdin/stdout
and `ADAPTER_LISTEN` TCP mode, including a real Live subscription, a real
`debugDisconnect`-triggered reconnect, and a bounded per-subscription
mailbox proven under a genuinely stopped reader.
`examples/basics/main.v` is the canonical example, proven both to fail
loudly with no configuration and to produce the exact transcript
`_shared/examples/basics.expected.txt` records, against a fixture and
against the real hosted deployment.

The design follows the same shape as this repository's `vhdl/` client
(also in progress): standard HDL has no sockets, no TLS and no clock
outside the simulator, so a small foreign-boundary module
(`client/native.c`) supplies exactly those primitives, and everything
else - the request framing, the JSON, the WebSocket handshake, the
`/api/sync` state machine - lives in Verilog itself, driven through a
clocked request/acknowledge circuit (`client/convex_transport.v`) rather
than through `iverilog` used as a scripting language with `#delay`
statements standing in for real synchronization.

Where VHDL reaches its foreign boundary through GHDL's VHPIDIRECT (a
direct binding from a VHDL function declaration to a C symbol), this
client reaches it through Icarus's VPI: `client/native.c` registers two
Verilog system functions, `$cx_dispatch` and `$cx_now_ms`, and Icarus
calls back into this module's C code whenever simulated Verilog evaluates
either one. The effect at the call site is the same kind of "ordinary
looking call secretly leaves the simulator" boundary; the wiring
underneath is a callback table Icarus consults rather than a linked
symbol. `runtime` and `example-runtime` are a second kind of boundary
crossing worth spelling out: Icarus is compile-then-interpret, so
`iverilog` (the front end) produces a `.vvp` bytecode file and `vvp` (a
wholly separate binary) is the runtime executor that interprets it - there
is no linked native ELF the way GHDL's LLVM backend produces for `vhdl/`.
Both runtime images therefore ship `vvp` plus this client's own
`native.vpi` plus the small subset of Icarus's own default VPI plugins
`vvp` needs at startup, and never `iverilog`/`ivl`/`ivlpp` (the compiler
front end and code generator), which live in the exact same Debian
package and the exact same directory.

## What works

| Behaviour | Status |
| --- | --- |
| Real TCP connection driven from Verilog through the VPI boundary | Proven in Docker (`tcp_smoke`) |
| Real TLS handshake with certificate and hostname verification | Proven in Docker (`tls_smoke`), against `usable-reindeer-44.convex.cloud:443` |
| JSON codec (encode, parse, integral-decimal rule) | Proven in Docker (`json_test`), language-local unit suite |
| HTTP/1.1 request/response framing | Proven in Docker (`http_smoke`), real `POST /api/query` round trip |
| SHA-1 + base64 (Sec-WebSocket-Accept) | Proven in Docker (`sha1_test`), RFC 6455's own worked example |
| RFC 6455 WebSocket framing (mask, fragmentation, control frames, UTF-8) | Proven in Docker (`ws_smoke`), against a fixture peer |
| `/api/sync` Live protocol (subscribe, reconnect, rehydration, backoff) | Proven in Docker (`sync_smoke`), against a fixture peer |
| `client/convex.v` call facade (query/mutation/action, structured errorData) | Proven in Docker (`convex_test`), against the real deployment |
| NDJSON conformance adapter (stdin/stdout, `ADAPTER_LISTEN`, Live, bounded mailbox) | Proven in Docker (Scenarios A-D) |
| Canonical `examples/basics` | Proven in Docker, exact transcript match |
| `example-runtime` / `runtime` Docker stages | Built, policy-checked (uid 65532, read-only, no compiler), and run against the real deployment |
| HTTP capability | Verified (`./run verify-all verilog` awarded it on both profiles) |
| Live capability | Verified (`./run verify-all verilog` awarded it on both profiles) |

## The canonical example

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

## Docker verification

```sh
docker build --target test -t verilog-test .
```

This installs the pinned Icarus Verilog toolchain, builds `client/native.c`
as a VPI module against `vpi_user.h`, and proves:

- **`tcp_smoke`**: a real TCP round trip, driven entirely from Verilog
  through `client/convex_transport.v`'s clocked request/acknowledge bus and
  `$cx_dispatch`, against a one-shot fixture TCP server built in the same
  Docker stage.
- **`tls_smoke`**: a real TLS 1.x handshake to
  `usable-reindeer-44.convex.cloud:443`, with both certificate and hostname
  verification (`SSL_set1_host` plus `SSL_get_verify_result`), through the
  same VPI boundary, followed by a real HTTP/1.1 request sent over that
  handshake and a real status line read back - proof that application bytes
  travel through the verified channel, not only that a verification flag was
  set.
- **`http_smoke`**: a real `POST /api/query` round trip to the shared
  demo deployment over that same verified channel, driven through
  `client/convex_http.v`'s request/response framing and
  `client/convex_buffer.v`'s JSON codec, checking the real
  status/value/errorMessage/logLines envelope Convex's HTTP API returns.
- **`sha1_test`**: `client/convex_sha1.v` and `client/convex_base64.v`
  against two known-answer vectors, including RFC 6455's own worked
  handshake example (`Sec-WebSocket-Key` `dGhlIHNhbXBsZSBub25jZQ==` must
  produce `Sec-WebSocket-Accept` `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`) - no
  network involved.
- **`ws_smoke`**: a real RFC 6455 WebSocket handshake and message round
  trip against a fixture peer, proving masking (client-to-server frames),
  fragmentation reassembly across an interleaved PING control frame, and
  one-shot UTF-8 validation over the fully reassembled message rather
  than per fragment - the fixture independently checks the client's PONG
  and CLOSE frames arrived masked with the right content.
- **`sync_smoke`**: a real `/api/sync` session against a fixture peer
  through six sequential connections (one initial connect plus five
  `debugDisconnect`-triggered reconnects), proving the initial value, an
  external mutation, `QueryFailed` followed by recovery on the same
  subscription, and - on every one of the five reconnects - that an
  unchanged rehydration is suppressed while a genuine mutation is still
  delivered. The fixture independently checks each connection's own
  `connectionCount` and `lastCloseReason`, and a separate deterministic
  check proves exponential backoff actually doubles on repeated failure.
- **`convex_test`**: `client/convex.v`'s `call()` facade against the real
  approved deployment - a successful query, a successful mutation, and a
  function-level failure carrying structured `errorData`.
- **the adapter, Scenarios A-D**: the NDJSON adapter over plain
  stdin/stdout (a real query call), over a FIFO-fed stdin with a real Live
  subscription and a real `debugDisconnect`-triggered second TCP
  connection, over `ADAPTER_LISTEN`'s TCP mode, and under a genuinely
  stopped reader (4000 unpaced `Transition`s, ~350 KB over a 64 KB pipe
  buffer, peak VmRSS sampled at 1.4 MB against the shared 128 MiB adapter
  memory limit).
- **the canonical example**: fails loudly (empty stdout, `CONVEX_URL is
  required` on stderr, exit 1) with no deployment configured, then produces
  the exact six lines `_shared/examples/basics.expected.txt` records
  against a fixture that times the post-mutation Live `Transition` to
  arrive after the mutation's own HTTP response has already completed.

```sh
docker build --target runtime -t verilog-runtime .
docker build --target example-runtime -t verilog-example-runtime .
```

Both stages ship only `vvp` and this client's own `native.vpi` - never
`iverilog`/`ivl`/`ivlpp` - run as `65532:65532`, and are proven with real
`docker run --read-only --cap-drop=ALL` invocations against the real
hosted deployment, not only the build-time `RUN` probes.

## Limitations and deferred work

- `client/convex_sync.v` does not validate Convex's `startVersion`/
  `endVersion` state-version continuity (a peer client,
  `mumps/client/convex.m`, does) - only `endVersion.ts` itself, for
  `maxObservedTimestamp`. See that file's own header comment for the
  reasoning; AGENTS.md's Live-acceptance section requires carrying
  `maxObservedTimestamp` correctly, not rejecting a state-version
  discontinuity, and the fixture peer never sends an invalid one.
- Live delivery is a bounded mailbox, not a growing queue:
  `convex_sync.v` keeps only the latest value per subscription (a single
  slot with a version counter), and the adapter's own "have I emitted the
  current version yet" tracking over it is the same fixed, `MAX_SUBS`-sized
  shape - a slow consumer sees the newest value next, not a backlog of
  every intermediate one. Proven under a real stopped reader; see the
  adapter Scenario D entry above.
- The gate's TCP, WebSocket and sync proofs, and every adapter scenario,
  all use a hermetic Docker-local fixture server; only the TLS, HTTP,
  `convex_test`, and canonical-example proofs reach the real Convex
  deployment, matching this project's policy against pointing arbitrary
  build-time network access at a real backend for anything but those
  proofs.
- The pinned `iverilog` does not support passing an unpacked array, a
  `ref` port, or even a dynamic `byte queue[$]`, into a task or function -
  confirmed directly against the toolchain rather than assumed. Every
  buffer in this client is therefore module state reached only through a
  hierarchical name, and `client/convex_buffer.v` combines byte storage
  with JSON parsing of its own content in one module rather than two
  separate packages the way `vhdl/` splits them.
- The same toolchain also expands a `\"` or a lone `\\` inside a
  SystemVerilog `string` literal into that escape's own four-character
  spelling instead of the single byte it should produce (`"a\"b".len()`
  reports 6, not 3) - documented in `client/convex_chars.vh`. Every
  string literal in this client that needs a literal quote or backslash
  spells it as an explicit byte constant instead.
- A third, previously-hidden Icarus 11.0 bug was found while wiring the
  adapter: `disable main;` inside a recursively self-nested
  `parse_object` or `parse_array` call (an object whose value is itself
  an object, or an array whose element is itself an array) does not only
  exit the inner frame the way IEEE 1800 automatic-task reentrancy
  requires - it also silently abandons the OUTER frame's own remaining
  statements. An ordinary `"args":{}` envelope (the empty-args case most
  adapter commands fall back to) was rejected as malformed even though
  the bytes were well-formed JSON. Fixed in `client/convex_buffer.v` by
  rewriting both tasks to thread a `failed` flag through nested
  `if`/`else` instead of ever calling `disable` from a frame that may be
  recursing; `{"a":[]}` (a DIFFERENT task recursing into the object one)
  never triggered it, which is what made it easy to miss.
- JSON string decoding does not combine a `\uD800`-`\uDBFF` /
  `\uDC00`-`\uDFFF` surrogate pair into one astral codepoint; it rejects
  the lone surrogate half instead. A Basic Multilingual Plane character
  (the overwhelming majority of real text, and everything Convex's own
  protocol control fields ever contain) decodes correctly; an emoji or
  rare CJK extension character in user data would not.
