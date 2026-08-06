%% Erlang side of Convex.Prelude.
%%
%% purerl represents `Effect a` however this module chooses to, because the
%% type is foreign: here it is a zero-argument fun, so `pure` and `bind` build
%% and compose thunks. Everything else is arithmetic, comparison, and string
%% handling that PureScript has no built-in operators for.
%%
%% Every export is total. A socket loop must not be able to crash on a bad
%% integer or an out-of-range slice, so the failure cases answer with a
%% sentinel the PureScript side already knows how to interpret.
-module(convex_prelude@foreign).

-export([unit/0,
         pure/1, bind/2,
         termEq/2, termLess/2,
         addInt/2, subInt/2, mulInt/2, divInt/2, remInt/2,
         negateInt/1, negateNumber/1,
         bitAnd/2, bitOr/2, bitXor/2,
         intToString/1, intToLowerHex/2,
         parseIntOk/1, parseIntValue/1,
         parseIntBase16Ok/1, parseIntBase16Value/1,
         intToNumber/1, truncateNumber/1,
         numberToString/1, parseNumberOk/1, parseNumberValue/1,
         maxSafeInt/0, minSafeInt/0, maxUnsigned32/0,
         appendString/2, stringByteLength/1, stringCodepointLength/1,
         stringSlice/3, stringIndexOf/2, stringLowercase/1, stringTrim/1]).

unit() -> unit.

pure(Value) -> fun() -> Value end.

%% `Action` is a thunk and `Next` is a curried PureScript function returning
%% another thunk, so the composed effect runs both in order when it is run.
bind(Action, Next) -> fun() -> (Next(Action()))() end.

%% Exact term equality. `=:=` keeps 1 and 1.0 distinct, which is what the JSON
%% layer relies on when it decides whether a Convex number is integral.
termEq(Left, Right) -> Left =:= Right.

%% Erlang's total ordering over any two terms. For the integers and binaries
%% this client compares it is the ordinary numeric and byte-wise ordering.
termLess(Left, Right) -> Left < Right.

addInt(Left, Right) -> Left + Right.
subInt(Left, Right) -> Left - Right.
mulInt(Left, Right) -> Left * Right.

%% Division by zero would be a programming error rather than bad input, but
%% answering zero keeps the whole FFI total.
divInt(_Left, 0) -> 0;
divInt(Left, Right) -> Left div Right.

remInt(_Left, 0) -> 0;
remInt(Left, Right) -> Left rem Right.

negateInt(Value) -> -Value.

negateNumber(Value) -> -Value.

bitAnd(Left, Right) -> Left band Right.
bitOr(Left, Right) -> Left bor Right.
bitXor(Left, Right) -> Left bxor Right.

intToString(Value) -> integer_to_binary(Value).

%% Lowercase hexadecimal, left-padded with zeros to at least `Width` digits.
intToLowerHex(Value, Width) ->
    Digits = string:lowercase(integer_to_binary(Value, 16)),
    Padding = Width - byte_size(Digits),
    case Padding > 0 of
        true -> <<(binary:copy(<<"0">>, Padding))/binary, Digits/binary>>;
        false -> Digits
    end.

parseIntOk(Text) ->
    try
        _ = binary_to_integer(Text),
        true
    catch
        _:_ -> false
    end.

parseIntValue(Text) ->
    try
        binary_to_integer(Text)
    catch
        _:_ -> 0
    end.

parseIntBase16Ok(Text) ->
    try
        _ = binary_to_integer(Text, 16),
        true
    catch
        _:_ -> false
    end.

parseIntBase16Value(Text) ->
    try
        binary_to_integer(Text, 16)
    catch
        _:_ -> 0
    end.

intToNumber(Value) -> float(Value).

truncateNumber(Value) -> trunc(Value).

%% `short` asks for the shortest text that reads back as the same float, so a
%% value that arrived as 42.5 leaves as 42.5 rather than 42.50000000000000.
numberToString(Value) -> float_to_binary(Value, [short]).

parseNumberOk(Text) ->
    try
        _ = binary_to_float(Text),
        true
    catch
        _:_ -> false
    end.

parseNumberValue(Text) ->
    try
        binary_to_float(Text)
    catch
        _:_ -> 0.0
    end.

%% BEAM integers are unbounded, so these bounds are policy rather than a
%% machine limit, and PureScript integer literals cannot express them.
maxSafeInt() -> 9223372036854775807.
minSafeInt() -> -9223372036854775808.
maxUnsigned32() -> 4294967295.

appendString(Left, Right) -> <<Left/binary, Right/binary>>.

stringByteLength(Text) -> byte_size(Text).

%% JSON Schema counts Unicode scalar values, not bytes, when it bounds the
%% adapter's identifier lengths.
stringCodepointLength(Text) ->
    case unicode:characters_to_list(Text) of
        List when is_list(List) -> length(List);
        _ -> byte_size(Text)
    end.

%% Clamped so an out-of-range slice is an empty string rather than a crash.
stringSlice(Start, Length, Text) ->
    Size = byte_size(Text),
    From = max(0, min(Start, Size)),
    Count = max(0, min(Length, Size - From)),
    binary:part(Text, From, Count).

stringIndexOf(_Haystack, <<>>) -> 0;
stringIndexOf(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> -1;
        {Index, _} -> Index
    end.

stringLowercase(Text) -> unicode:characters_to_binary(string:lowercase(Text)).

stringTrim(Text) -> unicode:characters_to_binary(string:trim(Text)).
