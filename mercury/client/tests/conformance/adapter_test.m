%-----------------------------------------------------------------------------%
% Language-local unit tests for the adapter's pure command parsing and event
% shaping, covering serialized success, structured HTTP error, subscription
% error, and close-event shapes without needing a live process or network
% (adapter_smoke, run manually against the hosted deployment during
% development, exercises the full NDJSON cycle end to end; this covers the
% shape-level edge cases a live run would not reliably hit).
%-----------------------------------------------------------------------------%
:- module adapter_test.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module adapter_logic.
:- import_module convex_json.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module string.

main(!IO) :-
    check_hello_parses(N01, P01),
    check_query_parses(N02, P02),
    check_query_rejects_short_path(N03, P03),
    check_query_rejects_extra_field(N04, P04),
    check_subscribe_parses(N05, P05),
    check_unsubscribe_parses(N06, P06),
    check_close_parses(N07, P07),
    check_unknown_op_invalid(N08, P08),
    check_non_object_invalid(N09, P09),
    check_function_error_event_shape(N10, P10),
    check_subscription_error_event_shape(N11, P11),
    check_error_event_omits_absent_data(N12, P12),
    Results = [N01 - P01, N02 - P02, N03 - P03, N04 - P04, N05 - P05,
        N06 - P06, N07 - P07, N08 - P08, N09 - P09, N10 - P10, N11 - P11,
        N12 - P12],
    report(Results, 0, Failures, !IO),
    ( Failures = 0 ->
        io.write_string("adapter_test: all checks passed\n", !IO)
    ;
        io.format("adapter_test: %d check(s) failed\n", [i(Failures)], !IO),
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

:- func parse(string) = parse_outcome is semidet.

parse(Text) = Outcome :-
    parse_json(Text, Json),
    parse_command(Json, Outcome).

:- pred check_hello_parses(string::out, bool::out) is det.

check_hello_parses(Name, Passed) :-
    Name = "a well-formed hello command parses",
    ( parse("{\"id\":\"1\",\"op\":\"hello\",\"protocolVersion\":1}") = parsed(cmd_hello("1")) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_query_parses(string::out, bool::out) is det.

check_query_parses(Name, Passed) :-
    Name = "a well-formed query command parses with its path and args",
    Text = "{\"id\":\"2\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{\"room\":\"r\"}}",
    ( parse(Text) = parsed(cmd_call("2", op_query, "demo:state", j_object(_))) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_query_rejects_short_path(string::out, bool::out) is det.

check_query_rejects_short_path(Name, Passed) :-
    Name = "a path shorter than 3 characters is rejected",
    Text = "{\"id\":\"3\",\"op\":\"query\",\"path\":\"ab\",\"args\":{}}",
    ( parse(Text) = invalid(yes("3"), _) -> Passed = yes ; Passed = no ).

:- pred check_query_rejects_extra_field(string::out, bool::out) is det.

check_query_rejects_extra_field(Name, Passed) :-
    Name = "an unrecognised extra field on a call command is rejected",
    Text = "{\"id\":\"4\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{},\"extra\":1}",
    ( parse(Text) = invalid(yes("4"), _) -> Passed = yes ; Passed = no ).

:- pred check_subscribe_parses(string::out, bool::out) is det.

check_subscribe_parses(Name, Passed) :-
    Name = "a well-formed subscribe command parses with its subscriptionId",
    Text = "{\"id\":\"5\",\"op\":\"subscribe\",\"subscriptionId\":\"s1\","
        ++ "\"path\":\"demo:state\",\"args\":{}}",
    ( parse(Text) = parsed(cmd_subscribe("5", "s1", "demo:state", j_object(_))) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_unsubscribe_parses(string::out, bool::out) is det.

check_unsubscribe_parses(Name, Passed) :-
    Name = "a well-formed unsubscribe command parses",
    Text = "{\"id\":\"6\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s1\"}",
    ( parse(Text) = parsed(cmd_unsubscribe("6", "s1")) -> Passed = yes ; Passed = no ).

:- pred check_close_parses(string::out, bool::out) is det.

check_close_parses(Name, Passed) :-
    Name = "a well-formed close command parses",
    ( parse("{\"id\":\"7\",\"op\":\"close\"}") = parsed(cmd_close("7")) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_unknown_op_invalid(string::out, bool::out) is det.

check_unknown_op_invalid(Name, Passed) :-
    Name = "an unrecognised op is reported invalid, carrying the command id",
    ( parse("{\"id\":\"8\",\"op\":\"teleport\"}") = invalid(yes("8"), _) ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_non_object_invalid(string::out, bool::out) is det.

check_non_object_invalid(Name, Passed) :-
    Name = "a JSON array instead of an object is reported invalid without an id",
    ( parse("[1,2,3]") = invalid(no, _) -> Passed = yes ; Passed = no ).

:- pred check_function_error_event_shape(string::out, bool::out) is det.

check_function_error_event_shape(Name, Passed) :-
    Name = "a FunctionError reply carries id, error.name/message/data, and logs",
    Event = error_event(yes("9"), no, "FunctionError", "boom",
        j_object(["code" - j_string("E")]), ["log line"]),
    ( Event = j_object(Fields),
      json_lookup("id", Event, j_string("9")),
      json_lookup("type", Event, j_string("error")),
      json_lookup("error", Event, j_object(ErrorFields)),
      assoc_list.search(ErrorFields, "name", j_string("FunctionError")),
      assoc_list.search(ErrorFields, "message", j_string("boom")),
      assoc_list.search(ErrorFields, "data", j_object(_)),
      json_lookup("logs", Event, j_array([j_string("log line")])),
      not assoc_list.search(Fields, "subscriptionId", _)
    ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_subscription_error_event_shape(string::out, bool::out) is det.

check_subscription_error_event_shape(Name, Passed) :-
    Name = "a subscription error carries subscriptionId instead of id",
    Event = error_event(no, yes("sub1"), "ProtocolError", "bad transition",
        j_null, []),
    ( json_lookup("type", Event, j_string("subscription")),
      json_lookup("subscriptionId", Event, j_string("sub1")),
      not json_lookup("id", Event, _)
    ->
        Passed = yes
    ;
        Passed = no
    ).

:- pred check_error_event_omits_absent_data(string::out, bool::out) is det.

check_error_event_omits_absent_data(Name, Passed) :-
    Name = "an error with no data omits the data field rather than sending null",
    Event = error_event(yes("10"), no, "TransportError", "closed", j_null, []),
    ( json_lookup("error", Event, j_object(ErrorFields)),
      not assoc_list.search(ErrorFields, "data", _)
    ->
        Passed = yes
    ;
        Passed = no
    ).
