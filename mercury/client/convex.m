%-----------------------------------------------------------------------------%
% convex: the Convex-specific client. Everything below this line is the
% actual demonstration: the HTTP envelope, the pinned sync protocol's
% message shapes, its version and timestamp validation, and how a Live
% transition becomes a delivered update. convex_transport supplies bytes;
% this module supplies meaning.
%
% Determinism is not decoration here. `http_call` is `det`: every failure
% mode (a bad response, a function error, a dropped connection) is a value,
% not an exception, because the adapter that drives this client must report
% each one as a distinct structured event. `validate_transition`, by
% contrast, is `semidet`: an invalid transition is a protocol violation the
% caller must treat as fatal to the connection, which is exactly what
% "fails instead of returning" means for a live sync client.
%-----------------------------------------------------------------------------%
:- module convex.
:- interface.

:- import_module convex_json.
:- import_module convex_transport.
:- import_module io.
:- import_module list.

%-----------------------------------------------------------------------------%
% HTTP: query, mutation, action.
%-----------------------------------------------------------------------------%

:- type client.

:- pred new_client(string::in, string::out, client::out) is semidet.
    % new_client(DeploymentUrl, NormalizedUrl, Client) strips a trailing
    % slash and rejects a URL without an http(s) scheme or host.

:- pred set_auth(string::in, client::in, client::out) is det.
:- pred clear_auth(client::in, client::out) is det.

:- type convex_error
    --->    function_error(string, json, list(string))
                % message, errorData (j_null if absent), logs
    ;       protocol_error(string)
    ;       transport_error(string).

:- type call_result
    --->    call_result(json, list(string)).  % value, logs

:- type maybe_call_result
    --->    call_ok(call_result)
    ;       call_error(convex_error).

:- pred query(client::in, string::in, json::in, maybe_call_result::out,
    io::di, io::uo) is det.
:- pred mutation(client::in, string::in, json::in, maybe_call_result::out,
    io::di, io::uo) is det.
:- pred action(client::in, string::in, json::in, maybe_call_result::out,
    io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
% Live: the pinned /api/sync protocol.
%
% This client owns exactly one subscription lifecycle at a time from the
% adapter's single-threaded reactor loop: connect, add queries, apply
% Transition messages, remove queries, close. There is no background
% worker and no shared mutable state, so the "one owner" rule the shared
% conformance suite cares about is enforced by construction rather than by
% discipline.
%-----------------------------------------------------------------------------%

:- type live_conn.
:- type live_state.

:- type maybe_live
    --->    live_ok(live_conn, live_state)
    ;       live_error(convex_error).

    % Open the sync WebSocket and send the initial Connect message. No
    % queries are active yet.
:- pred live_connect(client::in, maybe_live::out, io::di, io::uo) is det.

:- pred live_close(live_conn::in, io::di, io::uo) is det.

:- func live_fd(live_conn) = int.

    % One delivered change for a single active subscription: either a new
    % value or a structured error, keyed so the adapter can suppress a
    % rehydrated value that repeats the last one it already sent.
:- type live_change
    --->    live_value(int, json, list(string))            % queryId, value, logs
    ;       live_query_error(int, convex_error, list(string)). % queryId, error, logs

:- type live_poll_result
    --->    live_transition(live_state, list(live_change))
    ;       live_ping
    ;       live_ignored
    ;       live_protocol_error(string)
    ;       live_peer_closed
    ;       live_would_block.

    % Read and apply exactly one inbound WebSocket message. Ping and
    % already-handled control frames are consumed by convex_transport; this
    % only ever sees Convex sync-protocol JSON. Call this only after
    % poll_control (or an equivalent readiness check) reports the live
    % connection has bytes waiting.
:- pred live_poll(live_conn::in, live_state::in, live_poll_result::out,
    io::di, io::uo) is det.

    % Add one query to the active set, assigning it the next queryId.
:- pred live_add(live_conn::in, live_state::in, string::in, json::in,
    int::out, live_state::out, maybe_ok::out, io::di, io::uo) is det.

    % Remove a query by id. Silently succeeds if the id is not active
    % (mirrors an idempotent unsubscribe).
:- pred live_remove(live_conn::in, live_state::in, int::in,
    live_state::out, maybe_ok::out, io::di, io::uo) is det.

    % Every currently active (queryId, path, args) triple, e.g. so a caller
    % can re-subscribe them all against a fresh connection after
    % debugDisconnect.
:- type active_sub_info
    --->    active_sub_info(int, string, json).

:- func live_active_list(live_state) = list(active_sub_info).

:- implementation.

:- import_module assoc_list.
:- import_module bool.
:- import_module float.
:- import_module int.
:- import_module maybe.
:- import_module pair.
:- import_module string.

%-----------------------------------------------------------------------------%
% Client and HTTP.
%-----------------------------------------------------------------------------%

:- type client
    --->    client(
                client_url :: string,
                client_auth :: maybe(string)
            ).

:- func client_version = string.

client_version = "mercury-0.1.0".

new_client(UrlIn, Url, client(Url, no)) :-
    ( string.remove_suffix(UrlIn, "/", Trimmed) -> Url = Trimmed ; Url = UrlIn ),
    Url \= "",
    remove_scheme_prefix(Url, AfterScheme),
    string.length(AfterScheme) > 0.

    % Strip whichever scheme prefix is present and confirm a host follows.
:- pred remove_scheme_prefix(string::in, string::out) is semidet.

remove_scheme_prefix(Url, Rest) :-
    ( string.remove_prefix("https://", Url, R) -> Rest = R
    ; string.remove_prefix("http://", Url, R) -> Rest = R
    ; fail
    ).

set_auth(Token, client(Url, _), client(Url, yes(Token))).
clear_auth(client(Url, _), client(Url, no)).

query(Client, Path, Args, Result, !IO) :- http_call("query", Client, Path, Args, Result, !IO).
mutation(Client, Path, Args, Result, !IO) :- http_call("mutation", Client, Path, Args, Result, !IO).
action(Client, Path, Args, Result, !IO) :- http_call("action", Client, Path, Args, Result, !IO).

:- pred http_call(string::in, client::in, string::in, json::in,
    maybe_call_result::out, io::di, io::uo) is det.

http_call(Operation, client(Url, Auth), Path, Args, Result, !IO) :-
    RequestBody = to_json_string(j_object([
        "path" - j_string(Path),
        "args" - Args,
        "format" - j_string("json")
    ])),
    string.format("/api/%s", [s(Operation)], ApiPath),
    ( host_and_path(Url, Host, Port, BasePath) ->
        tls_open(Host, Port, MaybeConn, !IO),
        (
            MaybeConn = tls_ok(Conn),
            AuthHeader = ( Auth = yes(Token) -> "Authorization: Bearer " ++ Token ++ "\r\n" ; "" ),
            Request =
                "POST " ++ BasePath ++ ApiPath ++ " HTTP/1.1\r\n"
                ++ "Host: " ++ Host ++ "\r\n"
                ++ "Content-Type: application/json\r\n"
                ++ "Accept: application/json\r\n"
                ++ "Connection: close\r\n"
                ++ "Convex-Client: " ++ client_version ++ "\r\n"
                ++ AuthHeader
                ++ "Content-Length: " ++ string.int_to_string(string.length(RequestBody))
                ++ "\r\n\r\n" ++ RequestBody,
            tls_write(Conn, Request, WriteResult, !IO),
            (
                WriteResult = ok,
                tls_read_http_response(Conn, Resp, !IO),
                (
                    Resp = http_response(Status, Body),
                    Result = decode_http_response(Status, Body)
                ;
                    Resp = http_transport_error(Msg),
                    Result = call_error(transport_error(Msg))
                )
            ;
                WriteResult = transport_error(Msg),
                Result = call_error(transport_error(Msg))
            ),
            tls_close(Conn, !IO)
        ;
            MaybeConn = tls_error(Msg),
            Result = call_error(transport_error(Msg))
        )
    ;
        Result = call_error(protocol_error("Convex deployment URL omitted a host")),
        true
    ).

:- func decode_http_response(int, string) = maybe_call_result.

decode_http_response(_Status, Body) = Result :-
    ( parse_json(Body, j_object(Fields)) ->
        ( assoc_list.search(Fields, "status", j_string("success")) ->
            ( assoc_list.search(Fields, "value", Value) ->
                Logs = logs_field(Fields),
                Result = call_ok(call_result(Value, Logs))
            ;
                Result = call_error(protocol_error(
                    "Convex HTTP success response omitted a value"))
            )
        ; assoc_list.search(Fields, "status", j_string("error")) ->
            ( assoc_list.search(Fields, "errorMessage", j_string(Message)) ->
                ErrorData = json_lookup_default("errorData", j_object(Fields), j_null),
                Logs = logs_field(Fields),
                Result = call_error(function_error(Message, ErrorData, Logs))
            ;
                Result = call_error(protocol_error(
                    "Convex HTTP error response omitted a string errorMessage"))
            )
        ;
            Result = call_error(protocol_error(
                "Convex HTTP response omitted a recognised status"))
        )
    ;
        Result = call_error(protocol_error("Convex HTTP response was not valid JSON"))
    ).

:- func logs_field(assoc_list(string, json)) = list(string).

logs_field(Fields) = Logs :-
    ( assoc_list.search(Fields, "logLines", LogsJson), json_string_list(LogsJson, Found) ->
        Logs = Found
    ;
        Logs = []
    ).

    % Split "https://host[:port][/path]" into transport host/port and the
    % base path the /api/... suffix is appended to (empty when the URL had
    % none).
:- pred host_and_path(string::in, string::out, int::out, string::out)
    is semidet.

host_and_path(Url, Host, Port, BasePath) :-
    ( string.remove_prefix("https://", Url, R0) -> Rest0 = R0, DefaultPort = 443
    ; string.remove_prefix("http://", Url, R1) -> Rest0 = R1, DefaultPort = 80
    ; fail
    ),
    ( string.sub_string_search(Rest0, "/", SlashPos) ->
        string.split(Rest0, SlashPos, Authority, BasePath)
    ;
        Authority = Rest0, BasePath = ""
    ),
    Authority \= "",
    ( string.sub_string_search(Authority, ":", ColonPos) ->
        string.split(Authority, ColonPos, Host, PortText0),
        ( string.remove_prefix(":", PortText0, PT) -> PortText = PT ; PortText = PortText0 ),
        string.to_int(PortText, Port)
    ;
        Host = Authority,
        Port = DefaultPort
    ),
    Host \= "".

%-----------------------------------------------------------------------------%
% Live.
%-----------------------------------------------------------------------------%

:- type active_sub
    --->    active_sub(
                sub_id :: int,
                sub_path :: string,
                sub_args :: json,
                sub_last_key :: maybe(string)
                    % A digest of the last delivered value/error, so a
                    % rehydrated-but-unchanged value after a reconnect is
                    % suppressed rather than redelivered.
            ).

:- type sync_version
    --->    sync_version(int, int, string).  % querySet, identity, ts (base64)

:- type live_state
    --->    live_state(
                live_query_version :: int,
                live_remote :: sync_version,
                live_next_id :: int,
                live_active :: list(active_sub)
            ).

:- type live_conn
    --->    live_conn(tls_conn).

live_fd(live_conn(Conn)) = tls_fd(Conn).

:- func zero_ts = string.

zero_ts = "AAAAAAAAAAA=".

:- func initial_live_state = live_state.

initial_live_state = live_state(0, sync_version(0, 0, zero_ts), 0, []).

live_connect(client(Url, _), Result, !IO) :-
    ( host_and_path(Url, Host, Port, _BasePath) ->
        tls_open(Host, Port, MaybeConn, !IO),
        (
            MaybeConn = tls_ok(Conn),
            ws_handshake(Conn, Host, "/api/sync", HsResult, !IO),
            (
                HsResult = ok,
                random_hex(16, SessionId, !IO),
                Connect = j_object([
                    "type" - j_string("Connect"),
                    "sessionId" - j_string(SessionId),
                    "connectionCount" - j_number(0.0),
                    "lastCloseReason" - j_null,
                    "clientTs" - j_number(0.0)
                ]),
                ws_send_text(Conn, to_json_string(Connect), SendResult, !IO),
                (
                    SendResult = ok,
                    Result = live_ok(live_conn(Conn), initial_live_state)
                ;
                    SendResult = transport_error(Msg),
                    tls_close(Conn, !IO),
                    Result = live_error(transport_error(Msg))
                )
            ;
                HsResult = transport_error(Msg),
                tls_close(Conn, !IO),
                Result = live_error(transport_error(Msg))
            )
        ;
            MaybeConn = tls_error(Msg),
            Result = live_error(transport_error(Msg))
        )
    ;
        Result = live_error(protocol_error("Convex deployment URL omitted a host"))
    ).

live_close(live_conn(Conn), !IO) :- tls_close(Conn, !IO).

live_add(live_conn(Conn), State0, Path, Args, QueryId, State, Result, !IO) :-
    QueryId = State0 ^ live_next_id,
    NewSub = active_sub(QueryId, Path, Args, no),
    Active = State0 ^ live_active ++ [NewSub],
    BaseVersion = State0 ^ live_query_version,
    NewVersion = BaseVersion + 1,
    Modification = j_object([
        "type" - j_string("Add"),
        "queryId" - j_number(float(QueryId)),
        "udfPath" - j_string(Path),
        "args" - j_array([Args])
    ]),
    Message = modify_query_set_message(BaseVersion, NewVersion, [Modification]),
    ws_send_text(Conn, to_json_string(Message), Result, !IO),
    (
        Result = ok,
        State = ((State0 ^ live_active := Active) ^ live_query_version := NewVersion)
            ^ live_next_id := QueryId + 1
    ;
        Result = transport_error(_),
        State = State0 ^ live_next_id := QueryId + 1
    ).

live_remove(live_conn(Conn), State0, QueryId, State, Result, !IO) :-
    ( find_active(State0 ^ live_active, QueryId, _) ->
        Active = list.negated_filter(has_id(QueryId), State0 ^ live_active),
        BaseVersion = State0 ^ live_query_version,
        NewVersion = BaseVersion + 1,
        Modification = j_object([
            "type" - j_string("Remove"),
            "queryId" - j_number(float(QueryId))
        ]),
        Message = modify_query_set_message(BaseVersion, NewVersion, [Modification]),
        ws_send_text(Conn, to_json_string(Message), Result, !IO),
        (
            Result = ok,
            State = (State0 ^ live_active := Active) ^ live_query_version := NewVersion
        ;
            Result = transport_error(_),
            State = State0 ^ live_active := Active
        )
    ;
        State = State0,
        Result = ok
    ).

live_active_list(State) = list.map(to_active_info, State ^ live_active).

:- func to_active_info(active_sub) = active_sub_info.

to_active_info(Sub) = active_sub_info(Sub ^ sub_id, Sub ^ sub_path, Sub ^ sub_args).

:- pred has_id(int::in, active_sub::in) is semidet.

has_id(Id, Sub) :- Sub ^ sub_id = Id.

:- pred find_active(list(active_sub)::in, int::in, active_sub::out)
    is semidet.

find_active([Sub | Rest], Id, Found) :-
    ( Sub ^ sub_id = Id -> Found = Sub ; find_active(Rest, Id, Found) ).

:- func modify_query_set_message(int, int, list(json)) = json.

modify_query_set_message(BaseVersion, NewVersion, Modifications) = j_object([
    "type" - j_string("ModifyQuerySet"),
    "baseVersion" - j_number(float(BaseVersion)),
    "newVersion" - j_number(float(NewVersion)),
    "modifications" - j_array(Modifications)
]).

live_poll(live_conn(Conn), State, Result, !IO) :-
    ws_recv(Conn, 0, Event, !IO),
    (
        Event = ws_text(Text),
        ( parse_json(Text, Message) ->
            ( json_lookup("type", Message, j_string(Kind)) ->
                ( Kind = "Transition" ->
                    ( apply_transition(State, Message, NewState, Changes) ->
                        Result = live_transition(NewState, Changes)
                    ;
                        Result = live_protocol_error("invalid Transition message")
                    )
                ; Kind = "Ping" ->
                    Result = live_ping
                ; ( Kind = "MutationResponse" ; Kind = "ActionResponse" ) ->
                    Result = live_ignored
                ; Kind = "TransitionChunk" ->
                    Result = live_protocol_error(
                        "TransitionChunk assembly is not implemented")
                ; ( Kind = "FatalError" ; Kind = "AuthError" ) ->
                    Result = live_protocol_error("server reported " ++ Kind)
                ;
                    Result = live_protocol_error("unexpected sync message: " ++ Kind)
                )
            ;
                Result = live_protocol_error("sync message omitted a string type")
            )
        ;
            Result = live_protocol_error("sync message was not valid JSON")
        )
    ;
        Event = ws_timeout,
        Result = live_would_block
    ;
        Event = ws_peer_closed,
        Result = live_peer_closed
    ;
        Event = ws_recv_error(Msg),
        Result = live_protocol_error(Msg)
    ).

    % Validate startVersion/endVersion against local state, decode every
    % modification, coalesce repeats of the same queryId (only the final
    % modification for a query in one Transition is observable), and
    % deliver each surviving change against the active subscription list.
:- pred apply_transition(live_state::in, json::in, live_state::out,
    list(live_change)::out) is semidet.

apply_transition(State0, Message, State, Changes) :-
    json_lookup("startVersion", Message, StartJson),
    json_lookup("endVersion", Message, EndJson),
    json_lookup("modifications", Message, j_array(ModJson)),
    parse_sync_version(StartJson, Start),
    Start = State0 ^ live_remote,
    parse_sync_version(EndJson, End),
    version_order_ok(Start, End),
    map_parse_modification(ModJson, Parsed),
    coalesce_modifications(Parsed, Coalesced),
    deliver_all(Coalesced, State0 ^ live_active, Active, Changes),
    State = (State0 ^ live_remote := End) ^ live_active := Active.

:- pred parse_sync_version(json::in, sync_version::out) is semidet.

parse_sync_version(j_object(Fields), sync_version(QuerySet, Identity, Ts)) :-
    assoc_list.search(Fields, "querySet", QsJson),
    json_integral_int(QsJson, QuerySet),
    QuerySet >= 0, QuerySet =< 4294967295,
    assoc_list.search(Fields, "identity", IdJson),
    json_integral_int(IdJson, Identity),
    Identity >= 0, Identity =< 4294967295,
    assoc_list.search(Fields, "ts", j_string(Ts)),
    base64_decode_ts8(Ts, _).

:- pred version_order_ok(sync_version::in, sync_version::in) is semidet.

version_order_ok(sync_version(QS0, Id0, Ts0), sync_version(QS1, Id1, Ts1)) :-
    QS1 >= QS0,
    Id1 >= Id0,
    ts_value(Ts1) >= ts_value(Ts0).

    % The Live timestamp is an 8-byte little-endian counter; only relative
    % order matters here, never its absolute value. Decoding happens
    % directly to this integer (never through a Mercury string) because the
    % raw bytes may contain an embedded zero.
:- func ts_value(string) = int.

ts_value(Ts) = Value :-
    ( base64_decode_ts8(Ts, Decoded) -> Value = Decoded ; Value = 0 ).

:- type parsed_change
    --->    change_updated(int, json, list(string))
    ;       change_failed(int, string, json, list(string))
    ;       change_removed(int).

:- func change_id(parsed_change) = int.

change_id(change_updated(Id, _, _)) = Id.
change_id(change_failed(Id, _, _, _)) = Id.
change_id(change_removed(Id)) = Id.

:- pred map_parse_modification(list(json)::in, list(parsed_change)::out)
    is semidet.

map_parse_modification([], []).
map_parse_modification([J | Js], [P | Ps]) :-
    parse_modification(J, P),
    map_parse_modification(Js, Ps).

:- pred parse_modification(json::in, parsed_change::out) is semidet.

parse_modification(j_object(Fields), Change) :-
    assoc_list.search(Fields, "queryId", QidJson),
    json_integral_int(QidJson, QueryId),
    QueryId >= 0,
    assoc_list.search(Fields, "type", j_string(Kind)),
    ( Kind = "QueryUpdated" ->
        assoc_list.search(Fields, "value", Value),
        Logs = logs_field(Fields),
        Change = change_updated(QueryId, Value, Logs)
    ; Kind = "QueryFailed" ->
        assoc_list.search(Fields, "errorMessage", j_string(Message)),
        ErrorData = json_lookup_default("errorData", j_object(Fields), j_null),
        Logs = logs_field(Fields),
        Change = change_failed(QueryId, Message, ErrorData, Logs)
    ; Kind = "QueryRemoved" ->
        Change = change_removed(QueryId)
    ;
        fail
    ).

    % Keep only the last modification per queryId (a later entry for the
    % same query in one Transition fully supersedes an earlier one), while
    % preserving each surviving id's first-seen relative order.
:- pred coalesce_modifications(list(parsed_change)::in,
    list(parsed_change)::out) is det.

coalesce_modifications(Modifications, Coalesced) :-
    list.foldl(replace_modification, Modifications, [], Reversed),
    list.reverse(Reversed, Coalesced).

:- pred replace_modification(parsed_change::in, list(parsed_change)::in,
    list(parsed_change)::out) is det.

replace_modification(Change, Acc0, [Change | Acc]) :-
    Id = change_id(Change),
    Acc = list.negated_filter(matches_id(Id), Acc0).

:- pred matches_id(int::in, parsed_change::in) is semidet.

matches_id(Id, Change) :- change_id(Change) = Id.

:- pred deliver_all(list(parsed_change)::in, list(active_sub)::in,
    list(active_sub)::out, list(live_change)::out) is det.

deliver_all([], Active, Active, []).
deliver_all([Change | Rest], Active0, Active, AllDelivered) :-
    deliver_one(Change, Active0, Active1, MaybeDelivered),
    deliver_all(Rest, Active1, Active, RestDelivered),
    ( MaybeDelivered = yes(Delivered) -> AllDelivered = [Delivered | RestDelivered]
    ; AllDelivered = RestDelivered
    ).

:- pred deliver_one(parsed_change::in, list(active_sub)::in,
    list(active_sub)::out, maybe(live_change)::out) is det.

deliver_one(change_removed(Id), Active0, Active, no) :-
    Active = list.map(clear_key_if(Id), Active0).

deliver_one(change_updated(Id, Value, Logs), Active0, Active, Delivered) :-
    Key = "v:" ++ to_json_string(Value) ++ "|" ++ string.join_list(",", Logs),
    deliver_keyed(Id, Key, live_value(Id, Value, Logs), Active0, Active, Delivered).

deliver_one(change_failed(Id, Message, ErrorData, Logs), Active0, Active, Delivered) :-
    Key = "e:" ++ Message ++ "|" ++ to_json_string(ErrorData)
        ++ "|" ++ string.join_list(",", Logs),
    Error = function_error(Message, ErrorData, Logs),
    deliver_keyed(Id, Key, live_query_error(Id, Error, Logs), Active0, Active, Delivered).

:- pred deliver_keyed(int::in, string::in, live_change::in,
    list(active_sub)::in, list(active_sub)::out, maybe(live_change)::out)
    is det.

deliver_keyed(Id, Key, Change, Active0, Active, Delivered) :-
    ( find_active(Active0, Id, Sub) ->
        ( Sub ^ sub_last_key = yes(Key) ->
            Active = Active0,
            Delivered = no
        ;
            Active = list.map(set_key_if(Id, Key), Active0),
            Delivered = yes(Change)
        )
    ;
        % A change for a query this connection never asked for (or already
        % removed) is not this client's business to deliver.
        Active = Active0,
        Delivered = no
    ).

:- func clear_key_if(int, active_sub) = active_sub.

clear_key_if(Id, Sub) = Result :-
    ( Sub ^ sub_id = Id -> Result = Sub ^ sub_last_key := no ; Result = Sub ).

:- func set_key_if(int, string, active_sub) = active_sub.

set_key_if(Id, Key, Sub) = Result :-
    ( Sub ^ sub_id = Id -> Result = Sub ^ sub_last_key := yes(Key) ; Result = Sub ).
