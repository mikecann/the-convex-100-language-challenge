%% Deterministic acceptance fixtures use real TCP WebSocket peers. They test
%% Gun's framing path and the public owner calls, not internal state messages.
-module(live_socket_test).
-export([main/0, pressure_main/0, u32_main/0]).

-define(INITIAL_TS, <<"AAAAAAAAAAA=">>).

main() ->
    application:ensure_all_started(crypto),
    fragmented_utf8_control_and_query_failed_recovery(),
    atomic_transition_and_query_removed(),
    five_reconnects_and_hydration_dedup(),
    protocol_error_reconnect(),
    u32_wire_range_reconnect(),
    handshake_resets_accumulated_backoff(),
    five_failed_upgrades_then_success(),
    newest_sixteen_count_overflow(),
    newest_byte_overflow(),
    stale_generation_barrier(),
    stalled_handshake_and_partial_frame_are_bounded(),
    continuous_peer_close_is_bounded(),
    same_id_replacement_barrier(),
    tcp_partial_ndjson_and_eof_cleanup(),
    io:format("live socket tests passed~n").

%% This separate entrypoint makes the review regression cheap to rerun while
%% still exercising Gun and real TCP WebSocket peers.
u32_main() ->
    application:ensure_all_started(crypto),
    u32_wire_range_reconnect(),
    io:format("u32 wire range tests passed~n").

%% Host-side adversarial.sh runs this fixture in the real test image while the
%% final adapter has a 128 MiB cgroup limit. It stops reading controller output
%% after the subscribe ACK and drives real 240 KiB WebSocket transitions until
%% the adapter closes the stalled controller instead of accumulating memory.
pressure_main() ->
    application:ensure_all_started(crypto),
    {ok, Listen} =
        gen_tcp:listen(8081,
                       [binary, {packet, raw}, {active, false}, {reuseaddr, true},
                        {ip, {0, 0, 0, 0}}]),
    Parent = self(),
    _Server = spawn_link(fun() -> pressure_peer(Listen, Parent) end),
    Host =
        case os:getenv("ADAPTER_HOST") of
            false -> "adapter";
            Value -> Value
        end,
    Controller = pressure_connect(Host, 8080, 100),
    send_ndjson(Controller,
                #{<<"id">> => <<"pressure-subscribe">>, <<"op">> => <<"subscribe">>,
                  <<"subscriptionId">> => <<"pressure">>,
                  <<"path">> => <<"demo:state">>, <<"args">> => #{}}),
    #{<<"id">> := <<"pressure-subscribe">>, <<"type">> := <<"ack">>} =
        read_ndjson(Controller),
    %% Intentionally do not call recv again on Controller.
    receive
        {pressure_closed, Count} when Count < 200 -> ok;
        pressure_unbounded -> erlang:error(stopped_controller_was_not_bounded)
    after 10000 -> erlang:error(stopped_controller_was_not_bounded)
    end,
    gen_tcp:close(Controller),
    gen_tcp:close(Listen),
    io:format("stopped controller bounded~n").

pressure_peer(Listen, Parent) ->
    Socket = accept_ws(Listen),
    {_Connect, QueryId} = read_connect_add(Socket),
    Blob = binary:copy(<<"x">>, 240000),
    pressure_updates(Socket, Parent, QueryId, Blob, 0,
                     version(0, ?INITIAL_TS)).

pressure_updates(_Socket, Parent, _QueryId, _Blob, 200, _Start) ->
    Parent ! pressure_unbounded;
pressure_updates(Socket, Parent, QueryId, Blob, Count, Start) ->
    End = version(1, timestamp(Count + 1)),
    Payload =
        transition(Start, End,
                   [updated(QueryId,
                            #{<<"count">> => Count, <<"blob">> => Blob})]),
    case send_text(Socket, Payload) of
        ok -> pressure_updates(Socket, Parent, QueryId, Blob, Count + 1, End);
        {error, closed} -> Parent ! {pressure_closed, Count};
        {error, epipe} -> Parent ! {pressure_closed, Count}
    end.

pressure_connect(_Host, _Port, 0) -> erlang:error(adapter_connect_timeout);
pressure_connect(Host, Port, Attempts) ->
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, line}, {active, false}], 100) of
        {ok, Socket} -> Socket;
        {error, _} -> timer:sleep(25), pressure_connect(Host, Port, Attempts - 1)
    end.

atomic_transition_and_query_removed() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, QueryId} = read_connect_add(Socket),
        V1 = version(1, timestamp(1)),
        %% Only the final change for a query in one atomic Transition may be
        %% visible to the subscriber.
        send_text(Socket,
                  transition(version(0, ?INITIAL_TS), V1,
                             [updated(QueryId, #{<<"count">> => 0}),
                              updated(QueryId, #{<<"count">> => 1})])),
        V2 = version(1, timestamp(2)),
        send_text(Socket, transition(V1, V2, [removed(QueryId)])),
        Parent ! removed_sent,
        receive continue_after_remove -> ok end,
        V3 = version(1, timestamp(3)),
        send_text(Socket, transition(V2, V3, [updated(QueryId, #{<<"count">> => 1})])),
        receive send_malformed -> ok end,
        Bad = #{<<"type">> => <<"UnknownModification">>, <<"queryId">> => QueryId},
        send_text(Socket,
                  transition(V3, version(1, timestamp(4)),
                             [updated(QueryId, #{<<"count">> => 99}), Bad])),
        wait_closed(Socket)
    end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    receive removed_sent -> ok after 1000 -> erlang:error(remove_transition_timeout) end,
    assert_no_live(Id, 40),
    Server ! continue_after_remove,
    %% QueryRemoved clears the remote result, so the same value is a new
    %% hydration rather than a duplicate.
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    Server ! send_malformed,
    #{error := #{name := <<"ProtocolError">>}} = next_live(Id, 3000),
    assert_no_live(Id, 40),
    ok = convex:close(Client),
    flush_exits().

continuous_peer_close_is_bounded() ->
    Parent = self(),
    {Url, _} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, _QueryId} = read_connect_add(Socket),
        Parent ! continuous_ready,
        spawn(fun() -> send_pings_until_closed(Socket, 0) end),
        Remove = read_json_skipping_control(Socket),
        <<"Remove">> = modification_type(Remove),
        Parent ! continuous_remove_seen,
        wait_closed(Socket)
    end),
    {ok, Live} = live:start_link(#{url => Url}),
    {ok, Id} = live:subscribe(Live, <<"demo:state">>, #{}, self()),
    receive continuous_ready -> ok after 1000 -> erlang:error(continuous_peer_timeout) end,
    bounded(fun() -> live:unsubscribe(Live, Id) end, 700),
    receive continuous_remove_seen -> ok
    after 1000 -> erlang:error(continuous_remove_timeout)
    end,
    bounded(fun() -> live:close(Live) end, 700),
    flush_exits().

send_pings_until_closed(Socket, N) ->
    case send_frame(Socket, true, 9, integer_to_binary(N)) of
        ok -> timer:sleep(2), send_pings_until_closed(Socket, N + 1);
        {error, closed} -> ok;
        {error, epipe} -> ok
    end.

fragmented_utf8_control_and_query_failed_recovery() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, QueryId} = read_connect_add(Socket),
        V0 = version(0, ?INITIAL_TS),
        V1 = version(1, <<"AQAAAAAAAAA=">>),
        Initial = transition(V0, V1, [updated(QueryId, #{<<"word">> => <<"雪"/utf8>>})]),
        {Position, 3} = binary:match(Initial, <<"雪"/utf8>>),
        Split = Position + 1,
        <<First:Split/binary, Rest/binary>> = Initial,
        send_frame(Socket, false, 1, First),
        send_frame(Socket, true, 9, <<"fixture-ping">>),
        send_frame(Socket, true, 0, Rest),
        {10, <<"fixture-ping">>} = read_frame(Socket),
        V2 = version(1, <<"AgAAAAAAAAA=">>),
        send_text(Socket, transition(V1, V2, [failed_without_data(QueryId)])),
        V3 = version(1, <<"AwAAAAAAAAA=">>),
        send_text(Socket, transition(V2, V3, [failed_with_null(QueryId)])),
        V4 = version(1, <<"BAAAAAAAAAA=">>),
        send_text(Socket, transition(V3, V4, [updated(QueryId, #{<<"count">> => 1})])),
        Parent ! {fixture_ready, self()},
        receive finish -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    #{value := #{<<"word">> := <<"雪"/utf8>>}} = next_live(Id, 3000),
    #{error := AbsentError} = next_live(Id, 3000),
    #{name := <<"FunctionError">>, logs := [<<"absent">>]} = AbsentError,
    false = maps:is_key(data, AbsentError),
    #{error := #{name := <<"FunctionError">>, data := null,
                 logs := [<<"explicit null">>]}} = next_live(Id, 3000),
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    receive {fixture_ready, Server} -> ok after 1000 -> erlang:error(fixture_timeout) end,
    Server ! finish,
    ok = convex:close(Client),
    flush_exits().

five_reconnects_and_hydration_dedup() ->
    Parent = self(),
    {Url, _Server} = fixture(fun(Listen) -> reconnect_peer(Listen, Parent, 0) end),
    {ok, Client} = convex:new(Url),
    {ok, Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    assert_connect(0, undefined),
    #{value := #{<<"count">> := 0}} = next_live(Id, 3000),
    lists:foreach(
      fun(Attempt) ->
          ok = live:debug_disconnect(Live),
          ExpectedTs = timestamp(Attempt - 1),
          assert_connect(Attempt, ExpectedTs),
          case Attempt of
              5 -> #{value := #{<<"count">> := 1}} = next_live(Id, 3000);
              _ -> assert_no_live(Id, 40)
          end
      end,
      lists:seq(1, 5)),
    ok = convex:close(Client),
    flush_exits().

protocol_error_reconnect() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) -> protocol_recovery_peer(Listen, Parent) end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    #{value := #{<<"count">> := 0}} = next_live(Id, 3000),
    #{error := #{name := <<"ProtocolError">>}} = next_live(Id, 3000),
    #{error := #{name := <<"ProtocolError">>}} = next_live(Id, 3000),
    #{error := #{name := <<"ProtocolError">>}} = next_live(Id, 3000),
    %% The next visible event proves recovery on the same subscription after
    %% the malformed connection is abandoned.
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    receive {protocol_recovered, Server} -> ok
    after 1000 -> erlang:error(protocol_recovery_timeout)
    end,
    ok = convex:close(Client),
    flush_exits().

protocol_recovery_peer(Listen, Parent) ->
    Socket = accept_ws(Listen),
    {Connect, QueryId} = read_connect_add(Socket),
    0 = maps:get(<<"connectionCount">>, Connect),
    V1 = version(1, timestamp(1)),
    send_text(Socket,
              transition(version(0, ?INITIAL_TS), V1,
                         [updated(QueryId, #{<<"count">> => 0})])),
    %% A valid little-endian timestamp may not move backwards. The value in
    %% this rejected transaction must never escape to the subscriber.
    send_text(Socket,
              transition(V1, version(1, timestamp(0)),
                         [updated(QueryId, #{<<"count">> => 99})])),
    wait_closed(Socket),

    Noncanonical = accept_ws(Listen),
    {NoncanonicalConnect, NoncanonicalId} = read_connect_add(Noncanonical),
    1 = maps:get(<<"connectionCount">>, NoncanonicalConnect),
    true = timestamp(1) =:= maps:get(<<"maxObservedTimestamp">>, NoncanonicalConnect),
    %% This is an alternate base64 spelling of eight zero bytes. Only the
    %% canonical Convex spelling AAAAAAAAAAA= is accepted.
    send_text(Noncanonical,
              transition(version(0, ?INITIAL_TS),
                         version(1, <<"AAAAAAAAAAB=">>),
                         [updated(NoncanonicalId, #{<<"count">> => 88})])),
    wait_closed(Noncanonical),

    BadLogs = accept_ws(Listen),
    {BadLogsConnect, BadLogsId} = read_connect_add(BadLogs),
    2 = maps:get(<<"connectionCount">>, BadLogsConnect),
    true = timestamp(1) =:= maps:get(<<"maxObservedTimestamp">>, BadLogsConnect),
    InvalidLogs =
        #{<<"type">> => <<"QueryUpdated">>, <<"queryId">> => BadLogsId,
          <<"value">> => #{<<"count">> => 77}, <<"logLines">> => [7]},
    send_text(BadLogs,
              transition(version(0, ?INITIAL_TS), version(1, timestamp(2)),
                         [updated(BadLogsId, #{<<"count">> => 66}), InvalidLogs])),
    wait_closed(BadLogs),

    Recovered = accept_ws(Listen),
    {RecoveredConnect, RecoveredId} = read_connect_add(Recovered),
    3 = maps:get(<<"connectionCount">>, RecoveredConnect),
    true = timestamp(1) =:= maps:get(<<"maxObservedTimestamp">>, RecoveredConnect),
    send_text(Recovered,
              transition(version(0, ?INITIAL_TS), version(1, timestamp(2)),
                         [updated(RecoveredId, #{<<"count">> => 1})])),
    Parent ! {protocol_recovered, self()},
    receive finish -> ok after 2000 -> ok end,
    gen_tcp:close(Recovered).

u32_wire_range_reconnect() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) -> u32_range_peer(Listen, Parent) end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    #{value := #{<<"count">> := 0}} = next_live(Id, 3000),
    lists:foreach(
      fun(Attempt) ->
          %% Each bad Transition must report a protocol failure and retire its
          %% connection. A good update placed before the bad field must not
          %% leak from the rejected atomic transaction.
          #{error := #{name := <<"ProtocolError">>}} = next_live(Id, 3000),
          receive
              {u32_reconnected, Server, Attempt, Connect} ->
                  Attempt = maps:get(<<"connectionCount">>, Connect),
                  %% Advancing the rejected timestamp would expose timestamp
                  %% or version mutation in the following Connect metadata.
                  true = timestamp(1) =:=
                      maps:get(<<"maxObservedTimestamp">>, Connect)
          after 3000 ->
              erlang:error({u32_reconnect_timeout, Attempt})
          end,
          %% The fixture has completed a same-value rehydration and a Ping/Pong
          %% barrier. No invalid result or queued value may arrive afterwards.
          assert_no_live(Id, 100),
          Server ! {continue_u32, Attempt}
      end,
      lists:seq(1, 6)),
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    receive {u32_recovered, Server} -> ok
    after 1000 -> erlang:error(u32_recovery_timeout)
    end,
    Server ! finish,
    ok = convex:close(Client),
    flush_exits().

u32_range_peer(Listen, Parent) ->
    Socket = accept_ws(Listen),
    {_Connect, QueryId} = read_connect_add(Socket),
    V1 = version(1, timestamp(1)),
    send_text(Socket,
              transition(version(0, ?INITIAL_TS), V1,
                         [updated(QueryId, #{<<"count">> => 0})])),
    Cases = [negative_query_id, overflow_query_id,
             negative_query_set, overflow_query_set,
             negative_identity, overflow_identity],
    u32_range_reconnects(Listen, Parent, Socket, QueryId, V1, Cases, 1).

u32_range_reconnects(Listen, Parent, Socket, QueryId, V1,
                     [Case | Rest], Attempt) ->
    send_text(Socket, invalid_u32_transition(Case, QueryId, V1)),
    wait_closed(Socket),
    Reconnected = accept_ws(Listen),
    {Connect, ReconnectedId} = read_connect_add(Reconnected),
    Attempt = maps:get(<<"connectionCount">>, Connect),
    true = timestamp(1) =:= maps:get(<<"maxObservedTimestamp">>, Connect),
    %% Rehydrate the accepted state. The owner should deduplicate count 0,
    %% proving the rejected Transition changed neither result nor delivery.
    send_text(Reconnected,
              transition(version(0, ?INITIAL_TS), V1,
                         [updated(ReconnectedId, #{<<"count">> => 0})])),
    send_frame(Reconnected, true, 9, <<"u32-hydrated">>),
    {10, <<"u32-hydrated">>} = read_frame(Reconnected),
    Parent ! {u32_reconnected, self(), Attempt, Connect},
    receive {continue_u32, Attempt} -> ok end,
    case Rest of
        [] ->
            %% The upper endpoint is valid for all three pinned u32 types.
            %% Include an unknown max query ID beside the real subscription;
            %% accepting the Transition and delivering count 1 proves the
            %% guard did not accidentally narrow the range to signed u32.
            MaxU32 = 4294967295,
            V2 = #{<<"querySet">> => MaxU32, <<"identity">> => MaxU32,
                   <<"ts">> => timestamp(2)},
            send_text(Reconnected,
                      transition(V1, V2,
                                 [updated(ReconnectedId, #{<<"count">> => 1}),
                                  updated(MaxU32, #{<<"count">> => 77})])),
            Parent ! {u32_recovered, self()},
            receive finish -> ok after 2000 -> ok end,
            gen_tcp:close(Reconnected);
        _ ->
            u32_range_reconnects(Listen, Parent, Reconnected, ReconnectedId,
                                 V1, Rest, Attempt + 1)
    end.

invalid_u32_transition(negative_query_id, QueryId, V1) ->
    transition(V1, version(1, timestamp(2)),
               [updated(QueryId, #{<<"count">> => 99}),
                updated(-1, #{<<"count">> => 77})]);
invalid_u32_transition(overflow_query_id, QueryId, V1) ->
    transition(V1, version(1, timestamp(2)),
               [updated(QueryId, #{<<"count">> => 99}),
                updated(4294967296, #{<<"count">> => 77})]);
invalid_u32_transition(negative_query_set, QueryId, V1) ->
    End = (version(1, timestamp(2)))#{<<"querySet">> => -1},
    transition(V1, End, [updated(QueryId, #{<<"count">> => 99})]);
invalid_u32_transition(overflow_query_set, QueryId, V1) ->
    End = (version(1, timestamp(2)))#{<<"querySet">> => 4294967296},
    transition(V1, End, [updated(QueryId, #{<<"count">> => 99})]);
invalid_u32_transition(negative_identity, QueryId, V1) ->
    End = (version(1, timestamp(2)))#{<<"identity">> => -1},
    transition(V1, End, [updated(QueryId, #{<<"count">> => 99})]);
invalid_u32_transition(overflow_identity, QueryId, V1) ->
    End = (version(1, timestamp(2)))#{<<"identity">> => 4294967296},
    transition(V1, End, [updated(QueryId, #{<<"count">> => 99})]).

handshake_resets_accumulated_backoff() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) -> handshake_backoff_peer(Listen, Parent) end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    %% Two failed upgrades accumulate 100 ms then 200 ms. A successful third
    %% upgrade resets that history before its transport is deliberately closed.
    #{error := #{name := <<"TransportError">>}} = next_live(Id, 3000),
    #{error := #{name := <<"TransportError">>}} = next_live(Id, 3000),
    #{error := #{name := <<"TransportError">>}} = next_live(Id, 3000),
    #{value := #{<<"count">> := 1}} = next_live(Id, 3000),
    Times = receive {handshake_backoff_times, Server, Values} -> Values
            after 1000 -> erlang:error(handshake_backoff_timeout)
            end,
    [_T0, T1, T2, T3] = Times,
    SlowGap = T2 - T1,
    ResetGap = T3 - T2,
    true = SlowGap >= 150,
    true = ResetGap < SlowGap,
    ok = convex:close(Client),
    flush_exits().

handshake_backoff_peer(Listen, Parent) ->
    T0 = fail_upgrade(Listen),
    T1 = fail_upgrade(Listen),
    Healthy = accept_ws(Listen),
    {Connect, _QueryId} = read_connect_add(Healthy),
    2 = maps:get(<<"connectionCount">>, Connect),
    T2 = erlang:monotonic_time(millisecond),
    gen_tcp:close(Healthy),
    Recovered = accept_ws(Listen),
    {RecoveredConnect, RecoveredId} = read_connect_add(Recovered),
    3 = maps:get(<<"connectionCount">>, RecoveredConnect),
    T3 = erlang:monotonic_time(millisecond),
    send_text(Recovered,
              transition(version(0, ?INITIAL_TS), version(1, timestamp(1)),
                         [updated(RecoveredId, #{<<"count">> => 1})])),
    Parent ! {handshake_backoff_times, self(), [T0, T1, T2, T3]},
    receive finish -> ok after 2000 -> ok end,
    gen_tcp:close(Recovered).

fail_upgrade(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    _Request = read_headers(Socket, <<>>),
    Accepted = erlang:monotonic_time(millisecond),
    gen_tcp:close(Socket),
    Accepted.

five_failed_upgrades_then_success() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        lists:foreach(fun(_) -> fail_upgrade(Listen) end, lists:seq(1, 5)),
        Socket = accept_ws(Listen),
        {Connect, QueryId} = read_connect_add(Socket),
        5 = maps:get(<<"connectionCount">>, Connect),
        send_text(Socket,
                  transition(version(0, ?INITIAL_TS), version(1, timestamp(1)),
                             [updated(QueryId, #{<<"count">> => 1})])),
        Parent ! {five_upgrade_recovered, self()},
        receive finish -> ok after 2000 -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Client} = convex:new(Url),
    {ok, _Live, Id} = convex:subscribe(Client, <<"demo:state">>, #{}, self()),
    lists:foreach(
      fun(_) -> #{error := #{name := <<"TransportError">>}} = next_live(Id, 5000) end,
      lists:seq(1, 5)),
    #{value := #{<<"count">> := 1}} = next_live(Id, 5000),
    receive {five_upgrade_recovered, Server} -> ok
    after 1000 -> erlang:error(five_upgrade_recovery_timeout)
    end,
    Server ! finish,
    ok = convex:close(Client),
    flush_exits().

reconnect_peer(Listen, Parent, Attempt) ->
    Socket = accept_ws(Listen),
    {Connect, QueryId} = read_connect_add(Socket),
    Parent ! {connect, Attempt, Connect},
    Count = case Attempt of 5 -> 1; _ -> 0 end,
    send_text(Socket,
              transition(version(0, ?INITIAL_TS), version(1, timestamp(Attempt)),
                         [updated(QueryId, #{<<"count">> => Count})])),
    case Attempt of
        5 -> receive finish -> ok after 5000 -> ok end;
        _ -> wait_closed(Socket), reconnect_peer(Listen, Parent, Attempt + 1)
    end,
    gen_tcp:close(Socket).

assert_connect(Attempt, ExpectedMaxTs) ->
    receive
        {connect, Attempt, Connect} ->
            Attempt = maps:get(<<"connectionCount">>, Connect),
            case ExpectedMaxTs of
                undefined -> false = maps:is_key(<<"maxObservedTimestamp">>, Connect);
                _ ->
                    ExpectedMaxTs = maps:get(<<"maxObservedTimestamp">>, Connect),
                    <<"adapter debug disconnect">> = maps:get(<<"lastCloseReason">>, Connect)
            end
    after 3000 -> erlang:error({missing_reconnect, Attempt})
    end.

newest_sixteen_count_overflow() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, QueryId} = read_connect_add(Socket),
        lists:foldl(
          fun(Count, Start) ->
              End = version(1, timestamp(Count)),
              send_text(Socket, transition(Start, End,
                                           [updated(QueryId, #{<<"count">> => Count})])),
              End
          end,
          version(0, ?INITIAL_TS), lists:seq(0, 19)),
        send_frame(Socket, true, 9, <<"count-drained">>),
        {10, <<"count-drained">>} = read_frame(Socket),
        Parent ! queue_sent,
        receive finish -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Live} = live:start_link(#{url => Url, relay_test_gate => self()}),
    {ok, Id} = live:subscribe(Live, <<"demo:state">>, #{}, self()),
    {HeldRelay, #{value := #{<<"count">> := 0}}} = next_dequeued(Id),
    receive queue_sent -> ok after 3000 -> erlang:error(queue_fixture_timeout) end,
    Stats = live:debug_subscription(Live, Id),
    16 = maps:get(queue_count, Stats),
    true = maps:get(queue_bytes, Stats) =< 262144,
    release_relay(HeldRelay),
    drain_gated(Id, lists:seq(4, 19)),
    Server ! finish,
    ok = live:close(Live),
    flush_exits().

newest_byte_overflow() ->
    Parent = self(),
    Blob = binary:copy(<<"x">>, 100000),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, QueryId} = read_connect_add(Socket),
        lists:foldl(
          fun(Count, Start) ->
              End = version(1, timestamp(Count)),
              send_text(Socket,
                        transition(Start, End,
                                   [updated(QueryId, #{<<"count">> => Count,
                                                       <<"blob">> => Blob})])),
              End
          end,
          version(0, ?INITIAL_TS), lists:seq(0, 5)),
        send_frame(Socket, true, 9, <<"bytes-drained">>),
        {10, <<"bytes-drained">>} = read_frame(Socket),
        Parent ! byte_queue_sent,
        receive finish -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Live} = live:start_link(#{url => Url, relay_test_gate => self()}),
    {ok, Id} = live:subscribe(Live, <<"demo:state">>, #{}, self()),
    {HeldRelay, #{value := #{<<"count">> := 0}}} = next_dequeued(Id),
    receive byte_queue_sent -> ok after 3000 -> erlang:error(byte_queue_fixture_timeout) end,
    Stats = live:debug_subscription(Live, Id),
    2 = maps:get(queue_count, Stats),
    true = maps:get(queue_bytes, Stats) =< 262144,
    release_relay(HeldRelay),
    drain_gated(Id, [4, 5]),
    Server ! finish,
    ok = live:close(Live),
    flush_exits().

stale_generation_barrier() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, OldId} = read_connect_add(Socket),
        V1 = version(1, <<"AQAAAAAAAAA=">>),
        send_text(Socket, transition(version(0, ?INITIAL_TS), V1,
                                     [updated(OldId, #{<<"count">> => 0})])),
        receive send_stale -> ok end,
        V2 = version(1, <<"AgAAAAAAAAA=">>),
        send_text(Socket, transition(V1, V2, [updated(OldId, #{<<"count">> => 99})])),
        Parent ! stale_sent,
        Remove = read_json(Socket),
        <<"Remove">> = modification_type(Remove),
        Parent ! remove_seen,
        receive finish -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Live} = live:start_link(#{url => Url, relay_test_gate => self()}),
    {ok, Old} = live:subscribe(Live, <<"demo:state">>, #{}, self()),
    {InitialRelay, #{value := #{<<"count">> := 0}}} = next_dequeued(Old),
    release_relay(InitialRelay),
    #{value := #{<<"count">> := 0}} = next_live(Old, 3000),
    Server ! send_stale,
    receive stale_sent -> ok after 1000 -> erlang:error(stale_not_sent) end,
    {StaleRelay, #{value := #{<<"count">> := 99}}} = next_dequeued(Old),
    ok = live:unsubscribe(Live, Old),
    release_relay(StaleRelay),
    receive remove_seen -> ok after 1000 -> erlang:error(remove_not_seen) end,
    assert_no_live(Old, 350),
    Server ! finish,
    ok = live:close(Live),
    flush_exits().

stalled_handshake_and_partial_frame_are_bounded() ->
    Parent = self(),
    {Url1, _} = fixture(fun(Listen) ->
        {ok, Socket} = gen_tcp:accept(Listen),
        Parent ! stalled_accepted,
        receive after 1500 -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Stalled} = live:start_link(#{url => Url1}),
    {ok, StalledId} = live:subscribe(Stalled, <<"demo:state">>, #{}, self()),
    receive stalled_accepted -> ok after 1000 -> erlang:error(stalled_accept_timeout) end,
    bounded(fun() -> live:unsubscribe(Stalled, StalledId) end, 700),
    bounded(fun() -> live:close(Stalled) end, 700),
    flush_exits(),

    {IdleUrl, _} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, _QueryId} = read_connect_add(Socket),
        Parent ! idle_ready,
        Remove = read_json(Socket),
        <<"Remove">> = modification_type(Remove),
        Parent ! idle_remove_seen,
        wait_closed(Socket)
    end),
    {ok, Idle} = live:start_link(#{url => IdleUrl}),
    {ok, IdleId} = live:subscribe(Idle, <<"demo:state">>, #{}, self()),
    receive idle_ready -> ok after 1000 -> erlang:error(idle_peer_timeout) end,
    bounded(fun() -> live:unsubscribe(Idle, IdleId) end, 700),
    receive idle_remove_seen -> ok after 1000 -> erlang:error(idle_remove_timeout) end,
    bounded(fun() -> live:close(Idle) end, 700),
    flush_exits(),

    {Url2, _} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, _QueryId} = read_connect_add(Socket),
        send_frame(Socket, false, 1, <<"{\"type\":\"Trans">>),
        Parent ! partial_sent,
        Remove = read_json(Socket),
        <<"Remove">> = modification_type(Remove),
        Parent ! remove_seen,
        receive after 1500 -> ok end,
        gen_tcp:close(Socket)
    end),
    {ok, Partial} = live:start_link(#{url => Url2}),
    {ok, PartialId} = live:subscribe(Partial, <<"demo:state">>, #{}, self()),
    receive partial_sent -> ok after 1000 -> erlang:error(partial_not_sent) end,
    bounded(fun() -> live:unsubscribe(Partial, PartialId) end, 700),
    receive remove_seen -> ok after 1000 -> erlang:error(remove_not_seen) end,
    bounded(fun() -> live:close(Partial) end, 700),
    flush_exits().

tcp_partial_ndjson_and_eof_cleanup() ->
    Port = free_port(),
    Address = "127.0.0.1:" ++ integer_to_list(Port),
    Success = convex_json:encode(#{<<"status">> => <<"success">>,
                                   <<"value">> => #{<<"count">> => 7},
                                   <<"logLines">> => []}),
    Failure = convex_json:encode(#{<<"status">> => <<"error">>,
                                   <<"errorMessage">> => <<"fixture failure">>,
                                   <<"errorData">> => #{<<"code">> => <<"FIXTURE">>},
                                   <<"logLines">> => []}),
    AbsentData = convex_json:encode(#{<<"status">> => <<"error">>,
                                      <<"errorMessage">> => <<"absent data">>}),
    NullData = convex_json:encode(#{<<"status">> => <<"error">>,
                                    <<"errorMessage">> => <<"null data">>,
                                    <<"errorData">> => null,
                                    <<"logLines">> => []}),
    BadLogs = convex_json:encode(#{<<"status">> => <<"success">>,
                                   <<"value">> => #{<<"count">> => 8},
                                   <<"logLines">> => [7]}),
    {HttpUrl, _HttpServer} =
        http_fixture([Success, Failure, AbsentData, NullData, BadLogs]),
    true = os:putenv("ADAPTER_LISTEN", Address),
    true = os:putenv("CONVEX_URL", HttpUrl),
    {Pid, Monitor} = spawn_monitor(fun adapter:main/0),
    Socket = connect_retry(Port, 50),
    ok = gen_tcp:send(Socket, <<"{\"protocolVersion\":1,\"id\":">>),
    ok = gen_tcp:send(Socket, <<"\"hello\",\"op\":\"hel">>),
    ok = gen_tcp:send(Socket, <<"lo\"}\n">>),
    {Line, <<>>} = read_line(Socket, <<>>),
    {ok, #{<<"type">> := <<"ready">>, <<"language">> := <<"erlang">>}} = convex_json:decode(Line),
    %% Malformed commands are command-scoped ProtocolErrors. The reader stays
    %% alive and includes a valid id only when the malformed command had one.
    ok = gen_tcp:send(Socket, <<"{]\n">>),
    #{<<"type">> := <<"error">>, <<"error">> := #{<<"name">> := <<"ProtocolError">>}} =
        read_ndjson(Socket),
    ok = gen_tcp:send(Socket, <<"{\"op\":\"close\"}\n">>),
    MissingId = read_ndjson(Socket),
    false = maps:is_key(<<"id">>, MissingId),
    #{<<"type">> := <<"error">>} = MissingId,
    ok = gen_tcp:send(Socket,
                      <<"{\"id\":\"bad-query\",\"op\":\"query\",",
                        "\"path\":\"demo:state\"}\n">>),
    #{<<"id">> := <<"bad-query">>, <<"type">> := <<"error">>,
      <<"error">> := #{<<"name">> := <<"ProtocolError">>}} = read_ndjson(Socket),
    ok = gen_tcp:send(Socket, binary:copy(<<"x">>, 1048577)),
    ok = gen_tcp:send(Socket, <<"\n">>),
    #{<<"type">> := <<"error">>, <<"error">> := #{<<"name">> := <<"ProtocolError">>}} =
        read_ndjson(Socket),
    ok = gen_tcp:send(Socket, <<"{\"id\":\"query\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n">>),
    {ResultLine, <<>>} = read_line(Socket, <<>>),
    {ok, #{<<"id">> := <<"query">>, <<"type">> := <<"result">>,
           <<"value">> := #{<<"count">> := 7}, <<"logs">> := []}} =
        convex_json:decode(ResultLine),
    ok = gen_tcp:send(Socket, <<"{\"id\":\"failure\",\"op\":\"query\",\"path\":\"demo:fail\",\"args\":{}}\n">>),
    {ErrorLine, <<>>} = read_line(Socket, <<>>),
    {ok, #{<<"id">> := <<"failure">>, <<"type">> := <<"error">>,
           <<"error">> := #{<<"name">> := <<"FunctionError">>,
                            <<"message">> := <<"fixture failure">>,
                            <<"data">> := #{<<"code">> := <<"FIXTURE">>}}}} =
        convex_json:decode(ErrorLine),
    send_ndjson(Socket,
                #{<<"id">> => <<"absent">>, <<"op">> => <<"query">>,
                  <<"path">> => <<"demo:fail">>, <<"args">> => #{}}),
    #{<<"id">> := <<"absent">>, <<"type">> := <<"error">>,
      <<"error">> := AbsentError} = read_ndjson(Socket),
    #{<<"name">> := <<"FunctionError">>, <<"message">> := <<"absent data">>} =
        AbsentError,
    false = maps:is_key(<<"data">>, AbsentError),
    send_ndjson(Socket,
                #{<<"id">> => <<"null">>, <<"op">> => <<"query">>,
                  <<"path">> => <<"demo:fail">>, <<"args">> => #{}}),
    #{<<"id">> := <<"null">>, <<"type">> := <<"error">>,
      <<"error">> := #{<<"name">> := <<"FunctionError">>,
                       <<"data">> := null}} = read_ndjson(Socket),
    send_ndjson(Socket,
                #{<<"id">> => <<"bad-logs">>, <<"op">> => <<"query">>,
                  <<"path">> => <<"demo:state">>, <<"args">> => #{}}),
    #{<<"id">> := <<"bad-logs">>, <<"type">> := <<"error">>,
      <<"error">> := #{<<"name">> := <<"ProtocolError">>}} = read_ndjson(Socket),
    ok = gen_tcp:send(Socket, <<"{\"id\":\"unfinished\",\"op\":\"close\"}">>),
    gen_tcp:close(Socket),
    receive {'DOWN', Monitor, process, Pid, normal} -> ok after 2000 -> erlang:error(adapter_eof_timeout) end,
    true = os:unsetenv("ADAPTER_LISTEN"),
    true = os:unsetenv("CONVEX_URL").

http_fixture(Responses) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                     {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Listen),
    Pid = spawn_link(fun() ->
        lists:foreach(fun(Body) -> serve_http_once(Listen, Body) end, Responses),
        gen_tcp:close(Listen)
    end),
    {"http://127.0.0.1:" ++ integer_to_list(Port), Pid}.

serve_http_once(Listen, Body) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    _Request = read_headers(Socket, <<>>),
    ok = gen_tcp:send(Socket,
                      [<<"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
                         "Connection: close\r\nContent-Length: ">>,
                       integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>, Body]),
    gen_tcp:close(Socket).

same_id_replacement_barrier() ->
    Parent = self(),
    {Url, Server} = fixture(fun(Listen) ->
        Socket = accept_ws(Listen),
        {_Connect, OldId} = read_connect_add(Socket),
        V1 = version(1, timestamp(1)),
        send_text(Socket, transition(version(0, ?INITIAL_TS), V1,
                                     [updated(OldId, #{<<"count">> => 0})])),
        receive send_replacement_stale -> ok end,
        V2 = version(1, timestamp(2)),
        send_text(Socket, transition(V1, V2, [updated(OldId, #{<<"count">> => 99})])),
        Parent ! replacement_stale_sent,
        receive send_replacement_value -> ok end,
        NewId = OldId + 1,
        send_text(Socket,
                  transition(V2, version(3, timestamp(3)),
                             [updated(NewId, #{<<"count">> => 1})])),
        send_text(Socket,
                  transition(version(3, timestamp(3)), version(3, timestamp(4)),
                             [failed(NewId)])),
        wait_closed(Socket)
    end),
    Port = free_port(),
    Address = "127.0.0.1:" ++ integer_to_list(Port),
    true = os:putenv("ADAPTER_LISTEN", Address),
    true = os:putenv("CONVEX_URL", Url),
    true = register(live_relay_gate, self()),
    true = os:putenv("ADAPTER_TEST_RELAY_GATE", "1"),
    {Pid, Monitor} = spawn_monitor(fun adapter:main/0),
    Controller = connect_line_retry(Port, 50),
    send_ndjson(Controller,
                #{<<"id">> => <<"first">>, <<"op">> => <<"subscribe">>,
                  <<"subscriptionId">> => <<"same">>, <<"path">> => <<"demo:state">>,
                  <<"args">> => #{}}),
    #{<<"id">> := <<"first">>, <<"type">> := <<"ack">>} = read_ndjson(Controller),
    {InitialRelay, #{value := #{<<"count">> := 0}}} = next_dequeued(<<"0">>),
    release_relay(InitialRelay),
    #{<<"subscriptionId">> := <<"same">>, <<"value">> := #{<<"count">> := 0}} =
        read_ndjson(Controller),
    Server ! send_replacement_stale,
    receive replacement_stale_sent -> ok after 1000 -> erlang:error(replacement_stale_timeout) end,
    {_StaleRelay, #{value := #{<<"count">> := 99}}} = next_dequeued(<<"0">>),
    send_ndjson(Controller,
                #{<<"id">> => <<"replace">>, <<"op">> => <<"subscribe">>,
                  <<"subscriptionId">> => <<"same">>, <<"path">> => <<"demo:state">>,
                  <<"args">> => #{}}),
    #{<<"id">> := <<"replace">>, <<"type">> := <<"ack">>} = read_ndjson(Controller),
    Server ! send_replacement_value,
    {ReplacementRelay, #{value := #{<<"count">> := 1}}} = next_dequeued(<<"1">>),
    release_relay(ReplacementRelay),
    %% If the paused old relay crossed the replacement ACK this would be 99.
    #{<<"subscriptionId">> := <<"same">>, <<"value">> := #{<<"count">> := 1}} =
        read_ndjson(Controller),
    {FailureRelay, #{error := #{name := <<"FunctionError">>}}} = next_dequeued(<<"1">>),
    release_relay(FailureRelay),
    #{<<"subscriptionId">> := <<"same">>,
      <<"error">> := #{<<"name">> := <<"FunctionError">>,
                       <<"message">> := <<"empty">>}} = read_ndjson(Controller),
    send_ndjson(Controller, #{<<"id">> => <<"close">>, <<"op">> => <<"close">>}),
    #{<<"type">> := <<"closed">>} = read_ndjson(Controller),
    gen_tcp:close(Controller),
    receive {'DOWN', Monitor, process, Pid, normal} -> ok after 2000 -> erlang:error(replacement_adapter_timeout) end,
    true = unregister(live_relay_gate),
    true = os:unsetenv("ADAPTER_LISTEN"),
    true = os:unsetenv("CONVEX_URL"),
    true = os:unsetenv("ADAPTER_TEST_RELAY_GATE").

fixture(Fun) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                     {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Listen),
    Caller = self(),
    Pid = spawn_link(fun() ->
        try Fun(Listen)
        catch Class:Reason:Stack -> Caller ! {fixture_crash, self(), {Class, Reason, Stack}}
        after gen_tcp:close(Listen)
        end
    end),
    {"http://127.0.0.1:" ++ integer_to_list(Port), Pid}.

accept_ws(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Headers = read_headers(Socket, <<>>),
    Key = websocket_key(Headers),
    Accept = base64:encode(crypto:hash(sha, <<Key/binary,
                                               "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
    ok = gen_tcp:send(Socket,
                      [<<"HTTP/1.1 101 Switching Protocols\r\n",
                         "Upgrade: websocket\r\nConnection: Upgrade\r\n",
                         "Sec-WebSocket-Accept: ">>, Accept, <<"\r\n\r\n">>]),
    Socket.

read_headers(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 3000),
            read_headers(Socket, <<Buffer/binary, Data/binary>>);
        _ -> Buffer
    end.

websocket_key(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    [Line | _] = [L || L <- Lines,
                       lists:prefix("sec-websocket-key:",
                                    string:lowercase(binary_to_list(L)))],
    [_Name, Value] = binary:split(Line, <<":">>),
    unicode:characters_to_binary(string:trim(binary_to_list(Value))).

read_connect_add(Socket) ->
    Connect = read_json(Socket),
    <<"Connect">> = maps:get(<<"type">>, Connect),
    Add = read_json(Socket),
    <<"Add">> = modification_type(Add),
    {Connect, modification_query_id(Add)}.

read_json(Socket) ->
    {1, Payload} = read_frame(Socket),
    {ok, Value} = convex_json:decode(Payload),
    Value.

read_json_skipping_control(Socket) ->
    case read_frame(Socket) of
        {1, Payload} ->
            {ok, Value} = convex_json:decode(Payload),
            Value;
        {Opcode, _} when Opcode =:= 8; Opcode =:= 9; Opcode =:= 10 ->
            read_json_skipping_control(Socket)
    end.

read_frame(Socket) ->
    <<Fin:1, _Reserved:3, Opcode:4, Masked:1, Length0:7>> = recv_exact(Socket, 2, <<>>),
    Length = case Length0 of
        126 -> <<N:16>> = recv_exact(Socket, 2, <<>>), N;
        127 -> <<N:64>> = recv_exact(Socket, 8, <<>>), N;
        N -> N
    end,
    Mask = case Masked of 1 -> recv_exact(Socket, 4, <<>>); 0 -> <<>> end,
    Payload0 = recv_exact(Socket, Length, <<>>),
    Payload = case Masked of 1 -> unmask(Payload0, Mask, 0, <<>>); 0 -> Payload0 end,
    case {Fin, Opcode} of
        {1, _} -> {Opcode, Payload};
        _ -> erlang:error({unexpected_client_fragment, Opcode})
    end.

recv_exact(_Socket, 0, Acc) -> Acc;
recv_exact(Socket, Need, Acc) ->
    {ok, Data} = gen_tcp:recv(Socket, Need, 3000),
    recv_exact(Socket, Need - byte_size(Data), <<Acc/binary, Data/binary>>).

unmask(<<>>, _Mask, _Index, Acc) -> Acc;
unmask(<<Byte, Rest/binary>>, Mask, Index, Acc) ->
    MaskByte = binary:at(Mask, Index rem 4),
    unmask(Rest, Mask, Index + 1, <<Acc/binary, (Byte bxor MaskByte)>>).

send_text(Socket, Payload) -> send_frame(Socket, true, 1, Payload).

send_frame(Socket, Fin, Opcode, Payload) ->
    FinBit = case Fin of true -> 1; false -> 0 end,
    Length = byte_size(Payload),
    Header = case Length of
        N when N < 126 -> <<FinBit:1, 0:3, Opcode:4, 0:1, N:7>>;
        N when N < 65536 -> <<FinBit:1, 0:3, Opcode:4, 0:1, 126:7, N:16>>;
        N -> <<FinBit:1, 0:3, Opcode:4, 0:1, 127:7, N:64>>
    end,
    gen_tcp:send(Socket, [Header, Payload]).

version(QuerySet, Timestamp) ->
    #{<<"querySet">> => QuerySet, <<"identity">> => 0, <<"ts">> => Timestamp}.

timestamp(N) -> base64:encode(<<N:64/little-unsigned-integer>>).

transition(Start, End, Modifications) ->
    convex_json:encode(#{<<"type">> => <<"Transition">>, <<"startVersion">> => Start,
                         <<"endVersion">> => End, <<"modifications">> => Modifications}).

updated(QueryId, Value) ->
    #{<<"type">> => <<"QueryUpdated">>, <<"queryId">> => QueryId,
      <<"value">> => Value, <<"logLines">> => []}.

failed(QueryId) ->
    #{<<"type">> => <<"QueryFailed">>, <<"queryId">> => QueryId,
      <<"errorMessage">> => <<"empty">>, <<"errorData">> => #{<<"code">> => <<"EMPTY">>},
      <<"logLines">> => [<<"failed">>]}.

failed_without_data(QueryId) ->
    #{<<"type">> => <<"QueryFailed">>, <<"queryId">> => QueryId,
      <<"errorMessage">> => <<"absent data">>, <<"logLines">> => [<<"absent">>]}.

failed_with_null(QueryId) ->
    #{<<"type">> => <<"QueryFailed">>, <<"queryId">> => QueryId,
      <<"errorMessage">> => <<"null data">>, <<"errorData">> => null,
      <<"logLines">> => [<<"explicit null">>]}.

removed(QueryId) ->
    #{<<"type">> => <<"QueryRemoved">>, <<"queryId">> => QueryId}.

modification(Message) -> hd(maps:get(<<"modifications">>, Message)).
modification_type(Message) -> maps:get(<<"type">>, modification(Message)).
modification_query_id(Message) -> maps:get(<<"queryId">>, modification(Message)).

next_live(Id, Timeout) ->
    receive {convex_live, Id, Event} -> Event after Timeout -> erlang:error({live_timeout, Id}) end.

next_dequeued(Id) ->
    receive
        {relay_dequeued, Relay, Id, Event} ->
            case is_process_alive(Relay) of
                true -> {Relay, Event};
                false -> next_dequeued(Id)
            end
    after 3000 -> erlang:error({relay_dequeue_timeout, Id})
    end.

release_relay(Relay) -> Relay ! {relay_release, self()}.

drain_gated(_Id, []) -> ok;
drain_gated(Id, [Expected | Rest]) ->
    {Relay, #{value := #{<<"count">> := Expected}}} = next_dequeued(Id),
    release_relay(Relay),
    #{value := #{<<"count">> := Expected}} = next_live(Id, 3000),
    drain_gated(Id, Rest).

assert_no_live(Id, Timeout) ->
    receive {convex_live, Id, Event} -> erlang:error({unexpected_live, Event}) after Timeout -> ok end.

bounded(Fun, LimitMs) ->
    Started = erlang:monotonic_time(millisecond),
    ok = Fun(),
    true = erlang:monotonic_time(millisecond) - Started < LimitMs.

wait_closed(Socket) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {error, closed} -> ok;
        {ok, _} -> wait_closed(Socket)
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Socket),
    gen_tcp:close(Socket),
    Port.

connect_retry(_Port, 0) -> erlang:error(adapter_connect_timeout);
connect_retry(Port, Attempts) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, false}], 100) of
        {ok, Socket} -> Socket;
        {error, econnrefused} -> timer:sleep(20), connect_retry(Port, Attempts - 1)
    end.

connect_line_retry(_Port, 0) -> erlang:error(adapter_connect_timeout);
connect_line_retry(Port, Attempts) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port,
                         [binary, {packet, line}, {active, false}], 100) of
        {ok, Socket} -> Socket;
        {error, econnrefused} -> timer:sleep(20), connect_line_retry(Port, Attempts - 1)
    end.

send_ndjson(Socket, Value) -> gen_tcp:send(Socket, [convex_json:encode(Value), <<"\n">>]).

read_ndjson(Socket) ->
    {ok, Line} = gen_tcp:recv(Socket, 0, 3000),
    {ok, Value} = convex_json:decode(Line),
    Value.

read_line(Socket, Buffer) ->
    case binary:match(Buffer, <<"\n">>) of
        {Position, 1} ->
            <<Line:Position/binary, _Newline, Rest/binary>> = Buffer,
            {Line, Rest};
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 1000),
            read_line(Socket, <<Buffer/binary, Data/binary>>)
    end.

flush_exits() ->
    receive {'EXIT', _, normal} -> flush_exits() after 0 -> ok end.
