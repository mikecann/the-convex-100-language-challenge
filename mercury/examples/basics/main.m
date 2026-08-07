%-----------------------------------------------------------------------------%
% Convex from Mercury: the canonical shared counter demonstration.
%
% Walks the same 0 -> 1 journey every language in this project demonstrates:
% an HTTP query for the current count, a Live subscription started before
% any write so the reactive path cannot miss it, an idempotent mutation,
% and the resulting Live update -- proving HTTP and Live agree about the
% same room.
%-----------------------------------------------------------------------------%
:- module main.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module convex.
:- import_module convex_json.
:- import_module convex_transport.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module string.

main(!IO) :-
    % Configuration: both HTTPS and WSS reach the same approved Convex
    % deployment. The verifier supplies a unique room as this program's
    % first argument; running the image by hand falls back to a fixed room.
    io.get_environment_var("CONVEX_URL", MaybeUrl, !IO),
    (
        MaybeUrl = yes(Url),
        io.command_line_arguments(Args, !IO),
        Room = ( Args = [First | _] -> First ; "mercury-example" ),
        % Client creation: parse and validate the deployment URL once.
        ( new_client(Url, _, Client) ->
            run_example(Client, Room, !IO)
        ;
            report_and_fail("CONVEX_URL is not a valid Convex deployment URL", !IO)
        )
    ;
        MaybeUrl = no,
        report_and_fail("CONVEX_URL is required", !IO)
    ).

:- pred run_example(client::in, string::in, io::di, io::uo) is det.

run_example(Client, Room, !IO) :-
    RoomArgs = j_object(["room" - j_string(Room)]),

    % The HTTP query: a plain request/response read of the room's state.
    query(Client, "demo:state", RoomArgs, QueryResult, !IO),
    (
        QueryResult = call_ok(call_result(QueryValue, _Logs)),
        CurrentCount = whole_count("current query", QueryValue),
        io.format("current count: %d\n", [i(CurrentCount)], !IO),

        % Start Live before the mutation so the reactive path cannot miss
        % the write: connecting and subscribing first, then mutating,
        % guarantees the subscription's next update is the one that matters.
        live_connect(Client, MaybeLive, !IO),
        (
            MaybeLive = live_ok(Conn, LiveState0),
            live_add(Conn, LiveState0, "demo:state", RoomArgs, QueryId,
                LiveState1, AddResult, !IO),
            (
                AddResult = ok,
                await_live(Conn, LiveState1, QueryId, "initial Live value",
                    InitialUpdate, LiveState2, !IO),
                InitialCount = whole_count("initial Live value", InitialUpdate),
                ( InitialCount = CurrentCount -> true
                ; report_and_fail("Live initial value disagreed with HTTP", !IO)
                ),
                io.format("live initial count: %d\n", [i(InitialCount)], !IO),

                % The mutation and its idempotency key: runId lets a retried
                % call observe the same result without applying the write
                % twice. A random key means each run of this example is a
                % distinct logical write.
                random_hex(16, RunId, !IO),
                MutationArgs = j_object([
                    "room" - j_string(Room),
                    "language" - j_string("mercury"),
                    "runId" - j_string(RunId)
                ]),
                mutation(Client, "demo:increment", MutationArgs, MutationResult, !IO),
                (
                    MutationResult = call_ok(call_result(MutationValue, _)),
                    Applied = mutation_applied(MutationValue),
                    io.format("mutation applied: %s\n", [s(bool_word(Applied))], !IO),
                    MutationCount = whole_count("mutation", mutation_state(MutationValue)),
                    ( MutationCount = CurrentCount + 1 -> true
                    ; report_and_fail("mutation count was unexpected", !IO)
                    ),
                    io.format("mutation count: %d\n", [i(MutationCount)], !IO),

                    % The resulting Live update: received on the same
                    % subscription rather than issuing a second query.
                    await_live(Conn, LiveState2, QueryId, "updated Live value",
                        UpdatedUpdate, LiveState3, !IO),
                    UpdatedCount = whole_count("updated Live value", UpdatedUpdate),
                    ( UpdatedCount = MutationCount -> true
                    ; report_and_fail("Live update was unexpected", !IO)
                    ),
                    io.format("live updated count: %d\n", [i(UpdatedCount)], !IO),

                    % This final line only prints once HTTP and Live agree
                    % end to end.
                    io.format("verified count: %d -> %d\n",
                        [i(CurrentCount), i(UpdatedCount)], !IO),

                    live_remove(Conn, LiveState3, QueryId, _LiveState4, _RemoveResult, !IO),
                    live_close(Conn, !IO)
                ;
                    MutationResult = call_error(Err),
                    live_close(Conn, !IO),
                    report_and_fail("mutation failed: " ++ error_message(Err), !IO)
                )
            ;
                AddResult = transport_error(Msg),
                live_close(Conn, !IO),
                report_and_fail("could not subscribe: " ++ Msg, !IO)
            )
        ;
            MaybeLive = live_error(Err),
            report_and_fail("Live connect failed: " ++ error_message(Err), !IO)
        )
    ;
        QueryResult = call_error(Err),
        report_and_fail("current query failed: " ++ error_message(Err), !IO)
    ).

    % Poll the Live connection (blocking briefly between attempts) until an
    % update for the given query arrives, or give up after ten seconds.
:- pred await_live(live_conn::in, live_state::in, int::in, string::in,
    json::out, live_state::out, io::di, io::uo) is det.

await_live(Conn, State0, QueryId, Label, Value, State, !IO) :-
    await_live_loop(Conn, State0, QueryId, Label, 100, Value, State, !IO).

:- pred await_live_loop(live_conn::in, live_state::in, int::in, string::in,
    int::in, json::out, live_state::out, io::di, io::uo) is det.

await_live_loop(Conn, State0, QueryId, Label, TriesLeft, Value, State, !IO) :-
    ( TriesLeft =< 0 ->
        Value = j_null,
        State = State0,
        report_and_fail(Label ++ " timed out", !IO)
    ;
        poll_control(-1, live_conn(live_fd(Conn)), 100, PollResult, !IO),
        ( ( PollResult = poll_live_ready ; PollResult = poll_both_ready ) ->
            live_poll(Conn, State0, PollLive, !IO),
            (
                PollLive = live_transition(State1, Changes),
                ( find_change(QueryId, Changes, Found) ->
                    (
                        Found = live_value(_, Value0, _),
                        Value = Value0,
                        State = State1
                    ;
                        Found = live_query_error(_, Err, _),
                        Value = j_null,
                        State = State1,
                        report_and_fail(Label ++ " was an error: " ++ error_message(Err), !IO)
                    )
                ;
                    await_live_loop(Conn, State1, QueryId, Label, TriesLeft - 1,
                        Value, State, !IO)
                )
            ;
                ( PollLive = live_ping ; PollLive = live_ignored ; PollLive = live_would_block ),
                await_live_loop(Conn, State0, QueryId, Label, TriesLeft - 1,
                    Value, State, !IO)
            ;
                PollLive = live_protocol_error(Msg),
                Value = j_null,
                State = State0,
                report_and_fail(Label ++ ": protocol error: " ++ Msg, !IO)
            ;
                PollLive = live_peer_closed,
                Value = j_null,
                State = State0,
                report_and_fail(Label ++ ": connection closed", !IO)
            )
        ;
            await_live_loop(Conn, State0, QueryId, Label, TriesLeft - 1, Value, State, !IO)
        )
    ).

:- pred find_change(int::in, list(live_change)::in, live_change::out)
    is semidet.

find_change(QueryId, [Change | Rest], Found) :-
    ( change_query_id(Change) = QueryId -> Found = Change
    ; find_change(QueryId, Rest, Found)
    ).

:- func change_query_id(live_change) = int.

change_query_id(live_value(Id, _, _)) = Id.
change_query_id(live_query_error(Id, _, _)) = Id.

    % Convex values are JSON, so this decodes the demonstrated result into
    % the idiomatic Mercury int this example needs, rejecting a fractional,
    % missing, or out-of-range count rather than silently truncating one.
:- func whole_count(string, json) = int.

whole_count(Operation, Value) = Count :-
    ( Value = j_object(Fields), assoc_search(Fields, "count", CountJson) ->
        ( json_integral_int(CountJson, Found) ->
            Count = Found
        ;
            Count = 0,
            unexpected($module, $pred, Operation ++ " did not contain a whole count")
        )
    ;
        Count = 0,
        unexpected($module, $pred, Operation ++ " was not an object")
    ).

:- pred assoc_search(assoc_list(string, json)::in, string::in, json::out)
    is semidet.

assoc_search([Key - Value | Rest], Target, Found) :-
    ( Key = Target -> Found = Value ; assoc_search(Rest, Target, Found) ).

:- func mutation_applied(json) = bool.

mutation_applied(Value) = Applied :-
    ( Value = j_object(Fields), assoc_search(Fields, "applied", j_bool(j_true)) ->
        Applied = yes
    ;
        Applied = no
    ).

:- func mutation_state(json) = json.

mutation_state(Value) = State :-
    ( Value = j_object(Fields), assoc_search(Fields, "state", Found) ->
        State = Found
    ;
        State = j_null,
        unexpected($module, $pred, "mutation response omitted state")
    ).

:- func bool_word(bool) = string.

bool_word(yes) = "true".
bool_word(no) = "false".

:- func error_message(convex_error) = string.

error_message(function_error(Msg, _, _)) = Msg.
error_message(protocol_error(Msg)) = Msg.
error_message(transport_error(Msg)) = Msg.

    % Diagnostics belong on stderr: stdout is the exact, universal
    % happy-path transcript every language's canonical example must match.
:- pred report_and_fail(string::in, io::di, io::uo) is det.

report_and_fail(Message, !IO) :-
    io.stderr_stream(Stderr, !IO),
    io.format(Stderr, "mercury example failed: %s\n", [s(Message)], !IO),
    io.set_exit_status(1, !IO).
