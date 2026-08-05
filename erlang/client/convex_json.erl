%% A deliberately small JSON codec for the JSON-safe Convex values used here.
%% Keeping it local avoids turning this educational client into a wrapper around
%% another runtime or SDK.
-module(convex_json).
-export([encode/1, decode/1]).

encode(Value) -> iolist_to_binary(enc(Value)).
enc(null) -> "null";
enc(true) -> "true";
enc(false) -> "false";
enc(Value) when is_integer(Value) -> integer_to_list(Value);
enc(Value) when is_float(Value) -> io_lib:format("~p", [Value]);
enc(Value) when is_binary(Value) -> [$", escape(binary_to_list(Value)), $"];
enc(Value) when is_list(Value), Value =:= [] -> "[]";
enc(Value) when is_list(Value), is_tuple(hd(Value)) ->
    [$\{, join([[enc(key(K)), $:, enc(V)] || {K,V} <- Value]), $\}];
enc(Value) when is_list(Value) -> [$[, join([enc(V) || V <- Value]), $]];
enc(Value) when is_map(Value) -> enc(maps:to_list(Value)).
key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> atom_to_binary(K, utf8).
join([]) -> [];
join([H|T]) -> [H | [[ $,, X] || X <- T]].
escape([]) -> [];
escape([$"|T]) -> [$\\,$"|escape(T)];
escape([$\\|T]) -> [$\\,$\\|escape(T)];
escape([$\n|T]) -> [$\\,$n|escape(T)];
escape([$\r|T]) -> [$\\,$r|escape(T)];
escape([$\t|T]) -> [$\\,$t|escape(T)];
escape([H|T]) when H < 32 -> io_lib:format("\\u~4.16.0B", [H]) ++ escape(T);
escape([H|T]) -> [H|escape(T)].

decode(Bin) when is_binary(Bin) ->
    try {Value, Rest} = value(skip(binary_to_list(Bin))), [] = skip(Rest), {ok, Value}
    catch _:_ -> {error, invalid_json} end.
skip([C|T]) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 -> skip(T);
skip(T) -> T.
value([$\{|T]) -> object(skip(T), []);
value([$[|T]) -> array(skip(T), []);
value([$"|T]) -> string(T, []);
value("true" ++ T) -> {true,T}; value("false" ++ T) -> {false,T}; value("null" ++ T) -> {null,T};
value(T) -> number(T, []).
object([$\}|T], Acc) -> {lists:reverse(Acc),T};
object([$"|T], Acc) ->
    {K, AfterKey} = string(T, []), [$:|AfterColon] = skip(AfterKey),
    {V, AfterValue} = value(skip(AfterColon)),
    case skip(AfterValue) of [$,|Next] -> object(skip(Next), [{K,V}|Acc]); [$\}|Next] -> {lists:reverse([{K,V}|Acc]),Next} end.
array([$]|T], Acc) -> {lists:reverse(Acc),T};
array(T, Acc) ->
    {V, After} = value(T), case skip(After) of [$,|Next] -> array(skip(Next), [V|Acc]); [$]|Next] -> {lists:reverse([V|Acc]),Next} end.
string([$"|T], Acc) -> {unicode:characters_to_binary(lists:reverse(Acc)), T};
string([$\\,$"|T], Acc) -> string(T, [$"|Acc]);
string([$\\,$\\|T], Acc) -> string(T, [$\\|Acc]);
string([$\\,$/|T], Acc) -> string(T, [$/|Acc]);
string([$\\,$b|T], Acc) -> string(T, [8|Acc]);
string([$\\,$f|T], Acc) -> string(T, [12|Acc]);
string([$\\,$n|T], Acc) -> string(T, [$\n|Acc]);
string([$\\,$r|T], Acc) -> string(T, [$\r|Acc]);
string([$\\,$t|T], Acc) -> string(T, [$\t|Acc]);
string([$\\,$u,A,B,C,D|T], Acc) -> string(T, [list_to_integer([A,B,C,D],16)|Acc]);
string([H|T], Acc) -> string(T, [H|Acc]).
number([C|T], Acc) when (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $+ orelse C =:= $. orelse C =:= $e orelse C =:= $E -> number(T,[C|Acc]);
number(T, Acc) -> S=lists:reverse(Acc), {case lists:member($.,S) orelse lists:member($e,S) orelse lists:member($E,S) of true -> list_to_float(S); false -> list_to_integer(S) end,T}.
