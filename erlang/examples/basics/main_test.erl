%% Focused checks for the decoder used by the exact canonical example.
-module(main_test).
-export([main/0]).

main() ->
    %% Convex JSON numbers may use either spelling for an integral value.
    0 = main:count(#{<<"count">> => 0}),
    1 = main:count(#{<<"count">> => 1.0}),
    9223372036854775807 =
        main:count(#{<<"count">> => 9223372036854775807}),

    %% None of these values may be rounded or coerced into a successful count.
    rejects(#{<<"count">> => 1.5}),
    rejects(#{<<"count">> => <<"1">>}),
    rejects(#{<<"count">> => non_finite}),
    rejects(#{<<"count">> => 9223372036854775808}),
    rejects(#{<<"count">> => -9223372036854775809}),
    rejects(#{<<"count">> => 9223372036854775808.0}),
    rejects(#{<<"count">> => 1.0e20}),
    io:format("example number tests passed~n").

rejects(Value) ->
    try main:count(Value) of
        Accepted -> erlang:error({unexpected_count, Accepted})
    catch
        error:{invalid_count, _} -> ok
    end.
