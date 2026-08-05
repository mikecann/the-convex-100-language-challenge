%% One gen_server exclusively owns the WebSocket and all Convex sync state.
%% Per-subscription relays can be slow, but they must ask this owner for
%% generation permission immediately before delivery. That makes replacement
%% and unsubscribe acknowledgements real barriers, not timing assumptions.
-module(live).
-behaviour(gen_server).
-export([start_link/1, subscribe/4, unsubscribe/2, debug_disconnect/1, close/1]).
-ifdef(TEST).
-export([debug_subscription/2]).
-endif.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(INITIAL_TS, <<"AAAAAAAAAAA=">>).
-define(MAX_QUEUE_COUNT, 16).
-define(MAX_QUEUE_BYTES, 262144).
-define(INITIAL_BACKOFF, 100).
-define(MAX_BACKOFF, 15000).
-define(HANDSHAKE_TIMEOUT, 1000).

start_link(Client) -> gen_server:start_link(?MODULE, Client, []).
subscribe(Pid, Path, Args, Sink) -> gen_server:call(Pid, {subscribe, Path, Args, Sink}, 5000).
unsubscribe(Pid, Id) -> gen_server:call(Pid, {unsubscribe, Id}, 5000).
debug_disconnect(Pid) -> gen_server:call(Pid, debug_disconnect, 5000).
close(Pid) -> gen_server:call(Pid, close, 5000).

-ifdef(TEST).
%% Queue introspection exists only in the separately compiled test BEAM.
debug_subscription(Pid, Id) -> gen_server:call(Pid, {debug_subscription, Id}, 5000).
-endif.

init(Client) ->
    application:ensure_all_started(gun),
    {ok, #{client => Client, conn => undefined, stream => undefined,
           connected => false, subscriptions => #{}, next_query_id => 0,
           query_set => 0, remote_query_set => 0, remote_identity => 0,
           remote_ts => ?INITIAL_TS, max_ts => undefined,
           connection_count => 0, last_close_reason => <<"InitialConnect">>,
           backoff => ?INITIAL_BACKOFF, reconnect_timer => undefined,
           handshake_timer => undefined}}.

handle_call({subscribe, Path, Args, Sink}, _From, State0) ->
    QueryId = maps:get(next_query_id, State0),
    Id = integer_to_binary(QueryId),
    Generation = make_ref(),
    Owner = self(),
    Gate = relay_gate(maps:get(client, State0)),
    Relay = spawn(fun() -> relay_loop(Owner, Gate) end),
    Sub = #{query_id => QueryId, path => Path, args => Args, sink => Sink,
            generation => Generation, relay => Relay, last => undefined,
            queue => queue:new(), queue_count => 0, queue_bytes => 0,
            relay_busy => false, inflight => false,
            inflight_token => undefined, inflight_bytes => 0},
    State1 = State0#{subscriptions => maps:put(Id, Sub, maps:get(subscriptions, State0)),
                     next_query_id => QueryId + 1},
    {reply, {ok, Id}, ensure_connected(State1)};
handle_call({unsubscribe, Id}, _From, State0) ->
    case maps:take(Id, maps:get(subscriptions, State0)) of
        error -> {reply, ok, State0};
        {Sub, Subs} ->
            %% Erase the generation before killing the relay and writing Remove.
            %% A dequeued event can no longer obtain delivery permission.
            exit(maps:get(relay, Sub), kill),
            State1 = State0#{subscriptions => Subs},
            {reply, ok, maybe_send_modify(remove, Sub, State1)}
    end;
handle_call({relay_delivery, Id, Generation, Token, Event}, _From, State) ->
    case maps:find(Id, maps:get(subscriptions, State)) of
        {ok, #{generation := Generation, inflight_token := Token, sink := Sink}} ->
            Sink ! {convex_live, Id, Event},
            {reply, deliver, State};
        _ ->
            {reply, discard, State}
    end;
handle_call(debug_disconnect, _From, State0) ->
    %% gun:close/1 synchronously retires the old connection process. Only then
    %% do we acknowledge and begin the replacement connection.
    State1 = disconnect(<<"adapter debug disconnect">>, State0),
    {reply, ok, ensure_connected(State1)};
handle_call(close, _From, State) ->
    {stop, normal, ok, State};
handle_call(Request, From, State) -> handle_test_call(Request, From, State).

-ifdef(TEST).
handle_test_call({debug_subscription, Id}, _From, State) ->
    Reply = case maps:find(Id, maps:get(subscriptions, State)) of
        {ok, Sub} -> #{queue_count => maps:get(queue_count, Sub) + inflight_count(Sub),
                       queue_bytes => maps:get(queue_bytes, Sub) + maps:get(inflight_bytes, Sub),
                       inflight => maps:get(inflight, Sub)};
        error -> undefined
    end,
    {reply, Reply, State};
handle_test_call(_, _From, State) -> {reply, {error, unsupported}, State}.
-else.
handle_test_call(_, _From, State) -> {reply, {error, unsupported}, State}.
-endif.

handle_cast(_, State) -> {noreply, State}.

handle_info({gun_up, Conn, http}, State = #{conn := Conn}) ->
    Stream = gun:ws_upgrade(Conn, "/api/sync", [{<<"convex-client">>, <<"erlang-0.1.0">>}]),
    Timer = erlang:send_after(?HANDSHAKE_TIMEOUT, self(), {handshake_timeout, Conn}),
    {noreply, State#{stream => Stream, handshake_timer => Timer}};
handle_info({gun_upgrade, Conn, Stream, [<<"websocket">>], _},
            State = #{conn := Conn, stream := Stream}) ->
    %% A completed WebSocket upgrade is a healthy transport boundary. Do not
    %% make a later brief outage inherit backoff accumulated by failed handshakes.
    State1 = cancel_handshake(State#{connected => true, backoff => ?INITIAL_BACKOFF}),
    State2 = send_json(connect_message(State1), State1),
    {noreply, resend_all(State2)};
handle_info({gun_response, Conn, Stream, _, Status, _},
            State = #{conn := Conn, stream := Stream}) ->
    Message =
        iolist_to_binary(
          io_lib:format("WebSocket upgrade returned HTTP ~p", [Status])),
    {noreply, protocol_reconnect(Message, State)};
handle_info({gun_error, Conn, Stream, Reason},
            State = #{conn := Conn, stream := Stream}) ->
    {noreply, transport_reconnect(Reason, State)};
handle_info({gun_ws, Conn, Stream, {text, Message}},
            State = #{conn := Conn, stream := Stream}) ->
    {noreply, handle_server(Message, State)};
handle_info({gun_ws, Conn, Stream, ping}, State = #{conn := Conn, stream := Stream}) ->
    gun:ws_send(Conn, Stream, pong),
    {noreply, State};
handle_info({gun_ws, Conn, Stream, {ping, Data}}, State = #{conn := Conn, stream := Stream}) ->
    gun:ws_send(Conn, Stream, {pong, Data}),
    {noreply, State};
handle_info({gun_ws, Conn, Stream, pong}, State = #{conn := Conn, stream := Stream}) ->
    {noreply, State};
handle_info({gun_ws, Conn, Stream, {pong, _}}, State = #{conn := Conn, stream := Stream}) ->
    {noreply, State};
handle_info({gun_ws, Conn, Stream, close}, State = #{conn := Conn, stream := Stream}) ->
    {noreply, transport_reconnect(<<"WebSocket close">>, State)};
handle_info({gun_ws, Conn, Stream, {close, Code, Reason}},
            State = #{conn := Conn, stream := Stream}) ->
    Detail = iolist_to_binary(io_lib:format("WebSocket close ~p: ~ts", [Code, Reason])),
    {noreply, transport_reconnect(Detail, State)};
handle_info({gun_down, Conn, _, Reason, _}, State = #{conn := Conn}) ->
    {noreply, transport_reconnect(Reason, State)};
handle_info({handshake_timeout, Conn}, State = #{conn := Conn, connected := false}) ->
    {noreply, transport_reconnect(handshake_timeout,
                                  State#{handshake_timer => undefined})};
handle_info({handshake_timeout, _}, State) -> {noreply, State};
handle_info({reconnect, Token}, State = #{reconnect_timer := {_, Token}}) ->
    {noreply, ensure_connected(State#{reconnect_timer => undefined})};
handle_info({reconnect, _}, State) -> {noreply, State};
handle_info({relay_ready, Id, Generation, Token}, State0) ->
    case maps:find(Id, maps:get(subscriptions, State0)) of
        {ok, #{generation := Generation} = Sub0} ->
            %% relay_busy tracks the physical worker independently from the
            %% logical delivery token, which overflow may already invalidate.
            Sub1 = case maps:get(inflight_token, Sub0) of
                Token -> Sub0#{relay_busy => false, inflight => false,
                               inflight_token => undefined, inflight_bytes => 0};
                _ -> Sub0#{relay_busy => false}
            end,
            {Sub2, State1} = dispatch_next(Id, Sub1, State0),
            {noreply, put_sub(Id, Sub2, State1)};
        _ -> {noreply, State0}
    end;
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    cancel_timer(maps:get(reconnect_timer, State)),
    cancel_timer(maps:get(handshake_timer, State)),
    maps:foreach(fun(_, Sub) -> exit(maps:get(relay, Sub), kill) end,
                 maps:get(subscriptions, State)),
    case maps:get(conn, State) of undefined -> ok; Conn -> gun:close(Conn) end.

code_change(_, State, _) -> {ok, State}.

-ifdef(TEST).
relay_gate(Client) -> maps:get(relay_test_gate, Client, undefined).
-else.
relay_gate(_Client) -> undefined.
-endif.

relay_loop(Owner, Gate) ->
    receive
        {event, Id, Generation, Token, Event} ->
            relay_test_barrier(Gate, Id, Event),
            _ = try gen_server:call(Owner, {relay_delivery, Id, Generation, Token, Event}, 5000)
                catch exit:_ -> discard
                end,
            Owner ! {relay_ready, Id, Generation, Token},
            relay_loop(Owner, Gate)
    end.

-ifdef(TEST).
relay_test_barrier(undefined, _Id, _Event) -> ok;
relay_test_barrier(Gate, Id, Event) ->
    Gate ! {relay_dequeued, self(), Id, Event},
    receive {relay_release, Gate} -> ok end.
-else.
relay_test_barrier(_Gate, _Id, _Event) -> ok.
-endif.

ensure_connected(State = #{connected := true}) -> State;
ensure_connected(State = #{conn := undefined, subscriptions := Subs}) when map_size(Subs) =:= 0 -> State;
ensure_connected(State = #{conn := undefined}) ->
    {Host, Port, Transport} = endpoint(maps:get(url, maps:get(client, State))),
    Common = #{protocols => [http], retry => 0, connect_timeout => ?HANDSHAKE_TIMEOUT},
    Options = case Transport of
        tls -> Common#{transport => tls,
                       tls_opts => [{verify, verify_peer},
                                    {cacertfile, "/etc/ssl/certs/ca-certificates.crt"},
                                    {server_name_indication, Host},
                                    {customize_hostname_check,
                                     [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]};
        tcp -> Common#{transport => tcp}
    end,
    case gun:open(Host, Port, Options) of
        {ok, Conn} -> State#{conn => Conn};
        {error, Reason} -> transport_reconnect(Reason, State)
    end;
ensure_connected(State) -> State.

endpoint(Url) ->
    Uri = uri_string:parse(Url),
    Scheme = maps:get(scheme, Uri),
    Host = maps:get(host, Uri),
    case Scheme of
        "https" -> {Host, maps:get(port, Uri, 443), tls};
        "http" -> {Host, maps:get(port, Uri, 80), tcp}
    end.

connect_message(State) ->
    Base = #{<<"type">> => <<"Connect">>, <<"sessionId">> => uuid(),
             <<"connectionCount">> => maps:get(connection_count, State),
             <<"lastCloseReason">> => maps:get(last_close_reason, State),
             <<"clientTs">> => 0},
    case maps:get(max_ts, State) of
        undefined -> Base;
        Ts -> Base#{<<"maxObservedTimestamp">> => Ts}
    end.

uuid() ->
    <<A:32, B:16, C0:16, D0:16, E:48>> = crypto:strong_rand_bytes(16),
    C = (C0 band 16#0fff) bor 16#4000,
    D = (D0 band 16#3fff) bor 16#8000,
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
                                  [A, B, C, D, E])).

resend_all(State) ->
    lists:foldl(fun({_Id, Sub}, Acc) -> maybe_send_modify(add, Sub, Acc) end,
                State, lists:keysort(1, maps:to_list(maps:get(subscriptions, State)))).

maybe_send_modify(_, _, State = #{connected := false}) -> State;
maybe_send_modify(Type, Sub, State) ->
    Q = maps:get(query_set, State),
    Modification = case Type of
        add -> #{<<"type">> => <<"Add">>, <<"queryId">> => maps:get(query_id, Sub),
                 <<"udfPath">> => maps:get(path, Sub), <<"args">> => [maps:get(args, Sub)]};
        remove -> #{<<"type">> => <<"Remove">>, <<"queryId">> => maps:get(query_id, Sub)}
    end,
    send_json(#{<<"type">> => <<"ModifyQuerySet">>, <<"baseVersion">> => Q,
                <<"newVersion">> => Q + 1, <<"modifications">> => [Modification]},
              State#{query_set => Q + 1}).

send_json(Value, State = #{conn := Conn, stream := Stream})
  when Conn =/= undefined, Stream =/= undefined ->
    ok = gun:ws_send(Conn, Stream, {text, convex_json:encode(Value)}),
    State;
send_json(_, State) -> State.

handle_server(Message, State) ->
    case convex_json:decode(Message) of
        {ok, #{<<"type">> := <<"Transition">>} = Transition} -> transition(Transition, State);
        {ok, #{<<"type">> := <<"Ping">>}} -> State;
        {ok, Other} ->
            Detail = maps:get(<<"error">>, Other,
                              iolist_to_binary(io_lib:format("unexpected sync message ~p",
                                                            [maps:get(<<"type">>, Other, undefined)]))),
            protocol_reconnect(Detail, State);
        _ -> protocol_reconnect(<<"invalid sync JSON">>, State)
    end.

transition(#{<<"startVersion">> := Start, <<"endVersion">> := End,
             <<"modifications">> := Mods}, State) when is_list(Mods) ->
    case {version_matches(Start, State), valid_version(End), valid_modifications(Mods)} of
        {true, true, true} ->
            %% Collect the complete immutable Transition before touching
            %% subscriber state. Multiple modifications for one query collapse
            %% to its final result, exactly as an atomic query-set transition.
            Changes = lists:foldl(fun collect_change/2, #{}, Mods),
            State1 = State#{remote_query_set => maps:get(<<"querySet">>, End),
                            remote_identity => maps:get(<<"identity">>, End),
                            remote_ts => maps:get(<<"ts">>, End),
                            max_ts => observed_max(maps:get(max_ts, State), maps:get(<<"ts">>, End)),
                            backoff => ?INITIAL_BACKOFF},
            lists:foldl(fun apply_change/2, State1, lists:keysort(1, maps:to_list(Changes)));
        _ -> protocol_reconnect(<<"transition version mismatch">>, State)
    end;
transition(_, State) -> protocol_reconnect(<<"malformed Transition">>, State).

valid_version(#{<<"querySet">> := Q, <<"identity">> := I, <<"ts">> := Ts}) ->
    is_integer(Q) andalso is_integer(I) andalso is_binary(Ts) andalso
    timestamp_number(Ts) =/= error;
valid_version(_) -> false.

%% Validate every modification before applying any of them. A malformed tail
%% must not leak an earlier value from the same Transition or advance version
%% metadata, because the server transition is atomic.
valid_modifications(Mods) -> lists:all(fun valid_modification/1, Mods).

valid_modification(#{<<"type">> := <<"QueryUpdated">>, <<"queryId">> := Q,
                     <<"value">> := _}) -> is_integer(Q);
valid_modification(#{<<"type">> := <<"QueryFailed">>, <<"queryId">> := Q,
                     <<"errorMessage">> := Message}) ->
    is_integer(Q) andalso is_binary(Message);
valid_modification(#{<<"type">> := <<"QueryRemoved">>, <<"queryId">> := Q}) ->
    is_integer(Q);
valid_modification(_) -> false.

version_matches(#{<<"querySet">> := Q, <<"identity">> := I, <<"ts">> := Ts}, State) ->
    Q =:= maps:get(remote_query_set, State) andalso
    I =:= maps:get(remote_identity, State) andalso
    Ts =:= maps:get(remote_ts, State);
version_matches(_, _) -> false.

collect_change(#{<<"type">> := <<"QueryUpdated">>, <<"queryId">> := Q,
                 <<"value">> := Value} = Mod, Changes) ->
    maps:put(Q, {value, Value, maps:get(<<"logLines">>, Mod, [])}, Changes);
collect_change(#{<<"type">> := <<"QueryFailed">>, <<"queryId">> := Q} = Mod, Changes) ->
    Error = #{name => <<"FunctionError">>,
              message => maps:get(<<"errorMessage">>, Mod, <<"Live query failed">>),
              data => maps:get(<<"errorData">>, Mod, null),
              logs => maps:get(<<"logLines">>, Mod, [])},
    maps:put(Q, {error, Error}, Changes);
collect_change(#{<<"type">> := <<"QueryRemoved">>, <<"queryId">> := Q}, Changes) ->
    maps:put(Q, removed, Changes).

apply_change({QueryId, removed}, State) -> clear_last(QueryId, State);
apply_change({QueryId, Event}, State) -> publish(QueryId, Event, State).

clear_last(QueryId, State0) ->
    case find_subscription(QueryId, maps:to_list(maps:get(subscriptions, State0))) of
        none -> State0;
        {Id, Sub} -> put_sub(Id, Sub#{last => undefined}, State0)
    end.

publish(QueryId, Event, State0) ->
    case find_subscription(QueryId, maps:to_list(maps:get(subscriptions, State0))) of
        none -> State0;
        {Id, Sub0} ->
            Last = maps:get(last, Sub0),
            case Event of
                {value, Value, _} when Value =:= Last -> State0;
                {value, Value, Logs} ->
                    Sub1 = enqueue(Id, #{value => Value, logs => Logs}, Sub0#{last => Value}),
                    put_sub(Id, Sub1, State0);
                {error, Error} ->
                    Sub1 = enqueue(Id, #{error => Error}, Sub0#{last => undefined}),
                    put_sub(Id, Sub1, State0)
            end
    end.

find_subscription(_, []) -> none;
find_subscription(QueryId, [{Id, #{query_id := QueryId} = Sub} | _]) -> {Id, Sub};
find_subscription(QueryId, [_ | Rest]) -> find_subscription(QueryId, Rest).

enqueue(Id, Event, Sub0) ->
    Bytes = byte_size(convex_json:encode(Event)),
    case Bytes > ?MAX_QUEUE_BYTES of
        true -> Sub0;
        false -> enqueue_bounded(Id, Event, Bytes, Sub0)
    end.

enqueue_bounded(Id, Event, Bytes,
                Sub = #{relay_busy := false, relay := Relay, generation := Generation}) ->
    Token = make_ref(),
    Relay ! {event, Id, Generation, Token, Event},
    Sub#{relay_busy => true, inflight => true,
         inflight_token => Token, inflight_bytes => Bytes};
enqueue_bounded(_Id, Event, Bytes, Sub0) ->
    trim_pipeline(queue:in({Event, Bytes}, maps:get(queue, Sub0)),
                  maps:get(queue_count, Sub0) + 1,
                  maps:get(queue_bytes, Sub0) + Bytes,
                  Sub0).

trim_pipeline(Queue, Count, Bytes, Sub = #{inflight := true})
  when Count + 1 =< ?MAX_QUEUE_COUNT,
       Bytes + map_get(inflight_bytes, Sub) =< ?MAX_QUEUE_BYTES ->
    Sub#{queue => Queue, queue_count => Count, queue_bytes => Bytes};
trim_pipeline(Queue, Count, Bytes, Sub = #{inflight := false})
  when Count =< ?MAX_QUEUE_COUNT, Bytes =< ?MAX_QUEUE_BYTES ->
    Sub#{queue => Queue, queue_count => Count, queue_bytes => Bytes};
trim_pipeline(Queue, Count, Bytes, Sub = #{inflight := true}) ->
    %% The held relay event is the oldest. Logically invalidate its delivery
    %% token first so overflow really retains the newest events.
    trim_pipeline(Queue, Count, Bytes,
                  Sub#{inflight => false, inflight_token => undefined,
                       inflight_bytes => 0});
trim_pipeline(Queue0, Count, Bytes, Sub) ->
    {{value, {_Dropped, DroppedBytes}}, Queue1} = queue:out(Queue0),
    trim_pipeline(Queue1, Count - 1, Bytes - DroppedBytes, Sub).

dispatch_next(Id, Sub0, State) ->
    case queue:out(maps:get(queue, Sub0)) of
        {empty, _} -> {Sub0, State};
        {{value, {Event, Bytes}}, Queue1} ->
            Token = make_ref(),
            maps:get(relay, Sub0) ! {event, Id, maps:get(generation, Sub0), Token, Event},
            {Sub0#{queue => Queue1, queue_count => maps:get(queue_count, Sub0) - 1,
                   queue_bytes => maps:get(queue_bytes, Sub0) - Bytes,
                   relay_busy => true, inflight => true, inflight_token => Token,
                   inflight_bytes => Bytes}, State}
    end.

put_sub(Id, Sub, State) ->
    State#{subscriptions => maps:put(Id, Sub, maps:get(subscriptions, State))}.

broadcast_error(Error, State0) ->
    maps:fold(fun(Id, Sub0, Acc) ->
                      Sub1 = enqueue(Id, #{error => Error}, Sub0),
                      put_sub(Id, Sub1, Acc)
              end, State0, maps:get(subscriptions, State0)).

protocol_reconnect(Message, State0) ->
    Error = #{name => <<"ProtocolError">>, message => Message},
    Reason = {protocol_error, Message},
    schedule_reconnect(Reason, disconnect(Reason, broadcast_error(Error, State0))).

%% Transport failures are observable subscription events as well as reconnect
%% triggers. The adapter-forced disconnect deliberately bypasses this helper,
%% because that command is an acknowledged test action rather than a failure.
transport_reconnect(Reason, State0) ->
    Error = #{name => <<"TransportError">>, message => reason_binary(Reason)},
    schedule_reconnect(Reason, disconnect(Reason, broadcast_error(Error, State0))).

disconnect(Reason, State0) ->
    cancel_timer(maps:get(reconnect_timer, State0)),
    State1 = cancel_handshake(State0),
    case maps:get(conn, State1) of undefined -> ok; Conn -> gun:close(Conn) end,
    State1#{conn => undefined, stream => undefined, connected => false,
            query_set => 0, remote_query_set => 0, remote_identity => 0,
            remote_ts => ?INITIAL_TS,
            connection_count => maps:get(connection_count, State1) + 1,
            last_close_reason => reason_binary(Reason), reconnect_timer => undefined}.

schedule_reconnect(Reason, State = #{subscriptions := Subs}) when map_size(Subs) =:= 0 ->
    State#{last_close_reason => reason_binary(Reason)};
schedule_reconnect(Reason, State = #{reconnect_timer := undefined}) ->
    Delay = maps:get(backoff, State),
    Token = make_ref(),
    Ref = erlang:send_after(Delay, self(), {reconnect, Token}),
    State#{reconnect_timer => {Ref, Token}, backoff => min(?MAX_BACKOFF, Delay * 2),
           last_close_reason => reason_binary(Reason)};
schedule_reconnect(_, State) -> State.

cancel_handshake(State) ->
    cancel_timer(maps:get(handshake_timer, State)),
    State#{handshake_timer => undefined}.

cancel_timer(undefined) -> ok;
cancel_timer({Ref, _}) -> erlang:cancel_timer(Ref), ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref), ok.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

-ifdef(TEST).
inflight_count(#{inflight := true}) -> 1;
inflight_count(_) -> 0.
-endif.

observed_max(undefined, New) -> New;
observed_max(Current, New) ->
    case {timestamp_number(Current), timestamp_number(New)} of
        {{ok, A}, {ok, B}} when A >= B -> Current;
        _ -> New
    end.

timestamp_number(Timestamp) ->
    try
        case base64:decode(Timestamp) of
            <<Number:64/little-unsigned-integer>> -> {ok, Number};
            _ -> error
        end
    catch _:_ -> error
    end.
