-module(codec_test).
-export([main/0]).
main() ->
  Value = [{<<"unicode">>, <<"Hello, 世界 👋">>}, {<<"nested">>, [true,false,null,42.5]}],
  {ok, Value} = convex_json:decode(convex_json:encode(Value)),
  io:format("codec test passed~n").
