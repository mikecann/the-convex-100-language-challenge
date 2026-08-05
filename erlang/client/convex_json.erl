%% JSX is a normal Erlang JSON library, not a Convex client. Keeping the
%% Convex envelopes and sync state in this repository makes provenance clear.
-module(convex_json).
-export([encode/1, decode/1]).

encode(Value) -> jsx:encode(Value).
decode(Value) when is_binary(Value) ->
    try {ok, jsx:decode(Value, [return_maps])}
    catch _:_ -> {error, invalid_json}
    end.
