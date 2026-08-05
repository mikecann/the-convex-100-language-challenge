:- begin_tests(adapter).
:- use_module('../../../client/convex').

test(integer_value_preserves_counter_semantics) :- integer_json(0.0, 0), integer_json(1, 1).
test(fractional_value_is_not_a_counter, [fail]) :- integer_json(0.1, _).
:- end_tests(adapter).
