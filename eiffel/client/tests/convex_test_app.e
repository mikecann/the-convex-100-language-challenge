note
	description: "[
		Language-local unit tests for the JSON value type and parser, run
		with no network access as part of the Docker `test' image. These
		classes' correctness does not depend on a live deployment, unlike
		CONVEX_SOCKET, CONVEX_WEBSOCKET, CONVEX_SYNC, and CONVEX_CLIENT,
		which were validated end to end against a running local Convex
		backend and a real TLS host during development (see the client
		README); that network-dependent proof is what `./run
		verify-example' and `./run verify' repeat and check automatically.
	]"

class
	CONVEX_TEST_APP

create
	make

feature {NONE} -- Initialization

	make
		do
			check_roundtrip_and_escaping
			check_integral_range_acceptance
			check_object_field_lookup_by_content
			check_array_and_nesting
			check_parser_rejects_malformed_input
			print ("ALL_TESTS_PASSED%N")
		end

feature {NONE} -- Tests

	check_roundtrip_and_escaping
			-- A value carrying every JSON shape, plus the ASCII characters
			-- that must be escaped on the way back out, round-trips
			-- exactly through parse then encode then parse again.
		local
			parser: CONVEX_JSON_PARSER
			source, reencoded: STRING
		do
			source := "{%"a%":1.0,%"b%":[true,false,null],%"c%":%"line1\nline2\ttab\%"quote\%"backslash\\end%"}"
			create parser.make
			parser.parse (source)
			check first_parse_succeeded: parser.successful end
			check attached parser.last_value as l_value then
				reencoded := l_value.to_json
			end
			create parser.make
			parser.parse (reencoded)
			check second_parse_succeeded: parser.successful end
			check attached parser.last_value as l_reparsed then
				check same_number: l_reparsed.field ("a").number_item = 1.0 end
				check same_array_length: l_reparsed.field ("b").array_item.count = 3 end
				check same_string: l_reparsed.field ("c").string_item.is_equal (
					"line1%Nline2%Ttab%"quote%"backslash\end") end
			end
		end

	check_integral_range_acceptance
			-- Convex's JSON transport may render an integral value as
			-- "0.0"/"1.0"; callers must accept that form and still reject
			-- fractional or out-of-range values rather than truncating them
			-- silently. This is the specific regression AGENTS.md calls out
			-- for decoding, not a fixture only exercising integer literals.
		local
			parser: CONVEX_JSON_PARSER
		do
			create parser.make
			parser.parse ("0.0")
			check parsed: parser.successful end
			check attached parser.last_value as l_zero then
				check is_integral: l_zero.is_integral_in_range (0, 10) end
				check decodes_to_zero: l_zero.integer_item = 0 end
			end

			create parser.make
			parser.parse ("2.5")
			check parsed_fraction: parser.successful end
			check attached parser.last_value as l_fraction then
				check fraction_rejected: not l_fraction.is_integral_in_range (0, 10) end
			end

			create parser.make
			parser.parse ("42")
			check parsed_out_of_range: parser.successful end
			check attached parser.last_value as l_out_of_range then
				check out_of_range_rejected: not l_out_of_range.is_integral_in_range (0, 10) end
			end
		end

	check_object_field_lookup_by_content
			-- `has_field' and `field' must compare by text content, not by
			-- whether the caller happens to hold the exact same STRING
			-- object the parser allocated: a freshly parsed key and an
			-- unrelated literal with the same text are unrelated objects.
		local
			parser: CONVEX_JSON_PARSER
			key_from_elsewhere: STRING
		do
			create parser.make
			parser.parse ("{%"status%":%"success%"}")
			check parsed: parser.successful end
			create key_from_elsewhere.make_from_string ("status")
			check attached parser.last_value as l_value then
				check has_field_by_content: l_value.has_field (key_from_elsewhere) end
				check field_by_content: l_value.field (key_from_elsewhere).string_item.is_equal ("success") end
			end
		end

	check_array_and_nesting
		local
			parser: CONVEX_JSON_PARSER
		do
			create parser.make
			parser.parse ("[1.0,[2.0,3.0],{%"nested%":true}]")
			check parsed: parser.successful end
			check attached parser.last_value as l_value then
				check outer_length: l_value.array_item.count = 3 end
				check inner_array: l_value.array_item.i_th (2).array_item.i_th (2).number_item = 3.0 end
				check inner_object: l_value.array_item.i_th (3).field ("nested").boolean_item end
			end
		end

	check_parser_rejects_malformed_input
			-- A parser that only ever reports success on well-formed input
			-- is easy to write by accident; assert the failure path too.
		local
			parser: CONVEX_JSON_PARSER
		do
			create parser.make
			parser.parse ("{%"a%":}")
			check rejected_missing_value: not parser.successful end
			check attached parser.last_error end

			create parser.make
			parser.parse ("{%"a%":1.0 extra}")
			check rejected_trailing_content: not parser.successful end

			create parser.make
			parser.parse ("")
			check rejected_empty_input: not parser.successful end
		end

end
