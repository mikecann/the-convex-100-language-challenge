:- use_module('../convex').
:- use_module(library(base64)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/json)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/websocket)).

:- dynamic fixture_mode/1.
:- dynamic fixture_connection_count/1.
:- dynamic fixture_connect/3.
:- dynamic fixture_wire_change/2.

:- http_handler(root('api/sync'), fixture_upgrade, []).

fixture_upgrade(Request) :-
    http_upgrade_to_websocket(
        fixture_socket,
        [buffer_size(7)],
        Request
    ).

fixture_socket(WS) :-
    setup_call_cleanup(
        true,
        catch(
            fixture_session(WS),
            Error,
            ( print_message(error, Error),
              throw(Error)
            )
        ),
        catch(close(WS, [force(true)]), _, true)
    ).

fixture_session(WS) :-
    ws_receive(WS, Connect),
    Connect.opcode == text,
    record_connect(Connect.data),
    ws_receive(WS, Modify),
    Modify.opcode == text,
    atom_string(ModifyAtom, Modify.data),
    atom_json_dict(ModifyAtom, ModifyDict, []),
    record_wire_changes(ModifyDict),
    with_mutex(prolog_live_fixture, next_connection(Connection)),
    fixture_mode(Mode),
    fixture_mode_session(Mode, Connection, WS, ModifyDict).

next_connection(Connection) :-
    retract(fixture_connection_count(Previous)),
    Connection is Previous + 1,
    asserta(fixture_connection_count(Connection)).

fixture_mode_session(idle, _, _, _) :-
    sleep(3).
fixture_mode_session(continuous, _, WS, _) :-
    continuous_ping(WS).
fixture_mode_session(partial, _, WS, _) :-
    send_stalled_text_frame(WS).
fixture_mode_session(partial_recovery, Connection, WS, Modify) :-
    (   Connection =:= 1
    ->  send_stalled_text_frame(WS)
    ;   first_query_id(Modify, QueryId),
        send_initial_value_transition(WS, QueryId, Connection, 0),
        fixture_command_loop(WS)
    ).
fixture_mode_session(protocol_recovery, Connection, WS, Modify) :-
    first_query_id(Modify, QueryId),
    (   Connection =:= 1
    ->  send_malformed_transition(WS, QueryId)
    ;   send_initial_value_transition(WS, QueryId, Connection, 0),
        fixture_command_loop(WS)
    ).
fixture_mode_session(reconnect, Connection, WS, Modify) :-
    first_query_id(Modify, QueryId),
    send_initial_value_transition(WS, QueryId, Connection, 0),
    (   Connection >= 6
    ->  sleep(0.20),
        Next is Connection + 20,
        send_followup_value_transition(WS, QueryId, Connection, Next, 1)
    ;   true
    ),
    fixture_command_loop(WS).
fixture_mode_session(failure_recovery, Connection, WS, Modify) :-
    first_query_id(Modify, QueryId),
    send_failed_transition(WS, QueryId, Connection),
    sleep(0.05),
    Next is Connection + 1,
    send_followup_value_transition(WS, QueryId, Connection, Next, 0),
    fixture_command_loop(WS).
fixture_mode_session(record_ids, Connection, WS, Modify) :-
    first_query_id(Modify, QueryId),
    send_initial_value_transition(WS, QueryId, Connection, 0),
    fixture_command_loop(WS).

continuous_ping(WS) :-
    catch(
        ( ws_send(WS, ping("busy")),
          sleep(0.005),
          continuous_ping(WS)
        ),
        _,
        true
    ).

% Flush enough of one text frame to make the client consume its header and
% payload prefix, then stop. A correct client must abandon this connection on
% timeout instead of restarting its parser in the middle of the frame.
send_stalled_text_frame(WS) :-
    stream_pair(WS, _, Write),
    websocket:ws_start_message(Write, text),
    format(Write, '{"type":"Transition","padding":"'),
    flush_output(Write),
    sleep(3).

send_malformed_transition(WS, QueryId) :-
    zero_version(Start),
    Transition = _{
        type:"Transition",
        startVersion:Start,
        endVersion:_{querySet:"1", identity:0, ts:"AQAAAAAAAAA="},
        modifications:[_{
            type:"QueryUpdated",
            queryId:QueryId,
            value:_{count:99},
            logLines:[]
        }]
    },
    ws_send(WS, json(Transition)).

fixture_command_loop(WS) :-
    stream_pair(WS, Read, _),
    set_stream(Read, timeout(0.10)),
    catch(ws_receive(WS, Message), _, Message = websocket{opcode:timeout}),
    (   Message.opcode == close
    ->  true
    ;   Message.opcode == timeout
    ->  fixture_command_loop(WS)
    ;   Message.opcode == text
    ->  atom_string(Atom, Message.data),
        atom_json_dict(Atom, Dict, []),
        record_wire_changes(Dict),
        fixture_command_loop(WS)
    ;   fixture_command_loop(WS)
    ).

record_wire_changes(Dict) :-
    (   get_dict(modifications, Dict, Modifications)
    ->  forall(
            member(Change, Modifications),
            ( get_dict(type, Change, Type),
              get_dict(queryId, Change, Id),
              assertz(fixture_wire_change(Type, Id))
            )
        )
    ;   true
    ).

record_connect(Data) :-
    atom_string(Atom, Data),
    atom_json_dict(Atom, Connect, []),
    get_dict(connectionCount, Connect, Count),
    get_dict(lastCloseReason, Connect, LastClose),
    get_dict(maxObservedTimestamp, Connect, MaxTimestamp),
    assertz(fixture_connect(Count, LastClose, MaxTimestamp)).

first_query_id(Modify, QueryId) :-
    get_dict(modifications, Modify, [Add|_]),
    get_dict(queryId, Add, QueryId).

send_initial_value_transition(WS, QueryId, Serial, Count) :-
    zero_version(Start),
    timestamp(Serial, EndTimestamp),
    End = _{querySet:1, identity:0, ts:EndTimestamp},
    send_value_transition(WS, QueryId, Start, End, Count).

send_followup_value_transition(WS, QueryId, StartSerial, EndSerial, Count) :-
    timestamp(StartSerial, StartTimestamp),
    timestamp(EndSerial, EndTimestamp),
    Start = _{querySet:1, identity:0, ts:StartTimestamp},
    End = _{querySet:1, identity:0, ts:EndTimestamp},
    send_value_transition(WS, QueryId, Start, End, Count).

send_value_transition(WS, QueryId, Start, End, Count) :-
    Transition = _{
        type:"Transition",
        startVersion:Start,
        endVersion:End,
        modifications:[_{
            type:"QueryUpdated",
            queryId:QueryId,
            value:_{count:Count, text:"Hello, 世界 👋"},
            logLines:[]
        }]
    },
    ws_send(WS, json(Transition)).

send_failed_transition(WS, QueryId, Serial) :-
    zero_version(Start),
    timestamp(Serial, EndTimestamp),
    End = _{querySet:1, identity:0, ts:EndTimestamp},
    Transition = _{
        type:"Transition",
        startVersion:Start,
        endVersion:End,
        modifications:[_{
            type:"QueryFailed",
            queryId:QueryId,
            errorMessage:"expected fixture failure",
            errorData:_{code:"EXPECTED"},
            logLines:["fixture log"]
        }]
    },
    ws_send(WS, json(Transition)).

timestamp(Value, Timestamp) :-
    uint64_bytes(Value, Bytes),
    phrase(base64(Bytes), Codes),
    string_codes(Timestamp, Codes).

uint64_bytes(Value, Bytes) :-
    uint64_bytes(8, Value, Bytes).

uint64_bytes(0, _, []) :-
    !.
uint64_bytes(Count, Value, [Byte|Rest]) :-
    Byte is Value /\ 255,
    NextValue is Value >> 8,
    NextCount is Count - 1,
    uint64_bytes(NextCount, NextValue, Rest).

start_fixture(Mode, Server, URL) :-
    retractall(fixture_mode(_)),
    retractall(fixture_connection_count(_)),
    retractall(fixture_connect(_, _, _)),
    retractall(fixture_wire_change(_, _)),
    asserta(fixture_mode(Mode)),
    asserta(fixture_connection_count(0)),
    http_server(http_dispatch, [port(Port), workers(8)]),
    Server = Port,
    format(string(URL), 'http://127.0.0.1:~d', [Port]).

stop_fixture(Server) :-
    http_stop_server(Server, []).

wait_connections(Expected) :-
    between(1, 100, _),
    fixture_connection_count(Count),
    (   Count >= Expected
    ->  !
    ;   sleep(0.02),
        fail
    ).

elapsed(Goal, Seconds) :-
    get_time(Start),
    call(Goal),
    get_time(End),
    Seconds is End - Start.

zero_version(_{querySet:0, identity:0, ts:"AAAAAAAAAAA="}).

direct_state(Queue, State) :-
    message_queue_create(Queue),
    convex:initial_state(Initial),
    Active = [sub(7, "demo:state", _{}, Queue, none)],
    State = Initial.put(active, Active).

direct_transition(Start, End, Modifications, Transition) :-
    Transition = _{
        type:"Transition",
        startVersion:Start,
        endVersion:End,
        modifications:Modifications
    }.

:- begin_tests(live).

test(owner_unsubscribes_while_peer_is_idle) :-
    setup_call_cleanup(
        start_fixture(idle, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          sleep(0.10),
          elapsed(subscription_close(Subscription), Elapsed),
          assertion(Elapsed < 1.0),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(owner_unsubscribes_under_continuous_control_frames) :-
    setup_call_cleanup(
        start_fixture(continuous, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          sleep(0.10),
          elapsed(subscription_close(Subscription), Elapsed),
          assertion(Elapsed < 1.0),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(owner_closes_while_peer_stalls_mid_frame) :-
    setup_call_cleanup(
        start_fixture(partial, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          sleep(0.10),
          elapsed(subscription_close(Subscription), Elapsed),
          assertion(Elapsed < 1.0),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(partial_frame_transport_error_recovers) :-
    setup_call_cleanup(
        start_fixture(partial_recovery, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          subscription_next(
              Subscription,
              3,
              update(error(error(transport_error(live_read, _), _)), [])
          ),
          subscription_next(Subscription, 3, update(value(Value), [])),
          assertion(Value.count =:= 0),
          subscription_close(Subscription),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(malformed_transition_error_recovers) :-
    setup_call_cleanup(
        start_fixture(protocol_recovery, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          subscription_next(
              Subscription,
              3,
              update(error(error(protocol_error(_), _)), [])
          ),
          subscription_next(Subscription, 3, update(value(Value), [])),
          assertion(Value.count =:= 0),
          subscription_close(Subscription),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(five_reconnects_suppress_unchanged_hydration) :-
    setup_call_cleanup(
        start_fixture(reconnect, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          subscription_next(Subscription, 3, update(value(Initial), [])),
          assertion(Initial.count =:= 0),
          elapsed(
              forall(
                  between(1, 5, Number),
                  ( live_debug_disconnect(Live),
                    NextConnection is Number + 1,
                    wait_connections(NextConnection),
                    (   Number < 5
                    ->  assertion(\+ subscription_next(Subscription, 0.10, _))
                    ;   true
                    )
                  )
              ),
              ReconnectSeconds
          ),
          assertion(ReconnectSeconds < 2.5),
          findall(Id, fixture_wire_change("Add", Id), Adds),
          assertion(Adds == [0, 0, 0, 0, 0, 0]),
          findall(Count, fixture_connect(Count, _, _), Counts),
          assertion(Counts == [0, 1, 2, 3, 4, 5]),
          findall(
              LastClose,
              fixture_connect(_, LastClose, _),
              LastCloses
          ),
          assertion(
              LastCloses == [
                  "InitialConnect",
                  "DebugDisconnect",
                  "DebugDisconnect",
                  "DebugDisconnect",
                  "DebugDisconnect",
                  "DebugDisconnect"
              ]
          ),
          findall(
              Timestamp,
              fixture_connect(_, _, Timestamp),
              MaxTimestamps
          ),
          MaxTimestamps = ["AAAAAAAAAAA="|ObservedTimestamps],
          findall(
              ExpectedTimestamp,
              ( between(1, 5, Serial),
                timestamp(Serial, ExpectedTimestamp)
              ),
              ExpectedTimestamps
          ),
          assertion(ObservedTimestamps == ExpectedTimestamps),
          subscription_next(Subscription, 3, update(value(Updated), [])),
          assertion(Updated.count =:= 1),
          subscription_close(Subscription),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(query_failure_recovers_to_same_value) :-
    setup_call_cleanup(
        start_fixture(failure_recovery, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, Subscription),
          subscription_next(
              Subscription,
              3,
              update(error(error(function_error(query, _, Data, Logs), _)), Logs)
          ),
          assertion(Data.code == "EXPECTED"),
          assertion(Logs == ["fixture log"]),
          subscription_next(Subscription, 3, update(value(Value), [])),
          assertion(Value.count =:= 0),
          subscription_close(Subscription),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(query_ids_are_monotonic_after_remove) :-
    setup_call_cleanup(
        start_fixture(record_ids, Server, URL),
        ( new_client(URL, Client),
          live_start(Client, Live),
          live_subscribe(Live, "demo:state", _{}, First),
          live_subscribe(Live, "demo:state", _{}, Second),
          subscription_close(First),
          live_subscribe(Live, "demo:state", _{}, Third),
          sleep(0.15),
          findall(Id, fixture_wire_change("Add", Id), Adds),
          assertion(Adds == [0, 1, 2]),
          subscription_close(Second),
          subscription_close(Third),
          live_close(Live)
        ),
        stop_fixture(Server)
    ).

test(transition_is_transactional_and_coalesced) :-
    setup_call_cleanup(
        direct_state(Queue, State0),
        ( zero_version(Start),
          timestamp(1, Timestamp1),
          End = _{querySet:1, identity:0, ts:Timestamp1},
          Modifications = [
              _{type:"QueryUpdated", queryId:7, value:_{count:1}, logLines:[]},
              _{type:"QueryUpdated", queryId:7, value:_{count:2}, logLines:["last"]}
          ],
          direct_transition(Start, End, Modifications, Transition),
          convex:apply_transition(Transition, State0, _),
          thread_get_message(Queue, queued(_, _, update(value(Value), Logs)), [timeout(0)]),
          assertion(Value.count =:= 2),
          assertion(Logs == ["last"]),
          assertion(\+ thread_get_message(Queue, _, [timeout(0)]))
        ),
        message_queue_destroy(Queue)
    ).

test(invalid_transition_publishes_nothing) :-
    setup_call_cleanup(
        direct_state(Queue, State0),
        ( zero_version(Start),
          timestamp(1, Timestamp1),
          End = _{querySet:1, identity:0, ts:Timestamp1},
          Modifications = [
              _{type:"QueryUpdated", queryId:7, value:_{count:1}, logLines:[]},
              _{type:"QueryUpdated", queryId:7, value:_{count:2}, logLines:[99]}
          ],
          direct_transition(Start, End, Modifications, Transition),
          assert_protocol_error(convex:apply_transition(Transition, State0, _)),
          assertion(\+ thread_get_message(Queue, _, [timeout(0)]))
        ),
        message_queue_destroy(Queue)
    ).

test(version_fields_and_timestamps_are_strict) :-
    zero_version(Start),
    timestamp(2, Timestamp2),
    End = _{querySet:1, identity:0, ts:Timestamp2},
    direct_transition(Start, End, [], Valid),
    setup_call_cleanup(
        direct_state(Queue, State0),
        ( convex:apply_transition(Valid, State0, State1),
          BadTimestamp = _{querySet:1, identity:0, ts:"AQ=="},
          direct_transition(End, BadTimestamp, [], NonCanonical),
          assert_protocol_error(convex:apply_transition(NonCanonical, State1, _)),
          timestamp(1, Timestamp1),
          BackwardsEnd = _{querySet:2, identity:0, ts:Timestamp1},
          direct_transition(End, BackwardsEnd, [], Backwards),
          assert_protocol_error(convex:apply_transition(Backwards, State1, _)),
          StringVersion = _{querySet:"2", identity:0, ts:Timestamp2},
          direct_transition(End, StringVersion, [], WrongType),
          assert_protocol_error(convex:apply_transition(WrongType, State1, _))
        ),
        message_queue_destroy(Queue)
    ).

test(global_queue_keeps_newest_sixteen) :-
    setup_call_cleanup(
        direct_state(Queue, State0),
        ( foldl(queue_number(Queue), [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20], State0, State),
          assertion(State.pending_count =:= 16),
          drain_counts(Queue, Counts),
          assertion(Counts == [5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20])
        ),
        message_queue_destroy(Queue)
    ).

:- end_tests(live).

queue_number(Queue, Number, State0, State) :-
    convex:enqueue_update(Queue, update(value(_{count:Number}), []), State0, State).

drain_counts(Queue, [Count|Rest]) :-
    thread_get_message(
        Queue,
        queued(_, _, update(value(_{count:Count}), [])),
        [timeout(0)]
    ),
    !,
    drain_counts(Queue, Rest).
drain_counts(_, []).

assert_protocol_error(Goal) :-
    catch(Goal, Error, true),
    assertion(nonvar(Error)),
    assertion(Error = error(protocol_error(_), _)).
