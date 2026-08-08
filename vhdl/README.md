# Convex from VHDL

This is a Convex client written in VHDL, expressed as a *simulated
circuit* -- processes, signals and a clock -- rather than VHDL used
procedurally with `wait` statements sprinkled through it. GHDL compiles
the design to a standalone native executable that simulates the circuit;
there is no real hardware involved.

This is an educational, unofficial demonstration. It is not a production
Convex SDK and not a package intended for publication.

## Start here

[`examples/basics/main.vhdl`](examples/basics/main.vhdl) is the canonical
example. It reads a counter room over HTTP, starts a Live subscription
before mutating it so the initial snapshot cannot be missed, applies an
idempotent mutation, and proves the same `0 -> 1` journey arrived a second
time through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Not yet verified | Implemented -- `client/convex.vhdl`'s `client_call` builds the request envelope, sends it over `convex_http.vhdl`, and decodes both the success and structured function-error response shapes -- and exercised by `./run test vhdl`'s language-local suites, but shared black-box conformance has not run yet, so no badge is earned. |
| Live | Not yet verified | Implemented -- `client/convex_sync.vhdl`'s subscription manager drives Convex's `/api/sync` protocol, including reconnect and `debugDisconnect` -- and exercised by `./run test vhdl`'s language-local suites, but shared black-box conformance has not run yet, so no badge is earned. |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.vhdl -->
```vhdl
-- main.vhdl - a short tour of the native VHDL Convex client: an HTTP
-- query, a Live subscription started before a mutation so the initial
-- snapshot cannot be missed, an idempotent mutation, and the resulting
-- Live update. Every printed line is checked against the value Convex
-- actually returned; this program exits non-zero if any of them
-- disagree.
--
-- Like every other program in this client, the whole design elaborates
-- as one circuit: convex_transport's clocked request/acknowledge bus
-- (see convex_native.vhdl) plus this one driver process, which is the
-- sole caller of convex.vhdl's client_call (the HTTP half) and
-- convex_sync.vhdl's sync_ procedures (the Live half).
library ieee;
use ieee.std_logic_1164.all;
use work.convex_buffer.all;
use work.convex_json.all;
use work.convex_http.all;
use work.convex_native.all;
use work.convex_sync.all;
use work.convex.all;

entity main is
end entity main;

architecture behav of main is
begin

  xport_inst : entity work.convex_transport;

  driver : process is
    variable r : integer;

    procedure print_line(s : in string) is
      variable rr : integer;
    begin
      for i in s'range loop
        xport_call(xport_req, CMD_STDOUT_WRITE_BYTE,
                    character'pos(s(i)), 0, rr);
      end loop;
      xport_call(xport_req, CMD_STDOUT_WRITE_BYTE, 10, 0, rr);
      xport_call(xport_req, CMD_STDOUT_FLUSH, 0, 0, rr);
    end procedure print_line;

    procedure fatal(msg : in string) is
      variable rr : integer;
    begin
      for i in msg'range loop
        xport_call(xport_req, CMD_STDERR_WRITE_BYTE,
                    character'pos(msg(i)), 0, rr);
      end loop;
      xport_call(xport_req, CMD_STDERR_WRITE_BYTE, 10, 0, rr);
      xport_call(xport_req, CMD_EXIT, 1, 0, rr);
    end procedure fatal;

    procedure getenv(
      name      : in string;
      value     : inout byte_array;
      value_len : out natural;
      found     : out boolean
    ) is
      variable rr, lookup_len : integer;
    begin
      value_len := 0;
      xport_call(xport_req, CMD_GETENV_RESET, 0, 0, rr);
      for i in name'range loop
        xport_call(xport_req, CMD_GETENV_PUSH,
                    character'pos(name(i)), 0, rr);
      end loop;
      xport_call(xport_req, CMD_GETENV_LOOKUP, 0, 0, lookup_len);
      found := lookup_len >= 0;
      if not found then
        return;
      end if;
      for i in 0 to lookup_len - 1 loop
        xport_call(xport_req, CMD_GETENV_BYTE, i, 0, rr);
        buf_put_byte(value, value_len, rr);
      end loop;
    end procedure getenv;

    function string_of(buf : byte_array; len : natural) return string is
      variable s : string(1 to len);
    begin
      for i in 1 to len loop
        s(i) := character'val(buf(buf'low + i - 1));
      end loop;
      return s;
    end function string_of;

    -- Extracts a demo state's "count" field, which Convex's JSON-safe
    -- profile may represent as either an integer or an integral float
    -- (for example the literal 0.0); json_tok_as_int already implements
    -- exactly that acceptance rule, so this only has to find the field.
    procedure count_of(
      buf     : in byte_array;
      toks    : in json_tok_array;
      ntoks   : in natural;
      obj_tok : in integer;
      value   : out integer
    ) is
      variable t : integer;
      variable found, num_ok : boolean;
    begin
      json_object_get(buf, toks, ntoks, obj_tok, "count", t, found);
      if not found then
        fatal("demo state was missing count");
      end if;
      json_tok_as_int(buf, toks, t, value, num_ok);
      if not num_ok then
        fatal("demo count was not an integral number in range");
      end if;
    end procedure count_of;

    variable url_buf : byte_array(0 to 255);
    variable url_len : natural;
    variable have_url : boolean;
    variable room_buf : byte_array(0 to 127);
    variable room_len : natural;
    variable have_room : boolean;
    variable ep : http_endpoint_t;
    variable ep_ok : boolean;

    variable args_buf : byte_array(0 to 255);
    variable args_len : natural;
    variable no_token : byte_array(0 to 0);

    variable is_function_error : boolean;
    variable value_json : byte_array(0 to 4095);
    variable value_len : natural;
    variable logs_json : byte_array(0 to 4095);
    variable logs_len : natural;
    variable error_message : byte_array(0 to 511);
    variable error_message_len : natural;
    variable error_data : byte_array(0 to 1023);
    variable error_data_len : natural;
    variable call_ok : boolean;

    variable toks : json_tok_array(0 to 63);
    variable ntoks : natural;
    variable parse_ok : boolean;

    variable before, after_count : integer;

    variable sm : sync_manager_t;
    variable sub_ok : boolean;
    variable has_event : boolean;
    variable ev_kind : sync_event_kind_t;
    variable ev_sub_id : byte_array(0 to 15);
    variable ev_sub_id_len : natural;
    variable ev_value : byte_array(0 to 4095);
    variable ev_value_len : natural;
    variable ev_logs : byte_array(0 to 4095);
    variable ev_logs_len : natural;
    variable ev_err_name : byte_array(0 to 15);
    variable ev_err_name_len : natural;
    variable ev_err_message : byte_array(0 to 255);
    variable ev_err_message_len : natural;
    variable step_ok : boolean;
    variable live_count : integer;

    variable found : boolean;
    variable applied_tok, state_tok : integer;

    -- Steps the Live connection until an update arrives for the "example"
    -- subscription, or ten seconds pass without one, then decodes its
    -- count. Shared by both waits below: the initial snapshot and the
    -- post-mutation update.
    procedure wait_for_live_update(result_count : out integer) is
      variable local_attempts : natural := 0;
    begin
      loop
        sync_step(xport_req, sm, 100, has_event, ev_kind, ev_sub_id,
                   ev_sub_id_len, ev_value, ev_value_len, ev_logs,
                   ev_logs_len, ev_err_name, ev_err_name_len,
                   ev_err_message, ev_err_message_len, step_ok);
        if not step_ok then
          fatal("Live step failed");
        end if;
        exit when has_event;
        local_attempts := local_attempts + 1;
        if local_attempts >= 100 then
          fatal("timed out waiting for a Live update");
        end if;
      end loop;
      if ev_kind /= SYNC_UPDATED then
        fatal("live update failed: " &
              string_of(ev_err_message, ev_err_message_len));
      end if;
      json_parse(ev_value, ev_value_len, toks, ntoks, parse_ok);
      if not parse_ok then
        fatal("live value was not valid JSON");
      end if;
      count_of(ev_value, toks, ntoks, toks'low, result_count);
    end procedure wait_for_live_update;
  begin
    -- Configure the deployment: the client reads the URL from
    -- CONVEX_URL, same as this project's other native clients, and
    -- accepts a room name as EXAMPLE_ROOM (set by this image's
    -- entrypoint wrapper from the verifier's first positional argument;
    -- see vhdl/Dockerfile) so the shared verifier can target a unique
    -- room per run.
    getenv("CONVEX_URL", url_buf, url_len, have_url);
    if not have_url or url_len = 0 then
      fatal("CONVEX_URL is required");
    end if;
    getenv("EXAMPLE_ROOM", room_buf, room_len, have_room);
    if not have_room or room_len = 0 then
      room_len := 0;
      buf_put_str(room_buf, room_len, "vhdl-basic-example");
    end if;

    -- Create the native VHDL client's connection parameters.
    http_parse_endpoint(string_of(url_buf, url_len), ep, ep_ok);
    if not ep_ok then
      fatal("CONVEX_URL is not a valid deployment URL");
    end if;

    -- Query the counter through Convex's documented HTTP endpoint.
    args_len := 0;
    buf_put_byte(args_buf, args_len, character'pos('{'));
    json_put_string(args_buf, args_len, "room");
    buf_put_byte(args_buf, args_len, character'pos(':'));
    json_put_string_bytes(args_buf, args_len, room_buf, 0, room_len);
    buf_put_byte(args_buf, args_len, character'pos('}'));
    client_call(xport_req, ep, no_token, 0, "query", "demo:state",
                 args_buf, args_len, is_function_error, value_json,
                 value_len, logs_json, logs_len, error_message,
                 error_message_len, error_data, error_data_len, call_ok);
    if not call_ok or is_function_error then
      fatal("query failed");
    end if;
    json_parse(value_json, value_len, toks, ntoks, parse_ok);
    if not parse_ok then
      fatal("query response was not valid JSON");
    end if;
    count_of(value_json, toks, ntoks, toks'low, before);
    print_line("current count: " & integer'image(before));

    -- Start Live before the mutation so the initial snapshot cannot be
    -- missed: subscribing after the mutation could race the server and
    -- deliver the post-mutation value as if it were the starting point.
    sync_init(sm, ep);
    sync_subscribe(xport_req, sm, "example", "demo:state",
                    args_buf, args_len, sub_ok);
    if not sub_ok then
      fatal("subscribe failed");
    end if;

    -- Waits for the actual initial Live value from the bounded event
    -- stream, rather than assuming the first step call already has it.
    wait_for_live_update(live_count);
    if live_count /= before then
      fatal("live initial count did not match the query count");
    end if;
    print_line("live initial count: " & integer'image(before));

    -- Apply the mutation with a stable idempotency key, so retrying this
    -- example against the same room is always safe.
    args_len := 0;
    buf_put_byte(args_buf, args_len, character'pos('{'));
    json_put_string(args_buf, args_len, "room");
    buf_put_byte(args_buf, args_len, character'pos(':'));
    json_put_string_bytes(args_buf, args_len, room_buf, 0, room_len);
    buf_put_byte(args_buf, args_len, character'pos(','));
    json_put_string(args_buf, args_len, "language");
    buf_put_byte(args_buf, args_len, character'pos(':'));
    json_put_string(args_buf, args_len, "VHDL");
    buf_put_byte(args_buf, args_len, character'pos(','));
    json_put_string(args_buf, args_len, "runId");
    buf_put_byte(args_buf, args_len, character'pos(':'));
    buf_put_byte(args_buf, args_len, character'pos('"'));
    buf_put_slice(args_buf, args_len, room_buf, 0, room_len);
    buf_put_str(args_buf, args_len, "-once");
    buf_put_byte(args_buf, args_len, character'pos('"'));
    buf_put_byte(args_buf, args_len, character'pos('}'));
    client_call(xport_req, ep, no_token, 0, "mutation", "demo:increment",
                 args_buf, args_len, is_function_error, value_json,
                 value_len, logs_json, logs_len, error_message,
                 error_message_len, error_data, error_data_len, call_ok);
    if not call_ok or is_function_error then
      fatal("mutation failed");
    end if;
    json_parse(value_json, value_len, toks, ntoks, parse_ok);
    if not parse_ok then
      fatal("mutation response was not valid JSON");
    end if;
    json_object_get(value_json, toks, ntoks, toks'low,
                     "applied", applied_tok, found);
    if not found or toks(applied_tok).kind /= JSON_BOOL
        or not toks(applied_tok).bool_value then
      fatal("mutation was not applied");
    end if;
    json_object_get(value_json, toks, ntoks, toks'low,
                     "state", state_tok, found);
    if not found then
      fatal("mutation response was missing state");
    end if;
    count_of(value_json, toks, ntoks, state_tok, after_count);
    if after_count /= before + 1 then
      fatal("mutation count did not advance by exactly one");
    end if;
    print_line("mutation applied: true");
    print_line("mutation count: " & integer'image(after_count));

    -- Waits for the actual resulting Live value before printing the
    -- verification line.
    wait_for_live_update(live_count);
    if live_count /= after_count then
      fatal("live updated count did not match the mutation count");
    end if;
    print_line("live updated count: " & integer'image(after_count));
    print_line("verified count: " & integer'image(before) &
               " -> " & integer'image(after_count));

    sync_unsubscribe(xport_req, sm, "example", sub_ok);
    xport_call(xport_req, CMD_EXIT, 0, 0, r);
    wait;
  end process driver;

end architecture behav;
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test vhdl           # builds native.c, analyzes and elaborates every
                           # VHDL unit with GHDL 2.0.0's LLVM code generator,
                           # checks the source style gate, and runs every
                           # language-local suite plus three adapter
                           # scenarios and the example against a fixture
./run verify-example vhdl # runs the exact block above against a unique
                           # room on the local self-hosted backend
./run verify vhdl         # verify-example plus shared black-box conformance
./run verify-hosted vhdl  # example and conformance against the hosted
                           # drift target
./run verify-all vhdl     # both deployment profiles from the same build
```

## The GHDL driver-rule finding

GHDL requires an unresolved signal's complete set of drivers to come from
one process, or one procedure-call chain rooted in one process. Two
different processes may each drive a *different* field of the same record
signal, including fields of an unresolved type such as `integer` -- that
elaborates and runs fine. What GHDL forbids is two different processes
driving the *same* unresolved scalar; GHDL does not reject that at
analysis or elaboration-bind time, but the resulting executable fails at
simulation elaboration with `error: several sources for unresolved signal
... error during elaboration` (exit 1). `client/convex_native.vhdl` splits
the request and acknowledge halves of the bus into two separate records
for exactly this reason: `xport_req` is driven only by the driver-side
`xport_call` procedure chain, and `xport_ack` is driven only by
`convex_transport`'s own process. `client/tests/transport_smoke.vhdl` is
the empirical proof that this split satisfies the rule end to end,
including a real TLS handshake.

## Conformance and protocol notes

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- `client/native.c` is the entire foreign side. Standard VHDL has no
  sockets, no TLS, no monotonic clock, no entropy source, no environment
  access and no process exit status; this file supplies exactly those, as
  VHPIDIRECT-callable C functions and nothing else. Every byte of HTTP,
  WebSocket and JSON protocol text, and every deadline and retry, stays in
  VHDL.
- `client/convex_native.vhdl`'s clocked request/acknowledge bus connects
  VHDL to `native.c`; `client/convex_transport.vhdl`'s process is the sole
  owner of the foreign boundary.
- `client/convex_buffer.vhdl` supplies fixed-capacity byte buffers,
  decimal, base64 and hex helpers, since VHDL has no heap and no
  dynamically growing array. `client/convex_json.vhdl` is a bounded
  token-array JSON codec built on it.
- `client/convex_http.vhdl` is a hand-written HTTP/1.1 client (plain
  `Content-Length` and chunked `Transfer-Encoding` responses).
  `client/convex_ws.vhdl` is a hand-written RFC 6455 WebSocket layer:
  handshake, masked frame encode, unmasked decode with fragmentation
  reassembly, and transparent Ping/Pong.
- `client/convex_sync.vhdl` drives Convex's pinned `/api/sync` protocol:
  `Connect`/`ModifyQuerySet`/`Transition` handling, a bounded pending-event
  queue, exponential reconnect backoff, and `connectionCount`/
  `lastCloseReason`/`maxObservedTimestamp` bookkeeping.
- `client/tests/conformance/adapter.vhdl` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode
  (`CMD_LISTEN`/`CMD_ACCEPT` in `native.c`), and declares `debugDisconnect`
  as its one adapter-only command.
- Real OpenSSL certificate- and hostname-verified TLS runs through
  `native.c`'s boundary; `client/tests/transport_smoke.vhdl` proves it
  against a local `openssl s_server` behind a private CA.

## Limitations

- The WebSocket handshake does not verify the server's
  `Sec-WebSocket-Accept` response header against SHA-1 of the client's
  key. A valid HTTP 101 upgrade response is still required, and every
  frame exchanged afterward is real RFC 6455 framing; only that one
  header's cryptographic check is skipped.
- Live authentication, optimistic updates, WebSocket-issued mutations,
  WebSocket actions, and `TransitionChunk` assembly are deferred.
- `convex_sync.vhdl`'s own delivery queue holds at most `SYNC_MAX_PENDING`
  (8) already-decoded events between caller steps and drops the oldest
  undelivered event on overflow rather than growing without bound; it is a
  deliberately bounded queue, not a demand-driven stream, and its overflow
  behaviour is exercised by client-local tests.
- JSON numbers are accepted only when mathematically integral and
  representable exactly within a safe range; fractional, quoted,
  non-finite, and out-of-range values are rejected at the point of use.
- The client is single threaded by construction: `convex_transport`'s one
  process owns the foreign boundary end to end, so Live progress and any
  concurrent HTTP call are interleaved by that process's own request queue
  rather than by OS-level concurrency.
- Only the Docker `test` stage has run so far. Shared and hosted black-box
  conformance have not yet been attempted, so no capability is claimed and
  no badge is earned.
