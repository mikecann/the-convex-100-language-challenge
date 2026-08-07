# Convex from Prolog

This demonstration queries a Convex room with Prolog, observes it over Live,
increments it, and checks the reactive value changes from `0` to `1`.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.prolog`](examples/basics/main.prolog) is the exact program the
Docker image runs and the website displays. Its comments explain client setup,
the initial HTTP query, starting Live before the mutation, the idempotency key,
and the final reactive assertion.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native documented JSON query, mutation, action, bearer token, logs, and typed failures are implemented. |
| Live | Verified by shared local and hosted conformance | Native SWI WebSocket subscriptions, Add/Remove, typed query failures, and reconnect restoration are implemented for the pinned profile. |

The manifest deliberately awards no badges. Only root-owned local and hosted
black-box conformance can earn them.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.prolog -->
```prolog
:- use_module('../../client/convex').
:- use_module(library(random)).

main :-
    current_prolog_flag(argv, Arguments),
    main(Arguments).

main(Arguments) :-
    % The deployment URL stays outside the image so the same program can run
    % against the approved local backend or the hosted compatibility target.
    deployment_url(URL),
    % The verifier supplies a unique room as argv[1]. The fallback keeps the
    % image pleasant to run by hand without changing the canonical program.
    example_room(Arguments, Room),
    % This constructs the native Prolog client. No Convex CLI or delegated SDK
    % is involved.
    new_client(URL, Client),
    % Query the room through Convex's documented HTTP API and decode its
    % mathematically integral JSON count into a Prolog integer.
    query(
        Client,
        "demo:state",
        _{room:Room},
        result(State, _QueryLogs)
    ),
    count(State, Initial),
    format('current count: ~d~n', [Initial]),
    % Start Live before mutating, which closes the observation gap around the
    % write and lets us prove both the initial and changed reactive values.
    live_start(Client, Live),
    setup_call_cleanup(
        live_subscribe(
            Live,
            "demo:state",
            _{room:Room},
            Subscription
        ),
        demonstrate_counter(Client, Room, Initial, Subscription),
        % Both layers are explicitly closed so sockets, queues, and the single
        % Live owner thread are released on success or failure.
        ( subscription_close(Subscription),
          live_close(Live)
        )
    ).

demonstrate_counter(Client, Room, Initial, Subscription) :-
    % Convex hydrates a new subscription with its current value. It must agree
    % with the earlier HTTP query before the example continues.
    subscription_next(
        Subscription,
        10,
        update(value(LiveInitial), _InitialLogs)
    ),
    count(LiveInitial, Initial),
    format('live initial count: ~d~n', [Initial]),
    % A unique runId makes a retried HTTP mutation idempotent for this room.
    random_between(100000000, 999999999, RunId),
    format(string(RunIdText), 'prolog-~d', [RunId]),
    mutation(
        Client,
        "demo:increment",
        _{room:Room, language:"prolog", runId:RunIdText},
        result(Mutation, _MutationLogs)
    ),
    get_dict(applied, Mutation, true),
    get_dict(state, Mutation, MutationState),
    Expected is Initial + 1,
    count(MutationState, Expected),
    format('mutation applied: true~n'),
    format('mutation count: ~d~n', [Expected]),
    % The final value must come from the already-running Live subscription, not
    % from a second HTTP query.
    subscription_next(
        Subscription,
        10,
        update(value(LiveUpdated), _UpdatedLogs)
    ),
    count(LiveUpdated, Expected),
    format('live updated count: ~d~n', [Expected]),
    % Print verification only after HTTP and both Live values agree on 0 -> 1.
    format('verified count: ~d -> ~d~n', [Initial, Expected]).

deployment_url(URL) :-
    (   getenv('CONVEX_URL', URL)
    ->  true
    ;   throw(error(
            existence_error(environment_variable, 'CONVEX_URL'),
            _
        ))
    ).

example_room([RoomAtom|_], Room) :-
    !,
    atom_string(RoomAtom, Room).
example_room(_, "prolog-example").

% Convex may encode an integral count as 1 or 1.0. The client helper accepts
% both forms while rejecting fractions, strings, non-finite, and overflow.
count(State, Count) :-
    get_dict(count, State, Number),
    integer_json(Number, Count).
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test prolog
./run verify-example prolog
./run verify prolog
./run verify-hosted prolog
./run verify-all prolog
```

`test` runs the deterministic Prolog checks and builds the two native saved
executables. `verify-example` exercises the exact example above against a
unique room. The conformance commands are root-owned checks for the separate
self-hosted and dedicated hosted deployments.

## Conformance and protocol notes

HTTP calls use the documented `/api/query`, `/api/mutation`, and `/api/action`
JSON endpoints. Live uses SWI-Prolog's standard WebSocket library and the
unversioned `/api/sync` profile pinned to `convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

The test-only adapter accepts bounded UTF-8 NDJSON over stdin/stdout or one TCP
connection, including partial reads and command-scoped malformed-input errors.
`debugDisconnect` exists only for conformance reconnection tests, not the
educational API. One Live owner thread is the only code that touches a socket.
It validates and coalesces a whole Transition before delivery, invalidates an
entry before acknowledging its removal, and globally retains only the newest
16 updates within a 16 MiB encoded-byte budget. The adapter output queue has a
separate 16-event and 8 MiB encoded-byte budget.

## Limitations

Live authentication, WebSocket mutations/actions, TransitionChunk assembly,
optimistic updates, journals, replay, and Convex's non-JSON-safe value types
are out of scope. The saved runtime contains SWI's runtime libraries but no
`swipl` executable or compiler command. Its Debian command surface is reduced
to the verifier's shell and basic POSIX tools; Perl, package managers, network
tools, and delegated runtimes are absent. Realtime remains an internal
protocol, so even passing evidence would not make this an officially supported
SDK.
