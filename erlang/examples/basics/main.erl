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
