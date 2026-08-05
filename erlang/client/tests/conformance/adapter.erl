%% Adapter protocol v1. Input and output each have an explicit byte bound.
%% The controller process never performs a potentially blocking socket write:
%% one writer manager accounts for queued and physically in-flight binaries,
%% while one sender may block in gen_tcp:send/2 without growing any mailbox.
-module(adapter).
-export([main/0, ndjson_until/3]).

-define(MAX_NDJSON_BYTES, 1048576).
-define(MAX_OUTPUT_COUNT, 16).
-define(MAX_OUTPUT_BYTES, 262144).
-define(OUTPUT_CALL_TIMEOUT, 1000).

main() ->
    Url =
        case os:getenv("CONVEX_URL") of
            false -> "http://127.0.0.1";
            Value -> Value
        end,
    {ok, Client} = convex:new(Url),
    case os:getenv("ADAPTER_LISTEN") of
        false -> stdio_start(Client);
        Address -> tcp_start(Address, Client)
    end.

stdio_start(Client) ->
    Writer = output_start(self(), stdout),
    Owner = self(),
    _Reader = spawn(fun() -> stdin_reader(Owner) end),
    try loop(Client, maps:get(live, Client), #{}, Writer)
    after output_stop(Writer)
    end.

tcp_start(Address, Client) ->
    [Host, PortText] = string:split(Address, ":", all),
    Options =
        [binary, {packet, raw}, {active, false}, {reuseaddr, true},
         {recbuf, 16384},
         {ip, host(Host)}],
    {ok, Listen} = gen_tcp:listen(list_to_integer(PortText), Options),
    try
        {ok, Socket} = gen_tcp:accept(Listen),
        Writer = output_start(self(), {tcp, Socket}),
        try
            Owner = self(),
            _Reader = spawn(fun() -> tcp_reader(Socket, Owner, <<>>, false) end),
            loop(Client, maps:get(live, Client), #{}, Writer)
        after
            %% Killing the sender before closing the socket bounds shutdown
            %% even when the peer has stopped reading and send/2 is blocked.
            output_stop(Writer),
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

%% Both transports feed the same newline parser. EOF always discards a final
%% fragment, and a reader waits for an acknowledgement after each command, so
%% fast input cannot build an unbounded adapter mailbox.
stdin_reader(Owner) ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    stdin_reader_loop(Owner).

stdin_reader_loop(Owner) ->
    case io:request(standard_io,
                    {get_until, latin1, "", ?MODULE, ndjson_until,
                     [?MAX_NDJSON_BYTES]}) of
        eof -> Owner ! eof;
        {error, Reason} -> reader_deliver(Owner, {reader_error, Reason});
        oversized ->
            reader_deliver(Owner, oversized_command),
            stdin_reader_loop(Owner);
        {line, Line} ->
            reader_deliver(Owner, {line, Line}),
            stdin_reader_loop(Owner)
    end.

%% OTP's get_until I/O request calls this parser incrementally. The
%% continuation retains at most one bounded line; once the limit is crossed it
%% remembers only that it is discarding bytes until the next newline.
ndjson_until(Continuation, Chars, Limit) ->
    State =
        case Continuation of
            [] -> {normal, <<>>};
            _ -> Continuation
        end,
    ndjson_until_chars(State, Chars, Limit).

ndjson_until_chars({normal, _Partial}, eof, _Limit) -> {done, eof, []};
ndjson_until_chars(discarding, eof, _Limit) -> {done, eof, []};
ndjson_until_chars({normal, Buffer}, Chars, Limit) ->
    Combined = <<Buffer/binary, (iolist_to_binary(Chars))/binary>>,
    case binary:match(Combined, <<"\n">>) of
        {Position, 1} when Position =< Limit ->
            <<Line:Position/binary, _Newline, Rest/binary>> = Combined,
            {done, {line, Line}, binary_to_list(Rest)};
        {Position, 1} ->
            <<_Oversized:Position/binary, _Newline, Rest/binary>> = Combined,
            {done, oversized, binary_to_list(Rest)};
        nomatch when byte_size(Combined) > Limit ->
            {more, discarding};
        nomatch ->
            {more, {normal, Combined}}
    end;
ndjson_until_chars(discarding, Chars, _Limit) ->
    Data = iolist_to_binary(Chars),
    case binary:match(Data, <<"\n">>) of
        nomatch -> {more, discarding};
        {Position, 1} ->
            <<_Oversized:Position/binary, _Newline, Rest/binary>> = Data,
            {done, oversized, binary_to_list(Rest)}
    end.

tcp_reader(Socket, Owner, Buffer, Discarding) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            {Buffer1, Discarding1} =
                consume_input(Owner, Buffer, Discarding, Data),
            tcp_reader(Socket, Owner, Buffer1, Discarding1);
        {error, closed} ->
            %% NDJSON requires a terminating newline on every command.
            Owner ! eof;
        {error, Reason} ->
            reader_deliver(Owner, {reader_error, Reason})
    end.

consume_input(Owner, _Buffer, true, Data) ->
    case binary:match(Data, <<"\n">>) of
        nomatch -> {<<>>, true};
        {Position, 1} ->
            <<_Discarded:Position/binary, _Newline, Rest/binary>> = Data,
            consume_input(Owner, <<>>, false, Rest)
    end;
consume_input(Owner, Buffer, false, Data) ->
    parse_lines(Owner, <<Buffer/binary, Data/binary>>).

parse_lines(Owner, Buffer) ->
    case binary:match(Buffer, <<"\n">>) of
        {Position, 1} when Position =< ?MAX_NDJSON_BYTES ->
            <<Line:Position/binary, _Newline, Rest/binary>> = Buffer,
            reader_deliver(Owner, {line, Line}),
            parse_lines(Owner, Rest);
        {Position, 1} ->
            <<_Oversized:Position/binary, _Newline, Rest/binary>> = Buffer,
            reader_deliver(Owner, oversized_command),
            parse_lines(Owner, Rest);
        nomatch when byte_size(Buffer) > ?MAX_NDJSON_BYTES ->
            {<<>>, true};
        nomatch ->
            {Buffer, false}
    end.

reader_deliver(Owner, Event) ->
    Ref = make_ref(),
    Owner ! {reader, self(), Ref, Event},
    receive
        {reader_ack, Ref} -> ok
    after 5000 ->
        exit(normal)
    end.

loop(Client, Live, Subs, Writer) ->
    receive
        eof ->
            convex:close(Client);
        {output_error, Reason} ->
            diagnostics("controller output failed", Reason),
            convex:close(Client);
        {reader, Reader, Ref, {reader_error, Reason}} ->
            Message = reason_binary(Reason),
            _ = emit(Writer, error_event(undefined, <<"TransportError">>, Message)),
            _ = output_flush(Writer, 2000),
            Reader ! {reader_ack, Ref},
            convex:close(Client);
        {reader, Reader, Ref, oversized_command} ->
            Result =
                emit(Writer,
                     error_event(undefined, <<"ProtocolError">>,
                                 <<"NDJSON command exceeds 1 MiB">>)),
            Reader ! {reader_ack, Ref},
            continue_or_close(Result, Client, Live, Subs, Writer);
        {reader, Reader, Ref, {line, Line}} ->
            Result = process_line(Line, Client, Live, Subs, Writer),
            Reader ! {reader_ack, Ref},
            case Result of
                {continue, Client1, Live1, Subs1} ->
                    loop(Client1, Live1, Subs1, Writer);
                stop ->
                    _ = output_flush(Writer, 2000),
                    ok;
                overflow ->
                    diagnostics("controller output budget exceeded", bounded_output),
                    convex:close(Client)
            end;
        {convex_live, Id, Event} ->
            case maps:find(Id, Subs) of
                {ok, Requested} ->
                    Subscription =
                        Event#{<<"type">> => <<"subscription">>,
                               <<"subscriptionId">> => Requested},
                    continue_or_close(emit(Writer, Subscription),
                                      Client, Live, Subs, Writer);
                error ->
                    loop(Client, Live, Subs, Writer)
            end
    end.

process_line(Line, Client, Live, Subs, Writer) ->
    case decode_command(Line) of
        {ok, Command} ->
            {Client1, Live1, Subs1, Reply, Stop} =
                handle(Command, Client, Live, Subs),
            case emit(Writer, Reply) of
                ok when Stop -> stop;
                ok -> {continue, Client1, Live1, Subs1};
                overflow -> overflow
            end;
        {error, Id, Message} ->
            case emit(Writer, error_event(Id, <<"ProtocolError">>, Message)) of
                ok -> {continue, Client, Live, Subs};
                overflow -> overflow
            end
    end.

continue_or_close(ok, Client, Live, Subs, Writer) ->
    loop(Client, Live, Subs, Writer);
continue_or_close(overflow, Client, _Live, _Subs, _Writer) ->
    diagnostics("controller output budget exceeded", bounded_output),
    convex:close(Client).

decode_command(Line) ->
    case convex_json:decode(Line) of
        {ok, Command} when is_map(Command) -> validate_command(Command);
        _ -> {error, undefined, <<"invalid NDJSON command">>}
    end.

validate_command(Command) ->
    Id = optional_id(Command),
    case {valid_id(Id), maps:find(<<"op">>, Command)} of
        {true, {ok, Op}} when is_binary(Op) ->
            validate_operation(Op, Id, Command);
        _ ->
            {error, Id, <<"command requires string id and op">>}
    end.

validate_operation(<<"hello">>, Id, #{<<"protocolVersion">> := 1}) ->
    {ok, #{<<"id">> => Id, <<"op">> => <<"hello">>}};
validate_operation(Op, _Id, Command)
  when Op =:= <<"query">>; Op =:= <<"mutation">>; Op =:= <<"action">> ->
    case Command of
        #{<<"id">> := Id, <<"path">> := Path, <<"args">> := Args}
          when is_binary(Path), byte_size(Path) >= 3, is_map(Args) ->
            {ok, #{<<"id">> => Id, <<"op">> => Op,
                   <<"path">> => Path, <<"args">> => Args}};
        _ -> {error, optional_id(Command), <<"malformed function command">>}
    end;
validate_operation(<<"setAuth">>, Id, #{<<"token">> := Token})
  when is_binary(Token) ->
    {ok, #{<<"id">> => Id, <<"op">> => <<"setAuth">>, <<"token">> => Token}};
validate_operation(<<"subscribe">>, Id,
                   #{<<"subscriptionId">> := Requested, <<"path">> := Path,
                     <<"args">> := Args})
  when is_binary(Requested), byte_size(Requested) > 0,
       byte_size(Requested) =< 128, is_binary(Path), is_map(Args) ->
    {ok, #{<<"id">> => Id, <<"op">> => <<"subscribe">>,
           <<"subscriptionId">> => Requested, <<"path">> => Path,
           <<"args">> => Args}};
validate_operation(<<"unsubscribe">>, Id, #{<<"subscriptionId">> := Requested})
  when is_binary(Requested), byte_size(Requested) > 0,
       byte_size(Requested) =< 128 ->
    {ok, #{<<"id">> => Id, <<"op">> => <<"unsubscribe">>,
           <<"subscriptionId">> => Requested}};
validate_operation(Op, Id, _Command)
  when Op =:= <<"close">>; Op =:= <<"debugDisconnect">> ->
    {ok, #{<<"id">> => Id, <<"op">> => Op}};
validate_operation(Op, Id, _Command)
  when Op =:= <<"hello">>; Op =:= <<"setAuth">>;
       Op =:= <<"subscribe">>; Op =:= <<"unsubscribe">> ->
    {error, Id, <<"malformed command">>};
validate_operation(_Op, Id, Command) ->
    {ok, #{<<"id">> => Id, <<"op">> => maps:get(<<"op">>, Command)}}.

optional_id(Command) ->
    case maps:find(<<"id">>, Command) of
        {ok, Id} when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 128 -> Id;
        _ -> undefined
    end.

valid_id(Id) -> is_binary(Id) andalso byte_size(Id) > 0 andalso byte_size(Id) =< 128.

error_event(undefined, Name, Message) ->
    #{<<"type">> => <<"error">>, <<"error">> => make_error(Name, Message)};
error_event(Id, Name, Message) ->
    #{<<"id">> => Id, <<"type">> => <<"error">>,
      <<"error">> => make_error(Name, Message)}.

handle(C, Client, Live, Subs) ->
    Id = maps:get(<<"id">>, C),
    case maps:get(<<"op">>, C) of
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
        <<"query">> -> http(Id, query, C, Client, Live, Subs);
        <<"mutation">> -> http(Id, mutation, C, Client, Live, Subs);
        <<"action">> -> http(Id, action, C, Client, Live, Subs);
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
            Subs1 = remove_requested(RequestedId, Subs),
            %% A conformance adapter is deliberately long-lived, but an idle
            %% Live owner is not reusable evidence. Retire it once its last
            %% relay is gone so the next subscription owns a fresh transport
            %% rather than inheriting a closing Gun connection or timer.
            %% Keep the HTTP/auth client state intact across that boundary.
            {Client1, Live1} = reset_idle_live(Client, Live, Subs1),
            {Client1, Live1, Subs1, ack(Id), false};
        <<"debugDisconnect">> ->
            disconnect_reply(Id, Client, Live, Subs);
        <<"close">> ->
            convex:close(Client),
            Closed = #{<<"id">> => Id, <<"type">> => <<"closed">>},
            {Client, Live, #{}, Closed, true};
        _ ->
            {Client, Live, Subs,
             error_event(Id, <<"ProtocolError">>, <<"unknown operation">>), false}
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

reset_idle_live(Client, Live, Subs) when map_size(Subs) =:= 0, Live =/= undefined ->
    ok = convex:close(Client),
    {ok, FreshClient0} = convex:new(maps:get(url, Client)),
    FreshClient = restore_auth(FreshClient0, maps:get(token, Client)),
    {FreshClient, maps:get(live, FreshClient)};
reset_idle_live(Client, Live, _Subs) ->
    {Client, Live}.

restore_auth(Client, undefined) -> Client;
restore_auth(Client, Token) -> convex:set_auth(Client, Token).

ack(Id) ->
    #{<<"id">> => Id, <<"type">> => <<"ack">>}.

disconnect_reply(Id, Client, undefined, Subs) ->
    Reply = error_event(Id, <<"TransportError">>, <<"no active WebSocket">>),
    {Client, undefined, Subs, Reply, false};
disconnect_reply(Id, Client, Pid, Subs) ->
    case live:debug_disconnect(Pid) of
        ok -> {Client, Pid, Subs, ack(Id), false};
        _ ->
            Reply = error_event(Id, <<"TransportError">>, <<"disconnect failed">>),
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

%% The manager owns the global budget. Count and Bytes include the sender's
%% current binary, so a blocked syscall can never hide memory from accounting.
output_start(Owner, Transport) ->
    spawn(fun() -> output_manager(Owner, Transport) end).

output_manager(Owner, Transport) ->
    Manager = self(),
    Sender = spawn(fun() -> output_sender(Manager, Transport) end),
    output_manager(#{owner => Owner, sender => Sender, queue => queue:new(),
                     count => 0, bytes => 0, inflight => undefined,
                     flush_waiters => []}).

output_manager(State0) ->
    receive
        {enqueue, From, Ref, Payload} ->
            Size = byte_size(Payload),
            Count = maps:get(count, State0),
            Bytes = maps:get(bytes, State0),
            case Count < ?MAX_OUTPUT_COUNT andalso
                 Bytes + Size =< ?MAX_OUTPUT_BYTES of
                true ->
                    From ! {output_result, Ref, ok},
                    State1 =
                        State0#{queue => queue:in({Payload, Size}, maps:get(queue, State0)),
                                count => Count + 1, bytes => Bytes + Size},
                    output_manager(dispatch_output(State1));
                false ->
                    From ! {output_result, Ref, overflow},
                    output_manager(State0)
            end;
        {output_done, Sender, Result} when Sender =:= map_get(sender, State0) ->
            Inflight = maps:get(inflight, State0),
            State1 =
                State0#{count => maps:get(count, State0) - 1,
                        bytes => maps:get(bytes, State0) - Inflight,
                        inflight => undefined},
            case Result of
                ok -> ok;
                {error, Reason} -> maps:get(owner, State0) ! {output_error, Reason}
            end,
            output_manager(notify_flushers(dispatch_output(State1)));
        {flush, From, Ref} ->
            case maps:get(count, State0) of
                0 -> From ! {output_flushed, Ref}, output_manager(State0);
                _ ->
                    Waiters = [{From, Ref} | maps:get(flush_waiters, State0)],
                    output_manager(State0#{flush_waiters => Waiters})
            end;
        stop ->
            exit(maps:get(sender, State0), kill),
            ok
    end.

dispatch_output(State = #{inflight := undefined, queue := Queue, sender := Sender}) ->
    case queue:out(Queue) of
        {empty, _} -> State;
        {{value, {Payload, Size}}, Rest} ->
            Sender ! {output, Payload},
            State#{queue => Rest, inflight => Size}
    end;
dispatch_output(State) -> State.

notify_flushers(State = #{count := 0, flush_waiters := Waiters}) ->
    lists:foreach(fun({Pid, Ref}) -> Pid ! {output_flushed, Ref} end, Waiters),
    State#{flush_waiters => []};
notify_flushers(State) -> State.

output_sender(Manager, Transport) ->
    receive
        {output, Payload} ->
            Result = write_output(Transport, Payload),
            Manager ! {output_done, self(), Result},
            output_sender(Manager, Transport)
    end.

write_output(stdout, Payload) ->
    io:put_chars(standard_io, Payload);
write_output({tcp, Socket}, Payload) ->
    gen_tcp:send(Socket, Payload).

emit(Writer, Event) ->
    Payload = <<(convex_json:encode(Event))/binary, "\n">>,
    Ref = make_ref(),
    Writer ! {enqueue, self(), Ref, Payload},
    receive
        {output_result, Ref, Result} -> Result
    after ?OUTPUT_CALL_TIMEOUT ->
        overflow
    end.

output_flush(Writer, Timeout) ->
    Ref = make_ref(),
    Writer ! {flush, self(), Ref},
    receive {output_flushed, Ref} -> ok after Timeout -> timeout end.

output_stop(Writer) ->
    Writer ! stop,
    ok.

reason_binary(Reason) when is_binary(Reason) -> Reason;
reason_binary(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

diagnostics(Context, Reason) ->
    io:format(standard_error, "~s: ~p~n", [Context, Reason]).
