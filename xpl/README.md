# XPL

XPL is a compact language derived from PL/I for writing compilers. It was
announced at the 1968 Fall Joint Computer Conference, and the name covers both
the language and its original translator-writing system. XPL influenced the
PL/M family and HAL/S. Today it is a historical, specialist language with
modern ports rather than a mainstream application ecosystem. The
[XPL site hosted by co-creator David Wortman](https://www.cs.toronto.edu/XPL/)
collects its history, language description, and ports, while the
[compiler used here](https://github.com/sergev/xpl-compiler) translates XPL to
C.

This repository's client is an educational, unofficial demonstration. It is
not a production Convex SDK.

## Getting Started

Start with [`examples/basics/main.xpl`](examples/basics/main.xpl). It queries a
counter, starts a Live subscription, applies an idempotent mutation, and checks
that the reactive value moves from 0 to 1.

From the repository root, run the exact example in its Docker image against the
dedicated test backend:

```sh
./run verify-example xpl
```

The command builds and runs the XPL program inside Docker, so you do not need an
XPL compiler installed on your machine.

## Interesting Parts

### A mutation's arguments are spliced-together JSON text

XPL has no record or struct type, so the client can't hand `convex_call` a
typed argument object the way a generated Convex API would. The caller
concatenates JSON text by hand instead, leaning on `json_encode_string` only
for escaping:

```text
args = '{"room":' || json_encode_string('', room) ||
    ',"language":' || json_encode_string('', 'XPL') ||
    ',"runId":' || json_encode_string('', run_id) || '}';

if convex_call('mutation', 'demo:increment', args) = 0 then
    call die(g_error_message);
/* TypeScript: await increment({ room, language: "XPL", runId }) */
```

`||` is XPL's string operator, inherited from PL/I. There's no object literal
to reach for, so the request over the wire is exactly the text you build.

### A live query is a blocking call, not a subscribed callback

React's `useQuery` subscribes once and quietly re-renders on every push from
Convex. This client exposes the same WebSocket stream as an ordinary function
that blocks until Convex has something to say, and the caller dequeues
updates on its own schedule:

```text
if convex_subscribe('demo:state', args) = 0 then call die(g_error_message);
if convex_subscription_next = 0 then call die(g_error_message);
count = count_of(g_sub_pending_value);

/* TypeScript: const state = useQuery(api.demo.state, { room }) */
call convex_unsubscribe;
```

There's no component unmount to trigger cleanup, so `convex_unsubscribe` has
to be called by hand once the program is done watching.

### No struct type, so a WebSocket frame is poked into memory

XPL compiles down to C but never picked up a struct of its own, so the client
can't declare an RFC 6455 frame header as a record. Sending a Live message
means writing the header, mask, and masked payload straight into a raw byte
buffer, one `corebyte` poke at a time:

```text
mbase = addr(mask(0));
call RAND_bytes(mbase, 4);                 /* 4 random mask bytes, from OpenSSL */
fbase = addr(framebuf(0));

corebyte(fbase) = 128 | opcode;            /* fin bit + opcode */
corebyte(fbase + 1) = 128 | n;             /* masked bit + payload length */
corebyte(fbase + hlen) = mask(0);
corebyte(fbase + hlen + 1) = mask(1);
corebyte(fbase + hlen + 2) = mask(2);
corebyte(fbase + hlen + 3) = mask(3);
hlen = hlen + 4;
do i = 0 to n - 1;
    corebyte(fbase + hlen + i) = byte(payload, i) xor mask(i mod 4);
end;
```

Nothing in the runtime knows what a WebSocket frame is; the client builds one
from scratch, byte by byte, every time it talks to Convex.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live subscribe, unsubscribe, external updates, and query error recovery | Verified by shared local and hosted conformance |
| Concurrent multi-subscription delivery and five real `debugDisconnect` reconnects | Verified by shared local and hosted conformance |

The manifest records both `http` and `live` as earned capabilities. The table
above reports the existing evidence; this documentation change does not claim a
new verification run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.xpl -->
```text
/* Convex from XPL: the canonical counter walk.
 *
 * This program is the exact source shown in the README and on the
 * website. It proves the same 0 -> 1 journey over both transports:
 * an HTTP query for the current count, a Live subscription started
 * before the mutation so no update can be missed, the mutation
 * itself, and the resulting Live update.
 */

/* Convex renders a whole count as either "0" or "0.0"; this decodes
 * both to a plain integer and rejects anything that is not actually a
 * non-negative whole number (a quoted string, a fractional value, or
 * something too large to be a real count in this demonstration).
 */
decode_count: procedure(s, start, fin) fixed;
    declare s character, start fixed, fin fixed, i fixed, v fixed, digits fixed;
    i = start;
    v = 0;
    digits = 0;
    do while i < fin & byte(s, i) >= 48 & byte(s, i) <= 57;
        if v > 100000000 then return -1;
        v = v * 10 + (byte(s, i) - 48);
        digits = digits + 1;
        i = i + 1;
    end;
    if digits = 0 then return -1;
    if i < fin & byte(s, i) = 46 then do;
        i = i + 1;
        if i >= fin then return -1;
        do while i < fin & byte(s, i) >= 48 & byte(s, i) <= 57;
            if byte(s, i) ~= 48 then return -1;
            i = i + 1;
        end;
    end;
    if i ~= fin then return -1;
    return v;
end decode_count;

/* Reads the "count" member of a demo:state result value (query
   result, mutation's nested "state", or a Live update) and returns
   its decoded value, or -1 if "count" is missing or not a whole
   number. */
count_of: procedure(value_json) fixed;
    declare value_json character, found fixed;
    found = json_find_member(value_json, 1, 'count');
    if found = 0 then return -1;
    return decode_count(value_json, g_span_start, g_span_end);
end count_of;

die: procedure(message);
    declare message character;
    output(1) = message;
    call exit(1);
end die;

declare room character, args character, run_id character;
declare count fixed;

/* Configure the deployment from the environment and create the client. */
if convex_init = 0 then call die(g_error_message);
if argc > 1 then room = argv(1);
else room = 'xpl-basic-example';

/* Query the current counter over HTTP and decode its JSON object. */
args = '{"room":' || json_encode_string('', room) || '}';
if convex_call('query', 'demo:state', args) = 0 then
    call die('unexpected initial query value: ' || g_error_message);
count = count_of(g_value_json);
if count ~= 0 then call die('unexpected initial query value');
output = 'current count: 0';

/* Start Live before the mutation so no reactive update can be missed. */
if convex_subscribe('demo:state', args) = 0 then
    call die('could not subscribe: ' || g_error_message);
if convex_subscription_next = 0 then
    call die('unexpected initial Live value: ' || g_error_message);
if g_sub_pending_is_error = 1 then
    call die('unexpected initial Live value: ' || g_sub_pending_error_message);
count = count_of(g_sub_pending_value);
if count ~= 0 then call die('unexpected initial Live value');
output = 'live initial count: 0';

/* The run ID makes the mutation safe to retry without incrementing twice. */
run_id = room || '-once';
args = '{"room":' || json_encode_string('', room) ||
    ',"language":' || json_encode_string('', 'XPL') ||
    ',"runId":' || json_encode_string('', run_id) || '}';
if convex_call('mutation', 'demo:increment', args) = 0 then
    call die('mutation failed: ' || g_error_message);
if json_find_member(g_value_json, 1, 'applied') = 0 |
        raw_eq(g_value_json, g_span_start, g_span_end - g_span_start, 'true') = 0 then
    call die('unexpected mutation result');
if json_find_member(g_value_json, 1, 'state') = 0 then
    call die('unexpected mutation result');
count = count_of(substr(g_value_json, g_span_start, g_span_end - g_span_start));
if count ~= 1 then call die('unexpected mutation result');
output = 'mutation applied: true';
output = 'mutation count: 1';

/* Decode the resulting Live update, then cleanly remove the subscription. */
if convex_subscription_next = 0 then
    call die('unexpected updated Live value: ' || g_error_message);
if g_sub_pending_is_error = 1 then
    call die('unexpected updated Live value: ' || g_sub_pending_error_message);
count = count_of(g_sub_pending_value);
if count ~= 1 then call die('unexpected updated Live value');
output = 'live updated count: 1';
call convex_unsubscribe;

/* Print verification only after HTTP and Live agree on the 0 -> 1 journey. */
output = 'verified count: 0 -> 1';
eof
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The pinned XPL 1.0 translator emits C, and GCC turns that into the final ELF
executables. The compiler and GCC stay in the Docker build stage; the runtime
images contain only the binaries, CA certificates, and OpenSSL runtime needed
to connect to Convex.

There is no XPL package ecosystem to supply an HTTP, JSON, or WebSocket client.
[`client/convex.xpl`](client/convex.xpl) declares POSIX socket and OpenSSL
functions with `EXTERNAL`, then implements the Convex-specific request and Live
behavior itself. It also constructs `sockaddr_in`, `addrinfo`, and WebSocket
frame memory with `corebyte()`, `coreword()`, and `corelongword()` because this
code cannot pass C-style structures around naturally.

XPL procedures return one scalar and the client cannot use structs as ordinary
out-parameters, so operations publish result spans and error details through
globals. The hand-written JSON scanner is iterative because recursive nested
procedures are unsafe in this translator. Large JSON-safe values are kept as
exact source spans instead of decoded into a general XPL value and encoded
again.

XPL also has no module or `#include` system. The Docker build concatenates the
client core in front of the example, adapter, or unit-test entry point before
translation. For conformance, the adapter uses one `poll(2)` loop to own both
the controller socket and Live WebSocket. Its fixed table supports up to 32
simultaneous subscriptions without threads or runtime-computed function calls.

## Known Issues

1. The public client handles the JSON-safe Convex value subset only. Tagged
   values such as Convex integers and bytes do not have a general XPL decoding
   layer.
2. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are deferred. HTTP bearer-token replacement
   is supported.
3. The direct educational Live API owns one active subscription, while the
   conformance adapter multiplexes at most 32. The implementation is pinned to
   `linux/amd64` and relies on glibc x86-64 structure offsets.
