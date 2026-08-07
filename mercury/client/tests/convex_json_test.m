%-----------------------------------------------------------------------------%
% Language-local unit tests for convex_json: parse/render round-trips,
% escape and surrogate-pair handling, and the integral-number acceptance
% rules the canonical example's counter decoding depends on.
%-----------------------------------------------------------------------------%
:- module convex_json_test.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module convex_json.
:- import_module bool.
:- import_module char.
:- import_module int.
:- import_module list.
:- import_module pair.
:- import_module string.

main(!IO) :-
    check_object_roundtrip(N01, P01),
    check_array_roundtrip(N02, P02),
    check_string_escapes(N03, P03),
    check_unicode_surrogate_pair(N04, P04),
    check_reject_trailing_garbage(N05, P05),
    check_reject_unterminated_string(N06, P06),
    check_integral_accepts_whole_float(N07, P07),
    check_integral_rejects_fraction(N08, P08),
    check_integral_rejects_out_of_range(N09, P09),
    check_number_written_without_decimal(N10, P10),
    check_lookup_missing_key(N11, P11),
    Results = [N01 - P01, N02 - P02, N03 - P03, N04 - P04, N05 - P05,
        N06 - P06, N07 - P07, N08 - P08, N09 - P09, N10 - P10, N11 - P11],
    report(Results, 0, Failures, !IO),
    ( Failures = 0 ->
        io.write_string("convex_json_test: all checks passed\n", !IO)
    ;
        io.format("convex_json_test: %d check(s) failed\n", [i(Failures)], !IO),
        io.set_exit_status(1, !IO)
    ).

:- pred report(list(pair(string, bool))::in, int::in, int::out,
    io::di, io::uo) is det.

report([], Failures, Failures, !IO).
report([Name - Passed | Rest], Failures0, Failures, !IO) :-
    ( Passed = yes ->
        io.format("  ok   %s\n", [s(Name)], !IO),
        Failures1 = Failures0
    ;
        io.format("  FAIL %s\n", [s(Name)], !IO),
        Failures1 = Failures0 + 1
    ),
    report(Rest, Failures1, Failures, !IO).

:- pred check_object_roundtrip(string::out, bool::out) is det.

check_object_roundtrip(Name, Passed) :-
    Name = "object round-trip preserves keys, order, and nested types",
    Text = "{\"path\":\"counters:get\",\"args\":{\"room\":\"r1\",\"n\":2},\"ok\":true,\"missing\":null}",
    ( parse_json(Text, Value) ->
        Rendered = to_json_string(Value),
        ( parse_json(Rendered, Value2), Value2 = Value ->
            Passed = yes
        ;
            Passed = no
        )
    ;
        Passed = no
    ).

:- pred check_array_roundtrip(string::out, bool::out) is det.

check_array_roundtrip(Name, Passed) :-
    Name = "array of mixed values round-trips",
    Text = "[1, 2.5, \"three\", false, null, [ ] ]",
    ( parse_json(Text, j_array([j_number(N1), j_number(N2), j_string(S3),
            j_bool(j_false), j_null, j_array([])])),
      N1 = 1.0, N2 = 2.5, S3 = "three"
    ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_string_escapes(string::out, bool::out) is det.

check_string_escapes(Name, Passed) :-
    Name = "backslash, quote, and control escapes decode correctly",
    Text = "\"line1\\nline2\\ttab\\\"quote\\\"\\\\backslash\"",
    ( parse_json(Text, j_string(Decoded)) ->
        Expected = "line1\nline2\ttab\"quote\"\\backslash",
        ( Decoded = Expected -> Passed = yes ; Passed = no )
    ;
        Passed = no
    ).

:- pred check_unicode_surrogate_pair(string::out, bool::out) is det.

check_unicode_surrogate_pair(Name, Passed) :-
    Name = "a UTF-16 surrogate pair escape decodes to one code point",
    % U+1F600 GRINNING FACE, encoded as the surrogate pair D83D DE00.
    Text = "\"\\uD83D\\uDE00\"",
    ( parse_json(Text, j_string(Decoded)) ->
        Chars = string.to_char_list(Decoded),
        ( Chars = [Ch], char.to_int(Ch, 0x1F600) -> Passed = yes ; Passed = no )
    ;
        Passed = no
    ).

:- pred check_reject_trailing_garbage(string::out, bool::out) is det.

check_reject_trailing_garbage(Name, Passed) :-
    Name = "trailing bytes after a valid value are rejected",
    ( parse_json("1 2", _) -> Passed = no ; Passed = yes ).

:- pred check_reject_unterminated_string(string::out, bool::out) is det.

check_reject_unterminated_string(Name, Passed) :-
    Name = "an unterminated string literal is rejected, not silently closed",
    ( parse_json("\"abc", _) -> Passed = no ; Passed = yes ).

:- pred check_integral_accepts_whole_float(string::out, bool::out) is det.

check_integral_accepts_whole_float(Name, Passed) :-
    Name = "an integral-valued JSON number such as 1.0 decodes to 1",
    ( parse_json("1.0", Value), json_integral_int(Value, 1) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_integral_rejects_fraction(string::out, bool::out) is det.

check_integral_rejects_fraction(Name, Passed) :-
    Name = "a fractional JSON number is rejected by json_integral_int",
    ( parse_json("1.5", Value), json_integral_int(Value, _) ->
        Passed = no
    ;
        Passed = yes
    ).

:- pred check_integral_rejects_out_of_range(string::out, bool::out) is det.

check_integral_rejects_out_of_range(Name, Passed) :-
    Name = "a JSON number outside the safe-integer range is rejected",
    ( parse_json("9007199254740993", Value), json_integral_int(Value, _) ->
        Passed = no
    ;
        Passed = yes
    ).

:- pred check_number_written_without_decimal(string::out, bool::out) is det.

check_number_written_without_decimal(Name, Passed) :-
    Name = "a whole-number value renders without a trailing decimal point",
    Rendered = to_json_string(j_number(4.0)),
    ( Rendered = "4" -> Passed = yes ; Passed = no ).

:- pred check_lookup_missing_key(string::out, bool::out) is det.

check_lookup_missing_key(Name, Passed) :-
    Name = "json_lookup fails (not throws) on an absent key",
    ( parse_json("{\"a\":1}", Value), not json_lookup("b", Value, _) ->
        Passed = yes
    ;
        Passed = no
    ).
