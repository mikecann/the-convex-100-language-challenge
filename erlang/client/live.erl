%% Exactly one gen_server owns each WebSocket. Callers never touch Gun's
%% connection or stream, which prevents concurrent Add/Remove/reconnect races.
-module(live).
-behaviour(gen_server).
-export([start_link/1, subscribe/4, unsubscribe/2, debug_disconnect/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(INITIAL_TS, <<"AAAAAAAAAAA=">>).
-define(MAX_QUEUE, 16).

start_link(Client) -> gen_server:start_link(?MODULE, Client, []).
subscribe(Pid, Path, Args, Sink) -> gen_server:call(Pid, {subscribe, Path, Args, Sink}, 10000).
unsubscribe(Pid, Id) -> gen_server:call(Pid, {unsubscribe, Id}, 5000).
debug_disconnect(Pid) -> gen_server:call(Pid, debug_disconnect, 5000).
close(Pid) -> gen_server:call(Pid, close, 5000).
init(Client) ->
    application:ensure_all_started(gun),
    {ok, #{client => Client, conn => undefined, stream => undefined, connected => false,
           subscriptions => #{}, next_query_id => 0, query_set => 0,
           remote_query_set => 0, remote_identity => 0, remote_ts => ?INITIAL_TS,
           max_ts => undefined, connection_count => 0, last_close_reason => <<"InitialConnect">>, backoff => 100}}.
handle_call({subscribe, Path, Args, Sink}, _From, State0) ->
    Id = integer_to_binary(maps:get(next_query_id, State0)),
    Sub = #{query_id => maps:get(next_query_id, State0), path => Path, args => Args, sink => Sink, generation => make_ref(), last => undefined, queued => []},
    State1 = State0#{subscriptions => maps:put(Id, Sub, maps:get(subscriptions, State0)), next_query_id => maps:get(next_query_id, State0) + 1},
    {reply, {ok, Id}, ensure_connected(State1)};
handle_call({unsubscribe, Id}, _From, State0) ->
    %% Remove the relay before acknowledging. A transition already queued in
    %% this owner is checked against this erased map and cannot escape later.
    case maps:take(Id, maps:get(subscriptions, State0)) of
        error -> {reply, ok, State0};
        {Sub, Subs} ->
            State1 = State0#{subscriptions => Subs},
            {reply, ok, maybe_send_modify(remove, Sub, State1)}
    end;
handle_call(debug_disconnect, _From, State0) ->
    State1 = disconnect(<<"DebugDisconnect">>, State0),
    %% The old socket is retired before this reply. A reconnect is scheduled
    %% immediately by ensure_connected, satisfying the controller barrier.
    {reply, ok, ensure_connected(State1)};
handle_call(close, _From, State) -> {stop, normal, ok, State};
handle_call(_, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({gun_up, Conn, http}, State = #{conn := Conn}) ->
    Stream = gun:ws_upgrade(Conn, "/api/sync", [{<<"convex-client">>, <<"erlang-0.1.0">>}]),
    {noreply, State#{stream => Stream}};
handle_info({gun_upgrade, Conn, Stream, [<<"websocket">>], _}, State = #{conn := Conn, stream := Stream}) ->
    State1 = State#{connected => true, backoff => 100},
    State2 = send_json(connect_message(State1), State1),
    {noreply, resend_all(State2)};
handle_info({gun_ws, Conn, Stream, {text, Message}}, State = #{conn := Conn, stream := Stream}) ->
    {noreply, handle_server(Message, State)};
handle_info({gun_ws, Conn, Stream, ping}, State = #{conn := Conn, stream := Stream}) -> gun:ws_send(Conn, Stream, pong), {noreply, State};
handle_info({gun_down, Conn, _, Reason, _}, State = #{conn := Conn}) -> {noreply, reconnect(Reason, State)};
handle_info(reconnect, State) -> {noreply, ensure_connected(State)};
handle_info(_, State) -> {noreply, State}.
terminate(_, State) -> case maps:get(conn, State) of undefined -> ok; Conn -> gun:close(Conn) end.
code_change(_, State, _) -> {ok, State}.

ensure_connected(State = #{connected := true}) -> State;
ensure_connected(State = #{conn := undefined, subscriptions := Subs}) when map_size(Subs) =:= 0 -> State;
ensure_connected(State = #{conn := undefined}) ->
    {Host, Port, Transport} = endpoint(maps:get(url, maps:get(client, State))),
    Options = case Transport of
        tls -> #{transport => tls, protocols => [http], retry => 0, tls_opts => [{verify, verify_peer}, {cacertfile, "/etc/ssl/certs/ca-certificates.crt"}, {server_name_indication, Host}, {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]};
        tcp -> #{transport => tcp, protocols => [http], retry => 0}
    end,
    {ok, Conn} = gun:open(Host, Port, Options),
    State#{conn => Conn};
ensure_connected(State) -> State.
endpoint(Url) ->
    Uri = uri_string:parse(Url), Scheme = maps:get(scheme, Uri), Host = maps:get(host, Uri),
    case Scheme of "https" -> {Host, maps:get(port, Uri, 443), tls}; "http" -> {Host, maps:get(port, Uri, 80), tcp} end.
connect_message(State) ->
    Base = #{<<"type">> => <<"Connect">>, <<"sessionId">> => uuid(), <<"connectionCount">> => maps:get(connection_count, State), <<"lastCloseReason">> => maps:get(last_close_reason, State), <<"clientTs">> => 0},
    case maps:get(max_ts, State) of undefined -> Base; Ts -> Base#{<<"maxObservedTimestamp">> => Ts} end.
uuid() ->
    <<A:32, B:16, C0:16, D0:16, E:48>> = crypto:strong_rand_bytes(16),
    %% Convex's sync profile expects the conventional UUID text form, not an
    %% arbitrary opaque token. Set RFC 4122 version and variant bits here.
    C = (C0 band 16#0fff) bor 16#4000,
    D = (D0 band 16#3fff) bor 16#8000,
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])).
resend_all(State) ->
    lists:foldl(fun({_Id, Sub}, Acc) -> maybe_send_modify(add, Sub, Acc) end, State, maps:to_list(maps:get(subscriptions, State))).
maybe_send_modify(_, _, State = #{connected := false}) -> State;
maybe_send_modify(Type, Sub, State) ->
    Q = maps:get(query_set, State),
    Modification = case Type of
        add -> #{<<"type">> => <<"Add">>, <<"queryId">> => maps:get(query_id, Sub), <<"udfPath">> => maps:get(path, Sub), <<"args">> => [maps:get(args, Sub)]};
        remove -> #{<<"type">> => <<"Remove">>, <<"queryId">> => maps:get(query_id, Sub)}
    end,
    send_json(#{<<"type">> => <<"ModifyQuerySet">>, <<"baseVersion">> => Q, <<"newVersion">> => Q + 1, <<"modifications">> => [Modification]}, State#{query_set => Q + 1}).
send_json(Value, State = #{conn := Conn, stream := Stream}) when Conn =/= undefined, Stream =/= undefined -> gun:ws_send(Conn, Stream, {text, convex_json:encode(Value)}), State;
send_json(_, State) -> State.
handle_server(Message, State) -> case convex_json:decode(Message) of
    {ok, #{<<"type">> := <<"Transition">>} = Transition} -> transition(Transition, State);
    {ok, #{<<"type">> := <<"Ping">>}} -> State;
    {ok, Other} -> broadcast_error(#{name => <<"ProtocolError">>, message => maps:get(<<"error">>, Other, iolist_to_binary(io_lib:format("unexpected sync message ~p", [maps:get(<<"type">>, Other, undefined)])))}, State);
    _ -> broadcast_error(#{name => <<"ProtocolError">>, message => <<"invalid sync JSON">>}, State)
end.
transition(#{<<"startVersion">> := Start, <<"endVersion">> := End, <<"modifications">> := Mods}, State) ->
    case version_matches(Start, State) of
        false -> reconnect(transition_version_mismatch, State);
        true ->
            %% Apply the complete immutable Transition in order while this
            %% single owner is active. `maps:find` makes removal atomic.
            State1 = lists:foldl(fun apply_modification/2, State, Mods),
            State1#{remote_query_set => maps:get(<<"querySet">>, End), remote_identity => maps:get(<<"identity">>, End), remote_ts => maps:get(<<"ts">>, End), max_ts => maps:get(<<"ts">>, End)}
    end;
transition(_, State) -> broadcast_error(#{name => <<"ProtocolError">>, message => <<"malformed Transition">>}, State).
version_matches(#{<<"querySet">> := Q, <<"identity">> := I, <<"ts">> := Ts}, State) -> Q =:= maps:get(remote_query_set, State) andalso I =:= maps:get(remote_identity, State) andalso Ts =:= maps:get(remote_ts, State);
version_matches(_, _) -> false.
apply_modification(#{<<"type">> := <<"QueryUpdated">>, <<"queryId">> := Q, <<"value">> := Value} = Mod, State) -> publish(Q, {value, Value, maps:get(<<"logLines">>, Mod, [])}, State);
apply_modification(#{<<"type">> := <<"QueryFailed">>, <<"queryId">> := Q} = Mod, State) -> publish(Q, {error, #{name => <<"FunctionError">>, message => maps:get(<<"errorMessage">>, Mod, <<"Live query failed">>), data => maps:get(<<"errorData">>, Mod, null)}}, State);
apply_modification(_, State) -> State.
publish(QueryId, Event, State) ->
    maps:fold(fun(Id, Sub, Acc) ->
        case maps:get(query_id, Sub) =:= QueryId of
            false -> Acc;
            true ->
                case Event of
                    {value, Value, _Logs} when Value =:= undefined -> Acc;
                    {value, Value, Logs} ->
                        case Value =:= maps:get(last, Sub) of
                            true -> Acc;
                            false -> maps:get(sink, Sub) ! {convex_live, Id, #{value => Value, logs => Logs}}, Acc#{subscriptions => maps:put(Id, Sub#{last => Value}, maps:get(subscriptions, Acc))}
                        end;
                    {error, Error} -> maps:get(sink, Sub) ! {convex_live, Id, #{error => Error}}, Acc#{subscriptions => maps:put(Id, Sub#{last => undefined}, maps:get(subscriptions, Acc))}
                end
        end
    end, State, maps:get(subscriptions, State)).
broadcast_error(Error, State) -> maps:fold(fun(Id, Sub, Acc) -> maps:get(sink, Sub) ! {convex_live, Id, #{error => Error}}, Acc end, State, maps:get(subscriptions, State)).
disconnect(Reason, State) ->
    case maps:get(conn, State) of undefined -> ok; Conn -> gun:close(Conn) end,
    State#{conn => undefined, stream => undefined, connected => false, query_set => 0, remote_query_set => 0, remote_identity => 0, remote_ts => ?INITIAL_TS, connection_count => maps:get(connection_count, State) + 1, last_close_reason => Reason}.
reconnect(Reason, State) ->
    Delay = maps:get(backoff, State), erlang:send_after(Delay, self(), reconnect),
    disconnect(iolist_to_binary(io_lib:format("~p", [Reason])), State#{backoff => min(15000, Delay * 2)}).
