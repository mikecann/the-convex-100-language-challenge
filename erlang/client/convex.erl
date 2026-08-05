%% Public educational API. OTP supplies HTTPS/TLS; this module supplies the
%% Convex HTTP envelope and delegates only the native sync transport to live.
-module(convex).
-export([new/1, set_auth/2, call/4, subscribe/4, unsubscribe/2, debug_disconnect/1, close/1]).

new(Url0) when is_binary(Url0) -> new(binary_to_list(Url0));
new(Url0) when is_list(Url0) ->
    Url = string:trim(Url0, trailing, "/"),
    case lists:prefix("http://", Url) orelse lists:prefix("https://", Url) of
        true -> inets:start(), ssl:start(), {ok, #{url => Url, token => undefined, live => undefined}};
        false -> {error, make_error(<<"ProtocolError">>, <<"Convex URL must use http or https">>)}
    end.
set_auth(Client, <<>>) -> Client#{token => undefined};
set_auth(Client, Token) when is_binary(Token) -> Client#{token => Token}.
call(Client, Op, Path, Args) when is_binary(Path), is_map(Args) ->
    Request = convex_json:encode(#{<<"path">> => Path, <<"args">> => Args, <<"format">> => <<"json">>}),
    Headers0 = [{"content-type", "application/json"}, {"accept", "application/json"}, {"convex-client", "erlang-0.1.0"}],
    Headers = case maps:get(token, Client) of undefined -> Headers0; T -> [{"authorization", "Bearer " ++ binary_to_list(T)} | Headers0] end,
    Url = maps:get(url, Client) ++ "/api/" ++ atom_to_list(Op),
    case httpc:request(post, {Url, Headers, "application/json", Request}, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> decode_response(Body);
        {ok, {{_, Code, _}, _, Body}} -> {error, make_error(<<"TransportError">>, iolist_to_binary(io_lib:format("HTTP ~p: ~ts", [Code, Body])))};
        {error, Reason} -> {error, make_error(<<"TransportError">>, iolist_to_binary(io_lib:format("~p", [Reason])))}
    end.
subscribe(Client, Path, Args, Sink) ->
    case maps:get(live, Client) of
        undefined -> {ok, Pid} = live:start_link(Client), {ok, Id} = live:subscribe(Pid, Path, Args, Sink), {ok, Pid, Id};
        Pid -> {ok, Id} = live:subscribe(Pid, Path, Args, Sink), {ok, Pid, Id}
    end.
unsubscribe(Pid, SubscriptionId) -> live:unsubscribe(Pid, SubscriptionId).
debug_disconnect(Pid) -> live:debug_disconnect(Pid).
close(#{live := undefined}) -> ok;
close(#{live := Pid}) -> live:close(Pid).
decode_response(Body) ->
    case convex_json:decode(Body) of
        {ok, #{<<"status">> := <<"success">>, <<"value">> := Value} = R} -> {ok, Value, maps:get(<<"logLines">>, R, [])};
        {ok, #{<<"status">> := <<"error">>} = R} -> {error, maps:merge(make_error(<<"FunctionError">>, maps:get(<<"errorMessage">>, R, <<"Convex function failed">>)), #{data => maps:get(<<"errorData">>, R, null)})};
        _ -> {error, make_error(<<"ProtocolError">>, <<"invalid Convex HTTP response">>)}
    end.
make_error(Name, Message) -> #{name => Name, message => Message}.
