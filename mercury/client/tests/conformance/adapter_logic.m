%-----------------------------------------------------------------------------%
% adapter_logic: the pure half of the NDJSON adapter protocol -- command
% parsing and exact-shape validation, and event JSON shaping. Split out from
% adapter.m (which owns the reactor loop, the real entry point, and every
% side effect) purely so client/tests/conformance/adapter_test.m can import
% it without also linking a second `main/2`.
%-----------------------------------------------------------------------------%
:- module adapter_logic.
:- interface.

:- import_module convex_json.
:- import_module list.
:- import_module maybe.

:- type call_op
    --->    op_query
    ;       op_mutation
    ;       op_action.

:- type command
    --->    cmd_hello(string)
    ;       cmd_call(string, call_op, string, json)
    ;       cmd_set_auth(string, string)
    ;       cmd_subscribe(string, string, string, json)
    ;       cmd_unsubscribe(string, string)
    ;       cmd_close(string)
    ;       cmd_debug_disconnect(string).

:- type parse_outcome
    --->    parsed(command)
    ;       invalid(maybe(string), string).

:- pred parse_command(json::in, parse_outcome::out) is det.

:- func call_operation_text(call_op) = string.

    % The exact JSON shape written for a structured error or subscription
    % error event, independent of which file descriptor it is eventually
    % written to.
:- func error_event(maybe(string), maybe(string), string, string, json,
    list(string)) = json.

:- func string_list_json(list(string)) = json.

:- implementation.

:- import_module assoc_list.
:- import_module int.
:- import_module pair.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%
% Command parsing and exact-shape validation.
%-----------------------------------------------------------------------------%

parse_command(Json, Outcome) :-
    ( Json = j_object(Fields) ->
        MaybeId = string_field(Fields, "id"),
        ( valid_id(MaybeId) ->
            ( assoc_list.search(Fields, "op", j_string(Op)) ->
                ( Op = "hello", exact_keys(Fields, ["id", "op", "protocolVersion"]),
                  assoc_list.search(Fields, "protocolVersion", j_number(1.0)) ->
                    Outcome = parsed(cmd_hello(det_id(MaybeId)))
                ; ( Op = "query" ; Op = "mutation" ; Op = "action" ),
                  exact_keys(Fields, ["args", "id", "op", "path"]),
                  valid_path_args(Fields, Path, Args) ->
                    Outcome = parsed(cmd_call(det_id(MaybeId), call_op(Op), Path, Args))
                ; Op = "setAuth", exact_keys(Fields, ["id", "op", "token"]),
                  assoc_list.search(Fields, "token", j_string(Token)) ->
                    Outcome = parsed(cmd_set_auth(det_id(MaybeId), Token))
                ; Op = "subscribe",
                  exact_keys(Fields, ["args", "id", "op", "path", "subscriptionId"]),
                  valid_path_args(Fields, Path, Args),
                  SubId = string_field(Fields, "subscriptionId"),
                  valid_id(SubId) ->
                    Outcome = parsed(cmd_subscribe(det_id(MaybeId), det_id(SubId), Path, Args))
                ; Op = "unsubscribe", exact_keys(Fields, ["id", "op", "subscriptionId"]),
                  SubId2 = string_field(Fields, "subscriptionId"), valid_id(SubId2) ->
                    Outcome = parsed(cmd_unsubscribe(det_id(MaybeId), det_id(SubId2)))
                ; Op = "close", exact_keys(Fields, ["id", "op"]) ->
                    Outcome = parsed(cmd_close(det_id(MaybeId)))
                ; Op = "debugDisconnect", exact_keys(Fields, ["id", "op"]) ->
                    Outcome = parsed(cmd_debug_disconnect(det_id(MaybeId)))
                ;
                    Outcome = invalid(MaybeId, "invalid adapter command")
                )
            ;
                Outcome = invalid(MaybeId, "adapter command omitted a string op")
            )
        ;
            Outcome = invalid(no, "adapter command omitted a valid id")
        )
    ;
        Outcome = invalid(no, "adapter command was not a JSON object")
    ).

    % Only ever applied to a string already checked to be one of these
    % three by parse_command's guard, but Mercury cannot see that from the
    % string type alone, so the fallback exists purely to keep this det.
:- func call_op(string) = call_op.

call_op(Op) = Result :-
    ( Op = "query" -> Result = op_query
    ; Op = "mutation" -> Result = op_mutation
    ; Op = "action" -> Result = op_action
    ; Result = op_query, unexpected($module, $pred, "unrecognised call operation")
    ).

call_operation_text(op_query) = "query".
call_operation_text(op_mutation) = "mutation".
call_operation_text(op_action) = "action".

:- func string_field(assoc_list(string, json), string) = maybe(string).

string_field(Fields, Key) = Result :-
    ( assoc_list.search(Fields, Key, j_string(Value)) -> Result = yes(Value) ; Result = no ).

:- pred valid_id(maybe(string)::in) is semidet.

valid_id(yes(Id)) :-
    string.length(Id) >= 1,
    string.length(Id) =< 128.

:- func det_id(maybe(string)) = string.

det_id(yes(Id)) = Id.
det_id(no) = "" :- unexpected($module, $pred, "det_id called on an invalid id").

:- pred valid_path_args(assoc_list(string, json)::in, string::out, json::out)
    is semidet.

valid_path_args(Fields, Path, Args) :-
    assoc_list.search(Fields, "path", j_string(Path)),
    string.length(Path) >= 3,
    assoc_list.search(Fields, "args", Args),
    Args = j_object(_).

:- pred exact_keys(assoc_list(string, json)::in, list(string)::in) is semidet.

exact_keys(Fields, Expected) :-
    assoc_list.keys(Fields, ActualKeys),
    list.sort(ActualKeys, Actual),
    list.sort(Expected, ExpectedSorted),
    Actual = ExpectedSorted.

%-----------------------------------------------------------------------------%
% Event shaping.
%-----------------------------------------------------------------------------%

string_list_json(Strings) = j_array(list.map(func(S) = j_string(S), Strings)).

error_event(MaybeId, MaybeSubId, Name, Message, Data, Logs) = j_object(Fields) :-
    ErrorFields0 = ["name" - j_string(Name), "message" - j_string(Message)],
    ErrorFields = ( Data = j_null -> ErrorFields0 ; ErrorFields0 ++ ["data" - Data] ),
    BaseFields = [
        "error" - j_object(ErrorFields),
        "logs" - string_list_json(Logs)
    ],
    ( MaybeSubId = yes(SubId) ->
        Fields = [ "type" - j_string("subscription"), "subscriptionId" - j_string(SubId)
            | BaseFields ]
    ; MaybeId = yes(Id) ->
        Fields = [ "type" - j_string("error"), "id" - j_string(Id) | BaseFields ]
    ;
        Fields = [ "type" - j_string("error") | BaseFields ]
    ).
