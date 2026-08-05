# Convex from Prolog

This demonstration queries a Convex room with Prolog, observes it over Live,
increments it, and checks the reactive value changes from `0` to `1`.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.pl`](examples/basics/main.pl) is the exact program the
Docker image runs and the website displays. Its comments explain client setup,
the initial HTTP query, starting Live before the mutation, the idempotency key,
and the final reactive assertion.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared evidence | Native documented JSON query, mutation, action, bearer token, logs, and typed failures are implemented. |
| Live | Awaiting shared evidence | Native SWI WebSocket subscriptions, Add/Remove, typed query failures, and reconnect restoration are implemented for the pinned profile. |

The manifest deliberately awards no badges. Only root-owned local and hosted
black-box conformance can earn them.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pl -->
```perl
:- use_module('../../client/convex').
:- use_module(library(random)).

main :-
    current_prolog_flag(argv, Arguments),
    main(Arguments).

main(Arguments) :-
    ( getenv('CONVEX_URL', URL) -> true ; throw(error(existence_error(environment_variable, 'CONVEX_URL'), _)) ),
    ( Arguments = [RoomAtom|_] -> atom_string(RoomAtom, Room) ; Room = "prolog-example" ),
    new_client(URL, Client),
    % Query the room over Convex's documented HTTP API before opening Live.
    query(Client, "demo:state", _{room:Room}, result(State, _)), count(State, Initial),
    format('current count: ~d~n', [Initial]),
    % Subscribe before the mutation, closing the observation gap around the write.
    live_start(Client, Live),
    setup_call_cleanup(
        live_subscribe(Live, "demo:state", _{room:Room}, Subscription),
        demonstrate_counter(Client, Room, Initial, Subscription),
        ( subscription_close(Subscription), live_close(Live) )).

demonstrate_counter(Client, Room, Initial, Subscription) :-
    subscription_next(Subscription, 10, update(value(LiveInitial), _)),
    count(LiveInitial, Initial), format('live initial count: ~d~n', [Initial]),
    % The unique runId makes a retried HTTP mutation idempotent for this room.
    random_between(100000000, 999999999, RunId),
    format(string(RunIdText), 'prolog-~d', [RunId]),
    mutation(Client, "demo:increment", _{room:Room, language:"prolog", runId:RunIdText}, result(Mutation, _)),
    get_dict(applied, Mutation, true), get_dict(state, Mutation, MutationState),
    Expected is Initial + 1, count(MutationState, Expected),
    format('mutation applied: true~n'), format('mutation count: ~d~n', [Expected]),
    % The final value must be delivered by Live, not a second HTTP query.
    subscription_next(Subscription, 10, update(value(LiveUpdated), _)), count(LiveUpdated, Expected),
    format('live updated count: ~d~n', [Expected]),
    format('verified count: ~d -> ~d~n', [Initial, Expected]).

count(State, Count) :- get_dict(count, State, Number), integer_json(Number, Count).
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
connection. `debugDisconnect` exists only for conformance reconnection tests,
not the educational API. One Live owner thread is the only code that touches a
socket; it commits a whole Transition before delivery, invalidates an entry
before acknowledging its removal, and keeps each slow subscription to its
newest 16 updates.

## Limitations

Live authentication, WebSocket mutations/actions, TransitionChunk assembly,
optimistic updates, journals, replay, and Convex's non-JSON-safe value types
are out of scope. The saved runtime contains SWI's runtime libraries but no
`swipl` executable or compiler command. Realtime remains an internal protocol,
so even passing evidence would not make this an officially supported SDK.
