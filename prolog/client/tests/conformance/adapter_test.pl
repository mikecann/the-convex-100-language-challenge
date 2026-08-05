:- begin_tests(adapter).

:- use_module('../../../client/convex').
:- use_module('adapter').
:- use_module(library(http/json)).
:- use_module(library(socket)).

test(integer_value_preserves_counter_semantics) :-
    integer_json(0.0, 0),
    integer_json(1, 1).

test(fractional_value_is_not_a_counter, [fail]) :-
    integer_json(0.1, _).

test(utf8_limit_counts_encoded_bytes) :-
    convex_adapter:utf8_code_bytes(0'a, 1),
    convex_adapter:utf8_code_bytes(0x4E16, 3),
    convex_adapter:utf8_code_bytes(0x1F44B, 4).

test(output_event_uses_utf8_byte_bound) :-
    length(Codes, 530000),
    maplist(=(0x1F44B), Codes),
    string_codes(Value, Codes),
    fake_output(Output, Cleanup),
    call_cleanup(
        catch(
            convex_adapter:emit(Output, _{type:"result", value:Value}),
            Error,
            true
        ),
        call(Cleanup)
    ),
    assertion(nonvar(Error)),
    assertion(Error = adapter_error(none, "ProtocolError", _)).

test(output_backpressure_is_bounded) :-
    message_queue_create(Queue, [max_size(1)]),
    message_queue_create(Budget, [max_size(1)]),
    thread_send_message(Budget, 0),
    thread_create(sleep(2), Writer, [detached(false)]),
    thread_send_message(Queue, occupied),
    get_time(Start),
    catch(
        convex_adapter:emit(
            output(Queue, Writer, Budget),
            _{type:"result", value:_{count:1}}
        ),
        Error,
        true
    ),
    get_time(End),
    Elapsed is End - Start,
    thread_signal(Writer, throw(stop_test_writer)),
    thread_join(Writer, _),
    message_queue_destroy(Queue),
    message_queue_destroy(Budget),
    assertion(Elapsed < 1.0),
    assertion(Error = adapter_error(none, "TransportError", _)).

test(global_output_byte_budget_is_bounded) :-
    message_queue_create(Budget, [max_size(1)]),
    thread_send_message(Budget, 0),
    convex_adapter:reserve_output_bytes(Budget, 7000000),
    catch(
        convex_adapter:reserve_output_bytes(Budget, 2000000),
        Error,
        true
    ),
    thread_get_message(Budget, Reserved),
    message_queue_destroy(Budget),
    assertion(Reserved =:= 7000000),
    assertion(Error = adapter_error(none, "TransportError", _)).

test(tcp_partial_input_malformed_isolation_and_clean_close) :-
    setup_call_cleanup(
        start_tcp_adapter(Thread, In, Out),
        ( format(Out, '{"id":', []),
          flush_output(Out),
          sleep(0.03),
          format(Out, '}~n', []),
          flush_output(Out),
          read_event(In, Malformed),
          assertion(Malformed.type == "error"),
          assertion(Malformed.error.name == "ProtocolError"),
          send_fragmented(
              Out,
              '{"id":"hello-1","op":"hello",',
              '"protocolVersion":1}\n'
          ),
          read_event(In, Ready),
          assertion(Ready.type == "ready"),
          assertion(Ready.id == "hello-1"),
          send_line(
              Out,
              '{"id":"query-1","op":"query","path":"demo:state","args":{}}'
          ),
          read_event(In, QueryError),
          assertion(QueryError.id == "query-1"),
          assertion(QueryError.error.name == "TransportError"),
          send_line(Out, '{"id":"debug-1","op":"debugDisconnect"}'),
          read_event(In, DebugError),
          assertion(DebugError.id == "debug-1"),
          assertion(DebugError.error.name == "TransportError"),
          send_line(
              Out,
              '{"id":"bad-1","op":"close","unexpected":true}'
          ),
          read_event(In, Invalid),
          assertion(Invalid.id == "bad-1"),
          assertion(Invalid.error.name == "ProtocolError"),
          send_line(Out, '{"id":"close-1","op":"close"}'),
          read_event(In, Closed),
          assertion(Closed.id == "close-1"),
          assertion(Closed.type == "closed"),
          close(Out),
          close(In),
          join_with_deadline(Thread, 2)
        ),
        cleanup_tcp_adapter(Thread, In, Out)
    ).

test(tcp_eof_releases_adapter) :-
    setup_call_cleanup(
        start_tcp_adapter(Thread, In, Out),
        ( close(Out),
          close(In),
          join_with_deadline(Thread, 2)
        ),
        cleanup_tcp_adapter(Thread, In, Out)
    ).

test(tcp_invalid_utf8_is_command_scoped) :-
    setup_call_cleanup(
        start_tcp_adapter(Thread, In, Out),
        ( set_stream(Out, encoding(octet)),
          put_byte(Out, 195),
          put_byte(Out, 10),
          flush_output(Out),
          set_stream(Out, encoding(utf8)),
          read_event(In, InvalidUtf8),
          assertion(InvalidUtf8.type == "error"),
          assertion(InvalidUtf8.error.name == "ProtocolError"),
          send_line(
              Out,
              '{"id":"utf8-recovered","op":"hello","protocolVersion":1}'
          ),
          read_until_id(In, "utf8-recovered", Ready, 3),
          assertion(Ready.type == "ready"),
          send_line(Out, '{"id":"utf8-close","op":"close"}'),
          read_event(In, Closed),
          assertion(Closed.type == "closed"),
          close(Out),
          close(In),
          join_with_deadline(Thread, 2)
        ),
        cleanup_tcp_adapter(Thread, In, Out)
    ).

:- end_tests(adapter).

fake_output(output(Queue, Writer, Budget), cleanup_fake_output(Queue, Writer, Budget)) :-
    message_queue_create(Queue, [max_size(1)]),
    message_queue_create(Budget, [max_size(1)]),
    thread_send_message(Budget, 0),
    thread_create(sleep(2), Writer, [detached(false)]).

cleanup_fake_output(Queue, Writer, Budget) :-
    catch(thread_signal(Writer, throw(stop_test_writer)), _, true),
    catch(thread_join(Writer, _), _, true),
    catch(message_queue_destroy(Queue), _, true),
    catch(message_queue_destroy(Budget), _, true).

start_tcp_adapter(Thread, In, Out) :-
    free_port(Port),
    format(string(Address), '127.0.0.1:~d', [Port]),
    setenv('ADAPTER_LISTEN', Address),
    unsetenv('CONVEX_URL'),
    thread_create(convex_adapter:main, Thread, [detached(false)]),
    connect_adapter(Port, 100, In, Out),
    set_stream(In, encoding(utf8)),
    set_stream(Out, encoding(utf8)).

free_port(Port) :-
    tcp_socket(Socket),
    tcp_bind(Socket, '127.0.0.1':Port),
    tcp_close_socket(Socket).

connect_adapter(Port, Attempts, In, Out) :-
    Attempts > 0,
    tcp_socket(Socket),
    (   catch(tcp_connect(Socket, '127.0.0.1':Port), _, fail)
    ->  tcp_open_socket(Socket, In, Out)
    ;   tcp_close_socket(Socket),
        sleep(0.01),
        Next is Attempts - 1,
        connect_adapter(Port, Next, In, Out)
    ).

send_fragmented(Out, First, Second) :-
    format(Out, '~s', [First]),
    flush_output(Out),
    sleep(0.03),
    format(Out, '~s', [Second]),
    flush_output(Out).

send_line(Out, Line) :-
    format(Out, '~s~n', [Line]),
    flush_output(Out).

read_event(In, Event) :-
    read_line_to_string(In, Line),
    assertion(Line \== end_of_file),
    atom_string(Atom, Line),
    convex_adapter:atom_json_dict(Atom, Event, []).

read_until_id(In, Id, Event, Attempts) :-
    Attempts > 0,
    read_event(In, Candidate),
    (   get_dict(id, Candidate, Id)
    ->  Event = Candidate
    ;   Next is Attempts - 1,
        read_until_id(In, Id, Event, Next)
    ).

join_with_deadline(Thread, Timeout) :-
    call_with_time_limit(Timeout, thread_join(Thread, Status)),
    assertion(Status == true).

cleanup_tcp_adapter(Thread, In, Out) :-
    unsetenv('ADAPTER_LISTEN'),
    catch(close(Out, [force(true)]), _, true),
    catch(close(In, [force(true)]), _, true),
    (   catch(thread_property(Thread, status(running)), _, fail)
    ->  catch(thread_signal(Thread, throw(stop_test_adapter)), _, true),
        catch(thread_join(Thread, _), _, true)
    ;   true
    ).
