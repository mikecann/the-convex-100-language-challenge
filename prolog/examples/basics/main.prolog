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
