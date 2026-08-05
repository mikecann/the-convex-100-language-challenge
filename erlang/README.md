# Convex from Erlang

This native Erlang client queries a Convex counter, subscribes to it over Live,
mutates it, and proves the reactive value changes from `0` to `1`. OTP, Gun,
and JSX provide ordinary transport and JSON building blocks while Erlang owns
the Convex-specific behavior.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for Hex.

## Start here

[`examples/basics/main.erl`](examples/basics/main.erl) is the exact program
Docker runs and the website displays. Its comments follow the shared counter
from 0 to 1 with an HTTP query, a real `/api/sync` subscription started before
the mutation, and the resulting Live update.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared evidence | Native queries, mutations, actions, bearer-token replacement, logs, TLS verification, and structured errors are implemented. |
| Live | Awaiting shared evidence | One native WebSocket owner implements Add/Remove, typed query failures, bounded delivery, reconnect restoration, and stale-relay barriers against the pinned profile. |

The manifest intentionally awards no badges yet. Only the shared local and
hosted black-box controller may turn either row into a passing capability.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.erl -->
```erlang
-module(main).
-export([main/0]).

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

%% JSX follows JavaScript's number model, so Convex's integer counter can
%% arrive as a whole float. Reject fractions rather than silently truncating.
count(Value) ->
    case maps:get(<<"count">>, Value) of
        N when is_integer(N) -> N;
        N when is_float(N), trunc(N) == N -> trunc(N)
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> Value
    end.
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run test erlang
./run build erlang
```

`test` checks the target architecture, treats Erlang compiler lint warnings as
errors, compiles the client, example, and adapter, and runs deterministic
codec, real-socket Live, and partial-NDJSON fixtures. `build` creates the
minimal non-root conformance image. The root
integration task separately owns the serialized `verify-example`, `verify`,
`verify-hosted`, and `verify-all` evidence runs.

## Protocol notes and limits

OTP `httpc` and `ssl` provide ordinary HTTP/TLS transport. Gun 2.5.0 provides
ordinary WebSocket framing, fragmentation, and control handling, and JSX 3.1.0
provides JSON. The Erlang `live` owner alone opens `/api/sync`, sends
Connect/Add/Remove messages, maintains query-set and timestamp state, and
publishes atomically deduplicated updates.

Each subscription keeps the newest 16 undelivered events within a 256 KiB
bound. Both limits include the event currently held by its relay. The test-only
adapter supports NDJSON protocol v1 over stdin/stdout or one `ADAPTER_LISTEN`
TCP controller and exposes `debugDisconnect` only for conformance.

## Limitations

Live authentication, WebSocket mutations and actions, tagged Convex values,
mutation replay, optimistic updates, and `TransitionChunk` assembly are
deferred. Realtime is an internal protocol, so passing evidence for this pinned
revision would not make it a supported third-party SDK contract.

The pinned Gun dependency resolves Cowlib 2.19.0. Hex flags both packages for
request/response splitting (`GHSA-w4f7-4cxr-rv3c`) and separately flags
Cowlib's cookie encoder for header injection (`GHSA-g2wm-735q-3f56`). This
outbound client neither constructs responses nor calls that cookie encoder,
but the vulnerable code remains and no patched Hex release currently exists.
That unresolved dependency risk is another reason not to use this experiment
as production software. No HTTP or Live badge has been earned yet.
