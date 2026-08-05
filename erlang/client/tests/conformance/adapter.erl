%% Adapter protocol v1. A reader process is essential: its controller process
%% can relay WebSocket events while stdin or a TCP peer is quiet.
-module(adapter).
-export([main/0]).

main() ->
    Url = case os:getenv("CONVEX_URL") of false -> "http://127.0.0.1"; V -> V end,
    {ok, Client} = convex:new(Url),
    case os:getenv("ADAPTER_LISTEN") of
        false -> Owner = self(), spawn_link(fun() -> stdin_reader(Owner) end), loop(Client, undefined, #{}, fun stdout/1);
        Address -> tcp_start(Address, Client)
    end.
tcp_start(Address, Client) ->
    [Host, PortText] = string:split(Address, ":", all),
    {ok, Listen} = gen_tcp:listen(list_to_integer(PortText), [binary, {packet, line}, {active, false}, {reuseaddr, true}, {ip, host(Host)}]),
    {ok, Socket} = gen_tcp:accept(Listen),
    Owner = self(),
    spawn_link(fun() -> tcp_reader(Socket, Owner) end),
    loop(Client, undefined, #{}, fun(Bin) -> gen_tcp:send(Socket, [Bin, <<"\n">>]) end).
host("0.0.0.0") -> {0,0,0,0}; host("127.0.0.1") -> {127,0,0,1}; host(_) -> {0,0,0,0}.
stdin_reader(Owner) -> case io:get_line("") of eof -> Owner ! eof; Line -> Owner ! {line, iolist_to_binary(Line)}, stdin_reader(Owner) end.
tcp_reader(Socket, Owner) -> case gen_tcp:recv(Socket, 0) of {ok, Line} -> Owner ! {line, Line}, tcp_reader(Socket, Owner); {error, closed} -> Owner ! eof end.
stdout(Bin) -> io:format("~s~n", [Bin]).
loop(Client, Live, Subs, Send) -> receive
    eof -> case Live of undefined -> ok; Pid -> convex:close(#{live => Pid}) end;
    {line, Line} ->
        case convex_json:decode(Line) of
            {ok, Command} -> {Client1, Live1, Subs1, Reply, Stop} = handle(Command, Client, Live, Subs), Send(convex_json:encode(Reply)), case Stop of true -> ok; false -> loop(Client1, Live1, Subs1, Send) end;
            _ -> Send(convex_json:encode(#{<<"type">> => <<"error">>, <<"error">> => make_error(<<"ProtocolError">>, <<"invalid NDJSON">>)})), loop(Client, Live, Subs, Send)
        end;
    {convex_live, Id, Event} ->
        case maps:find(Id, Subs) of {ok, Requested} -> Send(convex_json:encode(Event#{<<"type">> => <<"subscription">>, <<"subscriptionId">> => Requested})); error -> ok end,
        loop(Client, Live, Subs, Send)
end.
handle(C, Client, Live, Subs) ->
    Id = maps:get(<<"id">>, C),
    Op = maps:get(<<"op">>, C),
    case Op of
        <<"hello">> -> {Client, Live, Subs, #{<<"protocolVersion">> => 1, <<"id">> => Id, <<"type">> => <<"ready">>, <<"language">> => <<"erlang">>, <<"implementation">> => <<"native-otp-gun-jsx-0.1.0">>, <<"runtime">> => unicode:characters_to_binary(erlang:system_info(otp_release))}, false};
        <<"query">> -> http(Id, query, C, Client, Live, Subs);
        <<"mutation">> -> http(Id, mutation, C, Client, Live, Subs);
        <<"action">> -> http(Id, action, C, Client, Live, Subs);
        <<"setAuth">> -> {convex:set_auth(Client, maps:get(<<"token">>, C)), Live, Subs, #{<<"id">> => Id, <<"type">> => <<"ack">>}, false};
        <<"subscribe">> ->
            {ok, Pid, SubscriptionId} = convex:subscribe(Client, maps:get(<<"path">>, C), maps:get(<<"args">>, C), self()),
            RequestedId = maps:get(<<"subscriptionId">>, C),
            %% Replace is a generation barrier: retire the old relay first.
            case [Real || {Real, Requested} <- maps:to_list(Subs), Requested =:= RequestedId] of [Old | _] -> convex:unsubscribe(Pid, Old); [] -> ok end,
            {Client, Pid, maps:put(SubscriptionId, RequestedId, Subs), #{<<"id">> => Id, <<"type">> => <<"ack">>}, false};
        <<"unsubscribe">> ->
            RequestedId = maps:get(<<"subscriptionId">>, C),
            case [Real || {Real, Requested} <- maps:to_list(Subs), Requested =:= RequestedId] of [RealId | _] when Live =/= undefined -> convex:unsubscribe(Live, RealId); _ -> ok end,
            {Client, Live, maps:filter(fun(_Real, Requested) -> Requested =/= RequestedId end, Subs), #{<<"id">> => Id, <<"type">> => <<"ack">>}, false};
        <<"debugDisconnect">> -> disconnect_reply(Id, Client, Live, Subs);
        <<"close">> ->
            case Live of undefined -> ok; Pid -> convex:close(#{live => Pid}) end,
            {Client, Live, #{}, #{<<"id">> => Id, <<"type">> => <<"closed">>}, true};
        _ -> {Client, Live, Subs, #{<<"id">> => Id, <<"type">> => <<"error">>, <<"error">> => make_error(<<"ProtocolError">>, <<"unknown operation">>)}, false}
    end.
disconnect_reply(Id, Client, undefined, Subs) ->
    {Client, undefined, Subs, #{<<"id">> => Id, <<"type">> => <<"error">>, <<"error">> => make_error(<<"TransportError">>, <<"no active WebSocket">>)}, false};
disconnect_reply(Id, Client, Pid, Subs) ->
    case convex:debug_disconnect(Pid) of
        ok -> {Client, Pid, Subs, #{<<"id">> => Id, <<"type">> => <<"ack">>}, false};
        _ -> {Client, Pid, Subs, #{<<"id">> => Id, <<"type">> => <<"error">>, <<"error">> => make_error(<<"TransportError">>, <<"disconnect failed">>)}, false}
    end.
http(Id, Op, C, Client, Live, Subs) -> case convex:call(Client, Op, maps:get(<<"path">>, C), maps:get(<<"args">>, C)) of
    {ok, Value, Logs} -> {Client, Live, Subs, #{<<"id">> => Id, <<"type">> => <<"result">>, <<"value">> => Value, <<"logs">> => Logs}, false};
    {error, Error} -> {Client, Live, Subs, #{<<"id">> => Id, <<"type">> => <<"error">>, <<"error">> => Error}, false}
end.
make_error(Name, Message) -> #{name => Name, message => Message}.
