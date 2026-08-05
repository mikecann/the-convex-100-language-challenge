:- module(convex_adapter, [main/0]).

:- use_module('../../convex').
:- use_module(library(http/json)).
:- use_module(library(socket)).

main :-
    ( getenv('ADAPTER_LISTEN', Address) -> tcp_transport(Address, In, Out) ; In = user_input, Out = user_output ),
    setup_call_cleanup(true, adapter_loop(In, Out, state(none, none, [])), close_transport(In, Out)).

tcp_transport(Address, In, Out) :-
    split_string(Address, ":", "", [Host, PortText]), number_string(Port, PortText),
    tcp_socket(Socket), tcp_bind(Socket, Host:Port), tcp_listen(Socket, 1),
    tcp_accept(Socket, Client, _), tcp_open_socket(Client, In, Out), tcp_close_socket(Socket).

close_transport(user_input, user_output) :- !.
close_transport(In, Out) :- close(In), close(Out).

adapter_loop(In, Out, State0) :-
    drain_updates(Out, State0),
    wait_for_input([In], Ready, 0.05),
    ( Ready = [In] ->
        ( bounded_line(In, Line) -> handle_line(Line, Out, State0, State, Continue) ; close_adapter(State0), Continue = stop )
    ; State = State0, Continue = continue
    ),
    ( Continue == stop -> true ; adapter_loop(In, Out, State) ).

bounded_line(In, Line) :- bounded_codes(In, 0, Codes), string_codes(Line, Codes).
bounded_codes(In, Count, Codes) :-
    get_code(In, Code), bounded_code(In, Code, Count, Codes).
bounded_code(_, -1, Count, []) :- Count > 0, !.
bounded_code(_, 10, _, []) :- !.
bounded_code(In, Code, Count, [Code|Rest]) :-
    Code \= -1, Code \= 10, Count < 1048576,
    Next is Count + 1, bounded_codes(In, Next, Rest).

handle_line(Line, Out, State0, State, Continue) :-
    catch((atom_string(Atom, Line), atom_json_dict(Atom, Command, []), handle_command(Command, Out, State0, State, Continue)),
          Error, (emit(Out, _{type:"error", error:_{name:"ProtocolError", message:Error}}), State = State0, Continue = continue)).

handle_command(Command, Out, State0, State, continue) :- get_dict(op, Command, "hello"), !,
    get_dict(id, Command, Id), get_dict(protocolVersion, Command, 1),
    current_prolog_flag(version_data, swi(Major, Minor, Patch, _)),
    format(string(Runtime), 'SWI-Prolog ~d.~d.~d', [Major, Minor, Patch]),
    emit(Out, _{protocolVersion:1, id:Id, type:"ready", language:"prolog", implementation:"native-swi-prolog", runtime:Runtime}), State = State0.
handle_command(Command, Out, State0, State, continue) :-
    get_dict(op, Command, Operation), memberchk(Operation, ["query", "mutation", "action"]), !,
    get_dict(id, Command, Id), ensure_client(State0, Client, State1),
    get_dict(path, Command, Path), (get_dict(args, Command, Args) -> true ; Args = _{}),
    catch((atom_string(Op, Operation), call(Op, Client, Path, Args, result(Value, Logs)), emit(Out, _{id:Id, type:"result", value:Value, logs:Logs})),
          Error, emit_error(Out, Id, none, Error)), State = State1.
handle_command(Command, Out, State0, State, continue) :- get_dict(op, Command, "setAuth"), !,
    get_dict(id, Command, Id), ensure_client(State0, Client0, state(_, Live, Subs)),
    (get_dict(token, Command, Token) -> true ; Token = ""), with_auth(Client0, Token, Client),
    emit(Out, _{id:Id, type:"ack"}), State = state(Client, Live, Subs).
handle_command(Command, Out, State0, State, continue) :- get_dict(op, Command, "subscribe"), !,
    get_dict(id, Command, Id), get_dict(subscriptionId, Command, SubscriptionId),
    ensure_client(State0, Client, state(Client, Live0, Subs0)),
    ( Live0 == none -> live_start(Client, Live) ; Live = Live0 ),
    get_dict(path, Command, Path), (get_dict(args, Command, Args) -> true ; Args = _{}),
    catch((live_subscribe(Live, Path, Args, Sub), replace_subscription(SubscriptionId, Sub, Subs0, Subs), emit(Out, _{id:Id, type:"ack"})),
          Error, (emit_error(Out, Id, none, Error), Subs = Subs0)), State = state(Client, Live, Subs).
handle_command(Command, Out, State0, State, continue) :- get_dict(op, Command, "unsubscribe"), !,
    get_dict(id, Command, Id), get_dict(subscriptionId, Command, SubscriptionId),
    State0 = state(Client, Live, Subs0), remove_subscription(SubscriptionId, Subs0, Subs), emit(Out, _{id:Id, type:"ack"}), State = state(Client, Live, Subs).
handle_command(Command, Out, State0, State, continue) :- get_dict(op, Command, "debugDisconnect"), !,
    get_dict(id, Command, Id), State0 = state(Client, Live, Subs),
    catch((live_debug_disconnect(Live), emit(Out, _{id:Id, type:"ack"})), Error, emit_error(Out, Id, none, Error)), State = state(Client, Live, Subs).
handle_command(Command, Out, State0, State0, stop) :- get_dict(op, Command, "close"), !,
    get_dict(id, Command, Id), close_adapter(State0), emit(Out, _{id:Id, type:"closed"}).
handle_command(Command, Out, State, State, continue) :-
    (get_dict(id, Command, Id) -> true ; Id = none), emit_error(Out, Id, none, error(protocol_error(unknown_operation), _)).

ensure_client(state(none, Live, Subs), Client, state(Client, Live, Subs)) :- getenv('CONVEX_URL', URL), new_client(URL, Client), !.
ensure_client(State, Client, State) :- State = state(Client, _, _).

replace_subscription(Id, Sub, Subs0, [pair(Id, Sub)|Rest]) :- remove_subscription(Id, Subs0, Rest).
remove_subscription(_, [], []).
remove_subscription(Id, [pair(Id, Sub)|Rest], Rest) :- !, catch(subscription_close(Sub), _, true).
remove_subscription(Id, [Pair|Rest], [Pair|Next]) :- remove_subscription(Id, Rest, Next).

drain_updates(_, state(_, _, [])) :- !.
drain_updates(Out, state(_, _, Subs)) :- forall(member(pair(Id, Sub), Subs), drain_subscription(Out, Id, Sub)).
drain_subscription(Out, Id, subscription(_, Queue, _)) :-
    ( thread_get_message(Queue, Update, [timeout(0)]) -> emit_update(Out, Id, Update), drain_subscription(Out, Id, subscription(_, Queue, _)) ; true ).
emit_update(Out, Id, update(value(Value), Logs)) :- emit(Out, _{type:"subscription", subscriptionId:Id, value:Value, logs:Logs}).
emit_update(Out, Id, update(error(Error), Logs)) :- error_dict(Error, Dict), emit(Out, _{type:"subscription", subscriptionId:Id, error:Dict, logs:Logs}).

close_adapter(state(_, Live, Subs)) :- forall(member(pair(_, Sub), Subs), catch(subscription_close(Sub), _, true)), (Live == none -> true ; catch(live_close(Live), _, true)).
emit(Out, Dict) :- json_write_dict(Out, Dict, [width(0)]), nl(Out), flush_output(Out).
emit_error(Out, Id, SubscriptionId, Error) :- error_dict(Error, Dict),
    ( SubscriptionId == none -> (Id == none -> emit(Out, _{type:"error", error:Dict}) ; emit(Out, _{id:Id, type:"error", error:Dict}))
    ; emit(Out, _{type:"subscription", subscriptionId:SubscriptionId, error:Dict}) ).
error_dict(error(function_error(_, Message, Data, _), _), _{name:"FunctionError", message:Message, data:Data}) :- !.
error_dict(error(protocol_error(Message), _), _{name:"ProtocolError", message:Message}) :- !.
error_dict(error(transport_error(_, Message), _), _{name:"TransportError", message:Message}) :- !.
error_dict(Error, _{name:"Error", message:Error}).
