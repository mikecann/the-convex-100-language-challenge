note
	description: "[
		A JSON value restricted to the shapes Convex's documented public
		HTTP and sync wire formats actually use: null, boolean, a Float64
		number, a UTF-8 string, an ordered array, or an object whose field
		order is preserved so encoded output is deterministic.

		This is a value type, not a parser: see CONVEX_JSON_PARSER for
		decoding text and CONVEX_JSON_VALUE.to_json for encoding.
	]"

class
	CONVEX_JSON_VALUE

create
	make_null, make_boolean, make_number, make_string, make_array, make_object

feature {NONE} -- Initialization

	make_null
			-- Create the JSON `null' value.
		do
			kind := Kind_null
		ensure
			is_null: is_null
		end

	make_boolean (a_value: BOOLEAN)
			-- Create a JSON boolean.
		do
			kind := Kind_boolean
			boolean_item := a_value
		ensure
			is_boolean: is_boolean
			value_set: boolean_item = a_value
		end

	make_number (a_value: REAL_64)
			-- Create a JSON number. Convex's documented HTTP format only
			-- carries Float64-range values; integral values arrive as
			-- `0.0'-style decimals, which callers decode explicitly.
		do
			kind := Kind_number
			number_item := a_value
		ensure
			is_number: is_number
			value_set: number_item = a_value
		end

	make_string (a_value: STRING)
			-- Create a JSON string.
		require
			a_value_attached: a_value /= Void
		do
			kind := Kind_string
			string_item_cell := a_value
		ensure
			is_string: is_string
			value_set: string_item = a_value
		end

	make_array
			-- Create an empty JSON array; grow it with `extend'.
		local
			l_cell: ARRAYED_LIST [CONVEX_JSON_VALUE]
		do
			kind := Kind_array
			create l_cell.make (4)
			array_item_cell := l_cell
		ensure
			is_array: is_array
			empty: array_item.is_empty
		end

	make_object
			-- Create an empty JSON object; grow it with `put_field'.
		local
			l_keys: ARRAYED_LIST [STRING]
			l_values: ARRAYED_LIST [CONVEX_JSON_VALUE]
		do
			kind := Kind_object
			create l_keys.make (4)
			create l_values.make (4)
			object_keys_cell := l_keys
			object_values_cell := l_values
		ensure
			is_object: is_object
			empty: object_keys.is_empty
		end

feature -- Kind constants

	Kind_null: INTEGER = 0
	Kind_boolean: INTEGER = 1
	Kind_number: INTEGER = 2
	Kind_string: INTEGER = 3
	Kind_array: INTEGER = 4
	Kind_object: INTEGER = 5

feature -- Kind query

	kind: INTEGER
			-- One of the `Kind_*' constants; see the class invariant.

	is_null: BOOLEAN
			-- Is this the JSON `null' value?
		do
			Result := kind = Kind_null
		end

	is_boolean: BOOLEAN
			-- Is this a JSON boolean?
		do
			Result := kind = Kind_boolean
		end

	is_number: BOOLEAN
			-- Is this a JSON number?
		do
			Result := kind = Kind_number
		end

	is_string: BOOLEAN
			-- Is this a JSON string?
		do
			Result := kind = Kind_string
		end

	is_array: BOOLEAN
			-- Is this a JSON array?
		do
			Result := kind = Kind_array
		end

	is_object: BOOLEAN
			-- Is this a JSON object?
		do
			Result := kind = Kind_object
		end

feature -- Access

	boolean_item: BOOLEAN
			-- The wrapped boolean. Only meaningful when `is_boolean'.

	number_item: REAL_64
			-- The wrapped Float64. Only meaningful when `is_number'.

	string_item: STRING
			-- The wrapped string. Only meaningful when `is_string'.
		require
			is_string: is_string
		do
			check attached string_item_cell as l_cell then
				Result := l_cell
			end
		end

	array_item: ARRAYED_LIST [CONVEX_JSON_VALUE]
			-- The wrapped elements, in order. Only meaningful when `is_array'.
		require
			is_array: is_array
		do
			check attached array_item_cell as l_cell then
				Result := l_cell
			end
		end

	object_keys: ARRAYED_LIST [STRING]
			-- Field names in the order they were added. Only meaningful
			-- when `is_object'.
		require
			is_object: is_object
		do
			check attached object_keys_cell as l_cell then
				Result := l_cell
			end
		end

	has_field (a_key: STRING): BOOLEAN
			-- Does this object carry a field named `a_key'?
		require
			is_object: is_object
			a_key_attached: a_key /= Void
		do
			Result := object_keys.has (a_key)
		end

	field (a_key: STRING): CONVEX_JSON_VALUE
			-- The value stored under `a_key'.
		require
			is_object: is_object
			has_field: has_field (a_key)
		local
			i: INTEGER
		do
			from
				i := 1
			until
				Result /= Void
			loop
				if object_keys.i_th (i) ~ a_key then
					Result := object_values.i_th (i)
				end
				i := i + 1
			end
		ensure
			result_attached: Result /= Void
		end

feature -- Element change

	extend (a_value: CONVEX_JSON_VALUE)
			-- Append `a_value' to this array.
		require
			is_array: is_array
			a_value_attached: a_value /= Void
		do
			array_item.extend (a_value)
		ensure
			grew: array_item.count = old array_item.count + 1
		end

	put_field (a_key: STRING; a_value: CONVEX_JSON_VALUE)
			-- Set (or replace) the field named `a_key' to `a_value',
			-- preserving first-seen field order.
		require
			is_object: is_object
			a_key_attached: a_key /= Void
			a_value_attached: a_value /= Void
		local
			i: INTEGER
			replaced: BOOLEAN
		do
			from
				i := 1
			until
				i > object_keys.count or replaced
			loop
				if object_keys.i_th (i) ~ a_key then
					object_values.put_i_th (a_value, i)
					replaced := True
				end
				i := i + 1
			end
			if not replaced then
				object_keys.extend (a_key)
				object_values.extend (a_value)
			end
		ensure
			has_field: has_field (a_key)
			value_set: field (a_key) = a_value
		end

feature -- Conversion helpers

	is_integral_in_range (a_low, a_high: INTEGER_64): BOOLEAN
			-- Is this number mathematically integral (no fractional part,
			-- finite) and within [a_low, a_high]? Convex's JSON transport
			-- may render an integral value as "0.0" or "1.0"; callers that
			-- expect a whole number must check this rather than truncating
			-- a fractional or out-of-range value silently.
		require
			is_number: is_number
		do
			Result := number_item = number_item.floor.to_double
				and then number_item >= a_low.to_double
				and then number_item <= a_high.to_double
				and then not number_item.is_nan
		end

	integer_item: INTEGER_64
			-- `number_item' truncated to an integer. Call only after
			-- `is_integral_in_range' has confirmed the value is safe.
		require
			is_number: is_number
			is_integral: is_integral_in_range ({INTEGER_64}.min_value, {INTEGER_64}.max_value)
		do
			Result := number_item.rounded
		end

feature -- Output

	to_json: STRING
			-- Encode this value as compact JSON text.
		local
			buffer: STRING
		do
			create buffer.make (32)
			append_to (buffer)
			Result := buffer
		end

	append_to (a_buffer: STRING)
			-- Append this value's compact JSON encoding to `a_buffer'.
		require
			a_buffer_attached: a_buffer /= Void
		local
			i: INTEGER
		do
			inspect kind
			when Kind_null then
				a_buffer.append ("null")
			when Kind_boolean then
				if boolean_item then
					a_buffer.append ("true")
				else
					a_buffer.append ("false")
				end
			when Kind_number then
				a_buffer.append (formatted_number (number_item))
			when Kind_string then
				append_quoted_string (a_buffer, string_item)
			when Kind_array then
				a_buffer.append_character ('[')
				from
					i := 1
				until
					i > array_item.count
				loop
					if i > 1 then
						a_buffer.append_character (',')
					end
					array_item.i_th (i).append_to (a_buffer)
					i := i + 1
				end
				a_buffer.append_character (']')
			when Kind_object then
				a_buffer.append_character ('{')
				from
					i := 1
				until
					i > object_keys.count
				loop
					if i > 1 then
						a_buffer.append_character (',')
					end
					append_quoted_string (a_buffer, object_keys.i_th (i))
					a_buffer.append_character (':')
					object_values.i_th (i).append_to (a_buffer)
					i := i + 1
				end
				a_buffer.append_character ('}')
			end
		end

feature {NONE} -- Output implementation

	object_values: ARRAYED_LIST [CONVEX_JSON_VALUE]
			-- Field values, parallel to `object_keys'. Only meaningful
			-- when `is_object'.
		require
			is_object: is_object
		do
			check attached object_values_cell as l_cell then
				Result := l_cell
			end
		end

	string_item_cell: detachable STRING
	array_item_cell: detachable ARRAYED_LIST [CONVEX_JSON_VALUE]
	object_keys_cell: detachable ARRAYED_LIST [STRING]
	object_values_cell: detachable ARRAYED_LIST [CONVEX_JSON_VALUE]

	formatted_number (a_value: REAL_64): STRING
			-- Render `a_value' the way Convex's documented format expects:
			-- a whole number still carries a decimal point (`0.0', not
			-- `0'), matching the shared example expectation and keeping the
			-- integral/fractional distinction visible on the wire.
		do
			if not a_value.is_nan and then a_value = a_value.floor.to_double then
				Result := integer_64_to_string (a_value.rounded) + ".0"
			else
				Result := a_value.out
			end
		end

	integer_64_to_string (a_value: INTEGER_64): STRING
		do
			Result := a_value.out
		end

	append_quoted_string (a_buffer: STRING; a_text: STRING)
			-- Append `a_text' to `a_buffer' as a quoted, escaped JSON
			-- string literal. `a_text' already holds raw UTF-8 bytes (the
			-- parser stores decoded text that way, and callers build
			-- strings from ordinary Eiffel literals or UTF-8 sources), so
			-- only the handful of ASCII characters JSON forbids unescaped
			-- need special handling; every other byte, including UTF-8
			-- continuation bytes, passes through unchanged.
		local
			i: INTEGER
			code: INTEGER
		do
			a_buffer.append_character ('"')
			from
				i := 1
			until
				i > a_text.count
			loop
				code := a_text.item (i).code
				if a_text.item (i) = '"' then
					a_buffer.append ("\%"")
				elseif a_text.item (i) = '\' then
					a_buffer.append ("\\")
				elseif code = 0x0A then
					a_buffer.append ("\n")
				elseif code = 0x0D then
					a_buffer.append ("\r")
				elseif code = 0x09 then
					a_buffer.append ("\t")
				elseif code < 0x20 then
					a_buffer.append ("\u00")
					a_buffer.append (hex_digit (code // 16))
					a_buffer.append (hex_digit (code \\ 16))
				else
					a_buffer.append_character (a_text.item (i))
				end
				i := i + 1
			end
			a_buffer.append_character ('"')
		end

	hex_digit (a_value: INTEGER): STRING
			-- One lowercase hexadecimal digit for `a_value'.
		require
			in_range: a_value >= 0 and a_value <= 15
		local
			c: CHARACTER
		do
			if a_value < 10 then
				c := (('0').code + a_value).to_character_8
			else
				c := (('a').code + a_value - 10).to_character_8
			end
			create Result.make_filled (c, 1)
		end

invariant
	kind_known: kind = Kind_null or kind = Kind_boolean or kind = Kind_number
		or kind = Kind_string or kind = Kind_array or kind = Kind_object
	string_attached_when_string: is_string implies string_item_cell /= Void
	array_attached_when_array: is_array implies array_item_cell /= Void
	object_parallel_when_object: is_object implies
		(object_keys_cell /= Void and object_values_cell /= Void
			and then object_keys_cell.count = object_values_cell.count)

end
