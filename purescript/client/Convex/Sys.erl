%% Erlang side of Convex.Sys.
%%
%% Nothing about Convex lives here. Sum types are never constructed on this
%% side either: the PureScript declaration passes its own constructors in, and
%% this module applies whichever one describes what happened. That keeps the
%% FFI independent of how purerl chooses to represent a tagged union.
%%
%% Every function whose PureScript type ends in `Effect a` returns a
%% zero-argument fun, which is how Convex.Prelude represents an effect.
-module(convex_sys@foreign).

-export([connectImpl/7, sendImpl/5, recvImpl/7, close/1,
         listenImpl/3, listenPortImpl/3, acceptImpl/4, controllingProcess/2,
         monotonicMs/0, randomBytes/1,
         stdinReadImpl/4, stdoutWriteImpl/3, stderrWrite/1,
         otpRelease/0, plainArgumentsImpl/2, getenvImpl/3, halt/1,
         spawnProcess/1, selfPid/0,
         sendCommand/2, receiveCommandImpl/3,
         sendEvent/2, receiveEventImpl/3,
         newRef/0, sendReply/3, awaitReplyImpl/4,
         sendCommandAfter/3, cancelTimer/1, killAndWait/2]).

-define(CA_BUNDLE, "/etc/ssl/certs/ca-certificates.crt").

%% ---------------------------------------------------------------------------
%% Sockets and TLS
%% ---------------------------------------------------------------------------

connectImpl(Secure, Host, Port, Timeout, VerifyPeer, Left, Right) ->
    fun() ->
        HostList = binary_to_list(Host),
        Outcome =
            case Secure of
                true ->
                    _ = application:ensure_all_started(ssl),
                    case ssl:connect(HostList, Port,
                                     tls_options(HostList, VerifyPeer),
                                     Timeout) of
                        {ok, Socket} -> {ok, {tls, Socket}};
                        {error, Reason} -> {error, Reason}
                    end;
                false ->
                    case gen_tcp:connect(HostList, Port, tcp_options(),
                                         Timeout) of
                        {ok, Socket} -> {ok, {tcp, Socket}};
                        {error, Reason} -> {error, Reason}
                    end
            end,
        case Outcome of
            {ok, Handle} -> Right(Handle);
            {error, Why} -> Left(reason(Why))
        end
    end.

tcp_options() ->
    [binary, {packet, raw}, {active, false}, {nodelay, true}].

%% Hostname verification is the part of TLS most easily left switched off by
%% accident, so it is spelled out here rather than inherited from a default.
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

sendImpl(Socket, Payload, Timeout, Left, Right) ->
    fun() ->
        Outcome =
            case Socket of
                {tcp, Handle} ->
                    _ = inet:setopts(Handle, [{send_timeout, Timeout},
                                              {send_timeout_close, true}]),
                    gen_tcp:send(Handle, Payload);
                {tls, Handle} ->
                    _ = ssl:setopts(Handle, [{send_timeout, Timeout},
                                             {send_timeout_close, true}]),
                    ssl:send(Handle, Payload)
            end,
        case Outcome of
            ok -> Right(unit);
            {error, Reason} -> Left(reason(Reason))
        end
    end.

%% Length 0 means "whatever has arrived".
recvImpl(Socket, Length, Timeout, Received, Timedout, Closed, Failed) ->
    fun() ->
        Outcome =
            case Socket of
                {tcp, Handle} -> gen_tcp:recv(Handle, Length, Timeout);
                {tls, Handle} -> ssl:recv(Handle, Length, Timeout)
            end,
        case Outcome of
            {ok, Data} -> Received(Data);
            {error, timeout} -> Timedout;
            {error, closed} -> Closed;
            {error, Reason} -> Failed(reason(Reason))
        end
    end.

%% Closing is best effort. Ownership of a socket can have moved on by the time
%% a caller tidies up, and a failed close must not take a process down.
close(Socket) ->
    fun() ->
        try
            case Socket of
                {tcp, Handle} -> _ = gen_tcp:close(Handle);
                {tls, Handle} -> _ = ssl:close(Handle)
            end
        catch
            _:_ -> ok
        end,
        unit
    end.

listenImpl(Port, Left, Right) ->
    fun() ->
        Options = tcp_options() ++ [{reuseaddr, true}, {ip, {127, 0, 0, 1}}],
        case gen_tcp:listen(Port, Options) of
            {ok, Socket} -> Right({tcp, Socket});
            {error, Reason} -> Left(reason(Reason))
        end
    end.

listenPortImpl(Socket, Left, Right) ->
    fun() ->
        {tcp, Handle} = Socket,
        case inet:port(Handle) of
            {ok, Port} -> Right(Port);
            {error, Reason} -> Left(reason(Reason))
        end
    end.

acceptImpl(Socket, Timeout, Left, Right) ->
    fun() ->
        {tcp, Handle} = Socket,
        case gen_tcp:accept(Handle, Timeout) of
            {ok, Accepted} -> Right({tcp, Accepted});
            {error, Reason} -> Left(reason(Reason))
        end
    end.

%% A passive socket may only be read by its owning process, so ownership is
%% transferred explicitly rather than assumed. Must be called by the owner.
controllingProcess(Socket, Pid) ->
    fun() ->
        Outcome =
            case Socket of
                {tcp, Handle} -> gen_tcp:controlling_process(Handle, Pid);
                {tls, Handle} -> ssl:controlling_process(Handle, Pid)
            end,
        Outcome =:= ok
    end.

%% ---------------------------------------------------------------------------
%% Clock, randomness, and the standard streams
%% ---------------------------------------------------------------------------

monotonicMs() ->
    fun() -> erlang:monotonic_time(millisecond) end.

randomBytes(Count) ->
    fun() ->
        _ = application:ensure_all_started(crypto),
        crypto:strong_rand_bytes(Count)
    end.

stdinReadImpl(Count, Chunk, End, Failed) ->
    fun() ->
        _ = io:setopts(standard_io, [binary]),
        case file:read(standard_io, Count) of
            {ok, Data} -> Chunk(Data);
            eof -> End;
            {error, Reason} -> Failed(reason(Reason))
        end
    end.

stdoutWriteImpl(Payload, Left, Right) ->
    fun() ->
        case file:write(standard_io, Payload) of
            ok -> Right(unit);
            {error, Reason} -> Left(reason(Reason))
        end
    end.

stderrWrite(Text) ->
    fun() ->
        io:put_chars(standard_error, [Text, $\n]),
        unit
    end.

otpRelease() ->
    fun() -> unicode:characters_to_binary(erlang:system_info(otp_release)) end.

plainArgumentsImpl(Nil, Cons) ->
    fun() ->
        lists:foldr(
          fun(Argument, Acc) ->
              (Cons(unicode:characters_to_binary(Argument)))(Acc)
          end,
          Nil,
          init:get_plain_arguments())
    end.

getenvImpl(Name, Nothing, Just) ->
    fun() ->
        case os:getenv(binary_to_list(Name)) of
            false -> Nothing;
            Value -> Just(unicode:characters_to_binary(Value))
        end
    end.

halt(Code) ->
    fun() -> erlang:halt(Code) end.

%% ---------------------------------------------------------------------------
%% Processes, mailboxes, and timers
%% ---------------------------------------------------------------------------

spawnProcess(Action) ->
    fun() -> erlang:spawn(fun() -> _ = Action(), ok end) end.

selfPid() ->
    fun() -> erlang:self() end.

sendCommand(Pid, Message) ->
    fun() ->
        Pid ! {'$convex_command', Message},
        unit
    end.

receiveCommandImpl(Timeout, Nothing, Just) ->
    fun() ->
        receive
            {'$convex_command', Message} -> Just(Message)
        after Timeout ->
            Nothing
        end
    end.

sendEvent(Pid, Message) ->
    fun() ->
        Pid ! {'$convex_event', Message},
        unit
    end.

receiveEventImpl(Timeout, Nothing, Just) ->
    fun() ->
        receive
            {'$convex_event', Message} -> Just(Message)
        after Timeout ->
            Nothing
        end
    end.

newRef() ->
    fun() -> erlang:make_ref() end.

sendReply(Pid, Reference, Value) ->
    fun() ->
        Pid ! {'$convex_reply', Reference, Value},
        unit
    end.

%% Matching on the reference makes this a selective receive: any command or
%% event already sitting in the mailbox stays there untouched.
awaitReplyImpl(Reference, Timeout, Nothing, Just) ->
    fun() ->
        receive
            {'$convex_reply', Reference, Value} -> Just(Value)
        after Timeout ->
            Nothing
        end
    end.

sendCommandAfter(Pid, Delay, Message) ->
    fun() -> erlang:send_after(Delay, Pid, {'$convex_command', Message}) end.

%% Cancelling cannot recall a message that has already been delivered, so every
%% caller also carries a token it checks when the command finally arrives.
cancelTimer(Timer) ->
    fun() ->
        _ = erlang:cancel_timer(Timer),
        unit
    end.

killAndWait(Pid, Timeout) ->
    fun() ->
        Monitor = erlang:monitor(process, Pid),
        exit(Pid, kill),
        receive
            {'DOWN', Monitor, process, Pid, _} -> true
        after Timeout ->
            erlang:demonitor(Monitor, [flush]),
            false
        end
    end.

reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).
