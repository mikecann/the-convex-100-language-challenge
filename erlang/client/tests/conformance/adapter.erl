%% Adapter protocol v1. A reader process is essential: its controller process
%% can relay WebSocket events while stdin or a TCP peer is quiet.
-module(adapter).
-export([main/0]).

main() ->
    Url =
        case os:getenv("CONVEX_URL") of
            false -> "http://127.0.0.1";
            Value -> Value
        end,
    {ok, Client} = convex:new(Url),
    case os:getenv("ADAPTER_LISTEN") of
        false ->
            Owner = self(),
            spawn_link(fun() -> stdin_reader(Owner) end),
            loop(Client, maps:get(live, Client), #{}, fun stdout/1);
        Address ->
            tcp_start(Address, Client)
    end.

tcp_start(Address, Client) ->
    [Host, PortText] = string:split(Address, ":", all),
    Options =
        [binary, {packet, raw}, {active, false}, {reuseaddr, true},
         {ip, host(Host)}],
    {ok, Listen} = gen_tcp:listen(list_to_integer(PortText), Options),
    try
        {ok, Socket} = gen_tcp:accept(Listen),
        try
            Owner = self(),
            spawn_link(fun() -> tcp_reader(Socket, Owner, <<>>) end),
            Send = fun(Bin) -> gen_tcp:send(Socket, [Bin, <<"\n">>]) end,
            loop(Client, maps:get(live, Client), #{}, Send)
        after
            gen_tcp:close(Socket)
        end
    after
        gen_tcp:close(Listen)
    end.

host("0.0.0.0") ->
    {0, 0, 0, 0};
host("127.0.0.1") ->
    {127, 0, 0, 1};
host(_) ->
    {0, 0, 0, 0}.

stdin_reader(Owner) ->
    case io:get_line("") of
        eof ->
            Owner ! eof;
        Line ->
            Owner ! {line, iolist_to_binary(Line)},
            stdin_reader(Owner)
    end.

tcp_reader(Socket, Owner, Buffer) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            tcp_lines(Socket, Owner, <<Buffer/binary, Data/binary>>);
        {error, closed} ->
            %% NDJSON requires a newline. Discard a trailing partial command,
            %% then let the controller close the sole Live owner.
            Owner ! eof;
        {error, Reason} ->
            Owner ! {reader_error, Reason}
    end.

tcp_lines(Socket, Owner, Buffer) ->
    case binary:match(Buffer, <<"\n">>) of
        nomatch ->
            tcp_reader(Socket, Owner, Buffer);
        {Position, 1} ->
            <<Line:Position/binary, _Newline, Rest/binary>> = Buffer,
            Owner ! {line, Line},
            tcp_lines(Socket, Owner, Rest)
    end.

stdout(Bin) ->
    io:format("~s~n", [Bin]).

loop(Client, Live, Subs, Send) ->
    receive
        eof ->
            convex:close(Client);
        {reader_error, Reason} ->
            Message = iolist_to_binary(io_lib:format("~p", [Reason])),
            send_error(Send, <<"TransportError">>, Message),
            convex:close(Client);
        {line, Line} ->
            case convex_json:decode(Line) of
                {ok, Command} ->
                    {Client1, Live1, Subs1, Reply, Stop} =
                        handle(Command, Client, Live, Subs),
                    Send(convex_json:encode(Reply)),
                    case Stop of
                        true -> ok;
                        false -> loop(Client1, Live1, Subs1, Send)
                    end;
                _ ->
                    send_error(Send, <<"ProtocolError">>, <<"invalid NDJSON">>),
                    loop(Client, Live, Subs, Send)
            end;
        {convex_live, Id, Event} ->
            case maps:find(Id, Subs) of
                {ok, Requested} ->
                    Subscription =
                        Event#{<<"type">> => <<"subscription">>,
                               <<"subscriptionId">> => Requested},
                    Send(convex_json:encode(Subscription));
                error ->
                    ok
            end,
            loop(Client, Live, Subs, Send)
    end.

send_error(Send, Name, Message) ->
    Event = #{<<"type">> => <<"error">>,
              <<"error">> => make_error(Name, Message)},
    Send(convex_json:encode(Event)).

handle(C, Client, Live, Subs) ->
    Id = maps:get(<<"id">>, C),
    Op = maps:get(<<"op">>, C),
    case Op of
        <<"hello">> ->
            Ready =
                #{<<"protocolVersion">> => 1,
                  <<"id">> => Id,
                  <<"type">> => <<"ready">>,
                  <<"language">> => <<"erlang">>,
                  <<"implementation">> => <<"native-otp-gun-jsx-0.1.0">>,
                  <<"runtime">> =>
                      unicode:characters_to_binary(
                        erlang:system_info(otp_release))},
            {Client, Live, Subs, Ready, false};
        <<"query">> ->
            http(Id, query, C, Client, Live, Subs);
        <<"mutation">> ->
            http(Id, mutation, C, Client, Live, Subs);
        <<"action">> ->
            http(Id, action, C, Client, Live, Subs);
        <<"setAuth">> ->
            Client1 = convex:set_auth(Client, maps:get(<<"token">>, C)),
            {Client1, Live, Subs, ack(Id), false};
        <<"subscribe">> ->
            RequestedId = maps:get(<<"subscriptionId">>, C),
            %% Replace is a generation barrier: retire the old relay first.
            unsubscribe_requested(Live, RequestedId, Subs),
            {ok, Pid, SubscriptionId} =
                convex:subscribe(Client,
                                 maps:get(<<"path">>, C),
                                 maps:get(<<"args">>, C),
                                 self()),
            Remaining = remove_requested(RequestedId, Subs),
            Subs1 = maps:put(SubscriptionId, RequestedId, Remaining),
            {Client, Pid, Subs1, ack(Id), false};
        <<"unsubscribe">> ->
            RequestedId = maps:get(<<"subscriptionId">>, C),
            unsubscribe_requested(Live, RequestedId, Subs),
            {Client, Live, remove_requested(RequestedId, Subs), ack(Id), false};
        <<"debugDisconnect">> ->
            disconnect_reply(Id, Client, Live, Subs);
        <<"close">> ->
            convex:close(Client),
            Closed = #{<<"id">> => Id, <<"type">> => <<"closed">>},
            {Client, Live, #{}, Closed, true};
        _ ->
            Error =
                #{<<"id">> => Id,
                  <<"type">> => <<"error">>,
                  <<"error">> =>
                      make_error(<<"ProtocolError">>, <<"unknown operation">>)},
            {Client, Live, Subs, Error, false}
    end.

unsubscribe_requested(undefined, _RequestedId, _Subs) ->
    ok;
unsubscribe_requested(Live, RequestedId, Subs) ->
    case [Real || {Real, Requested} <- maps:to_list(Subs),
                  Requested =:= RequestedId] of
        [RealId | _] -> convex:unsubscribe(Live, RealId);
        [] -> ok
    end.

remove_requested(RequestedId, Subs) ->
    maps:filter(fun(_Real, Requested) -> Requested =/= RequestedId end, Subs).

ack(Id) ->
    #{<<"id">> => Id, <<"type">> => <<"ack">>}.

disconnect_reply(Id, Client, undefined, Subs) ->
    Reply =
        #{<<"id">> => Id,
          <<"type">> => <<"error">>,
          <<"error">> =>
              make_error(<<"TransportError">>, <<"no active WebSocket">>)},
    {Client, undefined, Subs, Reply, false};
disconnect_reply(Id, Client, Pid, Subs) ->
    case live:debug_disconnect(Pid) of
        ok ->
            {Client, Pid, Subs, ack(Id), false};
        _ ->
            Reply =
                #{<<"id">> => Id,
                  <<"type">> => <<"error">>,
                  <<"error">> =>
                      make_error(<<"TransportError">>, <<"disconnect failed">>)},
            {Client, Pid, Subs, Reply, false}
    end.

http(Id, Op, Command, Client, Live, Subs) ->
    Result =
        convex:call(Client, Op,
                    maps:get(<<"path">>, Command),
                    maps:get(<<"args">>, Command)),
    case Result of
        {ok, Value, Logs} ->
            Reply =
                #{<<"id">> => Id,
                  <<"type">> => <<"result">>,
                  <<"value">> => Value,
                  <<"logs">> => Logs},
            {Client, Live, Subs, Reply, false};
        {error, Error} ->
            Reply =
                #{<<"id">> => Id,
                  <<"type">> => <<"error">>,
                  <<"error">> => Error},
            {Client, Live, Subs, Reply, false}
    end.

make_error(Name, Message) ->
    #{name => Name, message => Message}.
