<img src="logo.png" alt="SWI-Prolog logo" width="128" height="128">
<!-- Logo source: https://www.swi-prolog.org/download/logo/swipl-128.png -->

# Prolog

Prolog is a logic programming language: instead of spelling out every control-flow step, you describe facts and relationships, then ask which values make those relationships true. It began in Marseille in 1972 and became closely associated with symbolic AI, natural-language processing, expert systems, and constraint solving. The [Association for Logic Programming's 50-year history](https://prologyear.logicprogramming.org/local/PrologYear.html) is a good short account of where it came from.

This client uses [SWI-Prolog](https://www.swi-prolog.org/), a popular open-source implementation [started in 1986](https://www.swi-prolog.org/pldoc/man?section=implhistory). Its [current libraries and server features](https://www.swi-prolog.org/features.md) cover HTTP, JSON, WebSockets, RDF, and multithreading, which makes this unusual Convex experiment possible without delegating to another language. This is an educational, unofficial demonstration, not a production SDK or an officially supported Convex client.

## Getting Started

The canonical [`examples/basics/main.prolog`](examples/basics/main.prolog) program queries a fresh counter, subscribes to it before mutating, and confirms that Live delivers the change from `0` to `1`.

From the repository root, run it in Docker against the approved test deployment:

```sh
./run verify-example prolog
```

Docker builds the pinned `linux/amd64` SWI-Prolog image and runs that exact example in its minimal runtime. This command proves the example journey, not the full shared conformance suite.

## Interesting Parts

### Unification Decodes the Reply

Prolog has no `return` statement and no assignment operator, only unification: a variable and a term become equal to each other wherever a goal succeeds. Ask this client for a room's counter and the JSON Convex hands back becomes an ordinary SWI-Prolog dict, so pulling `count` out of it is that same unification the whole language runs on, not a special accessor call.

```prolog
show_room_count :-
    new_client(DeploymentURL, Client),
    % TypeScript: useQuery(api.demo.state, { room: "prolog-readme" })
    query(Client, "demo:state", _{room:"prolog-readme"}, result(State, _Logs)),
    % Unification binds Count to the field inside the returned dict.
    get_dict(count, State, Count),
    format('~w~n', [Count]).
```

There is no generated `api` object standing guard here — if the shape is wrong, `get_dict/3` simply fails.

### A Live Update Is a Term You Wait For

SWI-Prolog has shipped native threads and message queues since the late 1990s, and this client's Live layer leans on both: one background thread owns the WebSocket, and `subscription_next/3` blocks the calling thread until the next update — or a timeout — arrives as a term. Blocking is this client's own design choice for a linear command-line demo, not something the language forces on it.

```prolog
new_client(DeploymentURL, Client),
live_start(Client, Live),
setup_call_cleanup(
    % Subscribe before writing so no reactive update can be missed.
    live_subscribe(Live, "demo:state", _{room:Room}, Subscription),
    ( subscription_next(Subscription, 10, update(value(InitialState), _)),
      % TypeScript: useMutation(api.demo.increment)(args) — here it just blocks.
      mutation(Client, "demo:increment",
               _{room:Room, language:"prolog", runId:RunId}, _),
      subscription_next(Subscription, 10, update(value(UpdatedState), _))
    ),
    ( subscription_close(Subscription), live_close(Live) )
).
```

`setup_call_cleanup/3` guarantees the subscription and the Live client both close, whether the goal in between succeeds or throws.

### Success and Failure Are Different Clauses

Prolog has no `try`/`catch` idiom for picking a value apart and no boolean flag to branch on — it has clauses, tried top to bottom, each committing only once its head and body match. `decode_http_response/4` leans on exactly that to turn Convex's `"status": "success"` or `"status": "error"` JSON into either a `result/2` term or a thrown Prolog error, letting the dict itself choose the clause.

```prolog
decode_http_response(_, _, Response, result(Value, Logs)) :-
    get_dict(status, Response, "success"),
    get_dict(value, Response, Value),
    strict_logs(Response, Logs),
    !.
decode_http_response(Operation, _, Response, _) :-
    get_dict(status, Response, "error"),
    get_dict(errorMessage, Response, Message),
    throw(error(function_error(Operation, Message, _, _), _)).
decode_http_response(_, Status, Response, _) :-
    throw(error(protocol_error(http_response(Status, Response)), _)).
```

The cut (`!`) after the first clause is the only place the branching is explicit; the other two clauses simply never get tried once it fires.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native documented JSON query, mutation, action, bearer token, logs, and structured failures are implemented. |
| Live | Verified by shared local and hosted conformance | Native SWI-Prolog WebSocket subscriptions, add/remove, query failure recovery, and reconnect restoration are implemented for the pinned profile. |

The manifest records both earned capabilities. These are evidence-backed results for the pinned deployment profile, not a claim that every Convex feature is supported.

## Example

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

## Implementation Notes

- The public client is native Prolog. SWI-Prolog's standard HTTP, JSON, UUID, URI, and WebSocket libraries provide general transport and data handling; Convex-specific request, response, subscription, and reconnect behavior lives in [`client/convex.pl`](client/convex.pl).
- HTTP uses Convex's documented `/api/query`, `/api/mutation`, and `/api/action` JSON endpoints. Successful calls return `result(Value, Logs)` terms, while function, protocol, and transport failures remain distinguishable Prolog errors.
- Live uses one owner thread for all socket reads, writes, reconnects, and subscription changes. Callers receive updates through message queues, with the newest 16 updates retained inside a 16 MiB encoded-byte budget.
- The runtime is built from SWI-Prolog 9.2.8 saved states. Its final Debian image includes the SWI runtime libraries and CA certificates, but no `swipl` command, compiler frontend, package manager, Convex CLI, or delegated language runtime.
- Shared local and hosted evidence targets the unversioned `/api/sync` behavior pinned to `convex-rs` 0.10.4 at commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`. Passing that profile does not make the internal Live protocol stable or officially supported.

## Known Issues

1. Live authentication, WebSocket mutations and actions, transition chunks, optimistic updates, journals, and replay are not implemented.
2. The client handles JSON-safe Convex values only. It does not decode Convex's extended non-JSON value types.
3. Live delivery keeps only the newest 16 queued updates, capped at 16 MiB total and 2 MiB per event. A deliberately slow consumer can therefore lose older intermediate values.
4. `subscription_next/3` blocks until an update or timeout. Applications must explicitly close both the subscription and Live client; there is no React-style component lifecycle to do that work.
