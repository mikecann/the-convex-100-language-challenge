%% Public educational API. OTP supplies HTTPS/TLS; this module supplies the
%% Convex HTTP envelope and delegates only the native sync transport to live.
-module(convex).
-export([new/1, set_auth/2, call/4, subscribe/4, unsubscribe/2, close/1]).

new(Url0) when is_binary(Url0) ->
    new(binary_to_list(Url0));
new(Url0) when is_list(Url0) ->
    Url = string:trim(Url0, trailing, "/"),
    case lists:prefix("http://", Url) orelse lists:prefix("https://", Url) of
        true ->
            inets:start(),
            ssl:start(),
            Base =
                maps:merge(#{url => Url, token => undefined},
                           test_client_options()),
            %% A client has exactly one Live owner. Erlang maps are immutable,
            %% so creating the owner here avoids accidentally starting one
            %% owner per call to subscribe/4.
            {ok, Live} = live:start_link(Base),
            {ok, Base#{live => Live}};
        false ->
            {error,
             make_error(<<"ProtocolError">>,
                        <<"Convex URL must use http or https">>)}
    end.

set_auth(Client, <<>>) ->
    Client#{token => undefined};
set_auth(Client, Token) when is_binary(Token) ->
    Client#{token => Token}.

call(Client, Op, Path, Args) when is_binary(Path), is_map(Args) ->
    Request =
        convex_json:encode(#{<<"path">> => Path,
                             <<"args">> => Args,
                             <<"format">> => <<"json">>}),
    Headers0 =
        [{"content-type", "application/json"},
         {"accept", "application/json"},
         {"convex-client", "erlang-0.1.0"}],
    Headers =
        case maps:get(token, Client) of
            undefined ->
                Headers0;
            Token ->
                [{"authorization", "Bearer " ++ binary_to_list(Token)} |
                 Headers0]
        end,
    Url = maps:get(url, Client) ++ "/api/" ++ atom_to_list(Op),
    HttpOptions = request_options(Url),
    case httpc:request(post,
                       {Url, Headers, "application/json", Request},
                       HttpOptions,
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            decode_response(Body);
        {ok, {{_, Code, _}, _, Body}} ->
            Message =
                iolist_to_binary(io_lib:format("HTTP ~p: ~ts", [Code, Body])),
            {error, make_error(<<"TransportError">>, Message)};
        {error, Reason} ->
            Message = iolist_to_binary(io_lib:format("~p", [Reason])),
            {error, make_error(<<"TransportError">>, Message)}
    end.

subscribe(Client, Path, Args, Sink) ->
    Pid = maps:get(live, Client),
    {ok, Id} = live:subscribe(Pid, Path, Args, Sink),
    {ok, Pid, Id}.
unsubscribe(Pid, SubscriptionId) ->
    live:unsubscribe(Pid, SubscriptionId).

close(#{live := Pid}) ->
    live:close(Pid).

decode_response(Body) ->
    case convex_json:decode(Body) of
        {ok, #{<<"status">> := <<"success">>, <<"value">> := Value} = Response} ->
            {ok, Value, maps:get(<<"logLines">>, Response, [])};
        {ok, #{<<"status">> := <<"error">>} = Response} ->
            Base =
                make_error(<<"FunctionError">>,
                           maps:get(<<"errorMessage">>, Response,
                                    <<"Convex function failed">>)),
            {error,
             maps:merge(Base,
                        #{data => maps:get(<<"errorData">>, Response, null)})};
        _ ->
            {error,
             make_error(<<"ProtocolError">>,
                        <<"invalid Convex HTTP response">>)}
    end.

make_error(Name, Message) ->
    #{name => Name, message => Message}.

request_options(Url) ->
    Uri = uri_string:parse(Url),
    case maps:get(scheme, Uri) of
        "https" ->
            Host = maps:get(host, Uri),
            [{timeout, 30000},
             {ssl, [{verify, verify_peer},
                    {cacertfile, "/etc/ssl/certs/ca-certificates.crt"},
                    {server_name_indication, Host},
                    {customize_hostname_check,
                     [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}];
        "http" ->
            [{timeout, 30000}]
    end.

-ifdef(TEST).
%% This branch is compiled only into the Docker test ebin. The production
%% client and both final images contain no relay fault-injection hook.
test_client_options() ->
    case os:getenv("ADAPTER_TEST_RELAY_GATE") of
        false -> #{};
        _ -> #{relay_test_gate => whereis(live_relay_gate)}
    end.
-else.
test_client_options() ->
    #{}.
-endif.
