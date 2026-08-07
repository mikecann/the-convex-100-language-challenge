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
         monotonicMs/0, randomBytes/1, collectGarbage/0,
         stdinReadImpl/3, stdoutWriteImpl/3, stderrWrite/1,
         otpRelease/0, plainArgumentsImpl/2, getenvImpl/3, halt/1,
         spawnProcess/1, selfPid/0,
         sendCommand/2, receiveCommandImpl/3,
         sendEvent/2, receiveEventImpl/3,
         newRef/0, sendReply/3, awaitReplyImpl/4,
         sendCommandAfter/3, cancelTimer/1, killAndWait/2]).

-define(CA_BUNDLE, "/etc/ssl/certs/ca-certificates.crt").

%% Where the reading process remembers its standard input port. A port belongs
%% to the process that opened it, and only that process may receive from it.
-define(STDIN_KEY, '$convex_stdin').

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

%% Collect this process now, sweeping the old generation too.
%%
%% A byte string larger than 64 bytes lives off the process heap and is freed
%% by reference count, and the reference this process holds is only dropped
%% when the heap cell naming it is collected. A loop that keeps a small heap
%% therefore collects rarely, so megabytes that are already unreachable stay
%% resident: the reader below abandons whole rejected commands and would
%% otherwise carry several of them at once. A full sweep is the only collection
%% that reaches references promoted to the old generation.
collectGarbage() ->
    fun() ->
        _ = erlang:garbage_collect(erlang:self(), [{type, major}]),
        unit
    end.

%% Standard input is read through a port this process owns rather than through
%% the `standard_io` io server, because the io server is not flow controlled.
%% Under `-noshell` OTP starts a tty reader that pushes everything it can take
%% from file descriptor 0 into the `group` process's mailbox whether or not
%% anybody has asked for data, so a peer that writes faster than this client
%% parses is buffered on the emulator's heap instead of in the kernel's pipe.
%% Draining 54 MiB that way was measured here at 6.0 s and 101 MB of resident
%% memory, with 26k messages holding 27 MB of reference-counted binaries queued
%% inside `group`; the same 54 MiB through a port owned by the reader took
%% 0.09 s and 66 MB, because the bytes land in the mailbox of the one process
%% that is about to consume them. The entrypoint passes `-noinput` so OTP
%% starts no competing reader: with `-noshell` the tty reader wins part of the
%% stream and those bytes never reach this port at all.
%%
%% `eof` keeps the port alive at end of input rather than letting it exit and
%% signal its owner, so end of input is an ordinary message like any other.
stdinReadImpl(Chunk, End, Failed) ->
    fun() ->
        case stdin_port() of
            closed ->
                End;
            {failed, Why} ->
                Failed(Why);
            Port ->
                receive
                    {Port, {data, Data}} ->
                        Chunk(Data);
                    {Port, eof} ->
                        stdin_close(Port),
                        End;
                    %% Only a process trapping exits is handed a port's exit as
                    %% a message, so these two are for a caller that does. They
                    %% are what makes a driver failure a read failure instead of
                    %% a case that was assumed not to happen.
                    {'EXIT', Port, normal} ->
                        stdin_close(Port),
                        End;
                    {'EXIT', Port, Reason} ->
                        stdin_close(Port),
                        Failed(reason(Reason))
                end
        end
    end.

%% There is no descriptor to open when standard input was never connected, and
%% a read that cannot happen is a read failure rather than a crash.
stdin_port() ->
    case erlang:get(?STDIN_KEY) of
        undefined ->
            Opened =
                try erlang:open_port({fd, 0, 1}, [in, binary, stream, eof]) of
                    Port -> Port
                catch
                    _:Reason -> {failed, reason(Reason)}
                end,
            _ = erlang:put(?STDIN_KEY, Opened),
            Opened;
        Remembered ->
            Remembered
    end.

stdin_close(Port) ->
    _ = (catch erlang:port_close(Port)),
    _ = erlang:put(?STDIN_KEY, closed),
    ok.

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
