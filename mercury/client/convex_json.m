%-----------------------------------------------------------------------------%
% convex_json: a small, dependency-free JSON codec.
%
% Convex's HTTP and sync-protocol envelopes are ordinary JSON. Mercury has no
% JSON support in its standard library, so this module is native machinery,
% not a delegated parser: a hand-written recursive-descent reader over a
% Mercury string and a matching writer. Every predicate below carries a real
% determinism promise -- `parse_json` is `semidet` because malformed input is
% an expected, first-class outcome, not an exception; the writer is `det`
% because building text from an already-valid tree cannot fail.
%-----------------------------------------------------------------------------%
:- module convex_json.
:- interface.

:- import_module assoc_list.
:- import_module list.

    % The JSON value tree. Numbers are held as floats, matching JSON's own
    % single numeric type; convex_json_int below recovers an exact integer
    % from a value that is mathematically integral and in safe-integer range.
:- type json
    --->    j_null
    ;       j_bool(bool_lit)
    ;       j_number(float)
    ;       j_string(string)
    ;       j_array(list(json))
    ;       j_object(assoc_list(string, json)).

:- type bool_lit
    --->    j_true
    ;       j_false.

    % Parse a complete JSON document. Fails (rather than throwing) on any
    % malformed input: trailing garbage, unterminated strings, bad escapes,
    % and non-finite/overflowing number literals are all rejected here so
    % callers never have to distinguish "parse failed" from "parse threw".
:- pred parse_json(string::in, json::out) is semidet.

    % Render a json value as compact JSON text, suitable for an HTTP body or
    % a WebSocket text frame.
:- func to_json_string(json) = string.

    % Look up a key in a j_object. Fails if the value is not an object or the
    % key is absent.
:- pred json_lookup(string::in, json::in, json::out) is semidet.

    % Convenience: look up a key, defaulting when absent. Fails only when the
    % value is present but the wrong shape (checked by the caller).
:- func json_lookup_default(string, json, json) = json.

    % A JSON number is "integral" when it has no fractional part and lies
    % within the safe-integer range JSON producers (including Convex) use for
    % exact integers: +/- 2^53 - 1. Rejects fractional, infinite, and
    % out-of-range values. This is the one place float/int coercion happens;
    % every caller that needs a whole number goes through it.
:- pred json_integral_int(json::in, int::out) is semidet.

    % Decode a JSON string field, failing if the value is not a j_string.
:- pred json_string(json::in, string::out) is semidet.

    % Decode a JSON array of strings (used for Convex's logLines field),
    % failing if any element is not a string.
:- pred json_string_list(json::in, list(string)::out) is semidet.

:- implementation.

:- import_module char.
:- import_module float.
:- import_module int.
:- import_module pair.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%
% Parsing.
%
% The parser walks a list of Mercury `char`s (already-decoded Unicode code
% points, since Mercury strings are UTF-8) rather than indexing the packed
% string directly. That keeps every rule a simple structurally recursive
% predicate over "remaining input" -> "value" plus "remaining input", which
% is the natural shape for Mercury's mode system: each parsing predicate
% below is semidet in exactly the way a grammar rule is -- it either
% recognises a prefix of its input or it does not.
%-----------------------------------------------------------------------------%

parse_json(Text, Value) :-
    Chars = string.to_char_list(Text),
    skip_ws(Chars, Chars1),
    parse_value(Chars1, Value, Rest),
    skip_ws(Rest, []).

:- pred parse_value(list(char)::in, json::out, list(char)::out) is semidet.

parse_value(Chars0, Value, Rest) :-
    ( Chars0 = ['n', 'u', 'l', 'l' | Rest1] ->
        Value = j_null, Rest = Rest1
    ; Chars0 = ['t', 'r', 'u', 'e' | Rest1] ->
        Value = j_bool(j_true), Rest = Rest1
    ; Chars0 = ['f', 'a', 'l', 's', 'e' | Rest1] ->
        Value = j_bool(j_false), Rest = Rest1
    ; Chars0 = ['"' | Rest1] ->
        parse_string_body(Rest1, Str, Rest),
        Value = j_string(Str)
    ; Chars0 = ['[' | Rest1] ->
        skip_ws(Rest1, Rest2),
        parse_array_items(Rest2, Items, Rest),
        Value = j_array(Items)
    ; Chars0 = ['{' | Rest1] ->
        skip_ws(Rest1, Rest2),
        parse_object_members(Rest2, Members, Rest),
        Value = j_object(Members)
    ; Chars0 = [C | _], is_number_start(C) ->
        parse_number(Chars0, Num, Rest),
        Value = j_number(Num)
    ;
        fail
    ).

:- pred is_number_start(char::in) is semidet.

is_number_start(C) :- ( C = ('-') -> true ; char.is_digit(C) ).

:- pred parse_array_items(list(char)::in, list(json)::out, list(char)::out)
    is semidet.

parse_array_items(Chars0, Items, Rest) :-
    ( Chars0 = [']' | Rest1] ->
        Items = [], Rest = Rest1
    ;
        parse_value(Chars0, First, Rest1),
        skip_ws(Rest1, Rest2),
        parse_array_more(Rest2, [First], Items, Rest)
    ).

:- pred parse_array_more(list(char)::in, list(json)::in, list(json)::out,
    list(char)::out) is semidet.

parse_array_more([']' | Rest], Acc, Items, Rest) :-
    list.reverse(Acc, Items).
parse_array_more([',' | Rest0], Acc, Items, Rest) :-
    skip_ws(Rest0, Rest1),
    parse_value(Rest1, Next, Rest2),
    skip_ws(Rest2, Rest3),
    parse_array_more(Rest3, [Next | Acc], Items, Rest).

:- pred parse_object_members(list(char)::in, assoc_list(string, json)::out,
    list(char)::out) is semidet.

parse_object_members(['}' | Rest], [], Rest).
parse_object_members(['"' | Cs], Members, Rest) :-
    parse_member(['"' | Cs], First, Rest1),
    skip_ws(Rest1, Rest2),
    parse_object_more(Rest2, [First], Members, Rest).

:- pred parse_object_more(list(char)::in, assoc_list(string, json)::in,
    assoc_list(string, json)::out, list(char)::out) is semidet.

parse_object_more(['}' | Rest], Acc, Members, Rest) :-
    list.reverse(Acc, Members).
parse_object_more([',' | Rest0], Acc, Members, Rest) :-
    skip_ws(Rest0, Rest1),
    parse_member(Rest1, Next, Rest2),
    skip_ws(Rest2, Rest3),
    parse_object_more(Rest3, [Next | Acc], Members, Rest).

:- pred parse_member(list(char)::in, pair(string, json)::out, list(char)::out)
    is semidet.

parse_member(['"' | Rest0], Key - Value, Rest) :-
    parse_string_body(Rest0, Key, Rest1),
    skip_ws(Rest1, Rest2),
    Rest2 = [':' | Rest3],
    skip_ws(Rest3, Rest4),
    parse_value(Rest4, Value, Rest).

    % The opening quote has already been consumed; this reads up to and
    % including the closing quote, resolving escapes (including \uXXXX
    % surrogate pairs) as it goes.
:- pred parse_string_body(list(char)::in, string::out, list(char)::out)
    is semidet.

parse_string_body(Chars, Str, Rest) :-
    parse_string_chars(Chars, StrChars, Rest),
    string.from_char_list(StrChars, Str).

:- pred parse_string_chars(list(char)::in, list(char)::out, list(char)::out)
    is semidet.

parse_string_chars(Chars0, Out, Rest) :-
    ( Chars0 = ['"' | Rest1] ->
        Out = [], Rest = Rest1
    ; Chars0 = ['\\' | Rest1] ->
        ( Rest1 = [Esc | Rest2] ->
            ( simple_escape(Esc, Ch) ->
                parse_string_chars(Rest2, RestOut, Rest),
                Out = [Ch | RestOut]
            ; Esc = 'u' ->
                parse_unicode_escape(Rest2, Ch, Rest3),
                parse_string_chars(Rest3, RestOut, Rest),
                Out = [Ch | RestOut]
            ;
                fail
            )
        ;
            fail  % lone trailing backslash: malformed escape
        )
    ; Chars0 = [C | Rest1] ->
        parse_string_chars(Rest1, RestOut, Rest),
        Out = [C | RestOut]
    ;
        fail  % ran out of input before the closing quote
    ).

:- pred simple_escape(char::in, char::out) is semidet.

simple_escape('"', '"').
simple_escape('\\', '\\').
simple_escape('/', '/').
simple_escape('b', Ch) :- char.det_from_int(0x08, Ch).
simple_escape('f', Ch) :- char.det_from_int(0x0C, Ch).
simple_escape('n', '\n').
simple_escape('r', '\r').
simple_escape('t', '\t').

    % Reads exactly four hex digits after \u, then combines a UTF-16
    % surrogate pair into a single Unicode code point when the first unit is
    % a high surrogate and is immediately followed by \uDCxx-\uDFxx.
:- pred parse_unicode_escape(list(char)::in, char::out, list(char)::out)
    is semidet.

parse_unicode_escape(Chars0, Ch, Rest) :-
    parse_hex4(Chars0, Unit, Chars1),
    ( is_high_surrogate(Unit) ->
        Chars1 = ['\\', 'u' | Chars2],
        parse_hex4(Chars2, Low, Rest),
        is_low_surrogate(Low),
        CodePoint = 0x10000 + ((Unit - 0xD800) << 10) + (Low - 0xDC00),
        char.from_int(CodePoint, Ch)
    ;
        char.from_int(Unit, Ch),
        Rest = Chars1
    ).

:- pred is_high_surrogate(int::in) is semidet.

is_high_surrogate(Unit) :- Unit >= 0xD800, Unit =< 0xDBFF.

:- pred is_low_surrogate(int::in) is semidet.

is_low_surrogate(Unit) :- Unit >= 0xDC00, Unit =< 0xDFFF.

:- pred parse_hex4(list(char)::in, int::out, list(char)::out) is semidet.

parse_hex4([A, B, C, D | Rest], Value, Rest) :-
    hex_digit(A, Va),
    hex_digit(B, Vb),
    hex_digit(C, Vc),
    hex_digit(D, Vd),
    Value = (((Va << 4) \/ Vb) << 4 \/ Vc) << 4 \/ Vd.

:- pred hex_digit(char::in, int::out) is semidet.

hex_digit(Ch, Value) :-
    char.to_int(Ch, Code),
    ( Code >= 0x30, Code =< 0x39 -> Value = Code - 0x30
    ; Code >= 0x61, Code =< 0x66 -> Value = Code - 0x61 + 10
    ; Code >= 0x41, Code =< 0x46 -> Value = Code - 0x41 + 10
    ; fail
    ).

    % Numbers: an optional '-', an integer part, an optional fraction, an
    % optional exponent. The digits consumed are handed to Mercury's own
    % float parser rather than accumulated by hand, so double-rounding
    % matches the standard library everywhere else a float is read.
:- pred parse_number(list(char)::in, float::out, list(char)::out) is semidet.

parse_number(Chars0, Num, Rest) :-
    take_number_token(Chars0, TokenChars, Rest),
    TokenChars \= [],
    string.from_char_list(TokenChars, Token),
    string.to_float(Token, Num).

:- pred take_number_token(list(char)::in, list(char)::out, list(char)::out)
    is det.

take_number_token(Chars0, Token, Rest) :-
    ( Chars0 = [('-') | Chars1] ->
        take_digits(Chars1, IntDigits, Chars2),
        Prefix = [('-') | IntDigits]
    ;
        take_digits(Chars0, IntDigits, Chars2),
        Prefix = IntDigits
    ),
    ( Chars2 = [('.') | Chars3] ->
        take_digits(Chars3, FracDigits, Chars4),
        WithFrac = Prefix ++ [('.') | FracDigits]
    ;
        WithFrac = Prefix,
        Chars4 = Chars2
    ),
    ( Chars4 = [ExpCh | Chars5], ( ExpCh = 'e' ; ExpCh = 'E' ) ->
        ( Chars5 = [SignCh | Chars6], ( SignCh = ('+') ; SignCh = ('-') ) ->
            take_digits(Chars6, ExpDigits, Chars7),
            Token = WithFrac ++ [ExpCh, SignCh | ExpDigits],
            Rest = Chars7
        ;
            take_digits(Chars5, ExpDigits, Chars7),
            Token = WithFrac ++ [ExpCh | ExpDigits],
            Rest = Chars7
        )
    ;
        Token = WithFrac,
        Rest = Chars4
    ).

:- pred take_digits(list(char)::in, list(char)::out, list(char)::out) is det.

take_digits(Chars0, Digits, Rest) :-
    ( Chars0 = [C | Rest0], char.is_digit(C) ->
        take_digits(Rest0, Digits0, Rest),
        Digits = [C | Digits0]
    ;
        Digits = [],
        Rest = Chars0
    ).

:- pred skip_ws(list(char)::in, list(char)::out) is det.

skip_ws(Chars0, Rest) :-
    ( Chars0 = [C | Rest0], is_ws_char(C) ->
        skip_ws(Rest0, Rest)
    ;
        Rest = Chars0
    ).

:- pred is_ws_char(char::in) is semidet.

is_ws_char(' ').
is_ws_char('\t').
is_ws_char('\n').
is_ws_char('\r').

%-----------------------------------------------------------------------------%
% Rendering.
%-----------------------------------------------------------------------------%

to_json_string(Value) = string.append_list(render(Value)).

:- func render(json) = list(string).

render(j_null) = ["null"].
render(j_bool(j_true)) = ["true"].
render(j_bool(j_false)) = ["false"].
render(j_number(Num)) = [Str] :- render_number(Num, Str).
render(j_string(Str)) = ["\"", escape_string(Str), "\""].
render(j_array(Items)) = ["[" | render_array(Items)] ++ ["]"].
render(j_object(Members)) = ["{" | render_object(Members)] ++ ["}"].

:- pred render_number(float::in, string::out) is det.

render_number(Num, Str) :-
    ( ( is_nan(Num) ; is_inf(Num) ) ->
        Str = "",
        error("convex_json.render_number: refusing to render a non-finite number")
    ; ( Num >= -9007199254740991.0, Num =< 9007199254740991.0,
        RoundedInt = float.truncate_to_int(Num), float(RoundedInt) = Num ) ->
        Str = int_to_string(RoundedInt)
    ;
        Str = float_to_string(Num)
    ).

:- func render_array(list(json)) = list(string).

render_array([]) = [].
render_array([First | Rest]) = render(First) ++ render_array_rest(Rest).

:- func render_array_rest(list(json)) = list(string).

render_array_rest([]) = [].
render_array_rest([Item | Rest]) = ["," | render(Item)] ++ render_array_rest(Rest).

:- func render_object(assoc_list(string, json)) = list(string).

render_object([]) = [].
render_object([Key - Value | Rest]) =
    ["\"", escape_string(Key), "\":"] ++ render(Value)
        ++ render_object_rest(Rest).

:- func render_object_rest(assoc_list(string, json)) = list(string).

render_object_rest([]) = [].
render_object_rest([Key - Value | Rest]) =
    [",\"", escape_string(Key), "\":"] ++ render(Value)
        ++ render_object_rest(Rest).

:- func escape_string(string) = string.

escape_string(Str) =
    string.append_list(list.map(escape_char, string.to_char_list(Str))).

:- func escape_char(char) = string.

escape_char(Ch) = Escaped :-
    char.to_int(Ch, Code),
    ( Ch = '"' -> Escaped = "\\\""
    ; Ch = ('\\') -> Escaped = "\\\\"
    ; Code = 0x08 -> Escaped = "\\b"
    ; Code = 0x0C -> Escaped = "\\f"
    ; Ch = '\n' -> Escaped = "\\n"
    ; Ch = '\r' -> Escaped = "\\r"
    ; Ch = '\t' -> Escaped = "\\t"
    ; Code < 0x20 ->
        Escaped = "\\u" ++ string.format("%04x", [i(Code)])
    ;
        Escaped = string.from_char_list([Ch])
    ).

%-----------------------------------------------------------------------------%
% Accessors.
%-----------------------------------------------------------------------------%

json_lookup(Key, j_object(Members), Value) :-
    assoc_list.search(Members, Key, Value).

json_lookup_default(Key, Value0, Default) = Value :-
    ( json_lookup(Key, Value0, Found) ->
        Value = Found
    ;
        Value = Default
    ).

json_integral_int(j_number(Num), Int) :-
    not is_nan(Num),
    not is_inf(Num),
    Num >= -9007199254740991.0,
    Num =< 9007199254740991.0,
    RoundedInt = float.truncate_to_int(Num),
    float(RoundedInt) = Num,
    Int = RoundedInt.

json_string(j_string(Str), Str).

json_string_list(j_array(Items), Strings) :-
    map_json_string(Items, Strings).
json_string_list(j_null, []).

:- pred map_json_string(list(json)::in, list(string)::out) is semidet.

map_json_string([], []).
map_json_string([J | Js], [S | Ss]) :-
    json_string(J, S),
    map_json_string(Js, Ss).
