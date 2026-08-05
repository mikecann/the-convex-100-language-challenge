%% Native Convex HTTP implementation. OTP owns ordinary HTTPS/TLS transport;
%% this module owns Convex's request and response envelope.
-module(convex).
-export([new/1, set_auth/2, call/4, poll_subscribe/4, poll_next/2, close/1]).

new(Url0) when is_binary(Url0) -> new(binary_to_list(Url0));
new(Url0) when is_list(Url0) ->
    Url = string:trim(Url0, trailing, "/"),
    case lists:prefix("http://", Url) orelse lists:prefix("https://", Url) of
        true -> inets:start(), ssl:start(), {ok, #{url => Url, token => undefined}};
        false -> {error, #{name => <<"ProtocolError">>, message => <<"Convex URL must use http or https">>}}
    end.
set_auth(Client, <<>>) -> Client#{token => undefined};
set_auth(Client, Token) when is_binary(Token) -> Client#{token => Token}.
call(Client, Op, Path, Args) when is_binary(Path), is_list(Args) ->
    Request = convex_json:encode([{<<"path">>,Path},{<<"args">>,Args},{<<"format">>,<<"json">>}]),
    Headers0 = [{"content-type","application/json"},{"accept","application/json"},{"convex-client","erlang-0.1.0"}],
    Headers = case maps:get(token,Client) of undefined -> Headers0; T -> [{"authorization", "Bearer " ++ binary_to_list(T)}|Headers0] end,
    Url = maps:get(url,Client) ++ "/api/" ++ atom_to_list(Op),
    case httpc:request(post, {Url, Headers, "application/json", Request}, [{timeout,30000}], [{body_format,binary}]) of
        {ok, {{_,200,_}, _, Body}} -> decode_response(Body);
        {ok, {{_,Code,_}, _, Body}} -> {error, #{name => <<"TransportError">>, message => iolist_to_binary(io_lib:format("HTTP ~p: ~ts",[Code,Body]))}};
        {error, Reason} -> {error, #{name => <<"TransportError">>, message => iolist_to_binary(io_lib:format("~p",[Reason]))}}
    end.
decode_response(Body) -> case convex_json:decode(Body) of
    {ok, Fields} -> case proplists:get_value(<<"status">>, Fields) of
        <<"success">> -> {ok, proplists:get_value(<<"value">>,Fields), proplists:get_value(<<"logLines">>,Fields,[])};
        <<"error">> -> {error, #{name => <<"FunctionError">>, message => proplists:get_value(<<"errorMessage">>,Fields,<<"Convex function failed">>), data => proplists:get_value(<<"errorData">>,Fields,null)}};
        _ -> {error, #{name => <<"ProtocolError">>,message => <<"unknown Convex response">>}}
    end; _ -> {error,#{name => <<"ProtocolError">>,message => <<"invalid JSON response">>}} end.

%% This intentionally exposes polling separately. It is not represented as
%% Live capability: a real /api/sync WebSocket owner is still required.
poll_subscribe(Client, Path, Args, Owner) -> {ok, spawn_link(fun() -> poll_loop(Client,Path,Args,Owner,undefined) end)}.
poll_next(Pid, Timeout) -> Pid ! {poll, self()}, receive {convex_poll,Value} -> {ok,Value}; {convex_poll_error,E} -> {error,E} after Timeout -> timeout end.
poll_loop(Client,Path,Args,Owner,Last) -> receive
    {poll,From} -> case call(Client,query,Path,Args) of
        {ok,V,_} -> if V =:= Last -> poll_loop(Client,Path,Args,Owner,Last); true -> From ! {convex_poll,V}, poll_loop(Client,Path,Args,Owner,V) end;
        {error,E} -> From ! {convex_poll_error,E}, poll_loop(Client,Path,Args,Owner,Last)
    end;
    close -> ok
end.
close(Pid) when is_pid(Pid) -> Pid ! close, ok;
close(_) -> ok.
