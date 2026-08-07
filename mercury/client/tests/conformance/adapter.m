%-----------------------------------------------------------------------------%
% adapter: the NDJSON adapter protocol v1 executable.
%
% Test infrastructure, not public client code (see AGENTS.md): it exists so
% the shared conformance controller can drive the real convex.m client
% through every command the protocol defines. There is exactly one thread
% and one loop. Each iteration polls the control channel (stdin, or the
% accepted ADAPTER_LISTEN connection) and the Live WebSocket together, and
% handles whichever is ready -- so the "one owner" rule the shared
% conformance suite requires is not a discipline the adapter has to
% maintain, it is the only way this code is shaped.
%
% Command parsing and event-JSON shaping are pure and live in
% adapter_logic.m instead, where client/tests/conformance/adapter_test.m
% can exercise them directly without linking a second program entry point.
%-----------------------------------------------------------------------------%
:- module adapter.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module adapter_logic.
:- import_module convex.
:- import_module convex_json.
:- import_module convex_transport.

:- import_module assoc_list.
:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%
% Entry point and transport setup.
%-----------------------------------------------------------------------------%

main(!IO) :-
    io.get_environment_var("ADAPTER_LISTEN", MaybeListen, !IO),
    (
        MaybeListen = yes(Address),
        ( parse_host_port(Address, Host, Port) ->
            tcp_listen(Host, Port, MaybeListenFd, !IO),
            (
                MaybeListenFd = fd_ok(ListenFd),
                tcp_accept(ListenFd, MaybeConnFd, !IO),
                (
                    MaybeConnFd = fd_ok(ConnFd),
                    run(ConnFd, ConnFd, !IO)
                ;
                    MaybeConnFd = fd_error(Msg),
                    io.stderr_stream(Stderr, !IO),
                    io.format(Stderr, "adapter: accept failed: %s\n", [s(Msg)], !IO),
                    io.set_exit_status(1, !IO)
                )
            ;
                MaybeListenFd = fd_error(Msg),
                io.stderr_stream(Stderr, !IO),
                io.format(Stderr, "adapter: listen failed: %s\n", [s(Msg)], !IO),
                io.set_exit_status(1, !IO)
            )
        ;
            io.stderr_stream(Stderr, !IO),
            io.format(Stderr, "adapter: ADAPTER_LISTEN must be host:port\n", [], !IO),
            io.set_exit_status(1, !IO)
        )
    ;
        MaybeListen = no,
        run(0, 1, !IO)
    ).

:- pred parse_host_port(string::in, string::out, int::out) is semidet.

parse_host_port(Address, Host, Port) :-
    string.sub_string_search(Address, ":", ColonPos),
    string.split(Address, ColonPos, Host0, PortText0),
    string.remove_prefix(":", PortText0, PortText),
    string.to_int(PortText, Port),
    ( Host0 = "" -> Host = "0.0.0.0" ; Host = Host0 ).

:- pred run(int::in, int::in, io::di, io::uo) is det.

run(InFd, OutFd, !IO) :-
    State0 = adapter_state(no, no, []),
    reactor_loop(InFd, OutFd, State0, !IO).

%-----------------------------------------------------------------------------%
% Adapter state.
%-----------------------------------------------------------------------------%

:- type adapter_state
    --->    adapter_state(
                st_client :: maybe(client),
                st_live :: maybe(pair(live_conn, live_state)),
                st_subs :: assoc_list(string, int)    % subscriptionId -> queryId
            ).

    % A client is created lazily, from CONVEX_URL, the first time any
    % command needs one.
:- pred ensure_client(adapter_state::in, adapter_state::out,
    maybe_error(client)::out, io::di, io::uo) is det.

ensure_client(State0, State, Result, !IO) :-
    ( State0 ^ st_client = yes(Client) ->
        State = State0,
        Result = ok(Client)
    ;
        io.get_environment_var("CONVEX_URL", MaybeUrl, !IO),
        (
            MaybeUrl = yes(Url),
            ( new_client(Url, _, Client) ->
                State = State0 ^ st_client := yes(Client),
                Result = ok(Client)
            ;
                State = State0,
                Result = error("CONVEX_URL is not a valid Convex deployment URL")
            )
        ;
            MaybeUrl = no,
            State = State0,
            Result = error("CONVEX_URL is required")
        )
    ).

%-----------------------------------------------------------------------------%
% The reactor loop.
%-----------------------------------------------------------------------------%

:- pred reactor_loop(int::in, int::in, adapter_state::in, io::di, io::uo)
    is det.

reactor_loop(InFd, OutFd, State0, !IO) :-
    LiveFd = ( State0 ^ st_live = yes(Conn - _) -> live_conn(live_fd(Conn)) ; no_live_conn ),
    poll_control(InFd, LiveFd, 200, PollResult, !IO),
    (
        PollResult = poll_none,
        reactor_loop(InFd, OutFd, State0, !IO)
    ;
        PollResult = poll_control_ready,
        handle_control(InFd, OutFd, State0, State1, Continue, !IO),
        ( Continue = stop -> true ; reactor_loop(InFd, OutFd, State1, !IO) )
    ;
        PollResult = poll_live_ready,
        handle_live(OutFd, State0, State1, !IO),
        reactor_loop(InFd, OutFd, State1, !IO)
    ;
        PollResult = poll_both_ready,
        handle_control(InFd, OutFd, State0, State1, Continue, !IO),
        ( Continue = stop ->
            true
        ;
            handle_live(OutFd, State1, State2, !IO),
            reactor_loop(InFd, OutFd, State2, !IO)
        )
    ).

:- type continue_or_stop
    --->    continue
    ;       stop.

:- pred handle_control(int::in, int::in, adapter_state::in,
    adapter_state::out, continue_or_stop::out, io::di, io::uo) is det.

handle_control(InFd, OutFd, State0, State, Continue, !IO) :-
    read_line(InFd, LineEvent, !IO),
    (
        LineEvent = line_ok(Line),
        handle_line(Line, OutFd, State0, State, Continue, !IO)
    ;
        LineEvent = line_eof,
        close_resources(State0, State, !IO),
        Continue = stop
    ;
        LineEvent = line_error(Msg),
        emit_error(OutFd, no, no, "TransportError", Msg, j_null, [], !IO),
        State = State0,
        Continue = continue
    ).

:- pred handle_line(string::in, int::in, adapter_state::in,
    adapter_state::out, continue_or_stop::out, io::di, io::uo) is det.

handle_line(Line, OutFd, State0, State, Continue, !IO) :-
    ( parse_json(Line, Parsed) ->
        parse_command(Parsed, Outcome),
        (
            Outcome = parsed(Command),
            execute_command(Command, OutFd, State0, State, Continue, !IO)
        ;
            Outcome = invalid(MaybeId, Message),
            emit_error(OutFd, MaybeId, no, "ProtocolError", Message, j_null, [], !IO),
            State = State0,
            Continue = continue
        )
    ;
        emit_error(OutFd, no, no, "ProtocolError",
            "adapter command was not valid JSON", j_null, [], !IO),
        State = State0,
        Continue = continue
    ).

%-----------------------------------------------------------------------------%
% Command execution.
%-----------------------------------------------------------------------------%

:- pred execute_command(command::in, int::in, adapter_state::in,
    adapter_state::out, continue_or_stop::out, io::di, io::uo) is det.

execute_command(cmd_hello(Id), OutFd, State, State, continue, !IO) :-
    emit(OutFd, j_object([
        "protocolVersion" - j_number(1.0),
        "id" - j_string(Id),
        "type" - j_string("ready"),
        "language" - j_string("mercury"),
        "implementation" - j_string("native-mercury-0.1.0"),
        "runtime" - j_string("Mercury 22.01.8, asm_fast.gc")
    ]), !IO).

execute_command(cmd_call(Id, Op, Path, Args), OutFd, State0, State, continue, !IO) :-
    ensure_client(State0, State1, ClientResult, !IO),
    (
        ClientResult = ok(Client),
        call_operation(Op, Client, Path, Args, Result, !IO),
        (
            Result = call_ok(call_result(Value, Logs)),
            emit(OutFd, j_object([
                "id" - j_string(Id), "type" - j_string("result"),
                "value" - Value, "logs" - string_list_json(Logs)
            ]), !IO)
        ;
            Result = call_error(Err),
            emit_convex_error(OutFd, yes(Id), no, Err, !IO)
        ),
        State = State1
    ;
        ClientResult = error(Msg),
        emit_error(OutFd, yes(Id), no, "TransportError", Msg, j_null, [], !IO),
        State = State1
    ).

execute_command(cmd_set_auth(Id, Token), OutFd, State0, State, continue, !IO) :-
    ensure_client(State0, State1, ClientResult, !IO),
    (
        ClientResult = ok(Client),
        ( Token = "" -> clear_auth(Client, NewClient) ; set_auth(Token, Client, NewClient) ),
        State = State1 ^ st_client := yes(NewClient),
        emit(OutFd, j_object(["id" - j_string(Id), "type" - j_string("ack")]), !IO)
    ;
        ClientResult = error(Msg),
        emit_error(OutFd, yes(Id), no, "TransportError", Msg, j_null, [], !IO),
        State = State1
    ).

execute_command(cmd_subscribe(Id, SubId, Path, Args), OutFd, State0, State,
        continue, !IO) :-
    ensure_client(State0, State1, ClientResult, !IO),
    (
        ClientResult = ok(Client),
        ensure_live(Client, State1, State2, LiveResult, !IO),
        (
            LiveResult = ok(Conn - LiveState0),
            live_add(Conn, LiveState0, Path, Args, QueryId, LiveState1, AddResult, !IO),
            (
                AddResult = ok,
                Subs = [ SubId - QueryId
                    | list.negated_filter(sub_id_matches(SubId), State2 ^ st_subs) ],
                State = (State2 ^ st_live := yes(Conn - LiveState1)) ^ st_subs := Subs,
                emit(OutFd, j_object(["id" - j_string(Id), "type" - j_string("ack")]), !IO)
            ;
                AddResult = transport_error(Msg),
                State = State2 ^ st_live := yes(Conn - LiveState1),
                emit_error(OutFd, yes(Id), no, "TransportError", Msg, j_null, [], !IO)
            )
        ;
            LiveResult = error(Msg),
            State = State2,
            emit_error(OutFd, yes(Id), no, "TransportError", Msg, j_null, [], !IO)
        )
    ;
        ClientResult = error(Msg),
        State = State1,
        emit_error(OutFd, yes(Id), no, "TransportError", Msg, j_null, [], !IO)
    ).

execute_command(cmd_unsubscribe(Id, SubId), OutFd, State0, State, continue, !IO) :-
    ( assoc_list.search(State0 ^ st_subs, SubId, QueryId), State0 ^ st_live = yes(Conn - LiveState0) ->
        live_remove(Conn, LiveState0, QueryId, LiveState1, _Result, !IO),
        Subs = list.negated_filter(sub_id_matches(SubId), State0 ^ st_subs),
        State = (State0 ^ st_live := yes(Conn - LiveState1)) ^ st_subs := Subs
    ;
        State = State0 ^ st_subs := list.negated_filter(sub_id_matches(SubId), State0 ^ st_subs)
    ),
    emit(OutFd, j_object(["id" - j_string(Id), "type" - j_string("ack")]), !IO).

execute_command(cmd_debug_disconnect(Id), OutFd, State0, State, continue, !IO) :-
    ( State0 ^ st_live = yes(Conn - LiveState) ->
        live_close(Conn, !IO),
        Active = live_active_list(LiveState),
        live_connect(det_client(State0), MaybeLive, !IO),
        (
            MaybeLive = live_ok(NewConn, NewLiveState0),
            resubscribe_all(NewConn, Active, State0 ^ st_subs, NewLiveState0, NewLiveState,
                NewSubs, !IO),
            State = (State0 ^ st_live := yes(NewConn - NewLiveState)) ^ st_subs := NewSubs,
            emit(OutFd, j_object(["id" - j_string(Id), "type" - j_string("ack")]), !IO)
        ;
            MaybeLive = live_error(Err),
            State = State0 ^ st_live := no,
            emit_convex_error(OutFd, yes(Id), no, Err, !IO)
        )
    ;
        State = State0,
        emit_error(OutFd, yes(Id), no, "TransportError", "Live is not connected", j_null, [], !IO)
    ).

execute_command(cmd_close(Id), OutFd, State0, State, stop, !IO) :-
    close_resources(State0, State, !IO),
    emit(OutFd, j_object(["id" - j_string(Id), "type" - j_string("closed")]), !IO).

:- pred sub_id_matches(string::in, pair(string, int)::in) is semidet.

sub_id_matches(SubId, SubId - _).

:- pred call_operation(call_op::in, client::in, string::in, json::in,
    maybe_call_result::out, io::di, io::uo) is det.

call_operation(op_query, Client, Path, Args, Result, !IO) :- query(Client, Path, Args, Result, !IO).
call_operation(op_mutation, Client, Path, Args, Result, !IO) :- mutation(Client, Path, Args, Result, !IO).
call_operation(op_action, Client, Path, Args, Result, !IO) :- action(Client, Path, Args, Result, !IO).

:- func det_client(adapter_state) = client.

det_client(State) = Client :-
    ( State ^ st_client = yes(C) -> Client = C
    ; unexpected($module, $pred, "debugDisconnect without a client")
    ).

    % Connect the Live socket the first time a subscription needs it. On
    % success this hands back the same (connection, state) pair it just
    % stored, so callers never have to re-extract it from adapter_state
    % under an unchecked pattern match.
:- pred ensure_live(client::in, adapter_state::in, adapter_state::out,
    maybe_error(pair(live_conn, live_state))::out, io::di, io::uo) is det.

ensure_live(Client, State0, State, Result, !IO) :-
    ( State0 ^ st_live = yes(Existing) ->
        State = State0,
        Result = ok(Existing)
    ;
        live_connect(Client, MaybeLive, !IO),
        (
            MaybeLive = live_ok(Conn, LiveState),
            State = State0 ^ st_live := yes(Conn - LiveState),
            Result = ok(Conn - LiveState)
        ;
            MaybeLive = live_error(Err),
            State = State0,
            Result = error(convex_error_text(Err))
        )
    ).

:- pred resubscribe_all(live_conn::in, list(active_sub_info)::in,
    assoc_list(string, int)::in, live_state::in, live_state::out,
    assoc_list(string, int)::out, io::di, io::uo) is det.

resubscribe_all(_Conn, [], Subs, State, State, Subs, !IO).
resubscribe_all(Conn, [Info | Rest], Subs0, State0, State, Subs, !IO) :-
    Info = active_sub_info(OldId, _, _, _),
    live_add_resubscribe(Conn, State0, Info, NewId, State1, _Result, !IO),
    Subs1 = list.map(retarget(OldId, NewId), Subs0),
    resubscribe_all(Conn, Rest, Subs1, State1, State, Subs, !IO).

:- func retarget(int, int, pair(string, int)) = pair(string, int).

retarget(OldId, NewId, SubId - QueryId) = Result :-
    ( QueryId = OldId -> Result = SubId - NewId ; Result = SubId - QueryId ).

%-----------------------------------------------------------------------------%
% Live message delivery.
%-----------------------------------------------------------------------------%

:- pred handle_live(int::in, adapter_state::in, adapter_state::out,
    io::di, io::uo) is det.

handle_live(OutFd, State0, State, !IO) :-
    ( State0 ^ st_live = yes(Conn - LiveState0) ->
        live_poll(Conn, LiveState0, Result, !IO),
        (
            Result = live_transition(LiveState1, Changes),
            list.foldl(deliver_change(OutFd, State0 ^ st_subs), Changes, !IO),
            State = State0 ^ st_live := yes(Conn - LiveState1)
        ;
            Result = live_ping,
            State = State0
        ;
            Result = live_ignored,
            State = State0
        ;
            Result = live_would_block,
            State = State0
        ;
            Result = live_protocol_error(Msg),
            broadcast_disconnect(OutFd, State0 ^ st_subs, "ProtocolError", Msg, !IO),
            live_close(Conn, !IO),
            State = State0 ^ st_live := no
        ;
            Result = live_peer_closed,
            broadcast_disconnect(OutFd, State0 ^ st_subs, "TransportError",
                "Live connection closed by the server", !IO),
            live_close(Conn, !IO),
            State = State0 ^ st_live := no
        )
    ;
        State = State0
    ).

:- pred deliver_change(int::in, assoc_list(string, int)::in, live_change::in,
    io::di, io::uo) is det.

deliver_change(OutFd, Subs, live_value(QueryId, Value, Logs), !IO) :-
    ( find_sub_id(Subs, QueryId, SubId) ->
        emit(OutFd, j_object([
            "type" - j_string("subscription"), "subscriptionId" - j_string(SubId),
            "value" - Value, "logs" - string_list_json(Logs)
        ]), !IO)
    ;
        true
    ).
deliver_change(OutFd, Subs, live_query_error(QueryId, Err, Logs), !IO) :-
    ( find_sub_id(Subs, QueryId, SubId) ->
        emit_convex_error(OutFd, no, yes(SubId), Err, !IO),
        ( Logs = [] -> true ; true )
    ;
        true
    ).

:- pred find_sub_id(assoc_list(string, int)::in, int::in, string::out)
    is semidet.

find_sub_id([SubId - QueryId | Rest], Target, Found) :-
    ( QueryId = Target -> Found = SubId ; find_sub_id(Rest, Target, Found) ).

:- pred broadcast_disconnect(int::in, assoc_list(string, int)::in, string::in,
    string::in, io::di, io::uo) is det.

broadcast_disconnect(_OutFd, [], _Name, _Message, !IO).
broadcast_disconnect(OutFd, [SubId - _ | Rest], Name, Message, !IO) :-
    emit_error(OutFd, no, yes(SubId), Name, Message, j_null, [], !IO),
    broadcast_disconnect(OutFd, Rest, Name, Message, !IO).

%-----------------------------------------------------------------------------%
% Emitting events.
%-----------------------------------------------------------------------------%

:- pred emit(int::in, json::in, io::di, io::uo) is det.

emit(Fd, Value, !IO) :-
    write_line(Fd, to_json_string(Value), _Result, !IO).

:- pred emit_error(int::in, maybe(string)::in, maybe(string)::in, string::in,
    string::in, json::in, list(string)::in, io::di, io::uo) is det.

emit_error(Fd, MaybeId, MaybeSubId, Name, Message, Data, Logs, !IO) :-
    emit(Fd, error_event(MaybeId, MaybeSubId, Name, Message, Data, Logs), !IO).

:- pred emit_convex_error(int::in, maybe(string)::in, maybe(string)::in,
    convex_error::in, io::di, io::uo) is det.

emit_convex_error(Fd, MaybeId, MaybeSubId, function_error(Msg, Data, Logs), !IO) :-
    emit_error(Fd, MaybeId, MaybeSubId, "FunctionError", Msg, Data, Logs, !IO).
emit_convex_error(Fd, MaybeId, MaybeSubId, protocol_error(Msg), !IO) :-
    emit_error(Fd, MaybeId, MaybeSubId, "ProtocolError", Msg, j_null, [], !IO).
emit_convex_error(Fd, MaybeId, MaybeSubId, transport_error(Msg), !IO) :-
    emit_error(Fd, MaybeId, MaybeSubId, "TransportError", Msg, j_null, [], !IO).

:- func convex_error_text(convex_error) = string.

convex_error_text(function_error(Msg, _, _)) = Msg.
convex_error_text(protocol_error(Msg)) = Msg.
convex_error_text(transport_error(Msg)) = Msg.

%-----------------------------------------------------------------------------%
% Shutdown.
%-----------------------------------------------------------------------------%

:- pred close_resources(adapter_state::in, adapter_state::out, io::di, io::uo)
    is det.

close_resources(State0, State, !IO) :-
    ( State0 ^ st_live = yes(Conn - _) -> live_close(Conn, !IO) ; true ),
    State = (State0 ^ st_live := no) ^ st_subs := [].
