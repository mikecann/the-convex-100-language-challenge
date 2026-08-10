# Erlang

[Erlang](https://www.erlang.org/) is a functional language and runtime created
at Ericsson in the late 1980s for telecom systems. Its lightweight processes,
message passing, and fault-tolerance tools now also suit highly available
servers in areas such as banking, ecommerce, and messaging. OTP is the standard
set of Erlang libraries and middleware used to build those systems.

This repository uses those ideas to make a native Convex client. It is an
educational, unofficial demonstration, not a production SDK, an officially
sanctioned Convex client, or a package intended for Hex.

## Getting Started

The canonical [`examples/basics/main.erl`](examples/basics/main.erl) queries a
counter, starts a Live subscription, increments it, and receives the reactive
update from `0` to `1`. From the repository root, run it in Docker with:

```sh
./run verify-example erlang
```

## Interesting Parts

### Maps and pattern matching replace generated app types

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function handleClick() {
    const result = await increment({
      room: "docs-erlang",
      language: "TypeScript",
      runId: crypto.randomUUID(), // Fresh idempotency key for this click.
    });
    console.log(result.state.count); // Generated Convex types know this is a number.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Erlang**

```erlang
increment_once() ->
    Deployment =
        case os:getenv("CONVEX_URL") of
            false -> erlang:error(missing_convex_url);
            Url -> Url
        end,
    {ok, Client} = convex:new(Deployment),
    %% A new random idempotency key lets each invocation increment once.
    RunId = base64:encode(crypto:strong_rand_bytes(16)),
    Args = #{<<"room">> => <<"docs-erlang">>,
             <<"language">> => <<"Erlang">>,
             <<"runId">> => RunId},
    try
        %% convex:call/4 blocks, then returns decoded Erlang maps.
        {ok, #{<<"state">> := #{<<"count">> := Count}}, _Logs} =
            convex:call(Client, mutation, <<"demo:increment">>, Args),
        io:format("~p~n", [Count]) % Count is checked at runtime, not generated typing.
    after
        convex:close(Client)
    end.
```

Convex code generation gives the React call app-specific argument and return
types. This Erlang client has no equivalent generated type layer. It decodes
JSON to maps, and the pattern either binds `Count` from the expected shape or
fails immediately. The synchronous `convex:call/4` API is this client's design,
not a limitation of Erlang's process model.

### A Live value arrives as a process message

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "docs-erlang-live" });
  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // React rerenders when the query changes.
}
```

**Erlang**

```erlang
print_next_count() ->
    Deployment =
        case os:getenv("CONVEX_URL") of
            false -> erlang:error(missing_convex_url);
            Url -> Url
        end,
    {ok, Client} = convex:new(Deployment),
    Args = #{<<"room">> => <<"docs-erlang-live">>},
    %% self() makes this process the destination for Live messages.
    {ok, Live, Subscription} =
        convex:subscribe(Client, <<"demo:state">>, Args, self()),
    try
        receive
            %% This can be the initial value or a later reactive update.
            {convex_live, Subscription,
             #{value := #{<<"count">> := Count}}} ->
                io:format("~p~n", [Count])
        after 10000 ->
            erlang:error(live_timeout)
        end
    after
        %% A CLI program owns teardown that React handles on unmount.
        convex:unsubscribe(Live, Subscription),
        convex:close(Client)
    end.
```

React's `useQuery` owns the subscription lifecycle and rerenders the component.
Here one Erlang `gen_server` owns the WebSocket, then sends `{convex_live, ...}`
messages to the subscriber's mailbox. Erlang supports many ways to structure
that message handling. Blocking in `receive` is the small command-line API and
example's choice.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native queries, mutations, actions, bearer-token replacement, logs, TLS verification, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | One native WebSocket owner implements subscription add/remove, query failures, bounded delivery, reconnect restoration, and stale-message barriers against the pinned profile. |

The manifest records both HTTP and Live as earned capabilities. These results
apply to the repository's pinned backend and sync profile.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.erl -->
```erlang
-module(main).
-export([main/0]).
-ifdef(TEST).
-export([count/1]).
-endif.

-define(MIN_COUNT, -9223372036854775808).
-define(MAX_COUNT, 9223372036854775807).

main() ->
    Room =
        case init:get_plain_arguments() of
            [R | _] -> R;
            [] -> "erlang-basic-example"
        end,
    %% The verifier supplies a deployment URL; the local default is convenient
    %% when someone runs the example against the repository's test backend.
    Deployment = env("CONVEX_URL", "http://127.0.0.1:3210"),
    %% One client owns both documented HTTP calls and one /api/sync connection.
    {ok, Client} = convex:new(Deployment),
    Args = #{<<"room">> => unicode:characters_to_binary(Room)},
    %% These public demo functions need no bearer token. Protected functions
    %% would use convex:set_auth/2 before making HTTP calls.
    try
        %% First read the durable counter through Convex's documented HTTP API.
        {ok, Initial, _} = convex:call(Client, query, <<"demo:state">>, Args),
        0 = count(Initial),
        io:format("current count: 0~n"),
        %% Start Live before changing the counter, so no update can fall into a
        %% gap between the initial read and the subscription.
        {ok, Live, Subscription} =
            convex:subscribe(Client, <<"demo:state">>, Args, self()),
        try
            %% A Live query first hydrates its current value. Decode that value
            %% into the same idiomatic integer used by the HTTP result.
            0 = next_count(Subscription),
            io:format("live initial count: 0~n"),
            %% Convex records this idempotency key so retrying this exact write
            %% cannot increment the room twice.
            MutationArgs =
                #{<<"room">> => unicode:characters_to_binary(Room),
                  <<"language">> => <<"Erlang">>,
                  <<"runId">> => unicode:characters_to_binary(Room ++ "-once")},
            {ok, Mutation, _} =
                convex:call(Client, mutation, <<"demo:increment">>, MutationArgs),
            true = maps:get(<<"applied">>, Mutation),
            1 = count(maps:get(<<"state">>, Mutation)),
            io:format("mutation applied: true~nmutation count: 1~n"),
            %% The sole Live owner decodes the resulting WebSocket Transition
            %% and relays the changed value in protocol order.
            1 = next_count(Subscription),
            io:format("live updated count: 1~n"),
            %% Reaching this line proves HTTP and Live agreed on one 0 -> 1
            %% journey, so the universal transcript can report success.
            io:format("verified count: 0 -> 1~n")
        after
            %% Remove the server-side query even if a later assertion fails.
            convex:unsubscribe(Live, Subscription)
        end
    after
        %% Stop the sole socket owner and release every client connection.
        convex:close(Client)
    end.

%% Turn one reactive value into an integer, or fail clearly on query errors and
%% stalled delivery rather than leaving an educational example hanging.
next_count(Id) ->
    receive
        {convex_live, Id, #{value := Value}} -> count(Value);
        {convex_live, Id, #{error := Error}} -> erlang:error(Error)
    after 10000 ->
        erlang:error(live_timeout)
    end.

%% JSX may decode Convex's counter as either an integer or a whole float.
%% Accept both spellings within a signed 64-bit teaching value, but reject
%% fractions, strings, non-finite stand-ins, and values that would overflow.
count(Value) ->
    case maps:get(<<"count">>, Value) of
        N when is_integer(N), N >= ?MIN_COUNT, N =< ?MAX_COUNT -> N;
        N when is_float(N) ->
            Whole = trunc(N),
            case N == Whole andalso Whole >= ?MIN_COUNT andalso Whole =< ?MAX_COUNT of
                true -> Whole;
                false -> erlang:error({invalid_count, N})
            end;
        Invalid -> erlang:error({invalid_count, Invalid})
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> Value
    end.
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Erlang implementation. OTP 26.2.5.15 supplies `httpc`, TLS,
processes, and the `gen_server` behaviour. Gun 2.5.0 handles ordinary WebSocket
transport, Cowlib 2.19.0 supports Gun, and JSX 3.1.0 handles JSON. Erlang code in
[`client/convex.erl`](client/convex.erl) builds Convex HTTP requests and decodes
results, while [`client/live.erl`](client/live.erl) owns the Convex-specific
Live state.

One `gen_server` has exclusive ownership of the socket, reconnect state, and
query set. Per-subscription relay processes keep slow consumers away from that
owner. Each subscription retains at most the newest 16 undelivered events and
256 KiB, including an event already being delivered. The conformance adapter
has the same count and byte limits for output to a stalled controller.

The Docker image contains the BEAM runtime and the required OTP bytecode, but
not Erlang compiler commands or package tooling. HTTP, TLS, WebSocket, and JSON
startup are probed in that final non-root image. `debugDisconnect` is compiled
into the adapter for reconnect testing and is not part of the educational
client API.

For more background, Erlang's official documentation explains
[processes and message passing](https://www.erlang.org/doc/system/ref_man_processes.html),
[map patterns](https://www.erlang.org/doc/system/expressions.html#maps-in-patterns),
and [the language's history](https://www.erlang.org/course/history.html).
Convex documents how its React client
[manages reactive queries](https://docs.convex.dev/client/react/overview) and
how [generated API types](https://docs.convex.dev/generated-api/) provide
TypeScript type safety.

## Known Issues

1. Live authentication, WebSocket mutations and actions, tagged Convex values,
   and `TransitionChunk` assembly are not implemented.
2. Live relies on an internal, pinned Convex sync profile. Passing conformance
   does not make that profile a supported third-party SDK contract.
3. Gun 2.5.0 and Cowlib 2.19.0 contain code flagged by Hex for
   request/response splitting (`GHSA-w4f7-4cxr-rv3c`), and Cowlib's cookie
   encoder is flagged for header injection (`GHSA-g2wm-735q-3f56`). This
   outbound client does not construct responses or call the cookie encoder,
   but the dependency code remains and no patched Hex release is available.
4. Live delivery is intentionally bounded. A slow subscriber keeps only the
   newest 16 events within 256 KiB rather than an unlimited history.
