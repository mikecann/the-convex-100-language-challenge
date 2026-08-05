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
