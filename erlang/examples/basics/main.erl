-module(main).
-export([main/0]).
main() ->
    Room = case init:get_plain_arguments() of
        [R | _] -> R;
        [] -> "erlang-basic-example"
    end,
    {ok, Client} = convex:new(env("CONVEX_URL", "http://127.0.0.1:3210")),
    Args = [{<<"room">>, unicode:characters_to_binary(Room)}],
    %% Query the starting counter over Convex's documented HTTP endpoint.
    {ok, Initial, _} = convex:call(Client, query, <<"demo:state">>, Args),
    0 = count(Initial),
    io:format("current count: 0~n"),
    %% Live should start before mutation. This temporary polling helper keeps
    %% the sequence visible while the native WebSocket owner is unfinished.
    {ok, Poll} = convex:poll_subscribe(Client, <<"demo:state">>, Args, self()),
    {ok, Live0} = convex:poll_next(Poll, 10000),
    0 = count(Live0),
    io:format("live initial count: 0~n"),
    %% The run ID makes the mutation safe to retry without incrementing twice.
    RunId = unicode:characters_to_binary(Room ++ "-once"),
    MutationArgs = [
        {<<"room">>, unicode:characters_to_binary(Room)},
        {<<"language">>, <<"Erlang">>},
        {<<"runId">>, RunId}
    ],
    {ok, Mutation, _} = convex:call(Client, mutation, <<"demo:increment">>, MutationArgs),
    true = proplists:get_value(<<"applied">>, Mutation),
    1 = count(proplists:get_value(<<"state">>, Mutation)),
    io:format("mutation applied: true~n"),
    io:format("mutation count: 1~n"),
    {ok, Live1} = convex:poll_next(Poll, 10000),
    1 = count(Live1),
    io:format("live updated count: 1~n"),
    convex:close(Poll),
    %% Only print verification after the HTTP and observed update agree.
    io:format("verified count: 0 -> 1~n").
count(V) -> proplists:get_value(<<"count">>,V).
env(Name,Default) -> case os:getenv(Name) of false -> Default; Value -> Value end.
