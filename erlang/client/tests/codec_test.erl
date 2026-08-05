%% -*- coding: utf-8 -*-
-module(codec_test).
-export([main/0]).

main() ->
    Value =
        #{<<"unicode">> => <<"Hello, UTF-8">>,
          <<"nested">> => [true, false, null, 42.5]},
    {ok, Decoded} = convex_json:decode(convex_json:encode(Value)),
    <<"Hello, UTF-8">> = maps:get(<<"unicode">>, Decoded),
    42.5 = lists:last(maps:get(<<"nested">>, Decoded)),
    io:format("codec test passed~n").
