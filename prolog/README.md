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

### A query becomes a relationship between terms

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "prolog-readme" });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // `api` makes this result type-safe.
}
```

**Prolog**

```prolog
:- use_module('../../client/convex').

show_room_count :-
    % Construct a client term from configuration supplied by the environment.
    getenv('CONVEX_URL', DeploymentURL),
    new_client(DeploymentURL, Client),
    % _{room:...} is an SWI-Prolog dict and mirrors the Convex argument object.
    query(
        Client,
        "demo:state",
        _{room:"prolog-readme"},
        result(State, _Logs)
    ),
    % Unification binds Count to the returned dict field.
    get_dict(count, State, Count),
    format('~w~n', [Count]).
```

React's `useQuery` remains subscribed and rerenders the component. The Prolog `query/4` call above is deliberately a one-off HTTP request. Prolog has no generated Convex types here, so the result is a runtime dict and `get_dict/3` checks its shape while binding `Count`.

### Live is an owned resource, not a hook

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "prolog-live-readme";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    }); // Arguments and result are checked from generated Convex types.
  }

  // React starts, updates, and disposes the subscription for this component.
  return <button onClick={addOne}>{state?.count ?? "Loading..."}</button>;
}
```

**Prolog**

```prolog
:- use_module('../../client/convex').
:- use_module(library(random)).

observe_one_increment :-
    getenv('CONVEX_URL', DeploymentURL),
    Room = "prolog-live-readme",
    new_client(DeploymentURL, Client),
    live_start(Client, Live),
    setup_call_cleanup(
        % Subscribe before writing so no reactive update can be missed.
        live_subscribe(Live, "demo:state", _{room:Room}, Subscription),
        ( subscription_next(
              Subscription,
              10,
              update(value(InitialState), _InitialLogs)
          ),
          get_dict(count, InitialState, InitialCount),
          random_between(100000000, 999999999, RunNumber),
          format(string(RunId), 'prolog-readme-~d', [RunNumber]),
          mutation(
              Client,
              "demo:increment",
              _{room:Room, language:"prolog", runId:RunId},
              result(MutationResult, _MutationLogs)
          ),
          get_dict(applied, MutationResult, Applied),
          % Blocking next/3 is this client's API choice, not a Prolog limit.
          subscription_next(
              Subscription,
              10,
              update(value(UpdatedState), _UpdatedLogs)
          ),
          get_dict(count, UpdatedState, UpdatedCount),
          format('~w: ~d -> ~d~n', [Applied, InitialCount, UpdatedCount])
        ),
        % The command-line program owns both resources and closes them itself.
        ( subscription_close(Subscription),
          live_close(Live)
        )
    ).
```

The Prolog API exposes each update as a term returned by `subscription_next/3`. That blocking interface keeps a command-line example linear and readable; it is a design choice in this client, while SWI-Prolog itself also supports threads and message queues.

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
