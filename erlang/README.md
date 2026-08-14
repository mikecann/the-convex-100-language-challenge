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

### One pattern match takes the reply apart

Erlang has no generated type layer, and it barely misses one: pattern matching
reaches into the decoded JSON map, binds the one number you care about, and
refuses to continue if the shape is wrong. The `<<"...">>` marks are Erlang's
bit syntax — invented at Ericsson for dissecting telecom packets, doing double
duty here as JSON keys.

```erlang
Args = #{<<"room">> => <<"docs-erlang">>,
         <<"language">> => <<"Erlang">>,
         <<"runId">> => RunId},
%% TypeScript: const result = await increment({ room, language, runId });
{ok, #{<<"state">> := #{<<"count">> := Count}}, _Logs} =
    convex:call(Client, mutation, <<"demo:increment">>, Args),
io:format("count: ~p~n", [Count])
```

One `=` performed the success check, the destructuring, and the validation.

### The reactive update is mail in your mailbox

Every Erlang process has a mailbox, and `receive` is language syntax, not a
library. The client's `gen_server` owns the WebSocket; passing `self()` asks it
to mail this process each value of the query, from the initial hydration to
every later change.

```erlang
{ok, Live, Subscription} =
    convex:subscribe(Client, <<"demo:state">>, Args, self()),
receive
    %% TypeScript: const state = useQuery(api.demo.state, { room });
    {convex_live, Subscription, #{value := #{<<"count">> := Count}}} ->
        io:format("count is now ~p~n", [Count])
after 10000 ->
    erlang:error(live_timeout)
end
```

React rerenders a component; Erlang delivers a tuple. And the `after` clause is
a built-in timeout — no `Promise.race` required.

### Writing `1 =` is the whole assertion

Erlang was built for phone switches that must not stop, so its culture is "let
it crash": write the value you expect on the left of `=`, and any mismatch
throws `badmatch` with the offending value attached, ready for a supervisor to
handle. The canonical example verifies its whole `0 -> 1` journey this way
(`count/1` is the example's small decoder helper) — no assertion library in
sight.

```erlang
{ok, Initial, _} = convex:call(Client, query, <<"demo:state">>, Args),
0 = count(Initial),
{ok, Mutation, _} =
    convex:call(Client, mutation, <<"demo:increment">>, MutationArgs),
true = maps:get(<<"applied">>, Mutation),
1 = count(maps:get(<<"state">>, Mutation))
```

If the counter ever came back as `2`, the crash report would say exactly that.

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
