# Convex from Erlang

This native Erlang client demonstrates Convex HTTP queries, mutations, actions, and Live queries using OTP plus Gun and JSX.

It is educational and unofficial, not a production SDK.

## Start here

[`examples/basics/main.erl`](examples/basics/main.erl) follows the shared counter from 0 to 1 with an HTTP query, a real `/api/sync` WebSocket subscription started before the mutation, and the resulting Live update.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, auth replacement and structured errors | Implemented, awaiting shared HTTP conformance |
| Live initial values, updates, Remove, error recovery and reconnect | Implemented, awaiting shared evidence |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.erl -->
```text
-module(main).
-export([main/0]).

main() ->
    Room = case init:get_plain_arguments() of [R | _] -> R; [] -> "erlang-basic-example" end,
    {ok, Client} = convex:new(env("CONVEX_URL", "http://127.0.0.1:3210")),
    Args = #{<<"room">> => unicode:characters_to_binary(Room)},
    %% First read the durable counter through Convex's documented HTTP API.
    {ok, Initial, _} = convex:call(Client, query, <<"demo:state">>, Args),
    0 = count(Initial),
    io:format("current count: 0~n"),
    %% Start the real /api/sync subscription before changing the counter.
    {ok, Live, Subscription} = convex:subscribe(Client, <<"demo:state">>, Args, self()),
    0 = next_count(Subscription),
    io:format("live initial count: 0~n"),
    %% Convex records this idempotency key so retrying cannot increment twice.
    MutationArgs = #{<<"room">> => unicode:characters_to_binary(Room), <<"language">> => <<"Erlang">>, <<"runId">> => unicode:characters_to_binary(Room ++ "-once")},
    {ok, Mutation, _} = convex:call(Client, mutation, <<"demo:increment">>, MutationArgs),
    true = maps:get(<<"applied">>, Mutation),
    1 = count(maps:get(<<"state">>, Mutation)),
    io:format("mutation applied: true~nmutation count: 1~n"),
    %% The owner decodes the resulting WebSocket Transition in order.
    1 = next_count(Subscription),
    io:format("live updated count: 1~n"),
    convex:unsubscribe(Live, Subscription),
    convex:close(#{live => Live}),
    io:format("verified count: 0 -> 1~n").
next_count(Id) -> receive {convex_live, Id, #{value := Value}} -> count(Value); {convex_live, Id, #{error := Error}} -> erlang:error(Error) after 10000 -> erlang:error(live_timeout) end.
count(Value) -> maps:get(<<"count">>, Value).
env(Name, Default) -> case os:getenv(Name) of false -> Default; Value -> Value end.
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test erlang` compiles the Erlang modules and runs the local codec and adapter lifecycle checks in a linux/amd64 container. `./run build erlang` builds the minimal non-root adapter image. Root owns `verify-example`, `verify`, and hosted conformance.

## Protocol notes and limits

OTP `httpc` and `ssl` provide ordinary HTTP/TLS transport. Gun provides ordinary WebSocket framing, fragmentation and control handling. The Erlang `live` owner alone opens `/api/sync`, sends Connect/Add/Remove messages, maintains query-set/timestamp state, and publishes deduplicated updates.

## Limitations

Live authentication, WebSocket mutations/actions, tagged Convex values, and TransitionChunk assembly are deferred. The adapter supports both stdin/stdout and one `ADAPTER_LISTEN` TCP controller. No HTTP or Live badge has been earned until root runs shared evidence.
