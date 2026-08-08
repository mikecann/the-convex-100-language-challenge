# Convex from Mercury

This demonstration queries a Convex room with Mercury, observes it over Live,
increments it, and checks the reactive value changes from `0` to `1`. Mercury
is a logic/functional language with strong static types, mode declarations
(which arguments a predicate reads versus produces), and a determinism system
that states, for every predicate, exactly how many solutions it can have.
Those declarations are not decoration here: `parse_json` is `semidet` because
malformed input is an expected outcome rather than an exception, and
`validate_transition` is `semidet` for the same reason a Live sync protocol
violation should fail the connection rather than raise a surprise.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.m`](examples/basics/main.m) is the exact program the
Docker image runs and the website displays. Its comments explain client
setup, the initial HTTP query, starting Live before the mutation, the
idempotency key, and the final reactive assertion.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native query, mutation, and action over the documented JSON API, including bearer token auth, logs, and typed `FunctionError`/`ProtocolError`/`TransportError` failures. |
| Live | Verified by shared local and hosted conformance | Native WebSocket subscriptions against the pinned `/api/sync` profile: initial value, external updates, unsubscribe, query-error recovery, and five real `debugDisconnect` reconnects with rehydration correctly suppressed. |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
```objective-c
%-----------------------------------------------------------------------------%
% Convex from Mercury: the canonical shared counter demonstration.
%
% Walks the same 0 -> 1 journey every language in this project demonstrates:
% an HTTP query for the current count, a Live subscription started before
% any write so the reactive path cannot miss it, an idempotent mutation,
% and the resulting Live update -- proving HTTP and Live agree about the
% same room.
%-----------------------------------------------------------------------------%
:- module main.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module convex.
:- import_module convex_json.
:- import_module convex_transport.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module string.

main(!IO) :-
    % Configuration: both HTTPS and WSS reach the same approved Convex
    % deployment. The verifier supplies a unique room as this program's
    % first argument; running the image by hand falls back to a fixed room.
    io.get_environment_var("CONVEX_URL", MaybeUrl, !IO),
    (
        MaybeUrl = yes(Url),
        io.command_line_arguments(Args, !IO),
        Room = ( Args = [First | _] -> First ; "mercury-example" ),
        % Client creation: parse and validate the deployment URL once.
        ( new_client(Url, _, Client) ->
            run_example(Client, Room, !IO)
        ;
            report_and_fail("CONVEX_URL is not a valid Convex deployment URL", !IO)
        )
    ;
        MaybeUrl = no,
        report_and_fail("CONVEX_URL is required", !IO)
    ).

:- pred run_example(client::in, string::in, io::di, io::uo) is det.

run_example(Client, Room, !IO) :-
    RoomArgs = j_object(["room" - j_string(Room)]),

    % The HTTP query: a plain request/response read of the room's state.
    query(Client, "demo:state", RoomArgs, QueryResult, !IO),
    (
        QueryResult = call_ok(call_result(QueryValue, _Logs)),
        CurrentCount = whole_count("current query", QueryValue),
        io.format("current count: %d\n", [i(CurrentCount)], !IO),

        % Start Live before the mutation so the reactive path cannot miss
        % the write: connecting and subscribing first, then mutating,
        % guarantees the subscription's next update is the one that matters.
        live_connect(Client, MaybeLive, !IO),
        (
            MaybeLive = live_ok(Conn, LiveState0),
            live_add(Conn, LiveState0, "demo:state", RoomArgs, QueryId,
                LiveState1, AddResult, !IO),
            (
                AddResult = ok,
                await_live(Conn, LiveState1, QueryId, "initial Live value",
                    InitialUpdate, LiveState2, !IO),
                InitialCount = whole_count("initial Live value", InitialUpdate),
                ( InitialCount = CurrentCount -> true
                ; report_and_fail("Live initial value disagreed with HTTP", !IO)
                ),
                io.format("live initial count: %d\n", [i(InitialCount)], !IO),

                % The mutation and its idempotency key: runId lets a retried
                % call observe the same result without applying the write
                % twice. A random key means each run of this example is a
                % distinct logical write.
                random_hex(16, RunId, !IO),
                MutationArgs = j_object([
                    "room" - j_string(Room),
                    "language" - j_string("mercury"),
                    "runId" - j_string(RunId)
                ]),
                mutation(Client, "demo:increment", MutationArgs, MutationResult, !IO),
                (
                    MutationResult = call_ok(call_result(MutationValue, _)),
                    Applied = mutation_applied(MutationValue),
                    io.format("mutation applied: %s\n", [s(bool_word(Applied))], !IO),
                    MutationCount = whole_count("mutation", mutation_state(MutationValue)),
                    ( MutationCount = CurrentCount + 1 -> true
                    ; report_and_fail("mutation count was unexpected", !IO)
                    ),
                    io.format("mutation count: %d\n", [i(MutationCount)], !IO),

                    % The resulting Live update: received on the same
                    % subscription rather than issuing a second query.
                    await_live(Conn, LiveState2, QueryId, "updated Live value",
                        UpdatedUpdate, LiveState3, !IO),
                    UpdatedCount = whole_count("updated Live value", UpdatedUpdate),
                    ( UpdatedCount = MutationCount -> true
                    ; report_and_fail("Live update was unexpected", !IO)
                    ),
                    io.format("live updated count: %d\n", [i(UpdatedCount)], !IO),

                    % This final line only prints once HTTP and Live agree
                    % end to end.
                    io.format("verified count: %d -> %d\n",
                        [i(CurrentCount), i(UpdatedCount)], !IO),

                    live_remove(Conn, LiveState3, QueryId, _LiveState4, _RemoveResult, !IO),
                    live_close(Conn, !IO)
                ;
                    MutationResult = call_error(Err),
                    live_close(Conn, !IO),
                    report_and_fail("mutation failed: " ++ error_message(Err), !IO)
                )
            ;
                AddResult = transport_error(Msg),
                live_close(Conn, !IO),
                report_and_fail("could not subscribe: " ++ Msg, !IO)
            )
        ;
            MaybeLive = live_error(Err),
            report_and_fail("Live connect failed: " ++ error_message(Err), !IO)
        )
    ;
        QueryResult = call_error(Err),
        report_and_fail("current query failed: " ++ error_message(Err), !IO)
    ).

    % Poll the Live connection (blocking briefly between attempts) until an
    % update for the given query arrives, or give up after ten seconds.
:- pred await_live(live_conn::in, live_state::in, int::in, string::in,
    json::out, live_state::out, io::di, io::uo) is det.

await_live(Conn, State0, QueryId, Label, Value, State, !IO) :-
    await_live_loop(Conn, State0, QueryId, Label, 100, Value, State, !IO).

:- pred await_live_loop(live_conn::in, live_state::in, int::in, string::in,
    int::in, json::out, live_state::out, io::di, io::uo) is det.

await_live_loop(Conn, State0, QueryId, Label, TriesLeft, Value, State, !IO) :-
    ( TriesLeft =< 0 ->
        Value = j_null,
        State = State0,
        report_and_fail(Label ++ " timed out", !IO)
    ;
        poll_control(-1, live_conn(live_fd(Conn)), 100, PollResult, !IO),
        ( ( PollResult = poll_live_ready ; PollResult = poll_both_ready ) ->
            live_poll(Conn, State0, PollLive, !IO),
            (
                PollLive = live_transition(State1, Changes),
                ( find_change(QueryId, Changes, Found) ->
                    (
                        Found = live_value(_, Value0, _),
                        Value = Value0,
                        State = State1
                    ;
                        Found = live_query_error(_, Err, _),
                        Value = j_null,
                        State = State1,
                        report_and_fail(Label ++ " was an error: " ++ error_message(Err), !IO)
                    )
                ;
                    await_live_loop(Conn, State1, QueryId, Label, TriesLeft - 1,
                        Value, State, !IO)
                )
            ;
                ( PollLive = live_ping ; PollLive = live_ignored ; PollLive = live_would_block ),
                await_live_loop(Conn, State0, QueryId, Label, TriesLeft - 1,
                    Value, State, !IO)
            ;
                PollLive = live_protocol_error(Msg),
                Value = j_null,
                State = State0,
                report_and_fail(Label ++ ": protocol error: " ++ Msg, !IO)
            ;
                PollLive = live_peer_closed,
                Value = j_null,
                State = State0,
                report_and_fail(Label ++ ": connection closed", !IO)
            )
        ;
            await_live_loop(Conn, State0, QueryId, Label, TriesLeft - 1, Value, State, !IO)
        )
    ).

:- pred find_change(int::in, list(live_change)::in, live_change::out)
    is semidet.

find_change(QueryId, [Change | Rest], Found) :-
    ( change_query_id(Change) = QueryId -> Found = Change
    ; find_change(QueryId, Rest, Found)
    ).

:- func change_query_id(live_change) = int.

change_query_id(live_value(Id, _, _)) = Id.
change_query_id(live_query_error(Id, _, _)) = Id.

    % Convex values are JSON, so this decodes the demonstrated result into
    % the idiomatic Mercury int this example needs, rejecting a fractional,
    % missing, or out-of-range count rather than silently truncating one.
:- func whole_count(string, json) = int.

whole_count(Operation, Value) = Count :-
    ( Value = j_object(Fields), assoc_search(Fields, "count", CountJson) ->
        ( json_integral_int(CountJson, Found) ->
            Count = Found
        ;
            Count = 0,
            unexpected($module, $pred, Operation ++ " did not contain a whole count")
        )
    ;
        Count = 0,
        unexpected($module, $pred, Operation ++ " was not an object")
    ).

:- pred assoc_search(assoc_list(string, json)::in, string::in, json::out)
    is semidet.

assoc_search([Key - Value | Rest], Target, Found) :-
    ( Key = Target -> Found = Value ; assoc_search(Rest, Target, Found) ).

:- func mutation_applied(json) = bool.

mutation_applied(Value) = Applied :-
    ( Value = j_object(Fields), assoc_search(Fields, "applied", j_bool(j_true)) ->
        Applied = yes
    ;
        Applied = no
    ).

:- func mutation_state(json) = json.

mutation_state(Value) = State :-
    ( Value = j_object(Fields), assoc_search(Fields, "state", Found) ->
        State = Found
    ;
        State = j_null,
        unexpected($module, $pred, "mutation response omitted state")
    ).

:- func bool_word(bool) = string.

bool_word(yes) = "true".
bool_word(no) = "false".

:- func error_message(convex_error) = string.

error_message(function_error(Msg, _, _)) = Msg.
error_message(protocol_error(Msg)) = Msg.
error_message(transport_error(Msg)) = Msg.

    % Diagnostics belong on stderr: stdout is the exact, universal
    % happy-path transcript every language's canonical example must match.
:- pred report_and_fail(string::in, io::di, io::uo) is det.

report_and_fail(Message, !IO) :-
    io.stderr_stream(Stderr, !IO),
    io.format(Stderr, "mercury example failed: %s\n", [s(Message)], !IO),
    io.set_exit_status(1, !IO).
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test mercury
./run verify-example mercury
./run verify mercury
./run verify-hosted mercury
./run verify-all mercury
```

`test` builds every checked-in `.m` source with `mmc`, which performs
Mercury's full type, mode, and determinism check for every predicate before
running the language-local unit tests. `verify-example` exercises the exact
example above against a unique room. The conformance commands are root-owned
checks for the separate self-hosted and dedicated hosted deployments.

## Conformance and protocol notes

HTTP calls use the documented `/api/query`, `/api/mutation`, and
`/api/action` JSON endpoints. Live uses the unversioned `/api/sync` profile
pinned to `convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

Mercury has no HTTP, TLS, or WebSocket library in its standard distribution.
`client/convex_transport.m` reaches OpenSSL and POSIX sockets through
Mercury's C foreign-language interface for exactly the mechanical parts: TCP
connect, the TLS 1.2+ handshake with real certificate and hostname
verification against the system CA bundle, HTTP/1.1 response framing
(Content-Length and chunked), the RFC 6455 WebSocket opening handshake and
frame masking, base64, and `poll(2)`. Everything Convex-specific --
`/api/query`/`/api/mutation`/`/api/action` envelope decoding, the sync
protocol's `Connect`/`ModifyQuerySet`/`Transition` messages, version and
timestamp validation, and modification coalescing -- is written in Mercury
in `client/convex.m`, with a real `semidet`/`det` determinism declaration on
every predicate that touches protocol state.

The test-only adapter (`client/tests/conformance/adapter.m`) accepts NDJSON
over stdin/stdout or one `ADAPTER_LISTEN` TCP connection. It is a single
reactor loop: one `poll(2)` call over the control channel and the Live
socket together, so exactly one piece of code ever reads, writes, or
reconnects the WebSocket. Pure command parsing and event-JSON shaping live
in `client/tests/conformance/adapter_logic.m` so they can be unit tested
directly (`client/tests/conformance/adapter_test.m`) without a live process.

## Limitations

Live reconnect retries immediately rather than backing off exponentially
under sustained failure, and the inbound message queue is bounded only by
the shared 8 MiB per-frame limit, not by a dedicated slow-consumer count and
byte budget the way the Haskell and Prolog clients implement one. WebSocket
mutations/actions, `TransitionChunk` assembly, optimistic updates, journals,
replay, and Convex's non-JSON-safe value types are out of scope. The runtime
images contain Mercury's own `asm_fast.gc` grade runtime libraries, libgc,
and the OpenSSL 3 configuration and provider modules TLS needs at connect
time, but no `mmc` compiler, package manager, or delegated runtime. Realtime
remains an internal protocol, so even passing evidence would not make this
an officially supported SDK.
