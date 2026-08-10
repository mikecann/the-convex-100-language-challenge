# VHDL

VHDL is an IEEE-standard language for describing, simulating, verifying, and
synthesizing electronic systems. It grew out of the US Department of Defense's
[VHSIC programme](https://microelectronics.esa.int/vhdl/doc/VHDLReport.pdf) and
became IEEE Standard 1076 in 1987. Its strong typing and package syntax will
look a little like Ada, but its everyday niche is digital hardware design and
verification rather than application development. The
[IEEE P1076 page](https://standards.ieee.org/ieee/1076/12535/) describes the
current standard, while [GHDL](https://ghdl.github.io/ghdl/) is the open-source
analyser, compiler, and simulator used here.

This repository takes VHDL somewhere deliberately odd: a simulator-hosted
Convex teaching client. The design models a clocked transport circuit, while a
small C boundary supplies operating-system facilities that standard VHDL does
not have. It is an educational, unofficial demonstration, not a production SDK
or a claim that web clients belong in hardware.

## Getting Started

The canonical [`examples/basics/main.vhdl`](examples/basics/main.vhdl) queries a
counter, subscribes before mutating it, applies an idempotent increment, and
checks that Live delivers the same `0 -> 1` change. From the repository root,
run the exact example in its Docker image against a unique room:

```sh
./run verify-example vhdl
```

You only need Docker. The command builds the pinned GHDL environment and runs
the source reproduced in the Example section below.

## Interesting Parts

### Typed objects become bounded JSON buffers

With the generated TypeScript API, Convex checks the argument shape and knows
the query's return type. This client has no generated Convex types or general
JSON value tree, so its caller writes the object into a fixed-capacity byte
array, then explicitly parses and validates the returned `count`.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function Counter({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**VHDL**

```vhdl
procedure query_count(
  signal rq : inout xport_req_t;
  ep        : in http_endpoint_t;
  room      : in string;
  count     : out integer
) is
  variable args_buf : byte_array(0 to 255);
  variable args_len : natural := 0;
  variable no_token : byte_array(0 to 0);
  variable is_function_error : boolean;
  variable value_json, logs_json : byte_array(0 to 4095);
  variable value_len, logs_len : natural;
  variable error_message : byte_array(0 to 511);
  variable error_message_len : natural;
  variable error_data : byte_array(0 to 1023);
  variable error_data_len : natural;
  variable call_ok, parse_ok, found, count_ok : boolean;
  variable toks : json_tok_array(0 to 63);
  variable ntoks : natural;
  variable count_tok : integer;
begin
  -- Build the same { room } argument object byte by byte.
  buf_put_byte(args_buf, args_len, character'pos('{'));
  json_put_string(args_buf, args_len, "room");
  buf_put_byte(args_buf, args_len, character'pos(':'));
  json_put_string(args_buf, args_len, room);
  buf_put_byte(args_buf, args_len, character'pos('}'));

  -- Call the real demo:state query through this client's HTTP facade.
  client_call(rq, ep, no_token, 0, "query", "demo:state",
              args_buf, args_len, is_function_error, value_json,
              value_len, logs_json, logs_len, error_message,
              error_message_len, error_data, error_data_len, call_ok);
  assert call_ok and not is_function_error
    report "query failed" severity failure;

  -- VHDL types the buffer, not its JSON shape, so decode and check count.
  json_parse(value_json, value_len, toks, ntoks, parse_ok);
  assert parse_ok report "query returned invalid JSON" severity failure;
  json_object_get(value_json, toks, ntoks, toks'low,
                  "count", count_tok, found);
  assert found report "demo state was missing count" severity failure;
  json_tok_as_int(value_json, toks, count_tok, count, count_ok);
  assert count_ok
    report "demo count was not an integral number in range"
    severity failure;
end procedure query_count;
```

The full example accepts Convex's integral `0.0` representation while rejecting
fractional, quoted, non-finite, and overflowing values. That is runtime client
checking, not compile-time knowledge of the Convex schema.

### React owns reactivity; this process advances it

React's `useQuery` subscribes during rendering and cleans up with the component.
The command-line VHDL client instead owns a `sync_manager_t`: it subscribes,
calls `sync_step` until an event arrives, and unsubscribes explicitly.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function LiveCounter({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  if (state === undefined) return <p>Loading...</p>;

  // The generated API makes state.count a number, and React owns the update.
  return <p>{state.count}</p>;
}
```

**VHDL**

```vhdl
procedure observe_once(
  signal rq : inout xport_req_t;
  ep        : in http_endpoint_t;
  room      : in string
) is
  variable args_buf : byte_array(0 to 255);
  variable args_len : natural := 0;
  variable sm : sync_manager_t;
  variable sub_ok, has_event, step_ok : boolean;
  variable event_kind : sync_event_kind_t;
  variable sub_id : byte_array(0 to 15);
  variable sub_id_len : natural;
  variable value_json, logs_json : byte_array(0 to 4095);
  variable value_len, logs_len : natural;
  variable error_name : byte_array(0 to 15);
  variable error_name_len : natural;
  variable error_message : byte_array(0 to 255);
  variable error_message_len : natural;
  variable error_data : byte_array(0 to 511);
  variable error_data_len : natural;
  variable attempts : natural := 0;
begin
  -- The caller passes the endpoint parsed from CONVEX_URL and a real room.
  buf_put_byte(args_buf, args_len, character'pos('{'));
  json_put_string(args_buf, args_len, "room");
  buf_put_byte(args_buf, args_len, character'pos(':'));
  json_put_string(args_buf, args_len, room);
  buf_put_byte(args_buf, args_len, character'pos('}'));
  sync_init(sm, ep);
  sync_subscribe(rq, sm, "counter", "demo:state",
                 args_buf, args_len, sub_ok);
  assert sub_ok report "subscribe failed" severity failure;

  -- Unlike useQuery, this client must be stepped until an update arrives.
  loop
    sync_step(rq, sm, 100, has_event, event_kind, sub_id,
              sub_id_len, value_json, value_len, logs_json, logs_len,
              error_name, error_name_len, error_message,
              error_message_len, error_data, error_data_len, step_ok);
    assert step_ok report "Live step failed" severity failure;
    exit when has_event;
    attempts := attempts + 1;
    assert attempts < 100 report "Live query timed out" severity failure;
  end loop;
  assert event_kind = SYNC_UPDATED
    report "Live query failed" severity failure;

  -- value_json now contains the reactive state; the full example decodes it.
  sync_unsubscribe(rq, sm, "counter", sub_ok);
  assert sub_ok report "unsubscribe failed" severity failure;
end procedure observe_once;
```

`sync_step` is this client's blocking, demand-driven API, so no background
callback or React lifecycle hides ownership. The [canonical example](examples/basics/main.vhdl) shows
`CONVEX_URL` parsing, full event decoding, mutation, and cleanup.

## Status

| Capability | Current state | Evidence-backed scope |
| --- | --- | --- |
| HTTP | Badge earned | `client_call` supports query, mutation, action, bearer-token auth, logs, and structured function errors. |
| Live | Badge earned | The subscription manager supports subscribe/unsubscribe, five reconnects with backoff, and recovery after reactive errors, including structured `errorData`. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS. This README rewrite does not claim a new verification run.

## Example

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
    variable ev_err_data : byte_array(0 to 511);
    variable ev_err_data_len : natural;
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
                   ev_err_message, ev_err_message_len,
                   ev_err_data, ev_err_data_len, step_ok);
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

## Implementation Notes

This is native VHDL in the repository's provenance taxonomy because all
Convex-specific HTTP, JSON, WebSocket, and Live behaviour is implemented in
VHDL. `client/native.c` is a narrow VHPIDIRECT boundary for sockets, OpenSSL,
time, entropy, environment access, output, and process exit. It does not
delegate to another Convex client.

The program is still simulator-hosted. VHDL describes concurrent hardware
behaviour, and GHDL analyses, elaborates, and runs that design as a native ELF.
Every executable instantiates `convex_transport`, whose clocked process alone
calls the C boundary. A caller toggles `xport_req` and waits for `xport_ack`, so
network I/O looks like a peripheral transaction on a simulated bus. Nothing in
this repository turns that design into an FPGA or ASIC.

The request and acknowledgement records are separate because GHDL requires an
unresolved signal's drivers to come from one process or one procedure-call
chain. `xport_req` belongs to the caller side and `xport_ack` to the transport
process. The split is a practical VHDL constraint, not part of Convex.

Storage is deliberately bounded: byte buffers, JSON tokens, subscriptions, and
pending Live events all have fixed capacities. The Live manager supports eight
subscriptions and queues eight decoded events, dropping the oldest pending
event on overflow. HTTP mutation and action calls remain separate from the Live
WebSocket, and one process advances both sides rather than using OS threads.

## Known Issues

1. The WebSocket upgrade requires HTTP status 101 but does not verify
   `Sec-WebSocket-Accept` against the client's key.
2. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are not implemented.
3. Fixed-capacity buffers reject oversized data. Integral JSON numbers are
   accepted only within the client's safe range; fractional, quoted,
   non-finite, and overflowing values are rejected where integers are expected.
4. The eight-event Live queue drops its oldest undelivered item on overflow,
   and callers must keep invoking `sync_step` to make progress.
