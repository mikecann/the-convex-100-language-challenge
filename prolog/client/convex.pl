:- module(convex,
    [ new_client/2,
      with_auth/3,
      query/4,
      mutation/4,
      action/4,
      live_start/2,
      live_subscribe/4,
      subscription_next/3,
      subscription_close/1,
      live_debug_disconnect/1,
      live_close/1,
      integer_json/2,
      timestamp_newer/2
    ]).

:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(http/websocket)).
:- use_module(library(lists)).
:- use_module(library(random)).
:- use_module(library(uri)).
:- use_module(library(uuid)).

/*
  This is deliberately a small educational client.  HTTP functions use
  Convex's documented JSON endpoint.  Live uses the explicitly pinned
  unversioned /api/sync profile and is owned by exactly one Prolog thread:
  callers only send commands to it, so a read, write, reconnect, or query-set
  change can never race another socket operation.
*/

client_version("prolog-0.1.0").
initial_timestamp("AAAAAAAAAAA=").
max_frame_bytes(2097152).
max_update_count(16).
max_update_bytes(8388608).

new_client(URLInput, client(URL, "", Version)) :-
    ( string(URLInput) -> URL0 = URLInput ; atom(URLInput) -> atom_string(URLInput, URL0) ; must_be(string, URLInput) ),
    uri_components(URL0, Components),
    uri_data(scheme, Components, Scheme),
    ( memberchk(Scheme, [http, https]) -> true ; throw(error(domain_error(convex_url_scheme, Scheme), _)) ),
    uri_data(authority, Components, Authority),
    Authority \= '',
    uri_data(path, Components, Path0),
    string_concat(URL0, "", Raw),
    ( sub_string(Raw, _, 1, 0, "/") -> sub_string(Raw, 0, _, 1, URL) ; URL = Raw ),
    Path0 = Path0,
    client_version(Version).

with_auth(client(URL, _, Version), Token, client(URL, Token, Version)) :-
    must_be(string, Token).

query(Client, Path, Args, Result) :- call_http(Client, query, Path, Args, Result).
mutation(Client, Path, Args, Result) :- call_http(Client, mutation, Path, Args, Result).
action(Client, Path, Args, Result) :- call_http(Client, action, Path, Args, Result).

call_http(client(Base, Token, Version), Operation, Path, Args, Result) :-
    must_be(string, Path), Path \= "",
    is_dict(Args),
    atom_string(Operation, OperationText),
    string_concat(Base, "/api/", Prefix),
    string_concat(Prefix, OperationText, URL),
    Request = _{path:Path, args:Args, format:"json"},
    headers(Token, Version, Headers),
    catch(
        http_post(URL, json(Request), Response,
            [ json_object(dict), status_code(Status), timeout(15),
              request_header('Accept'='application/json') | Headers ]),
        Error,
        throw(error(transport_error(Operation, Error), _))),
    ( get_dict(status, Response, "success"), get_dict(value, Response, Value) ->
        response_logs(Response, Logs), Result = result(Value, Logs)
    ; get_dict(status, Response, "error") ->
        response_logs(Response, Logs),
        ( get_dict(errorMessage, Response, Message) -> true ; Message = "Convex function failed" ),
        ( get_dict(errorData, Response, Data) -> true ; Data = null ),
        throw(error(function_error(Operation, Message, Data, Logs), _))
    ; throw(error(protocol_error(http_response(Status, Response)), _))
    ).

headers("", Version, [request_header('Convex-Client'=Version)]).
headers(Token, Version,
        [request_header('Convex-Client'=Version), request_header('Authorization'=Authorization)]) :-
    Token \= "", string_concat("Bearer ", Token, Authorization).

response_logs(Response, Logs) :- get_dict(logLines, Response, Logs), is_list(Logs), !.
response_logs(_, []).

/* Live public API --------------------------------------------------------- */

live_start(Client, live(Commands, Thread)) :-
    message_queue_create(Commands),
    thread_create(live_owner(Commands, Client), Thread, [detached(false)]).

live_subscribe(live(Commands, _), Path, Args, subscription(Id, Updates, Commands)) :-
    must_be(string, Path), Path \= "", is_dict(Args),
    message_queue_create(Updates), message_queue_create(Reply),
    thread_send_message(Commands, subscribe(Path, Args, Updates, Reply)),
    thread_get_message(Reply, ReplyValue, [timeout(15)]),
    message_queue_destroy(Reply),
    ( ReplyValue = ok(Id) -> true ; message_queue_destroy(Updates), throw(ReplyValue) ).

subscription_next(subscription(_, Updates, _), TimeoutSeconds, Update) :-
    thread_get_message(Updates, Update, [timeout(TimeoutSeconds)]).

subscription_close(subscription(Id, Updates, Commands)) :-
    message_queue_create(Reply),
    thread_send_message(Commands, unsubscribe(Id, Updates, Reply)),
    thread_get_message(Reply, ReplyValue, [timeout(5)]),
    message_queue_destroy(Reply),
    ( ReplyValue == ok -> true ; throw(ReplyValue) ).

live_debug_disconnect(live(Commands, _)) :-
    message_queue_create(Reply), thread_send_message(Commands, debug_disconnect(Reply)),
    thread_get_message(Reply, ReplyValue, [timeout(10)]), message_queue_destroy(Reply),
    ( ReplyValue == ok -> true ; throw(ReplyValue) ).

live_close(live(Commands, Thread)) :-
    message_queue_create(Reply), thread_send_message(Commands, close(Reply)),
    thread_get_message(Reply, _, [timeout(5)]), message_queue_destroy(Reply),
    thread_join(Thread, _), message_queue_destroy(Commands).

/* The Live owner.  It is the only thread that ever receives from, writes to,
   or closes the WebSocket.  That gives Add/Remove and disconnect commands a
   real acknowledgement barrier before a caller is told that they completed. */
live_owner(Commands, Client) :-
    initial_timestamp(Zero),
    State = state(none, [], 0, version(0, 0, Zero), 0, "InitialConnect", Zero, 100),
    catch(live_loop(Commands, Client, State), Error,
          print_message(error, Error)).

live_loop(Commands, Client, State0) :-
    ensure_connected(Client, State0, State1),
    ( thread_get_message(Commands, Command, [timeout(0.02)]) ->
        handle_command(Command, Client, State1, State2, Continue)
    ; poll_socket(State1, State2, Continue)
    ),
    ( Continue == stop -> close_state(State2)
    ; live_loop(Commands, Client, State2)
    ).

ensure_connected(_, State, State) :- State = state(WS, _, _, _, _, _, _, _), WS \= none, !.
ensure_connected(_, State, State) :- State = state(none, [], _, _, _, _, _, _), !.
ensure_connected(Client, state(none, Active, _, _, Count, Last, Timestamp, Backoff), Next) :-
    ( catch(open_live_socket(Client, Count, Last, Timestamp, WS), _, fail) ->
        install_active(WS, Active, 0, Version),
        initial_timestamp(Zero),
        % A successful handshake resets the exponential transport backoff.
        Next = state(WS, Active, Version, version(0, 0, Zero), Count, Last, Timestamp, 100)
    ; Delay is Backoff / 1000, sleep(Delay),
      NextBackoff is min(Backoff * 2, 15000), NextCount is Count + 1,
      initial_timestamp(Zero),
      Next = state(none, Active, 0, version(0, 0, Zero), NextCount,
                   "ConnectFailed", Timestamp, NextBackoff)
    ).

open_live_socket(client(Base, _, Version), Count, Last, Timestamp, WS) :-
    ws_url(Base, URL),
    http_open_websocket(URL, WS,
        [ timeout(10), request_header('Convex-Client'=Version) ]),
    uuid(SessionUUID), atom_string(SessionUUID, SessionId),
    Connect = _{type:"Connect", sessionId:SessionId, connectionCount:Count,
                lastCloseReason:Last, maxObservedTimestamp:Timestamp, clientTs:0},
    ws_json_send(WS, Connect).

ws_url(Base, URL) :-
    uri_components(Base, Components0),
    uri_data(scheme, Components0, Scheme0),
    ( Scheme0 == http -> Scheme = ws ; Scheme = wss ),
    uri_data(path, Components0, Path0),
    string_concat(Path0, "/api/sync", Path),
    uri_data(scheme, Components0, Scheme, Components1),
    uri_data(path, Components1, Path, Components),
    uri_components(URL, Components).

install_active(_, [], Version, Version).
install_active(WS, Active, Base, NewVersion) :-
    additions(Active, Adds),
    ( Adds = [] -> NewVersion = Base
    ; NewVersion is Base + 1,
      ws_json_send(WS, _{type:"ModifyQuerySet", baseVersion:Base,
                          newVersion:NewVersion, modifications:Adds})
    ).

additions([], []).
additions([entry(Id, Path, Args, _, _)|Rest],
          [_{type:"Add", queryId:Id, udfPath:Path, args:[Args]}|Adds]) :- additions(Rest, Adds).

handle_command(subscribe(Path, Args, Updates, Reply), Client,
               state(WS0, Active0, Version0, Remote, Count, Last, Timestamp, Backoff),
               State, continue) :-
    length(Active0, Id), Entry = entry(Id, Path, Args, Updates, 0), append(Active0, [Entry], Active),
    ( WS0 == none ->
        State0 = state(none, Active, Version0, Remote, Count, Last, Timestamp, Backoff),
        ensure_connected(Client, State0, State)
    ; Version is Version0 + 1,
      ws_json_send(WS0, _{type:"ModifyQuerySet", baseVersion:Version0, newVersion:Version,
                            modifications:[_{type:"Add", queryId:Id, udfPath:Path, args:[Args]}]}),
      State = state(WS0, Active, Version, Remote, Count, Last, Timestamp, Backoff)
    ), thread_send_message(Reply, ok(Id)).
handle_command(unsubscribe(Id, Updates, Reply), _,
               state(WS0, Active0, Version0, Remote, Count, Last, Timestamp, Backoff),
               State, continue) :-
    remove_entry(Id, Active0, Active),
    % Removing the entry before the acknowledgement makes stale relays impossible.
    ( WS0 == none -> Version = Version0
    ; Version is Version0 + 1,
      catch(ws_json_send(WS0, _{type:"ModifyQuerySet", baseVersion:Version0, newVersion:Version,
                                modifications:[_{type:"Remove", queryId:Id}]}), _, true)
    ), message_queue_destroy(Updates),
    State = state(WS0, Active, Version, Remote, Count, Last, Timestamp, Backoff),
    thread_send_message(Reply, ok).
handle_command(debug_disconnect(Reply), _, State0, State, continue) :-
    retire_socket("DebugDisconnect", State0, State), thread_send_message(Reply, ok).
handle_command(close(Reply), _, State, State, stop) :- thread_send_message(Reply, closed).

remove_entry(_, [], []).
remove_entry(Id, [entry(Id, _, _, _, _)|Rest], Rest) :- !.
remove_entry(Id, [Entry|Rest], [Entry|Result]) :- remove_entry(Id, Rest, Result).

poll_socket(State, State, continue) :- State = state(none, _, _, _, _, _, _, _), !.
poll_socket(State0, State, continue) :-
    State0 = state(WS, _, _, _, _, _, _, _),
    catch(ws_receive(WS, Message, [timeout(0.02)]), _, Message = websocket{opcode:close}),
    ( Message.opcode == text -> handle_server_message(Message.data, State0, State)
    ; Message.opcode == close -> retire_socket("PeerClosed", State0, State)
    ; State = State0
    ).

handle_server_message(Data, State0, State) :-
    ( string(Data) -> Text = Data ; atom_string(Data, Text) ),
    ( string_length(Text, Bytes), max_frame_bytes(Max), Bytes =< Max -> true
    ; throw(error(protocol_error(frame_too_large), _)) ),
    atom_string(Atom, Text),
    catch(atom_json_dict(Atom, Message, []), _, throw(error(protocol_error(invalid_json), _))),
    get_dict(type, Message, Type),
    ( Type == "Transition" -> apply_transition(Message, State0, State)
    ; memberchk(Type, ["Ping", "MutationResponse", "ActionResponse"]) -> State = State0
    ; memberchk(Type, ["FatalError", "AuthError", "TransitionChunk"]) ->
        broadcast_error(protocol_error(Type), State0), retire_socket(Type, State0, State)
    ; broadcast_error(protocol_error(unknown_message(Type)), State0), retire_socket("ProtocolError", State0, State)
    ).

apply_transition(Message, state(WS, Active, Version, Remote0, Count, Last, _Timestamp0, Backoff),
                 state(WS, Active, Version, Remote, Count, Last, Timestamp, Backoff)) :-
    get_dict(startVersion, Message, Start), get_dict(endVersion, Message, End),
    version_term(Start, StartVersion), StartVersion = Remote0,
    get_dict(modifications, Message, Modifications),
    % Validate all modifications before emitting any update.  A malformed
    % transition therefore cannot leak a partially applied reactive state.
    maplist(valid_modification, Modifications),
    version_term(End, Remote), Remote = version(_, _, Timestamp),
    maplist(deliver_modification(Active), Modifications).

version_term(Dict, version(QuerySet, Identity, Timestamp)) :-
    get_dict(querySet, Dict, QuerySet), get_dict(identity, Dict, Identity), get_dict(ts, Dict, Timestamp).

valid_modification(Dict) :-
    get_dict(type, Dict, Type), memberchk(Type, ["QueryUpdated", "QueryFailed", "QueryRemoved"]),
    get_dict(queryId, Dict, Id), integer(Id), Id >= 0,
    ( Type == "QueryUpdated" -> get_dict(value, Dict, _) ; true ).

deliver_modification(_, Dict) :- get_dict(type, Dict, "QueryRemoved"), !.
deliver_modification(Active, Dict) :-
    get_dict(queryId, Dict, Id), member(entry(Id, _, _, Queue, _), Active), !,
    get_dict(type, Dict, Type), response_logs(Dict, Logs),
    ( Type == "QueryUpdated" -> get_dict(value, Dict, Value), Update = update(value(Value), Logs)
    ; ( get_dict(errorMessage, Dict, Message) -> true ; Message = "Live query failed" ),
      ( get_dict(errorData, Dict, Data) -> true ; Data = null ),
      Update = update(error(function_error(query, Message, Data, Logs)), Logs)
    ), bounded_send(Queue, Update).
deliver_modification(_, _).

bounded_send(Queue, Update) :-
    term_string(Update, Text), string_length(Text, Bytes), max_update_bytes(MaxBytes), Bytes =< MaxBytes,
    message_queue_property(Queue, size(Size)), max_update_count(MaxCount),
    ( Size >= MaxCount -> thread_get_message(Queue, _, [timeout(0)]) ; true ),
    thread_send_message(Queue, Update).

broadcast_error(Error, state(_, Active, _, _, _, _, _, _)) :-
    forall(member(entry(_, _, _, Queue, _), Active), bounded_send(Queue, update(error(Error), []))).

retire_socket(Reason, state(WS, Active, _, _, Count0, _, Timestamp, Backoff0),
              state(none, Active, 0, Remote, Count, Reason, Timestamp, Backoff)) :-
    ( WS == none -> Count = Count0 ; catch(ws_close(WS, 1001, Reason), _, true), Count is Count0 + 1 ),
    initial_timestamp(Zero), Remote = version(0, 0, Zero), Backoff is min(Backoff0 * 2, 15000).

close_state(state(WS, Active, _, _, _, _, _, _)) :-
    ( WS == none -> true ; catch(ws_close(WS, 1000, "client closed"), _, true) ),
    forall(member(entry(_, _, _, Queue, _), Active), message_queue_destroy(Queue)).

ws_json_send(WS, Dict) :-
    with_output_to(string(Text), json_write_dict(current_output, Dict, [width(0)])),
    ws_send(WS, text(Text)).

/* Convex counter examples deliberately accept whole JSON numbers like 1.0
   but reject quoted, fractional, non-finite, and out-of-range values. */
integer_json(Number, Integer) :-
    number(Number), float(Number), Number =:= floor(Number),
    Number >= -9007199254740991, Number =< 9007199254740991, !, Integer is floor(Number).
integer_json(Integer, Integer) :- integer(Integer), Integer >= -9007199254740991, Integer =< 9007199254740991.

timestamp_newer(Newer, Older) :-
    string_codes(Newer, NewerCodes), string_codes(Older, OlderCodes),
    phrase(base64(BytesNewer), NewerCodes), phrase(base64(BytesOlder), OlderCodes),
    little_endian_uint(BytesNewer, New), little_endian_uint(BytesOlder, Old), New > Old.

little_endian_uint(Bytes, Value) :- little_endian_uint(Bytes, 0, 1, Value).
little_endian_uint([], Value, _, Value).
little_endian_uint([Byte|Rest], Acc0, Factor, Value) :-
    Acc is Acc0 + Byte * Factor, NextFactor is Factor * 256,
    little_endian_uint(Rest, Acc, NextFactor, Value).
