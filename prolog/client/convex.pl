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

:- use_module(library(base64)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(http/websocket)).
:- use_module(library(lists)).
:- use_module(library(uri)).
:- use_module(library(uuid)).

/*
  This educational client implements Convex behaviour in Prolog. HTTP uses the
  documented JSON API. One owner thread exclusively performs every Live read,
  write, reconnect, and query-set change for the pinned /api/sync profile.
*/

client_version("prolog-0.2.0").
initial_timestamp("AAAAAAAAAAA=").
max_frame_bytes(2097152).
max_pending_count(16).
max_pending_bytes(16777216).
socket_read_timeout(0.50).
socket_write_timeout(1.0).
initial_backoff(0.10).
maximum_backoff(15.0).

new_client(URLInput, client(URL, "", Version)) :-
    text_string(URLInput, URL0),
    uri_components(URL0, Components),
    uri_data(scheme, Components, Scheme),
    (   memberchk(Scheme, [http, https])
    ->  true
    ;   throw(error(domain_error(convex_url_scheme, Scheme), _))
    ),
    uri_data(authority, Components, Authority),
    Authority \= '',
    (   sub_string(URL0, _, 1, 0, "/")
    ->  sub_string(URL0, 0, _, 1, URL)
    ;   URL = URL0
    ),
    client_version(Version).

text_string(Text, String) :-
    (   string(Text)
    ->  String = Text
    ;   atom(Text)
    ->  atom_string(Text, String)
    ;   must_be(string, Text)
    ).

with_auth(client(URL, _, Version), Token, client(URL, Token, Version)) :-
    must_be(string, Token).

query(Client, Path, Args, Result) :-
    call_http(Client, query, Path, Args, Result).

mutation(Client, Path, Args, Result) :-
    call_http(Client, mutation, Path, Args, Result).

action(Client, Path, Args, Result) :-
    call_http(Client, action, Path, Args, Result).

call_http(client(Base, Token, Version), Operation, Path, Args, Result) :-
    must_be(string, Path),
    Path \= "",
    is_dict(Args),
    atom_string(Operation, OperationText),
    string_concat(Base, "/api/", Prefix),
    string_concat(Prefix, OperationText, URL),
    Request = _{path:Path, args:Args, format:"json"},
    request_headers(Token, Version, Headers),
    catch(
        http_post(
            URL,
            json(Request),
            Response,
            [ json_object(dict),
              status_code(Status),
              timeout(15),
              request_header('Accept'='application/json')
            | Headers
            ]
        ),
        Error,
        throw(error(transport_error(Operation, Error), _))
    ),
    decode_http_response(Operation, Status, Response, Result).

request_headers("", Version, [request_header('Convex-Client'=Version)]).
request_headers(Token, Version, Headers) :-
    Token \= "",
    string_concat("Bearer ", Token, Authorization),
    Headers =
        [ request_header('Convex-Client'=Version),
          request_header('Authorization'=Authorization)
        ].

decode_http_response(_, _, Response, result(Value, Logs)) :-
    get_dict(status, Response, "success"),
    get_dict(value, Response, Value),
    strict_logs(Response, Logs),
    !.
decode_http_response(Operation, _, Response, _) :-
    get_dict(status, Response, "error"),
    strict_logs(Response, Logs),
    (   get_dict(errorMessage, Response, Message), string(Message)
    ->  true
    ;   Message = "Convex function failed"
    ),
    (get_dict(errorData, Response, Data) -> true ; Data = null),
    throw(error(function_error(Operation, Message, Data, Logs), _)).
decode_http_response(_, Status, Response, _) :-
    throw(error(protocol_error(http_response(Status, Response)), _)).

strict_logs(Dict, Logs) :-
    (   get_dict(logLines, Dict, Candidate)
    ->  string_list(Candidate),
        Logs = Candidate
    ;   Logs = []
    ).

string_list(Value) :-
    is_list(Value),
    maplist(string, Value).

/* Live public API ------------------------------------------------------- */

live_start(Client, live(Commands, Thread)) :-
    message_queue_create(Commands),
    thread_create(live_owner(Commands, Client), Thread, [detached(false)]).

live_subscribe(live(Commands, _), Path, Args, Subscription) :-
    must_be(string, Path),
    Path \= "",
    is_dict(Args),
    message_queue_create(Updates),
    request_owner(
        Commands,
        subscribe(Path, Args, Updates),
        12,
        Reply
    ),
    (   Reply = ok(Id)
    ->  Subscription = subscription(Id, Updates, Commands)
    ;   message_queue_destroy(Updates),
        throw(Reply)
    ).

subscription_next(
    subscription(_, Updates, Commands),
    TimeoutSeconds,
    Update
) :-
    thread_get_message(
        Updates,
        queued(Serial, Bytes, Update),
        [timeout(TimeoutSeconds)]
    ),
    thread_send_message(Commands, released(Serial, Bytes)).

subscription_close(subscription(Id, Updates, Commands)) :-
    request_owner(Commands, unsubscribe(Id, Updates), 3, Reply),
    (Reply == ok -> true ; throw(Reply)).

live_debug_disconnect(live(Commands, _)) :-
    request_owner(Commands, debug_disconnect, 3, Reply),
    (Reply == ok -> true ; throw(Reply)).

live_close(live(Commands, Thread)) :-
    request_owner(Commands, close, 3, Reply),
    (Reply == closed -> true ; throw(Reply)),
    thread_join(Thread, _),
    message_queue_destroy(Commands).

request_owner(Commands, Operation, Timeout, ReplyValue) :-
    message_queue_create(Reply),
    setup_call_cleanup(
        thread_send_message(Commands, command(Operation, Reply)),
        thread_get_message(Reply, ReplyValue, [timeout(Timeout)]),
        message_queue_destroy(Reply)
    ).

/* Live owner ------------------------------------------------------------ */

live_owner(Commands, Client) :-
    initial_state(State),
    catch(
        live_loop(Commands, Client, State),
        Error,
        print_message(error, Error)
    ).

initial_state(State) :-
    initial_timestamp(Zero),
    initial_backoff(Backoff),
    State = live_state{
        ws:none,
        active:[],
        next_id:0,
        query_version:0,
        remote:version(0, 0, Zero, 0),
        connection_count:0,
        last_close:"InitialConnect",
        max_timestamp:timestamp(0, Zero),
        backoff:Backoff,
        retry_at:0.0,
        pending:[],
        pending_count:0,
        pending_bytes:0,
        next_serial:0
    }.

live_loop(Commands, Client, State0) :-
    maybe_reconnect(Client, State0, State1),
    (   thread_get_message(Commands, Message, [timeout(0.01)])
    ->  handle_owner_message(Message, Client, State1, State2, Continue)
    ;   poll_socket(State1, State2),
        Continue = continue
    ),
    (   Continue == stop
    ->  close_state(State2)
    ;   live_loop(Commands, Client, State2)
    ).

handle_owner_message(released(Serial, Bytes), _, State0, State, continue) :-
    release_pending(Serial, Bytes, State0, State).
handle_owner_message(command(Operation, Reply), Client, State0, State, Continue) :-
    catch(
        handle_command(Operation, Client, State0, State, Continue, ReplyValue),
        Error,
        ( State = State0,
          Continue = continue,
          ReplyValue = Error
        )
    ),
    thread_send_message(Reply, ReplyValue).

handle_command(
    subscribe(Path, Args, Updates),
    Client,
    State0,
    State,
    continue,
    Reply
) :-
    Id = State0.next_id,
    NextId is Id + 1,
    Sub = sub(Id, Path, Args, Updates, none),
    append(State0.active, [Sub], Active),
    Candidate = State0.put(_{active:Active, next_id:NextId}),
    catch(
        subscribe_state(Client, State0, Candidate, Sub, Connected),
        Error,
        true
    ),
    (   var(Error)
    ->  State = Connected,
        Reply = ok(Id)
    ;   % Once an ID is allocated it is never reused, even if the transport
        % fails while adding it. Retire a possibly half-written connection so
        % the next generation cannot collide with a server-side ghost Add.
        WithoutNew = State0.put(next_id, NextId),
        (   State0.ws == none
        ->  State = WithoutNew
        ;   retire_socket("AddWriteFailed", WithoutNew, State)
        ),
        Reply = Error
    ).

handle_command(
    unsubscribe(Id, Updates),
    _,
    State0,
    State,
    continue,
    ok
) :-
    remove_subscription(Id, State0.active, Active, Removed),
    drop_queue_pending(Updates, State0, WithoutPending),
    Candidate = WithoutPending.put(active, Active),
    remove_remote_subscription(Removed, Candidate, State),
    message_queue_destroy(Updates).
handle_command(debug_disconnect, _, State0, State, continue, ok) :-
    (   State0.ws == none
    ->  throw(error(transport_error(debug_disconnect, "Live is not connected"), _))
    ;   retire_socket("DebugDisconnect", State0, State)
    ).
handle_command(close, _, State, State, stop, closed).

subscribe_state(Client, State0, Candidate, Sub, State) :-
    ensure_initial_connection(Client, Candidate, Connected),
    (   State0.ws == none
    ->  State = Connected
    ;   add_remote_subscription(Sub, Connected, State)
    ).

ensure_initial_connection(_, State, State) :-
    State.ws \= none,
    !.
ensure_initial_connection(Client, State0, State) :-
    catch(connect_state(Client, State0, State), Error, true),
    (   var(Error)
    ->  true
    ;   throw(error(transport_error(live_connect, Error), _))
    ).

maybe_reconnect(_, State, State) :-
    (State.ws \= none ; State.active == []),
    !.
maybe_reconnect(Client, State0, State) :-
    get_time(Now),
    (   Now < State0.retry_at
    ->  State = State0
    ;   catch(connect_state(Client, State0, Connected), _, fail)
    ->  State = Connected
    ;   schedule_retry("ConnectFailed", State0, State)
    ).

connect_state(Client, State0, State) :-
    State0.max_timestamp = timestamp(_, Timestamp),
    open_live_socket(
        Client,
        State0.connection_count,
        State0.last_close,
        Timestamp,
        WS
    ),
    install_active(WS, State0.active, QueryVersion),
    initial_timestamp(Zero),
    initial_backoff(Backoff),
    State = State0.put(_{
        ws:WS,
        query_version:QueryVersion,
        remote:version(0, 0, Zero, 0),
        backoff:Backoff,
        retry_at:0.0
    }).

open_live_socket(client(Base, _, Version), Count, Last, Timestamp, WS) :-
    ws_url(Base, URL),
    http_open_websocket(
        URL,
        WS,
        [ timeout(3),
          request_header('Convex-Client'=Version)
        ]
    ),
    stream_pair(WS, Read, Write),
    socket_read_timeout(ReadTimeout),
    socket_write_timeout(WriteTimeout),
    set_stream(Read, timeout(ReadTimeout)),
    set_stream(Write, timeout(WriteTimeout)),
    uuid(SessionUUID),
    atom_string(SessionUUID, SessionId),
    Connect = _{
        type:"Connect",
        sessionId:SessionId,
        connectionCount:Count,
        lastCloseReason:Last,
        maxObservedTimestamp:Timestamp,
        clientTs:0
    },
    catch(ws_json_send(WS, Connect), Error, (force_close(WS), throw(Error))).

ws_url(Base, URL) :-
    uri_components(Base, Components0),
    uri_data(scheme, Components0, Scheme0),
    (Scheme0 == http -> Scheme = ws ; Scheme = wss),
    uri_data(path, Components0, Path0),
    string_concat(Path0, "/api/sync", Path),
    uri_data(scheme, Components0, Scheme, Components1),
    uri_data(path, Components1, Path, Components),
    uri_components(URL, Components).

install_active(_, [], 0).
install_active(WS, Active, 1) :-
    additions(Active, Adds),
    ws_json_send(WS, _{
        type:"ModifyQuerySet",
        baseVersion:0,
        newVersion:1,
        modifications:Adds
    }).

additions([], []).
additions([sub(Id, Path, Args, _, _)|Rest], [Add|Adds]) :-
    Add = _{type:"Add", queryId:Id, udfPath:Path, args:[Args]},
    additions(Rest, Adds).

add_remote_subscription(_, State, State) :-
    State.ws == none,
    !.
add_remote_subscription(sub(Id, Path, Args, _, _), State0, State) :-
    Version is State0.query_version + 1,
    Add = _{type:"Add", queryId:Id, udfPath:Path, args:[Args]},
    ws_json_send(State0.ws, _{
        type:"ModifyQuerySet",
        baseVersion:State0.query_version,
        newVersion:Version,
        modifications:[Add]
    }),
    State = State0.put(query_version, Version).

remove_remote_subscription(none, State, State) :-
    !.
remove_remote_subscription(_, State, State) :-
    State.ws == none,
    !.
remove_remote_subscription(sub(Id, _, _, _, _), State0, State) :-
    Version is State0.query_version + 1,
    Remove = _{type:"Remove", queryId:Id},
    catch(
        ws_json_send(State0.ws, _{
            type:"ModifyQuerySet",
            baseVersion:State0.query_version,
            newVersion:Version,
            modifications:[Remove]
        }),
        _,
        fail
    ),
    !,
    State = State0.put(query_version, Version).
remove_remote_subscription(_, State0, State) :-
    retire_socket("RemoveWriteFailed", State0, State).

remove_subscription(_, [], [], none).
remove_subscription(Id, [Sub|Rest], Active, Removed) :-
    Sub = sub(SubId, _, _, _, _),
    (   Id =:= SubId
    ->  Active = Rest,
        Removed = Sub
    ;   Active = [Sub|Next],
        remove_subscription(Id, Rest, Next, Removed)
    ).

/* Poll only when bytes are available. If a partial frame stalls after any byte
   has been consumed, the stream timeout aborts the whole connection, so the
   parser can never restart at a false frame boundary. */
poll_socket(State, State) :-
    State.ws == none,
    !.
poll_socket(State0, State) :-
    stream_pair(State0.ws, Read, _),
    wait_for_input([Read], Ready, 0),
    (   Ready == []
    ->  State = State0
    ;   catch(ws_receive_one(State0.ws, Message), Error, true),
        (   var(Error)
        ->  handle_socket_message(Message, State0, State)
        ;   error_text(Error, ErrorText),
            broadcast_error(
                error(transport_error(live_read, ErrorText), _),
                State0,
                WithError
            ),
            retire_socket("ReadFailed", WithError, State)
        )
    ).

/* SWI's public ws_receive/2 recursively waits after every Ping. Reading one
   frame at a time keeps the owner responsive even when a peer sends control
   frames continuously. These predicates are the same low-level primitives
   used by the standard library's public wrapper. */
ws_receive_one(WS, Message) :-
    websocket:ws_read_header(WS, Code, RSV),
    (   Code == end_of_file
    ->  Message = websocket{opcode:close, data:end_of_file}
    ;   (websocket:ws_opcode(OpCode, Code) -> true ; OpCode = Code),
        websocket:read_data(OpCode, WS, Data, []),
        (   RSV =:= 0
        ->  true
        ;   throw(error(protocol_error(reserved_websocket_bits(RSV)), _))
        ),
        (   OpCode == ping
        ->  websocket:reply_pong(WS, Data.data),
            Message = websocket{opcode:ping, data:Data.data}
        ;   Message = Data
        )
    ).

handle_socket_message(Message, State0, State) :-
    (   Message.opcode == text
    ->  catch(
            handle_server_message(Message.data, State0, State),
            Error,
            ( broadcast_error(Error, State0, WithError),
              retire_socket("ProtocolError", WithError, State)
            )
        )
    ;   Message.opcode == close
    ->  broadcast_error(
            error(transport_error(live_read, "peer closed"), _),
            State0,
            WithError
        ),
        retire_socket("PeerClosed", WithError, State)
    ;   State = State0
    ).

handle_server_message(Data, State0, State) :-
    text_string(Data, Text),
    utf8_length(Text, Bytes),
    max_frame_bytes(MaxFrame),
    (Bytes =< MaxFrame -> true ; throw(error(protocol_error(frame_too_large), _))),
    atom_string(Atom, Text),
    catch(
        atom_json_dict(Atom, Message, []),
        _,
        throw(error(protocol_error(invalid_json), _))
    ),
    (   get_dict(type, Message, Type), string(Type)
    ->  true
    ;   throw(error(protocol_error(missing_message_type), _))
    ),
    handle_server_type(Type, Message, State0, State).

handle_server_type("Transition", Message, State0, State) :-
    apply_transition(Message, State0, State).
handle_server_type(Type, _, State, State) :-
    memberchk(Type, ["Ping", "MutationResponse", "ActionResponse"]),
    !.
handle_server_type(Type, Message, _, _) :-
    memberchk(Type, ["FatalError", "AuthError"]),
    (get_dict(error, Message, Detail) -> true ; Detail = Type),
    throw(error(protocol_error(server(Type, Detail)), _)).
handle_server_type("TransitionChunk", _, _, _) :-
    throw(error(protocol_error(transition_chunk_not_supported), _)).
handle_server_type(Type, _, _, _) :-
    throw(error(protocol_error(unknown_message(Type)), _)).

apply_transition(Message, State0, State) :-
    validate_transition(Message, State0, EndVersion, EndTimestamp, Updates),
    deliver_updates(Updates, State0, Delivered),
    State = Delivered.put(_{
        remote:EndVersion,
        max_timestamp:EndTimestamp,
        backoff:0.10
    }).

validate_transition(Message, State, EndVersion, EndTimestamp, Updates) :-
    (   validate_transition_fields(
            Message,
            State,
            EndVersion,
            EndTimestamp,
            Updates
        )
    ->  true
    ;   throw(error(protocol_error(invalid_transition), _))
    ).

validate_transition_fields(Message, State, EndVersion, EndTimestamp, Updates) :-
    get_dict(startVersion, Message, StartDict),
    get_dict(endVersion, Message, EndDict),
    get_dict(modifications, Message, Modifications),
    is_list(Modifications),
    valid_version(StartDict, StartVersion, StartTimestamp),
    StartVersion = State.remote,
    valid_version(EndDict, EndVersion, EndTimestamp),
    EndTimestamp = timestamp(EndValue, _),
    StartTimestamp = timestamp(StartValue, _),
    State.max_timestamp = timestamp(MaxValue, _),
    EndValue >= StartValue,
    EndValue >= MaxValue,
    maplist(valid_modification, Modifications, Validated),
    coalesce_modifications(Validated, Updates).

valid_version(Dict, version(QuerySet, Identity, Timestamp, Value), TimestampValue) :-
    is_dict(Dict),
    get_dict(querySet, Dict, QuerySet),
    get_dict(identity, Dict, Identity),
    get_dict(ts, Dict, Timestamp),
    uint32(QuerySet),
    uint32(Identity),
    canonical_timestamp(Timestamp, Value),
    TimestampValue = timestamp(Value, Timestamp).

uint32(Value) :-
    integer(Value),
    Value >= 0,
    Value =< 4294967295.

canonical_timestamp(Timestamp, Value) :-
    string(Timestamp),
    string_codes(Timestamp, Encoded),
    catch(phrase(base64(Bytes), Encoded), _, fail),
    length(Bytes, 8),
    phrase(base64(Bytes), CanonicalCodes),
    string_codes(Canonical, CanonicalCodes),
    Canonical == Timestamp,
    little_endian_uint(Bytes, Value).

valid_modification(Dict, modification(Id, removed)) :-
    get_dict(type, Dict, "QueryRemoved"),
    valid_query_id(Dict, Id),
    !.
valid_modification(Dict, modification(Id, update(Update, Key))) :-
    get_dict(type, Dict, "QueryUpdated"),
    valid_query_id(Dict, Id),
    get_dict(value, Dict, Value),
    strict_logs(Dict, Logs),
    Update = update(value(Value), Logs),
    valid_update_size(Update),
    update_key(Update, Key),
    !.
valid_modification(Dict, modification(Id, update(Update, Key))) :-
    get_dict(type, Dict, "QueryFailed"),
    valid_query_id(Dict, Id),
    get_dict(errorMessage, Dict, Message),
    string(Message),
    (get_dict(errorData, Dict, Data) -> true ; Data = null),
    strict_logs(Dict, Logs),
    Error = error(function_error(query, Message, Data, Logs), _),
    Update = update(error(Error), Logs),
    valid_update_size(Update),
    update_key(Update, Key),
    !.
valid_modification(Dict, _) :-
    throw(error(protocol_error(invalid_modification(Dict)), _)).

valid_query_id(Dict, Id) :-
    get_dict(queryId, Dict, Id),
    uint32(Id).

valid_update_size(Update) :-
    update_wire_size(Update, Bytes),
    max_frame_bytes(MaxFrame),
    (   Bytes =< MaxFrame
    ->  true
    ;   throw(error(protocol_error(update_too_large), _))
    ).

coalesce_modifications(Modifications, Coalesced) :-
    foldl(replace_modification, Modifications, [], Reversed),
    reverse(Reversed, Coalesced).

replace_modification(Modification, Acc0, [Modification|Acc]) :-
    Modification = modification(Id, _),
    exclude(modification_id(Id), Acc0, Acc).

modification_id(Id, modification(Id, _)).

deliver_updates([], State, State).
deliver_updates([modification(Id, Change)|Rest], State0, State) :-
    deliver_change(Id, Change, State0, State1),
    deliver_updates(Rest, State1, State).

deliver_change(Id, removed, State0, State) :-
    clear_last_key(Id, State0, State).
deliver_change(Id, update(Update, Key), State0, State) :-
    (   select_sub(Id, State0.active, Sub, Before, After)
    ->  Sub = sub(Id, Path, Args, Queue, LastKey),
        (   LastKey == Key
        ->  State = State0
        ;   enqueue_update(Queue, Update, State0, Queued),
            UpdatedSub = sub(Id, Path, Args, Queue, Key),
            append(Before, [UpdatedSub|After], Active),
            State = Queued.put(active, Active)
        )
    ;   State = State0
    ).

select_sub(Id, [Sub|Rest], Found, [], Rest) :-
    Sub = sub(Id, _, _, _, _),
    Found = Sub,
    !.
select_sub(Id, [Sub|Rest], Found, [Sub|Before], After) :-
    select_sub(Id, Rest, Found, Before, After).

clear_last_key(Id, State0, State) :-
    (   select_sub(Id, State0.active, sub(Id, Path, Args, Queue, _), Before, After)
    ->  append(Before, [sub(Id, Path, Args, Queue, none)|After], Active),
        State = State0.put(active, Active)
    ;   State = State0
    ).

update_key(update(value(Value), Logs), Key) :-
    json_text(_{kind:"value", value:Value, logs:Logs}, Key).
update_key(update(error(Error), Logs), Key) :-
    error_payload(Error, ErrorPayload),
    json_text(_{kind:"error", error:ErrorPayload, logs:Logs}, Key).

enqueue_update(Queue, Update, State0, State) :-
    update_wire_size(Update, Bytes),
    max_frame_bytes(MaxFrame),
    (Bytes =< MaxFrame -> true ; throw(error(protocol_error(update_too_large), _))),
    Serial = State0.next_serial,
    NextSerial is Serial + 1,
    Pending0 = State0.pending,
    Count0 is State0.pending_count + 1,
    Bytes0 is State0.pending_bytes + Bytes,
    append(Pending0, [pending(Serial, Queue, Bytes)], Pending1),
    trim_pending(Pending1, Count0, Bytes0, Pending, Count, TotalBytes),
    thread_send_message(Queue, queued(Serial, Bytes, Update)),
    State = State0.put(_{
        pending:Pending,
        pending_count:Count,
        pending_bytes:TotalBytes,
        next_serial:NextSerial
    }).

trim_pending(Pending0, Count0, Bytes0, Pending, Count, Bytes) :-
    max_pending_count(MaxCount),
    max_pending_bytes(MaxBytes),
    (   Count0 =< MaxCount,
        Bytes0 =< MaxBytes
    ->  Pending = Pending0,
        Count = Count0,
        Bytes = Bytes0
    ;   Pending0 = [pending(Serial, Queue, OldBytes)|Rest],
        (   thread_get_message(
                Queue,
                queued(Serial, OldBytes, _),
                [timeout(0)]
            )
        ->  true
        ;   true
        ),
        NextCount is Count0 - 1,
        NextBytes is Bytes0 - OldBytes,
        trim_pending(Rest, NextCount, NextBytes, Pending, Count, Bytes)
    ).

release_pending(Serial, Bytes, State0, State) :-
    (   select(pending(Serial, _, Bytes), State0.pending, Pending)
    ->  Count is State0.pending_count - 1,
        TotalBytes is State0.pending_bytes - Bytes,
        State = State0.put(_{
            pending:Pending,
            pending_count:Count,
            pending_bytes:TotalBytes
        })
    ;   State = State0
    ).

drop_queue_pending(Queue, State0, State) :-
    partition(pending_queue(Queue), State0.pending, Dropped, Pending),
    dropped_totals(Dropped, DroppedCount, DroppedBytes),
    Count is State0.pending_count - DroppedCount,
    Bytes is State0.pending_bytes - DroppedBytes,
    State = State0.put(_{
        pending:Pending,
        pending_count:Count,
        pending_bytes:Bytes
    }).

pending_queue(Queue, pending(_, Queue, _)).

dropped_totals([], 0, 0).
dropped_totals([pending(_, _, Bytes)|Rest], Count, TotalBytes) :-
    dropped_totals(Rest, RestCount, RestBytes),
    Count is RestCount + 1,
    TotalBytes is RestBytes + Bytes.

broadcast_error(Error, State0, State) :-
    update_key(update(error(Error), []), Key),
    findall(
        modification(Id, update(update(error(Error), []), Key)),
        member(sub(Id, _, _, _, _), State0.active),
        Updates
    ),
    deliver_updates(Updates, State0, State).

retire_socket(Reason, State0, State) :-
    (   State0.ws == none
    ->  Count = State0.connection_count
    ;   force_close(State0.ws),
        Count is State0.connection_count + 1
    ),
    initial_timestamp(Zero),
    get_time(Now),
    RetryAt is Now + State0.backoff,
    maximum_backoff(MaxBackoff),
    NextBackoff is min(State0.backoff * 2, MaxBackoff),
    State = State0.put(_{
        ws:none,
        query_version:0,
        remote:version(0, 0, Zero, 0),
        connection_count:Count,
        last_close:Reason,
        backoff:NextBackoff,
        retry_at:RetryAt
    }).

schedule_retry(Reason, State0, State) :-
    get_time(Now),
    RetryAt is Now + State0.backoff,
    maximum_backoff(MaxBackoff),
    NextBackoff is min(State0.backoff * 2, MaxBackoff),
    Count is State0.connection_count + 1,
    State = State0.put(_{
        connection_count:Count,
        last_close:Reason,
        backoff:NextBackoff,
        retry_at:RetryAt
    }).

close_state(State) :-
    (State.ws == none -> true ; force_close(State.ws)),
    forall(
        member(sub(_, _, _, Queue, _), State.active),
        catch(message_queue_destroy(Queue), _, true)
    ).

force_close(WS) :-
    catch(close(WS, [force(true)]), _, true).

ws_json_send(WS, Dict) :-
    json_text(Dict, Text),
    utf8_length(Text, Bytes),
    max_frame_bytes(MaxFrame),
    (Bytes =< MaxFrame -> true ; throw(error(transport_error(live_write, "frame too large"), _))),
    socket_write_timeout(Timeout),
    catch(
        call_with_time_limit(Timeout, ws_send(WS, text(Text))),
        Error,
        throw(error(transport_error(live_write, Error), _))
    ).

json_text(Dict, Text) :-
    with_output_to(
        string(Text),
        json_write_dict(current_output, Dict, [width(0)])
    ).

utf8_length(Text, Bytes) :-
    string_bytes(Text, Encoded, utf8),
    length(Encoded, Bytes).

update_wire_size(update(value(Value), Logs), Bytes) :-
    json_text(_{type:"subscription", subscriptionId:"x", value:Value, logs:Logs}, Text),
    utf8_length(Text, Encoded),
    Bytes is Encoded + 256.
update_wire_size(update(error(Error), Logs), Bytes) :-
    error_payload(Error, Payload),
    json_text(_{type:"subscription", subscriptionId:"x", error:Payload, logs:Logs}, Text),
    utf8_length(Text, Encoded),
    Bytes is Encoded + 256.

error_payload(error(function_error(_, Message, Data, _), _), Payload) :-
    !,
    Payload = _{name:"FunctionError", message:Message, data:Data}.
error_payload(error(protocol_error(Detail), _), Payload) :-
    !,
    error_text(Detail, Message),
    Payload = _{name:"ProtocolError", message:Message}.
error_payload(error(transport_error(_, Detail), _), Payload) :-
    !,
    error_text(Detail, Message),
    Payload = _{name:"TransportError", message:Message}.
error_payload(Error, Payload) :-
    error_text(Error, Message),
    Payload = _{name:"Error", message:Message}.

error_text(Error, Text) :-
    catch(message_to_string(Error, Text), _, Text = "unknown error").

/* Numeric helpers ------------------------------------------------------- */

integer_json(Number, Integer) :-
    float(Number),
    Number =:= floor(Number),
    Number >= -9007199254740991,
    Number =< 9007199254740991,
    !,
    Integer is floor(Number).
integer_json(Integer, Integer) :-
    integer(Integer),
    Integer >= -9007199254740991,
    Integer =< 9007199254740991.

timestamp_newer(Newer, Older) :-
    canonical_timestamp(Newer, New),
    canonical_timestamp(Older, Old),
    New > Old.

little_endian_uint(Bytes, Value) :-
    little_endian_uint(Bytes, 0, 1, Value).

little_endian_uint([], Value, _, Value).
little_endian_uint([Byte|Rest], Acc0, Factor, Value) :-
    Acc is Acc0 + Byte * Factor,
    NextFactor is Factor * 256,
    little_endian_uint(Rest, Acc, NextFactor, Value).
