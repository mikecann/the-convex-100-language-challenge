-module(adapter).
-export([main/0]).

main() ->
    Url = os:getenv("CONVEX_URL"), {ok, Client} = convex:new(case Url of false -> "http://127.0.0.1"; V -> V end),
    loop(Client, #{}).
loop(Client, Subs) ->
    case io:get_line("") of eof -> ok; Line ->
        case convex_json:decode(iolist_to_binary(Line)) of
            {ok, Command} -> {NextClient,NextSubs,Reply,Stop} = handle(Command,Client,Subs), io:format("~s~n",[convex_json:encode(Reply)]), case Stop of true -> ok; false -> loop(NextClient,NextSubs) end;
            _ -> io:format("~s~n",[convex_json:encode([{<<"type">>,<<"error">>},{<<"error">>,err(<<"ProtocolError">>,<<"invalid NDJSON">>)}])]), loop(Client,Subs)
        end
    end.
handle(C,Client,Subs) -> Id=proplists:get_value(<<"id">>,C), Op=proplists:get_value(<<"op">>,C),
 case Op of
  <<"hello">> -> {Client,Subs,[{<<"protocolVersion">>,1},{<<"id">>,Id},{<<"type">>,<<"ready">>},{<<"language">>,<<"erlang">>},{<<"implementation">>,<<"native-otp-httpc-0.1.0">>},{<<"runtime">>,unicode:characters_to_binary(erlang:system_info(otp_release))}],false};
  <<"query">> -> call_reply(Id,Client,query,C,Subs); <<"mutation">> -> call_reply(Id,Client,mutation,C,Subs); <<"action">> -> call_reply(Id,Client,action,C,Subs);
  <<"setAuth">> -> {convex:set_auth(Client,proplists:get_value(<<"token">>,C)),Subs,[{<<"id">>,Id},{<<"type">>,<<"ack">>}],false};
  <<"close">> -> {Client,Subs,[{<<"id">>,Id},{<<"type">>,<<"closed">>}],true};
  _ -> {Client,Subs,[{<<"id">>,Id},{<<"type">>,<<"error">>},{<<"error">>,err(<<"ProtocolError">>,<<"Live adapter is not implemented">>)}],false}
 end.
call_reply(Id,Client,Op,C,Subs) -> case convex:call(Client,Op,proplists:get_value(<<"path">>,C),proplists:get_value(<<"args">>,C)) of
 {ok,V,Logs} -> {Client,Subs,[{<<"id">>,Id},{<<"type">>,<<"result">>},{<<"value">>,V},{<<"logs">>,Logs}],false};
 {error,E} -> {Client,Subs,[{<<"id">>,Id},{<<"type">>,<<"error">>},{<<"error">>,E}],false} end.
err(Name,Message) -> [{<<"name">>,Name},{<<"message">>,Message}].
