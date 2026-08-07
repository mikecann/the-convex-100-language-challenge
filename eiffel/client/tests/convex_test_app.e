note
	description: "Temporary smoke-test root used only while bringing up the toolchain; replaced by CONVEX_JSON_TESTS once the ECF plumbing is verified."

class
	CONVEX_TEST_APP

create
	make

feature {NONE} -- Initialization

	make
		local
			parser: CONVEX_JSON_PARSER
			value: CONVEX_JSON_VALUE
			obj: CONVEX_JSON_VALUE
		do
			create parser.make
			parser.parse ("{%"a%":1.0,%"b%":[true,false,null],%"c%":%"hi é %"quote\%"%"}")
			check parsed: parser.successful end
			if attached parser.last_value as l_value then
				value := l_value
				check has_a: value.has_field ("a") end
				check number_ok: value.field ("a").number_item = 1.0 end
				check array_len: value.field ("b").array_item.count = 3 end
				print (value.to_json)
				print ("%N")
			else
				print ("PARSE_FAILED_UNEXPECTEDLY%N")
			end

			create obj.make_object
			obj.put_field ("room", create {CONVEX_JSON_VALUE}.make_string ("demo"))
			print (obj.to_json)
			print ("%N")
			print ("SMOKE_OK%N")
		end

end
