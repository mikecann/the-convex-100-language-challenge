:- module(convex_adapter, [main/0]).

:- use_module('../../convex').
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(socket)).

max_command_bytes(1048576).
max_output_bytes(2097152).
max_output_messages(16).
max_output_pending_bytes(8388608).
write_timeout(1.0).

main :-
    catch(
        main_transport,
        adapter_error(none, "TransportError", Message),
        format(user_error, 'adapter transport closed: ~s~n', [Message])
    ).

main_transport :-
    open_transport(In, Out),
    setup_call_cleanup(
        start_writer(Out, Output),
        run_adapter(In, Output),
        ( stop_writer(Output),
          close_transport(In, Out)
        )
    ).

open_transport(In, Out) :-
    (   getenv('ADAPTER_LISTEN', Address)
    ->  tcp_transport(Address, In, Out)
    ;   In = user_input,
        Out = user_output
    ),
    set_stream(In, encoding(utf8)),
    set_stream(Out, encoding(utf8)),
    catch(set_stream(Out, timeout(1.0)), _, true).

tcp_transport(Address, In, Out) :-
    split_string(Address, ":", "", [Host, PortText]),
    number_string(Port, PortText),
    tcp_socket(Server),
    setup_call_cleanup(
        ( tcp_bind(Server, Host:Port),
          tcp_listen(Server, 1)
        ),
        tcp_accept(Server, Client, _),
        tcp_close_socket(Server)
    ),
    tcp_open_socket(Client, In, Out).

close_transport(user_input, user_output) :-
    !.
close_transport(In, Out) :-
    catch(close(In, [force(true)]), _, true),
    catch(close(Out, [force(true)]), _, true).

start_writer(Out, output(Queue, Thread, Budget)) :-
    max_output_messages(MaxMessages),
    message_queue_create(Queue, [max_size(MaxMessages)]),
    message_queue_create(Budget, [max_size(1)]),
    thread_send_message(Budget, 0),
    thread_create(writer_loop(Out, Queue, Budget), Thread, [detached(false)]).

stop_writer(output(Queue, Thread, Budget)) :-
    message_queue_create(Reply),
    (   catch(
            thread_send_message(Queue, stop(Reply), [timeout(0.2)]),
            _,
            fail
        ),
        catch(thread_get_message(Reply, stopped, [timeout(2)]), _, fail)
    ->  true
    ;   catch(thread_signal(Thread, throw(adapter_writer_stopped)), _, true)
    ),
    catch(thread_join(Thread, _), _, true),
    message_queue_destroy(Reply),
    message_queue_destroy(Queue),
    message_queue_destroy(Budget).

writer_loop(Out, Queue, Budget) :-
    thread_get_message(Queue, Message),
    (   Message = line(Text, Bytes)
    ->  write_timeout(Timeout),
        call_cleanup(
            call_with_time_limit(
                Timeout,
                ( format(Out, '~s~n', [Text]),
                  flush_output(Out)
                )
            ),
            release_output_bytes(Budget, Bytes)
        ),
        writer_loop(Out, Queue, Budget)
    ;   Message = stop(Reply),
        thread_send_message(Reply, stopped)
    ).

run_adapter(In, Output) :-
    Input = input([], 0, false),
    State = adapter_state{
        client:none,
        live:none,
        subscriptions:[],
        input:Input,
        output:Output
    },
    adapter_loop(In, State).

adapter_loop(In, State0) :-
    drain_updates(State0, State1),
    read_available(In, State1.input, Input, ReadResult),
    State2 = State1.put(input, Input),
    handle_read_result(ReadResult, State2, State, Continue),
    (   Continue == stop
    ->  close_adapter(State)
    ;   adapter_loop(In, State)
    ).

read_available(In, Input0, Input, Result) :-
    wait_for_input([In], Ready, 0.02),
    (   Ready == []
    ->  Input = Input0,
        Result = idle
    ;   catch(get_code(In, Code), Error, true),
        (   var(Error)
        ->  consume_code(Code, In, Input0, Input, Result)
        ;   Input = input([], 0, false),
            error_text(Error, Message),
            Result = error(protocol, Message)
        )
    ).

consume_code(-1, _, input([], 0, false), input([], 0, false), eof) :-
    !.
consume_code(-1, _, input(Codes, _, false), input([], 0, false), line(Line)) :-
    !,
    reverse(Codes, Ordered),
    string_codes(Line, Ordered).
consume_code(-1, _, input(_, _, true), input([], 0, false),
             error(protocol, "adapter command exceeds 1048576 UTF-8 bytes")) :-
    !.
consume_code(10, _, input(Codes, _, false), input([], 0, false), line(Line)) :-
    !,
    reverse(Codes, Ordered),
    string_codes(Line, Ordered).
consume_code(10, _, input(_, _, true), input([], 0, false),
             error(protocol, "adapter command exceeds 1048576 UTF-8 bytes")) :-
    !.
consume_code(_, _, input(Codes, Bytes, true), input(Codes, Bytes, true), idle) :-
    !,
    true.
consume_code(Code, _, input(Codes, Bytes0, false), Input, idle) :-
    utf8_code_bytes(Code, CodeBytes),
    Bytes is Bytes0 + CodeBytes,
    max_command_bytes(MaxBytes),
    (   Bytes =< MaxBytes
    ->  Next = input([Code|Codes], Bytes, false)
    ;   Next = input([], Bytes, true)
    ),
    Input = Next.

utf8_code_bytes(Code, 1) :- Code =< 127, !.
utf8_code_bytes(Code, 2) :- Code =< 2047, !.
utf8_code_bytes(Code, 3) :- Code =< 65535, !.
utf8_code_bytes(_, 4).

handle_read_result(idle, State, State, continue).
handle_read_result(eof, State, State, stop).
handle_read_result(error(protocol, Message), State, State, continue) :-
    emit_error(State.output, none, none, "ProtocolError", Message, none, []).
handle_read_result(line(Line), State0, State, Continue) :-
    handle_line(Line, State0, State, Continue).

handle_line(Line, State0, State, Continue) :-
    catch(
        ( atom_string(Atom, Line),
          atom_json_dict(Atom, Command, []),
          validate_command(Command, Valid),
          execute_command(Valid, State0, State, Continue)
        ),
        Error,
        command_failure(Error, State0, State, Continue)
    ).

command_failure(Error, State, State, continue) :-
    command_error_fields(Error, Id, Name, Message, Data, Logs),
    emit_error(State.output, Id, none, Name, Message, Data, Logs).

command_error_fields(adapter_error(Id, Name, Message), Id, Name, Message, none, []) :-
    !.
command_error_fields(
    error(function_error(_, Message, Data, Logs), _),
    none,
    "FunctionError",
    Message,
    Data,
    Logs
) :-
    !.
command_error_fields(error(protocol_error(Detail), _), none,
                     "ProtocolError", Message, none, []) :-
    !,
    error_text(Detail, Message).
command_error_fields(error(transport_error(_, Detail), _), none,
                     "TransportError", Message, none, []) :-
    !,
    error_text(Detail, Message).
command_error_fields(
    command_execution_error(Id, Name, Message, Data, Logs),
    Id,
    Name,
    Message,
    Data,
    Logs
) :-
    !.
command_error_fields(Error, none, "ProtocolError", Message, none, []) :-
    error_text(Error, Message).

/* Validate exact adapter protocol-v1 command shapes before executing them. */
validate_command(Command, valid(hello, Id, Command)) :-
    exact_command(Command, [id, op, protocolVersion]),
    get_dict(op, Command, "hello"),
    valid_id(Command, Id),
    get_dict(protocolVersion, Command, 1),
    !.
validate_command(Command, valid(Operation, Id, Command)) :-
    exact_command(Command, [args, id, op, path]),
    get_dict(op, Command, Operation),
    memberchk(Operation, ["query", "mutation", "action"]),
    valid_id(Command, Id),
    valid_path_and_args(Command),
    !.
validate_command(Command, valid("setAuth", Id, Command)) :-
    exact_command(Command, [id, op, token]),
    get_dict(op, Command, "setAuth"),
    valid_id(Command, Id),
    get_dict(token, Command, Token),
    string(Token),
    !.
validate_command(Command, valid("subscribe", Id, Command)) :-
    exact_command(Command, [args, id, op, path, subscriptionId]),
    get_dict(op, Command, "subscribe"),
    valid_id(Command, Id),
    valid_subscription_id(Command, _),
    valid_path_and_args(Command),
    !.
validate_command(Command, valid("unsubscribe", Id, Command)) :-
    exact_command(Command, [id, op, subscriptionId]),
    get_dict(op, Command, "unsubscribe"),
    valid_id(Command, Id),
    valid_subscription_id(Command, _),
    !.
validate_command(Command, valid(Operation, Id, Command)) :-
    exact_command(Command, [id, op]),
    get_dict(op, Command, Operation),
    memberchk(Operation, ["close", "debugDisconnect"]),
    valid_id(Command, Id),
    !.
validate_command(Command, _) :-
    command_id_or_none(Command, Id),
    throw(adapter_error(Id, "ProtocolError", "invalid adapter command" )).

exact_command(Command, Expected) :-
    is_dict(Command),
    dict_pairs(Command, _, Pairs),
    pairs_keys(Pairs, Keys0),
    sort(Keys0, Keys),
    sort(Expected, Keys).

pairs_keys([], []).
pairs_keys([Key-_|Rest], [Key|Keys]) :-
    pairs_keys(Rest, Keys).

valid_id(Command, Id) :-
    get_dict(id, Command, Id),
    string(Id),
    string_length(Id, Length),
    Length >= 1,
    Length =< 128.

valid_subscription_id(Command, Id) :-
    get_dict(subscriptionId, Command, Id),
    string(Id),
    string_length(Id, Length),
    Length >= 1,
    Length =< 128.

valid_path_and_args(Command) :-
    get_dict(path, Command, Path),
    string(Path),
    string_length(Path, PathLength),
    PathLength >= 3,
    get_dict(args, Command, Args),
    is_dict(Args).

command_id_or_none(Command, Id) :-
    (is_dict(Command), get_dict(id, Command, Candidate), string(Candidate) -> Id = Candidate ; Id = none).

execute_command(valid(hello, Id, _), State, State, continue) :-
    current_prolog_flag(version_data, swi(Major, Minor, Patch, _)),
    format(string(Runtime), 'SWI-Prolog ~d.~d.~d', [Major, Minor, Patch]),
    emit(State.output, _{
        protocolVersion:1,
        id:Id,
        type:"ready",
        language:"prolog",
        implementation:"native-swi-prolog",
        runtime:Runtime
    }).
execute_command(valid(Operation, Id, Command), State0, State, continue) :-
    memberchk(Operation, ["query", "mutation", "action"]),
    catch(
        ( ensure_client(State0, Client, State),
          get_dict(path, Command, Path),
          get_dict(args, Command, Args),
          atom_string(Predicate, Operation),
          call(Predicate, Client, Path, Args, result(Value, Logs))
        ),
        Error,
        throw_with_id(Id, Error)
    ),
    emit(State.output, _{id:Id, type:"result", value:Value, logs:Logs}).
execute_command(valid("setAuth", Id, Command), State0, State, continue) :-
    catch(
        ( ensure_client(State0, Client0, WithClient),
          get_dict(token, Command, Token),
          with_auth(Client0, Token, Client),
          State = WithClient.put(client, Client)
        ),
        Error,
        throw_with_id(Id, Error)
    ),
    emit(State.output, _{id:Id, type:"ack"}).
execute_command(valid("subscribe", Id, Command), State0, State, continue) :-
    catch(
        ( ensure_live(State0, Live, WithLive),
          get_dict(subscriptionId, Command, SubscriptionId),
          get_dict(path, Command, Path),
          get_dict(args, Command, Args),
          live_subscribe(Live, Path, Args, Subscription)
        ),
        Error,
        throw_with_id(Id, Error)
    ),
    % Create the replacement first. If that fails, the existing subscription
    % remains usable. Before acknowledging success, close the old generation so
    % no stale event can cross the replacement barrier.
    remove_adapter_subscription(
        SubscriptionId,
        WithLive.subscriptions,
        WithoutOld
    ),
    Subs = [adapter_sub(SubscriptionId, Subscription)|WithoutOld],
    State = WithLive.put(subscriptions, Subs),
    emit(State.output, _{id:Id, type:"ack"}).
execute_command(valid("unsubscribe", Id, Command), State0, State, continue) :-
    get_dict(subscriptionId, Command, SubscriptionId),
    remove_adapter_subscription(
        SubscriptionId,
        State0.subscriptions,
        Subs
    ),
    State = State0.put(subscriptions, Subs),
    emit(State.output, _{id:Id, type:"ack"}).
execute_command(valid("debugDisconnect", Id, _), State, State, continue) :-
    (   State.live == none
    ->  emit_error(
            State.output,
            Id,
            none,
            "TransportError",
            "Live is not connected",
            none,
            []
        )
    ;   catch(
            live_debug_disconnect(State.live),
            Error,
            throw_with_id(Id, Error)
        ),
        emit(State.output, _{id:Id, type:"ack"})
    ).
execute_command(valid("close", Id, _), State0, State, stop) :-
    close_adapter_resources(State0, State),
    emit(State.output, _{id:Id, type:"closed"}).

throw_with_id(Id, Error) :-
    command_error_fields(Error, _, Name, Message, _, _),
    (   Error = error(function_error(_, _, Data, Logs), _)
    ->  throw(command_execution_error(Id, Name, Message, Data, Logs))
    ;   throw(command_execution_error(Id, Name, Message, none, []))
    ).

ensure_client(State, State.client, State) :-
    State.client \= none,
    !.
ensure_client(State0, Client, State) :-
    (   getenv('CONVEX_URL', URL)
    ->  new_client(URL, Client),
        State = State0.put(client, Client)
    ;   throw(error(transport_error(adapter, "CONVEX_URL is required"), _))
    ).

ensure_live(State, State.live, State) :-
    State.live \= none,
    !.
ensure_live(State0, Live, State) :-
    ensure_client(State0, Client, WithClient),
    live_start(Client, Live),
    State = WithClient.put(live, Live).

remove_adapter_subscription(_, [], []).
remove_adapter_subscription(Id, [adapter_sub(Id, Sub)|Rest], Rest) :-
    !,
    catch(subscription_close(Sub), _, true).
remove_adapter_subscription(Id, [Sub|Rest], [Sub|Next]) :-
    remove_adapter_subscription(Id, Rest, Next).

drain_updates(State0, State) :-
    drain_subscriptions(State0.subscriptions, State0.output, Subs),
    State = State0.put(subscriptions, Subs).

drain_subscriptions([], _, []).
drain_subscriptions(
    [adapter_sub(Id, Sub)|Rest],
    Output,
    [adapter_sub(Id, Sub)|Next]
) :-
    (   catch(subscription_next(Sub, 0, Update), _, fail)
    ->  emit_update(Output, Id, Update)
    ;   true
    ),
    drain_subscriptions(Rest, Output, Next).

emit_update(Output, Id, update(value(Value), Logs)) :-
    emit(Output, _{
        type:"subscription",
        subscriptionId:Id,
        value:Value,
        logs:Logs
    }).
emit_update(Output, Id, update(error(Error), Logs)) :-
    adapter_error_payload(Error, Name, Message, Data),
    emit_error(Output, none, Id, Name, Message, Data, Logs).

close_adapter(State) :-
    close_adapter_resources(State, _).

close_adapter_resources(State0, State) :-
    forall(
        member(adapter_sub(_, Sub), State0.subscriptions),
        catch(subscription_close(Sub), _, true)
    ),
    (   State0.live == none
    ->  true
    ;   catch(live_close(State0.live), _, true)
    ),
    State = State0.put(_{live:none, subscriptions:[]}).

emit(Output, Dict) :-
    with_output_to(
        string(Text),
        json_write_dict(current_output, Dict, [width(0)])
    ),
    string_bytes(Text, Encoded, utf8),
    length(Encoded, Bytes),
    max_output_bytes(MaxBytes),
    (   Bytes =< MaxBytes
    ->  true
    ;   throw(adapter_error(none, "ProtocolError", "adapter event exceeds output bound"))
    ),
    Output = output(Queue, Writer, Budget),
    reserve_output_bytes(Budget, Bytes),
    (   thread_property(Writer, status(running)),
        catch(
            thread_send_message(Queue, line(Text, Bytes), [timeout(0.2)]),
            _,
            fail
        )
    ->  true
    ;   release_output_bytes(Budget, Bytes),
        throw(adapter_error(
            none,
            "TransportError",
            "controller output is not writable"
        ))
    ).

reserve_output_bytes(Budget, Bytes) :-
    with_mutex(
        convex_adapter_output_budget,
        ( thread_get_message(Budget, Current),
          Next is Current + Bytes,
          max_output_pending_bytes(MaxBytes),
          (   Next =< MaxBytes
          ->  thread_send_message(Budget, Next)
          ;   thread_send_message(Budget, Current),
              throw(adapter_error(
                  none,
                  "TransportError",
                  "controller output byte budget is full"
              ))
          )
        )
    ).

release_output_bytes(Budget, Bytes) :-
    with_mutex(
        convex_adapter_output_budget,
        ( thread_get_message(Budget, Current),
          Next is max(0, Current - Bytes),
          thread_send_message(Budget, Next)
        )
    ).

emit_error(Output, Id, SubscriptionId, Name, Message, Data, Logs) :-
    Base = _{error:_{name:Name, message:Message}, logs:Logs},
    add_error_data(Data, Base, WithData),
    (   SubscriptionId \= none
    ->  Event = WithData.put(_{
            type:"subscription",
            subscriptionId:SubscriptionId
        })
    ;   Id \= none
    ->  Event = WithData.put(_{type:"error", id:Id})
    ;   Event = WithData.put(type, "error")
    ),
    emit(Output, Event).

add_error_data(none, Event, Event).
add_error_data(Data, Event0, Event) :-
    Error = Event0.error.put(data, Data),
    Event = Event0.put(error, Error).

adapter_error_payload(error(function_error(_, Message, Data, _), _),
                      "FunctionError", Message, Data) :-
    !.
adapter_error_payload(error(protocol_error(Detail), _),
                      "ProtocolError", Message, none) :-
    !,
    error_text(Detail, Message).
adapter_error_payload(error(transport_error(_, Detail), _),
                      "TransportError", Message, none) :-
    !,
    error_text(Detail, Message).
adapter_error_payload(Error, "Error", Message, none) :-
    error_text(Error, Message).

error_text(Error, Message) :-
    catch(message_to_string(Error, Message), _, Message = "unknown error").
