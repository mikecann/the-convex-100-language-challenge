:- begin_tests(convex).
:- use_module('../convex').

test(integer_json_accepts_integral_decimal) :- integer_json(1.0, 1).
test(integer_json_rejects_fractional, [fail]) :- integer_json(1.5, _).
test(integer_json_rejects_quoted, [fail]) :- integer_json("1", _).
test(timestamp_is_little_endian) :- timestamp_newer("AQAAAAAAAAA=", "AAAAAAAAAAA=").
test(timestamp_does_not_reverse_order, [fail]) :- timestamp_newer("AAAAAAAAAAA=", "AQAAAAAAAAA=").
test(client_rejects_non_http_url, [throws(error(domain_error(_, _), _))]) :- new_client("ftp://example.invalid", _).
:- end_tests(convex).
