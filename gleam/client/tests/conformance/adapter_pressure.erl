%% Final-adapter stopped-reader fixture and controller.
%%
%% This module is test infrastructure. The Docker probe runs its two entry
%% points in containers separate from the real final adapter, so their memory
%% cannot make the adapter's 128 MiB cgroup evidence look better or worse.
-module(adapter_pressure).
-export([self_test/0, fixture_main/0, controller_main/0]).

-define(WS_MAX_BYTES, 8388608).
-define(NDJSON_MAX_BYTES, 9437184).
-define(NEAR_WS_BLOB_BYTES, 7864320).
-define(DELIVERABLE_BLOB_BYTES, 1900000).
-define(NEAR_COMMAND_BLOB_BYTES, 9000000).

self_test() ->
    NearCommand = near_command(),
    true = byte_size(NearCommand) > 8 * 1024 * 1024,
    true = byte_size(NearCommand) < ?NDJSON_MAX_BYTES,
    NearNumber = near_numeric_command(),
    true = byte_size(NearNumber) > 8 * 1024 * 1024,
    true = byte_size(NearNumber) < ?NDJSON_MAX_BYTES,
    NearWs = transition(0, 0, 1, 1, 0, ?NEAR_WS_BLOB_BYTES),
    true = byte_size(NearWs) > 7 * 1024 * 1024,
    true = byte_size(NearWs) < ?WS_MAX_BYTES,
    <<16#81, 127, _Length:64/unsigned-big>> = frame_header(byte_size(NearWs)),
    io:format("adapter pressure fixture self-test passed~n").

fixture_main() ->
    ok = ensure_started(crypto),
    Mode = required_mode(),
    {ok, Listener} =
        gen_tcp:listen(8081,
                       [binary, {packet, raw}, {active, false}, {reuseaddr, true},
                        {ip, {0, 0, 0, 0}}]),
    {ok, Socket} = gen_tcp:accept(Listener, 60000),
    Buffer0 = upgrade(Socket),
    {Connect, Buffer1} = read_client_text(Socket, Buffer0),
    true = contains(Connect, <<"\"Connect\"">>),
    {Add, _Buffer2} = read_client_text(Socket, Buffer1),
    true = contains(Add, <<"\"type\":\"Add\"">>),

    %% The declared frame is above the client's conservative 7 MiB retained
    %% limit but below the protocol's 8 MiB boundary. The decoder must reject
    %% it from the header, retire this TCP connection, and reconnect without
    %% attempting to buffer the large payload.
    ok = send_text_allow_close(
           Socket, transition(0, 0, 1, 1, 0, ?NEAR_WS_BLOB_BYTES)),
    ok = wait_for_close(Socket, 10000),
    gen_tcp:close(Socket),

    %% Recovery happens on a genuinely new WebSocket. Its legal update is
    %% large enough to physically stall the adapter's 4 KiB output socket.
    {ok, Second} = gen_tcp:accept(Listener, 60000),
    SecondBuffer0 = upgrade(Second),
    {SecondConnect, SecondBuffer1} = read_client_text(Second, SecondBuffer0),
    true = contains(SecondConnect, <<"\"Connect\"">>),
    {SecondAdd, _SecondBuffer2} = read_client_text(Second, SecondBuffer1),
    true = contains(SecondAdd, <<"\"type\":\"Add\"">>),
    ok = send_text(Second,
                   transition(0, 0, 1, 1, 1, ?DELIVERABLE_BLOB_BYTES)),
    case Mode of
        "recover" -> ok;
        "deadline" ->
            %% One legal event can fit in a host-specific loopback buffer even
            %% with a 4 KiB socket request. Two more sequential values force
            %% the exact sender to remain blocked, without exceeding either
            %% the client's bounded queue or the adapter's output budget.
            ok = send_text(Second,
                           transition(1, 1, 1, 2, 2,
                                      ?DELIVERABLE_BLOB_BYTES)),
            ok = send_text(Second,
                           transition(1, 2, 1, 3, 3,
                                      ?DELIVERABLE_BLOB_BYTES))
    end,
    ok = wait_for_close(Second, 10000),
    gen_tcp:close(Second),
    gen_tcp:close(Listener),
    io:format("fixture ~s complete~n", [Mode]).

controller_main() ->
    Mode = required_mode(),
    %% amd64 emulation may need several seconds to boot the minimal BEAM. This
    %% retry budget applies only before the proof begins; every stopped-reader
    %% and send deadline below starts from an observed protocol barrier.
    AdapterHost = case os:getenv("ADAPTER_HOST") of
        false -> "adapter";
        Host -> Host
    end,
    Socket = connect_retry(AdapterHost, 8080, 1200),

    case Mode of
        "near-command" -> near_command_probe(Socket);
        "recover" -> stopped_reader_probe(Socket, Mode);
        "deadline" -> stopped_reader_probe(Socket, Mode)
    end.

near_command_probe(Socket) ->
    %% Exercise the legal 9 MiB command boundary in its own final-adapter
    %% process. The stopped-reader cases each use another fresh adapter so the
    %% two independent wire limits do not manufacture an unrealistic retained
    %% heap overlap under the shared 128 MiB cgroup.
    ok = gen_tcp:send(Socket, near_command()),
    NearError = read_small_line(Socket, <<>>, 4096,
                                erlang:monotonic_time(millisecond) + 10000),
    true = contains(NearError, <<"\"id\":\"near-limit\"">>),
    true = contains(NearError, <<"\"name\":\"ProtocolError\"">>),
    %% A near-limit number used to append one byte to a growing binary on every
    %% parser step. This second legal NDJSON line proves the linear scanner
    %% rejects the unreasonable numeric token and releases it before recovery.
    ok = gen_tcp:send(Socket, near_numeric_command()),
    NumericError = read_small_line(Socket, <<>>, 4096,
                                   erlang:monotonic_time(millisecond) + 10000),
    true = contains(NumericError, <<"\"name\":\"ProtocolError\"">>),
    ok = send_line(Socket,
                   <<"{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}">>),
    Ready = read_small_line(Socket, <<>>, 4096,
                            erlang:monotonic_time(millisecond) + 10000),
    true = contains(Ready, <<"\"type\":\"ready\"">>),
    ok = send_line(Socket, <<"{\"id\":\"close\",\"op\":\"close\"}">>),
    Closed = read_small_line(Socket, <<>>, 4096,
                             erlang:monotonic_time(millisecond) + 10000),
    true = contains(Closed, <<"\"type\":\"closed\"">>),
    gen_tcp:close(Socket),
    io:format("near-command probe passed~n").

stopped_reader_probe(Socket, Mode) ->
    %% The near-command case above proves the independent NDJSON limit. Start
    %% this final adapter with a small hello so the measured peak here belongs
    %% to Live decoding and the physically blocked output writer.
    ok = send_line(Socket,
                   <<"{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}">>),
    Ready = read_small_line(Socket, <<>>, 4096,
                            erlang:monotonic_time(millisecond) + 10000),
    true = contains(Ready, <<"\"type\":\"ready\"">>),

    ok = send_line(Socket,
                   <<"{\"id\":\"pressure-subscribe\",\"op\":\"subscribe\","
                     "\"subscriptionId\":\"pressure\",\"path\":\"demo:state\","
                     "\"args\":{}}">>),
    Ack = read_small_line(Socket, <<>>, 4096,
                          erlang:monotonic_time(millisecond) + 10000),
    true = contains(Ack, <<"\"id\":\"pressure-subscribe\"">>),
    true = contains(Ack, <<"\"type\":\"ack\"">>),

    %% The near-8 MiB declared frame is rejected from its header and reported
    %% before the client reconnects for the deliverable value.
    NearFailure = read_small_line(Socket, <<>>, 4096,
                                  erlang:monotonic_time(millisecond) + 10000),
    true = contains(NearFailure, <<"\"name\":\"ProtocolError\"">>),
    true = contains(NearFailure, <<"WebSocket frame exceeds the client limit">>),

    %% Read exactly one byte of the first subscription event. This is the
    %% deterministic barrier proving the adapter has begun its large write;
    %% the controller then leaves every remaining byte unread.
    {ok, FirstByte} = gen_tcp:recv(Socket, 1, 10000),
    case Mode of
        "recover" -> recover_after_pause(Socket, FirstByte);
        "deadline" -> deadline_after_stop(Socket, FirstByte)
    end.

recover_after_pause(Socket, Buffer) ->
    %% The receive buffer is only 4 KiB. Not reading here physically stalls
    %% the adapter's near-2 MiB write, rather than merely slowing a consumer.
    timer:sleep(250),
    ok = inet:setopts(Socket, [{recbuf, 4194304}, {buffer, 4194304}]),
    {Update, Buffer1} = read_line(Socket, Buffer, 3000000, 10000),
    false = contains(Update, <<"\"count\":0">>),
    case contains(Update, <<"\"count\":1">>) of
        true -> ok;
        false ->
            PrefixBytes = erlang:min(byte_size(Update), 512),
            Prefix = binary:part(Update, 0, PrefixBytes),
            erlang:error({unexpected_recovery_event, byte_size(Update), Prefix})
    end,
    true = contains(Update, <<"\"type\":\"subscription\"">>),
    true = contains(Update, <<"\"subscriptionId\":\"pressure\"">>),
    ok = send_line(Socket, <<"{\"id\":\"close\",\"op\":\"close\"}">>),
    {Closed, _Buffer2} = read_line(Socket, Buffer1, 3000000, 10000),
    true = contains(Closed, <<"\"type\":\"closed\"">>),
    gen_tcp:close(Socket),
    io:format("recovery probe passed~n").

deadline_after_stop(Socket, Buffer) ->
    Started = erlang:monotonic_time(millisecond),
    %% Never decode another event. The adapter has a one-second send deadline,
    %% and the controller allows six seconds for the close to become visible.
    timer:sleep(2500),
    {closed, Bytes} = drain_until_closed(Socket, Buffer, 0, Started + 6000),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    true = Elapsed < 6000,
    gen_tcp:close(Socket),
    io:format("deadline probe passed: elapsed_ms=~B drained_bytes=~B~n",
              [Elapsed, Bytes]).

required_mode() ->
    case os:getenv("PRESSURE_MODE") of
        "near-command" -> "near-command";
        "recover" -> "recover";
        "deadline" -> "deadline";
        _ -> erlang:error(pressure_mode_must_be_near_command_recover_or_deadline)
    end.

connect_retry(_Host, _Port, 0) ->
    erlang:error(adapter_connect_timeout);
connect_retry(Host, Port, Attempts) ->
    Options = [binary, {packet, raw}, {active, false}, {recbuf, 4096},
               {buffer, 4096}],
    case gen_tcp:connect(Host, Port, Options, 100) of
        {ok, Socket} -> Socket;
        {error, _} ->
            timer:sleep(25),
            connect_retry(Host, Port, Attempts - 1)
    end.

near_command() ->
    iolist_to_binary([
        <<"{\"id\":\"near-limit\",\"op\":\"unknown\",\"padding\":\"">>,
        binary:copy(<<"x">>, ?NEAR_COMMAND_BLOB_BYTES),
        <<"\"}\n">>
    ]).

near_numeric_command() ->
    iolist_to_binary([
        <<"{\"id\":\"near-number\",\"op\":\"unknown\",\"padding\":" >>,
        binary:copy(<<"1">>, ?NEAR_COMMAND_BLOB_BYTES),
        <<"}\n">>
    ]).

send_line(Socket, Line) ->
    gen_tcp:send(Socket, [Line, <<"\n">>]).

read_line(Socket, Buffer, Limit, Timeout) ->
    case binary:match(Buffer, <<"\n">>) of
        {Index, 1} ->
            <<Line:Index/binary, _Newline, Rest/binary>> = Buffer,
            {Line, Rest};
        nomatch ->
            read_line_chunks(Socket, [Buffer], byte_size(Buffer), Limit,
                             erlang:monotonic_time(millisecond) + Timeout)
    end.

read_line_chunks(_Socket, _Chunks, Bytes, Limit, _Deadline) when Bytes > Limit ->
    erlang:error(controller_line_exceeded_limit);
read_line_chunks(Socket, Chunks, Bytes, Limit, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    true = Now < Deadline,
    case gen_tcp:recv(Socket, 0, erlang:max(1, Deadline - Now)) of
        {ok, Chunk} ->
            case binary:match(Chunk, <<"\n">>) of
                {Index, 1} ->
                    <<Prefix:Index/binary, _Newline, Rest/binary>> = Chunk,
                    Line = iolist_to_binary(lists:reverse([Prefix | Chunks])),
                    true = byte_size(Line) =< Limit,
                    {Line, Rest};
                nomatch ->
                    read_line_chunks(Socket, [Chunk | Chunks],
                                     Bytes + byte_size(Chunk), Limit, Deadline)
            end;
        {error, Reason} -> erlang:error({controller_read_failed, Reason})
    end.

read_small_line(Socket, Buffer, Limit, Deadline) ->
    case byte_size(Buffer) >= Limit of
        true -> erlang:error(controller_small_line_exceeded_limit);
        false ->
            Now = erlang:monotonic_time(millisecond),
            true = Now < Deadline,
            case gen_tcp:recv(Socket, 1, erlang:max(1, Deadline - Now)) of
                {ok, <<"\n">>} -> Buffer;
                {ok, Byte} ->
                    read_small_line(Socket, <<Buffer/binary, Byte/binary>>,
                                    Limit, Deadline);
                {error, Reason} -> erlang:error({controller_read_failed, Reason})
            end
    end.

drain_until_closed(Socket, Buffer, Total, Deadline) ->
    NewTotal = Total + byte_size(Buffer),
    true = NewTotal =< 16 * 1024 * 1024,
    Now = erlang:monotonic_time(millisecond),
    true = Now < Deadline,
    case gen_tcp:recv(Socket, 65536, erlang:min(250, Deadline - Now)) of
        {ok, Chunk} -> drain_until_closed(Socket, <<>>, NewTotal + byte_size(Chunk),
                                          Deadline);
        {error, timeout} -> drain_until_closed(Socket, <<>>, NewTotal, Deadline);
        {error, closed} -> {closed, NewTotal};
        {error, Reason} -> erlang:error({controller_drain_failed, Reason})
    end.

upgrade(Socket) ->
    {Head, Rest} = read_http_head(Socket, <<>>),
    Key = header_value(Head, <<"sec-websocket-key:">>),
    Accept = base64:encode(crypto:hash(sha, <<Key/binary,
                                             "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
    ok = gen_tcp:send(Socket,
                      [<<"HTTP/1.1 101 Switching Protocols\r\n"
                         "Upgrade: websocket\r\n"
                         "Connection: Upgrade\r\n"
                         "Sec-WebSocket-Accept: ">>, Accept, <<"\r\n\r\n">>]),
    Rest.

read_http_head(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        {Index, 4} ->
            <<Head:Index/binary, _Separator:4/binary, Rest/binary>> = Buffer,
            {Head, Rest};
        nomatch when byte_size(Buffer) > 65536 -> erlang:error(http_head_too_large);
        nomatch ->
            case gen_tcp:recv(Socket, 0, 10000) of
                {ok, Chunk} -> read_http_head(Socket, <<Buffer/binary, Chunk/binary>>);
                {error, Reason} -> erlang:error({http_head_failed, Reason})
            end
    end.

header_value(Head, Name) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    header_value_lines(Lines, Name).

header_value_lines([], Name) -> erlang:error({missing_header, Name});
header_value_lines([Line | Rest], Name) ->
    Lower = unicode:characters_to_binary(string:lowercase(binary_to_list(Line))),
    NameSize = byte_size(Name),
    case Lower of
        <<Name:NameSize/binary, _LowerValue/binary>> ->
            %% Header names are case-insensitive, but Sec-WebSocket-Key is a
            %% case-sensitive base64 value. Match using the folded line and
            %% derive the accept hash from the untouched original bytes.
            <<_OriginalName:NameSize/binary, Value/binary>> = Line,
            unicode:characters_to_binary(string:trim(binary_to_list(Value)));
        _ -> header_value_lines(Rest, Name)
    end.

read_client_text(Socket, Buffer) ->
    case take_client_frame(Buffer) of
        more ->
            %% Parsing the preceding near-9 MiB controller command can take
            %% well over ten seconds under amd64 emulation. This wait is only
            %% fixture setup; the measured writer deadline begins later from
            %% the controller's observed first-byte barrier.
            case gen_tcp:recv(Socket, 0, 60000) of
                {ok, Chunk} -> read_client_text(Socket, <<Buffer/binary, Chunk/binary>>);
                {error, Reason} -> erlang:error({client_frame_failed, Reason})
            end;
        {ok, 1, Payload, Rest} -> {Payload, Rest};
        {ok, _Opcode, _Payload, Rest} -> read_client_text(Socket, Rest)
    end.

take_client_frame(Buffer) when byte_size(Buffer) < 2 -> more;
take_client_frame(<<First, Second, Rest/binary>>) ->
    true = (Second band 16#80) =/= 0,
    Opcode = First band 16#0f,
    case Second band 16#7f of
        Length when Length < 126 -> take_client_payload(Opcode, Length, Rest);
        126 when byte_size(Rest) >= 2 ->
            <<Length:16/unsigned-big, Tail/binary>> = Rest,
            take_client_payload(Opcode, Length, Tail);
        127 when byte_size(Rest) >= 8 ->
            <<Length:64/unsigned-big, Tail/binary>> = Rest,
            take_client_payload(Opcode, Length, Tail);
        _ -> more
    end.

take_client_payload(_Opcode, Length, Rest) when byte_size(Rest) < Length + 4 -> more;
take_client_payload(Opcode, Length, Bytes) ->
    <<Mask:4/binary, Payload:Length/binary, Rest/binary>> = Bytes,
    {ok, Opcode, unmask(Payload, Mask), Rest}.

unmask(Payload, <<K0, K1, K2, K3>>) ->
    Keys = {K0, K1, K2, K3},
    unmask(Payload, Keys, 0, []).

unmask(<<>>, _Keys, _Index, Acc) -> iolist_to_binary(lists:reverse(Acc));
unmask(<<Byte, Rest/binary>>, Keys, Index, Acc) ->
    Key = element((Index rem 4) + 1, Keys),
    unmask(Rest, Keys, Index + 1, [Byte bxor Key | Acc]).

send_text(Socket, Payload) ->
    gen_tcp:send(Socket, [frame_header(byte_size(Payload)), Payload]).

send_text_allow_close(Socket, Payload) ->
    case gen_tcp:send(Socket, [frame_header(byte_size(Payload)), Payload]) of
        ok -> ok;
        {error, closed} -> ok;
        {error, econnreset} -> ok
    end.

frame_header(Length) when Length < 126 -> <<16#81, Length>>;
frame_header(Length) when Length < 65536 -> <<16#81, 126, Length:16/unsigned-big>>;
frame_header(Length) -> <<16#81, 127, Length:64/unsigned-big>>.

transition(StartQuerySet, StartTimestamp, EndQuerySet, EndTimestamp, Count,
           BlobBytes) ->
    iolist_to_binary([
        <<"{\"type\":\"Transition\",\"startVersion\":">>,
        version(StartQuerySet, StartTimestamp),
        <<",\"endVersion\":">>, version(EndQuerySet, EndTimestamp),
        <<",\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,"
          "\"value\":{\"count\":">>, integer_to_binary(Count),
        <<",\"blob\":\"">>, binary:copy(<<"x">>, BlobBytes),
        <<"\"},\"logLines\":[]}]}">>
    ]).

version(QuerySet, Timestamp) ->
    [<<"{\"querySet\":">>, integer_to_binary(QuerySet),
     <<",\"identity\":0,\"ts\":\"">>, timestamp(Timestamp), <<"\"}">>].

timestamp(Value) -> base64:encode(<<Value:64/little-signed>>).

wait_for_close(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, _Bytes} -> wait_for_close(Socket, Timeout);
        {error, closed} -> ok;
        {error, econnreset} -> ok;
        {error, timeout} -> erlang:error(fixture_close_timeout)
    end.

contains(Haystack, Needle) -> binary:match(Haystack, Needle) =/= nomatch.

ensure_started(Application) ->
    case application:ensure_all_started(Application) of
        {ok, _} -> ok;
        {error, {already_started, Application}} -> ok;
        {error, Reason} -> erlang:error({application_start_failed, Reason})
    end.
