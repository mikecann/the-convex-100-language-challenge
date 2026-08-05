:- use_module('../convex').
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/thread_httpd)).

:- dynamic fixture_request/3.

:- http_handler(root('api/query'), http_fixture(query), []).
:- http_handler(root('api/mutation'), http_fixture(mutation), []).
:- http_handler(root('api/action'), http_fixture(action), []).

:- begin_tests(convex).

test(integer_json_accepts_integral_decimal) :-
    integer_json(1.0, 1).

test(integer_json_rejects_fractional, [fail]) :-
    integer_json(1.5, _).

test(integer_json_rejects_quoted, [fail]) :-
    integer_json("1", _).

test(timestamp_is_little_endian) :-
    timestamp_newer("AQAAAAAAAAA=", "AAAAAAAAAAA=").

test(timestamp_does_not_reverse_order, [fail]) :-
    timestamp_newer("AAAAAAAAAAA=", "AQAAAAAAAAA=").

test(timestamp_rejects_noncanonical_base64, [fail]) :-
    timestamp_newer("AQ==", "AAAAAAAAAAA=").

test(client_rejects_non_http_url,
     [throws(error(domain_error(_, _), _))]) :-
    new_client("ftp://example.invalid", _).

test(real_http_success_auth_and_function_error) :-
    setup_call_cleanup(
        start_http_fixture(Server, URL),
        ( new_client(URL, Plain),
          with_auth(Plain, "test-token", Client),
          query(
              Client,
              "demo:state",
              _{room:"room-1"},
              result(Value, Logs)
          ),
          assertion(Value.count =:= 0.0),
          assertion(Logs == ["query log"]),
          user:fixture_request(query, QueryBody, QueryAuth),
          assertion(QueryBody.path == "demo:state"),
          assertion(QueryBody.args.room == "room-1"),
          assertion(QueryAuth == "Bearer test-token"),
          catch(
              mutation(Client, "demo:fail", _{}, _),
              Error,
              true
          ),
          assertion(
              Error = error(
                  function_error(
                      mutation,
                      "expected failure",
                      _{code:"EXPECTED"},
                      ["mutation log"]
                  ),
                  _
              )
          )
        ),
        stop_http_fixture(Server)
    ).

test(malformed_log_array_is_protocol_error) :-
    setup_call_cleanup(
        start_http_fixture(Server, URL),
        ( new_client(URL, Client),
          catch(action(Client, "demo:badLogs", _{}, _), Error, true),
          assertion(Error = error(protocol_error(http_response(_, _)), _))
        ),
        stop_http_fixture(Server)
    ).

:- end_tests(convex).

start_http_fixture(Server, URL) :-
    retractall(fixture_request(_, _, _)),
    http_server(http_dispatch, [port(Server), workers(2)]),
    format(string(URL), 'http://127.0.0.1:~d', [Server]).

stop_http_fixture(Server) :-
    http_stop_server(Server, []).

http_fixture(Operation, Request) :-
    http_read_json_dict(Request, Body),
    (   memberchk(authorization(AuthAtom), Request)
    ->  atom_string(AuthAtom, Auth)
    ;   Auth = ""
    ),
    assertz(fixture_request(Operation, Body, Auth)),
    http_fixture_response(Operation, Body, Response),
    reply_json_dict(Response).

http_fixture_response(query, _, _{
    status:"success",
    value:_{count:0.0},
    logLines:["query log"]
}).
http_fixture_response(mutation, Body, Response) :-
    (   Body.path == "demo:fail"
    ->  Response = _{
            status:"error",
            errorMessage:"expected failure",
            errorData:_{code:"EXPECTED"},
            logLines:["mutation log"]
        }
    ;   Response = _{status:"success", value:_{ok:true}, logLines:[]}
    ).
http_fixture_response(action, _, _{
    status:"success",
    value:_{ok:true},
    logLines:[7]
}).
