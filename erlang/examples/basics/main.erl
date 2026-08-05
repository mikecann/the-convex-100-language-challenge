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
%% JSX follows JavaScript's number model, so Convex's integer counter can
%% arrive as a whole float. Reject fractions rather than silently truncating.
count(Value) ->
    case maps:get(<<"count">>, Value) of
        N when is_integer(N) -> N;
        N when is_float(N), trunc(N) == N -> trunc(N)
    end.
env(Name, Default) -> case os:getenv(Name) of false -> Default; Value -> Value end.
