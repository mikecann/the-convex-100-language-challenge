%% Thin OTP bindings for the facilities Gleam cannot reach on its own: BSD
%% sockets, TLS, the crypto primitives the WebSocket handshake needs, a
%% monotonic clock, the standard streams, and process retirement.
%%
%% Nothing about Convex lives here. Every return shape is chosen so the Gleam
%% compiler can type it directly: `{ok, X}`/`{error, X}` become `Result`, and
%% tagged tuples such as `{received, Bytes}` become Gleam custom-type variants.
-module(convex_ffi).
-export([connect/5, socket_send/3, socket_recv/3, socket_close/1,
         listen/2, listen_port/1, accept/2,
         sha1/1, base64_encode/1, base64_decode/1, random_bytes/1,
         xor_repeating/2,
         concat_binaries/1,
         split_newline/1, find_sequence/2,
         scan_json_string/1,
         monotonic_ms/0, stdin_read/1, stdout_write/1, stderr_write/1,
         otp_release/0, plain_arguments/0, getenv/1, kill_and_wait/2]).

-define(CA_BUNDLE, "/etc/ssl/certs/ca-certificates.crt").

%% A plain TCP connection is only used for the local self-hosted backend and
%% for the deterministic fixture servers in the language-local tests.
connect(tcp, Host, Port, Timeout, _Verify) ->
    case gen_tcp:connect(binary_to_list(Host), Port, tcp_options(), Timeout) of
        {ok, Socket} -> {ok, {tcp, Socket}};
        {error, Reason} -> {error, reason(Reason)}
    end;
connect(tls, Host, Port, Timeout, Verify) ->
    ensure_started(ssl),
    HostList = binary_to_list(Host),
    Options = tls_options(HostList, Verify),
    case ssl:connect(HostList, Port, Options, Timeout) of
        {ok, Socket} -> {ok, {tls, Socket}};
        {error, Reason} -> {error, reason(Reason)}
    end.

tcp_options() ->
    [binary, {packet, raw}, {active, false}, {nodelay, true}].

%% Hostname verification is the part of TLS most easily left switched off by
%% accident, so it is spelled out rather than inherited from a default.
tls_options(Host, true) ->
    tcp_options() ++
        [{verify, verify_peer},
         {depth, 10},
         {cacertfile, ca_bundle()},
         {server_name_indication, Host},
         {customize_hostname_check,
          [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
tls_options(Host, false) ->
    tcp_options() ++ [{verify, verify_none}, {server_name_indication, Host}].

ca_bundle() ->
    case os:getenv("CONVEX_CA_BUNDLE") of
        false -> ?CA_BUNDLE;
        Path -> Path
    end.

socket_send({tcp, Socket}, Data, Timeout) ->
    _ = inet:setopts(Socket, [{send_timeout, Timeout}, {send_timeout_close, true}]),
    normalise(gen_tcp:send(Socket, Data));
socket_send({tls, Socket}, Data, Timeout) ->
    _ = ssl:setopts(Socket, [{send_timeout, Timeout}, {send_timeout_close, true}]),
    normalise(ssl:send(Socket, Data)).

%% Length 0 means "whatever has arrived". The caller owns frame reassembly, so
%% a short read is normal rather than an error.
socket_recv({tcp, Socket}, Length, Timeout) ->
    recv_result(gen_tcp:recv(Socket, Length, Timeout));
socket_recv({tls, Socket}, Length, Timeout) ->
    recv_result(ssl:recv(Socket, Length, Timeout)).

recv_result({ok, Data}) -> {received, Data};
recv_result({error, timeout}) -> recv_timeout;
recv_result({error, closed}) -> recv_closed;
recv_result({error, Reason}) -> {recv_failed, reason(Reason)}.

socket_close({tcp, Socket}) ->
    _ = gen_tcp:close(Socket),
    nil;
socket_close({tls, Socket}) ->
    _ = ssl:close(Socket),
    nil.

%% Port 0 asks the kernel for a free port, which keeps the fixture servers in
%% the language-local tests independent of each other.
listen(Host, Port) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, Address} ->
            Options = tcp_options() ++ [{reuseaddr, true}, {ip, Address}],
            case gen_tcp:listen(Port, Options) of
                {ok, Socket} -> {ok, {tcp, Socket}};
                {error, Reason} -> {error, reason(Reason)}
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

listen_port({tcp, Socket}) ->
    case inet:port(Socket) of
        {ok, Port} -> {ok, Port};
        {error, Reason} -> {error, reason(Reason)}
    end.

accept({tcp, Socket}, Timeout) ->
    case gen_tcp:accept(Socket, Timeout) of
        {ok, Accepted} ->
            case apply_adapter_send_buffer(Accepted) of
                ok -> {ok, {tcp, Accepted}};
                {error, Reason} ->
                    _ = gen_tcp:close(Accepted),
                    {error, reason(Reason)}
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Adapter controller output is deliberately bounded at the socket as well as
%% in its userspace writer. A fixed 64 KiB request makes backpressure behavior
%% portable without a test-only environment hook in the final client beam.
%% Public HTTP and Live connections never call accept/2.
apply_adapter_send_buffer(Socket) ->
    inet:setopts(Socket, [{sndbuf, 65536}]).

sha1(Data) ->
    ensure_started(crypto),
    crypto:hash(sha, Data).

base64_encode(Data) ->
    base64:encode(Data).

base64_decode(Text) ->
    try
        {ok, base64:decode(Text)}
    catch
        _:_ -> {error, nil}
    end.

random_bytes(Count) ->
    ensure_started(crypto),
    crypto:strong_rand_bytes(Count).

xor_repeating(Data, <<>>) ->
    Data;
xor_repeating(Data, Key) ->
    ensure_started(crypto),
    Size = byte_size(Data),
    KeySize = byte_size(Key),
    Repeated = binary:copy(Key, (Size + KeySize - 1) div KeySize),
    crypto:exor(Data, binary:part(Repeated, 0, Size)).

concat_binaries(Chunks) ->
    iolist_to_binary(Chunks).

split_newline(Data) ->
    case binary:match(Data, <<"\n">>) of
        nomatch -> no_line;
        {Index, 1} ->
            {line_found,
             binary:part(Data, 0, Index),
             binary:part(Data, Index + 1, byte_size(Data) - Index - 1)}
    end.

%% Return the byte offset of a delimiter without copying the bytes before it.
%% Gleam's HTTP readers retain chunks and flatten only after this search finds
%% the complete boundary.
find_sequence(Data, Sequence) ->
    case binary:match(Data, Sequence) of
        nomatch -> {error, nil};
        {Index, _Length} -> {ok, Index}
    end.

scan_json_string(Data) ->
    scan_json_string(Data, Data, 0).

scan_json_string(Original, <<>>, _Index) -> {string_end, Original};
scan_json_string(Original, <<Byte, Rest/binary>>, Index) when Byte =:= 16#22 ->
    {string_quote, binary:part(Original, 0, Index), Rest};
scan_json_string(Original, <<Byte, Rest/binary>>, Index) when Byte =:= 16#5c ->
    {string_escape, binary:part(Original, 0, Index), Rest};
scan_json_string(Original, <<Byte, Rest/binary>>, Index) when Byte < 16#20 ->
    {string_control, binary:part(Original, 0, Index), Byte, Rest};
scan_json_string(Original, <<_Byte, Rest/binary>>, Index) ->
    scan_json_string(Original, Rest, Index + 1).

%% Backoff and deadlines must not move when the wall clock is adjusted.
monotonic_ms() ->
    erlang:monotonic_time(millisecond).

%% The adapter reads bytes, not characters: NDJSON framing is defined on bytes
%% and a command may split a multi-byte character across two reads.
stdin_read(Count) ->
    _ = io:setopts(standard_io, [binary]),
    case file:read(standard_io, Count) of
        {ok, Data} -> {read_chunk, Data};
        eof -> read_end;
        {error, Reason} -> {read_failed, reason(Reason)}
    end.

stdout_write(Data) ->
    normalise(file:write(standard_io, Data)).

stderr_write(Text) ->
    io:put_chars(standard_error, [Text, $\n]),
    nil.

otp_release() ->
    unicode:characters_to_binary(erlang:system_info(otp_release)).

plain_arguments() ->
    [unicode:characters_to_binary(Argument)
     || Argument <- init:get_plain_arguments()].

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Retiring a worker has to be a barrier, not a hint. The caller relies on the
%% dead process being unable to deliver anything once this returns.
kill_and_wait(Pid, Timeout) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> {ok, nil}
    after Timeout ->
        erlang:demonitor(Monitor, [flush]),
        {error, nil}
    end.

ensure_started(Application) ->
    _ = application:ensure_all_started(Application),
    ok.

normalise(ok) -> {ok, nil};
normalise({error, Reason}) -> {error, reason(Reason)}.

reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).
