# C3

[C3](https://c3-lang.org/) is a modern systems language inspired by C, with
modules, safer defaults, optional error returns, and familiar low-level control.
It is used for native tools, games, and other software where a small compiled
binary and predictable resource use matter. This repository's client is an
unofficial educational demonstration, not a production SDK.

## Getting Started

Start with [`examples/basics/main.c3`](examples/basics/main.c3). From the
repository root, Docker builds the pinned `linux/amd64` toolchain and runs that
exact program against a fresh room:

```sh
./run verify-example c3
```

## Interesting Parts

### A fault travels inside `int?`

C3 is Christoffer Lernö's careful evolution of C, and its signature move is the
Optional: `int?` is an `int` that may instead carry a named fault, fusing
`Option` and `Result` into one type. Faults are declared with `faultdef` and
raised with a `~` suffix — so when Convex serialises a counter as the JSON
double `1.0`, the decoder can insist it is mathematically integral:

```c3
faultdef EXPECTED_INTEGRAL_NUMBER, OUT_OF_RANGE;

fn int? parse_counter(String encoded)
{
    Object* value = json::tparse(encoded, JSON)!;
    if (value.type != double) return EXPECTED_INTEGRAL_NUMBER~;
    double number = value.f;
    if (number != (double)(int)number) return EXPECTED_INTEGRAL_NUMBER~;
    if (number > 2147483647.0 || number < -2147483648.0) return OUT_OF_RANGE~;
    return (int)number;
}
```

### `??` turns a missing key into a raised fault

Most languages give `??` a default value. In C3 the right-hand side can itself
be a raised fault, and a trailing `!` re-raises it — so "fetch this key or fail
the whole decode" is one line, repeated for each field of Convex's response
envelope:

```c3
fn DecodedResponse? decode(String body)
{
    Object* root = json::parse(mem, body, JSON)!;
    if (!root.is_map()) return PROTOCOL_ERROR~;
    Object* status = root.get("status") ?? PROTOCOL_ERROR~!;
    // ...
    Object* value = root.get("value") ?? PROTOCOL_ERROR~!;
    return { .kind = SUCCESS, .value = value, .logs = logs };
}
```

### Backtick JSON on the temp allocator

C3's backtick strings are raw, so a JSON template keeps its quotes unescaped.
The stdlib's `t`-prefixed functions (`tformat`, `tescape`) allocate on the temp
allocator — an arena wiped wholesale at scope end, so building an envelope per
request never needs an individual `free`:

```c3
// TypeScript: await client.mutation(api.demo.increment, { room, ... })
fn String mutation_envelope(String path, String args, String idempotency_key)
{
    return string::tformat(`{"path":%s,"args":%s,"format":"json","idempotencyKey":%s}`,
                           path.tescape(), args, idempotency_key.tescape());
}
```

### Live is a loop you tick

No hidden background thread: one `Manager` owns the WebSocket, query-set
versions, reconnect backoff, and bounded event queues, and it only makes
progress when you call `manager_tick`. Updates come out as owned events you
dispose yourself — allocation stays visible, C-style:

```c3
c3_live::Manager live;
c3_live::manager_init(&live, deployment);
if (!c3_live::manager_subscribe(&live, "example", "demo:state", state_args)) return;

while (c3_monotonic_millis() < deadline)
{
    c3_live::manager_tick(&live);
    c3_live::LiveEvent event;
    if (!c3_live::manager_take_event(&live, &event)) continue;
    // TypeScript: const state = useQuery(api.demo.state, { room }) re-renders here
    Object* root = json::tparse(event.payload, JSON)!!;
    c3_live::live_event_dispose(&event);
}
```

The same tick also drives the five real reconnects the conformance suite
demands — one loop, one owner, no callbacks.

## Status

| Capability | Status |
| --- | --- |
| HTTP | Passing locally and hosted |
| Live | Passing locally and hosted |

The shared black-box suite passes against both the self-hosted and hosted test
deployments, including five real Live reconnects and recovery after query errors.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.c3 -->
```c3
module c3_example;

import std::collections::object;
import std::encoding::json;
import std::io;
import std::os::env;
import c3_http;
import c3_live;
import c3_response;
import c3_values;

faultdef LIVE_TIMEOUT, LIVE_FAILED;

extern fn CLongLong c3_monotonic_millis();

fn String object_json(Object* value) => string::tformat("%s", value);

fn int? count_of(Object* value)
{
    if (!value.is_map() || !value.has_key("count")) return LIVE_FAILED~;
    return c3_values::parse_counter(object_json(value.get("count")!!));
}

// Live events share the adapter's JSON shape. This helper waits for a value,
// while treating a structured subscription error as a failed example.
fn int? next_live_count(c3_live::Manager* live)
{
    CLongLong deadline = c3_monotonic_millis() + 15000;
    while (c3_monotonic_millis() < deadline)
    {
        c3_live::manager_tick(live);
        c3_live::LiveEvent event;
        if (!c3_live::manager_take_event(live, &event)) continue;
        Object* root = json::tparse(event.payload, JSON)!!;
        if (!root.has_key("value"))
        {
            io::eprintfn("Live subscription failed: %s", event.payload)!!;
            c3_live::live_event_dispose(&event);
            return LIVE_FAILED~;
        }
        int? count = count_of(root.get("value")!!);
        c3_live::live_event_dispose(&event);
        return count;
    }
    return LIVE_TIMEOUT~;
}

// The verifier supplies a unique room as argv[1], so every run starts from a
// fresh counter without needing a test-only reset operation.
fn int main(String[] args)
{
    if (args.len < 2) { io::eprintn("usage: convex-example ROOM"); return 1; }
    String deployment = env::tget_var("CONVEX_URL") ?? "";
    if (!deployment.len) { io::eprintn("CONVEX_URL is required"); return 1; }
    String room = args[1];
    char[65536] response;
    usz response_length;
    String state_args = string::tformat(`{"room":"%s"}`, room);

    // Create the HTTP client request and decode Convex's first query result as
    // an integral C3 value.
    String query = c3_http::query_envelope("demo:state", state_args);
    c3_http::post(deployment, "/api/query", query, "", response[..], &response_length)!!;
    c3_response::DecodedResponse first = c3_response::decode((String)response[:response_length])!!;
    int before = count_of(first.value)!!;
    if (before != 0) { io::eprintn("expected initial counter 0"); return 1; }

    // Start Live before mutating, then wait for its initial value. This ordering
    // proves the later value arrived through the subscription, not another query.
    c3_live::Manager live;
    c3_live::manager_init(&live, deployment);
    if (!c3_live::manager_subscribe(&live, "example", "demo:state", state_args))
    {
        io::eprintn("Live subscription could not connect");
        c3_live::manager_close(&live);
        return 1;
    }
    int live_before = next_live_count(&live)!!;
    if (live_before != 0) { io::eprintn("expected initial Live counter 0"); c3_live::manager_close(&live); return 1; }

    // The room is also the idempotency key, so retrying this exact example
    // cannot apply the same logical mutation twice.
    String mutation_args = string::tformat(
        `{"room":"%s","language":"C3","runId":"%s-once"}`, room, room);
    String mutation = c3_http::mutation_envelope("demo:increment", mutation_args, room);
    c3_http::post(deployment, "/api/mutation", mutation, "", response[..], &response_length)!!;
    c3_response::DecodedResponse applied = c3_response::decode((String)response[:response_length])!!;
    if (!applied.value.is_map() || !applied.value.has_key("applied")
        || object_json(applied.value.get("applied")!!) != "true"
        || !applied.value.has_key("state"))
    {
        io::eprintn("unexpected mutation result");
        c3_live::manager_close(&live);
        return 1;
    }
    int mutation_count = count_of(applied.value.get("state")!!)!!;
    if (mutation_count != 1) { io::eprintn("expected mutation counter 1"); c3_live::manager_close(&live); return 1; }

    // Decode the resulting Live update, then use one final HTTP query as an
    // independent check that both transports agree on the committed value.
    int live_after = next_live_count(&live)!!;
    if (live_after != 1) { io::eprintn("expected updated Live counter 1"); c3_live::manager_close(&live); return 1; }
    c3_http::post(deployment, "/api/query", query, "", response[..], &response_length)!!;
    c3_response::DecodedResponse second = c3_response::decode((String)response[:response_length])!!;
    int after = count_of(second.value)!!;
    c3_live::manager_close(&live);
    if (after != 1) { io::eprintn("expected final counter 1"); return 1; }

    io::printn("current count: 0");
    io::printn("live initial count: 0");
    io::printn("mutation applied: true");
    io::printn("mutation count: 1");
    io::printn("live updated count: 1");
    io::printn("verified count: 0 -> 1");
    return 0;
}
```
<!-- END GENERATED EXAMPLE -->

Its expected stdout transcript is the repository-wide six-line basics
transcript, proving the `0 -> 1` journey across HTTP and Live.

## Implementation Notes

- The implementation is native C3. C3 owns HTTP envelopes, Convex response
  decoding, Live transitions, query-set versions, subscriptions, and recovery.
  A narrow C shim uses pinned libcurl and OpenSSL for HTTPS, verified TLS,
  secure randomness, clocks, and RFC6455 transport bytes.
- One manager owns WebSocket I/O. Each subscription is bounded to 16 events and
  256 KiB, while incoming WebSocket messages are capped at 2 MiB.
- `debugDisconnect` is adapter-only test infrastructure. It retires the old
  connection before acknowledging and is not part of the educational API.
- Runtime images are Debian-derived, run as `65532:65532`, and contain only the
  allowlisted shell/text tools, compiled binaries, CA data, and TLS/DNS closure.

## Known Issues

1. HTTP authentication is supported by the conformance adapter, but Live auth
   transitions are not yet exposed by the small public C3 API.
