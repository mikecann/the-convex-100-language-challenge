note
	description: "[
		A recursive-descent parser for the restricted JSON grammar Convex's
		documented HTTP format and pinned sync profile actually send: null,
		booleans, Float64 numbers, UTF-8 strings, arrays and objects. It
		does not attempt to parse the richer `convex_encoded_json' tagged
		encoding, which this client deliberately does not use.
	]"

class
	CONVEX_JSON_PARSER

create
	make

feature {NONE} -- Initialization

	make
		do
			create text.make_empty
			successful := False
		end

feature -- Access

	successful: BOOLEAN
			-- Did the last `parse' call decode a complete, valid value?

	last_value: detachable CONVEX_JSON_VALUE
			-- The decoded value, attached exactly when `successful'.

	last_error: detachable STRING
			-- A short diagnostic, attached exactly when not `successful'.

feature -- Basic operations

	parse (a_text: STRING)
			-- Decode `a_text' as one JSON value with no trailing content
			-- besides whitespace. Sets exactly one of `last_value' (with
			-- `successful' True) or `last_error' (with `successful' False).
		require
			a_text_attached: a_text /= Void
		local
			value: detachable CONVEX_JSON_VALUE
		do
			text := a_text
			position := 1
			last_value := Void
			last_error := Void
			skip_whitespace
			value := parse_value
			if value = Void then
				successful := False
				if last_error = Void then
					last_error := "empty input"
				end
			else
				skip_whitespace
				if position <= text.count then
					successful := False
					last_error := "trailing content after JSON value at byte " + position.out
				else
					successful := True
					last_value := value
				end
			end
		ensure
			exactly_one_result: successful = (last_value /= Void)
			error_when_failed: not successful implies last_error /= Void
		end

feature {NONE} -- Parsing state

	text: STRING
	position: INTEGER
			-- 1-based index of the next unread byte in `text'.

feature {NONE} -- Character classification

	at_end: BOOLEAN
		do
			Result := position > text.count
		end

	current_character: CHARACTER
		require
			not_at_end: not at_end
		do
			Result := text.item (position)
		end

	skip_whitespace
		do
			from until at_end or else not is_whitespace (current_character)
			loop
				position := position + 1
			end
		end

	is_whitespace (c: CHARACTER): BOOLEAN
		do
			Result := c = ' ' or c = '%T' or c = '%N' or c = '%R'
		end

	is_digit (c: CHARACTER): BOOLEAN
		do
			Result := c >= '0' and c <= '9'
		end

feature {NONE} -- Value dispatch

	parse_value: detachable CONVEX_JSON_VALUE
			-- Parse one value at `position', or leave `last_error' set and
			-- return Void.
		do
			if at_end then
				last_error := "unexpected end of input"
			elseif current_character = '{' then
				Result := parse_object
			elseif current_character = '[' then
				Result := parse_array
			elseif current_character = '"' then
				Result := parse_string_value
			elseif current_character = 't' or current_character = 'f' then
				Result := parse_boolean
			elseif current_character = 'n' then
				Result := parse_null
			elseif current_character = '-' or is_digit (current_character) then
				Result := parse_number
			else
				last_error := "unexpected character %'" + current_character.out + "%' at byte " + position.out
			end
		end

	expect (c: CHARACTER): BOOLEAN
			-- Consume `c' if present, else set `last_error' and return False.
		do
			if not at_end and then current_character = c then
				position := position + 1
				Result := True
			else
				last_error := "expected %'" + c.out + "%' at byte " + position.out
			end
		end

feature {NONE} -- Literals

	parse_boolean: detachable CONVEX_JSON_VALUE
		do
			if matches_literal ("true") then
				create Result.make_boolean (True)
			elseif matches_literal ("false") then
				create Result.make_boolean (False)
			else
				last_error := "invalid literal at byte " + position.out
			end
		end

	parse_null: detachable CONVEX_JSON_VALUE
		do
			if matches_literal ("null") then
				create Result.make_null
			else
				last_error := "invalid literal at byte " + position.out
			end
		end

	matches_literal (a_literal: STRING): BOOLEAN
		do
			if position + a_literal.count - 1 <= text.count
				and then text.substring (position, position + a_literal.count - 1) ~ a_literal
			then
				position := position + a_literal.count
				Result := True
			end
		end

feature {NONE} -- Numbers

	parse_number: detachable CONVEX_JSON_VALUE
		local
			start: INTEGER
			text_value: STRING
		do
			start := position
			if not at_end and then current_character = '-' then
				position := position + 1
			end
			from until at_end or else not is_digit (current_character)
			loop
				position := position + 1
			end
			if not at_end and then current_character = '.' then
				position := position + 1
				from until at_end or else not is_digit (current_character)
				loop
					position := position + 1
				end
			end
			if not at_end and then (current_character = 'e' or current_character = 'E') then
				position := position + 1
				if not at_end and then (current_character = '+' or current_character = '-') then
					position := position + 1
				end
				from until at_end or else not is_digit (current_character)
				loop
					position := position + 1
				end
			end
			if position = start then
				last_error := "invalid number at byte " + position.out
			else
				text_value := text.substring (start, position - 1)
				create Result.make_number (text_value.to_double)
			end
		end

feature {NONE} -- Strings

	parse_string_value: detachable CONVEX_JSON_VALUE
		local
			decoded: detachable STRING
		do
			decoded := parse_raw_string
			if decoded /= Void then
				create Result.make_string (decoded)
			end
		end

	parse_raw_string: detachable STRING
			-- Consume a quoted, escaped JSON string and return its decoded
			-- UTF-8 bytes, or Void with `last_error' set.
		local
			buffer: STRING
			utf8: CONVEX_UTF8
			done: BOOLEAN
			high_surrogate: INTEGER
		do
			if expect ('"') then
				create buffer.make (16)
				create utf8
				high_surrogate := -1
				from until done
				loop
					if at_end then
						last_error := "unterminated string"
						done := True
					elseif current_character = '"' then
						position := position + 1
						done := True
					elseif current_character = '\' then
						position := position + 1
						if at_end then
							last_error := "unterminated escape"
							done := True
						elseif current_character = 'u' then
							position := position + 1
							if not append_unicode_escape (buffer, utf8, high_surrogate) then
								done := True
							else
								high_surrogate := last_pending_surrogate
							end
						else
							if not append_simple_escape (buffer) then
								done := True
							end
							high_surrogate := -1
						end
					else
						buffer.append_character (current_character)
						position := position + 1
						high_surrogate := -1
					end
				end
				if last_error = Void then
					Result := buffer
				end
			end
		end

	last_pending_surrogate: INTEGER
			-- Set by `append_unicode_escape' when it consumed a high
			-- surrogate that still needs its low-surrogate partner.

	append_simple_escape (a_buffer: STRING): BOOLEAN
		do
			Result := True
			if current_character = '"' then
				a_buffer.append_character ('"')
			elseif current_character = '\' then
				a_buffer.append_character ('\')
			elseif current_character = '/' then
				a_buffer.append_character ('/')
			elseif current_character = 'b' then
				a_buffer.append_character ('%B')
			elseif current_character = 'f' then
				a_buffer.append_character ('%F')
			elseif current_character = 'n' then
				a_buffer.append_character ('%N')
			elseif current_character = 'r' then
				a_buffer.append_character ('%R')
			elseif current_character = 't' then
				a_buffer.append_character ('%T')
			else
				last_error := "invalid escape %'\" + current_character.out + "%' at byte " + position.out
				Result := False
			end
			if Result then
				position := position + 1
			end
		end

	append_unicode_escape (a_buffer: STRING; a_utf8: CONVEX_UTF8; a_pending_high_surrogate: INTEGER): BOOLEAN
			-- Consume four hex digits (already past `\u') and either buffer
			-- a pending high surrogate or emit UTF-8 bytes, combining a
			-- trailing low surrogate with `a_pending_high_surrogate' when
			-- one is pending.
		local
			code: INTEGER
			combined: NATURAL_32
		do
			code := read_hex4
			if code < 0 then
				Result := False
			elseif a_pending_high_surrogate >= 0 then
				if code >= 0xDC00 and code <= 0xDFFF then
					combined := (0x10000).to_natural_32
						+ ((a_pending_high_surrogate - 0xD800).to_natural_32 * (0x400).to_natural_32)
						+ (code - 0xDC00).to_natural_32
					a_utf8.append_code_point (a_buffer, combined)
					last_pending_surrogate := -1
					Result := True
				else
					last_error := "unpaired high surrogate at byte " + position.out
					Result := False
				end
			elseif code >= 0xD800 and code <= 0xDBFF then
				last_pending_surrogate := code
				Result := True
			else
				a_utf8.append_code_point (a_buffer, code.to_natural_32)
				last_pending_surrogate := -1
				Result := True
			end
		end

	read_hex4: INTEGER
			-- Read four hex digits at `position', or -1 with `last_error'
			-- set.
		local
			i, digit: INTEGER
		do
			if position + 3 > text.count then
				last_error := "truncated \u escape at byte " + position.out
				Result := -1
			else
				from i := 0 until i = 4 or Result = -1
				loop
					digit := hex_value (text.item (position))
					if digit < 0 then
						last_error := "invalid hex digit at byte " + position.out
						Result := -1
					else
						Result := Result.max (0) * 16 + digit
						position := position + 1
					end
					i := i + 1
				end
			end
		end

	hex_value (c: CHARACTER): INTEGER
		do
			if c >= '0' and c <= '9' then
				Result := c.code - ('0').code
			elseif c >= 'a' and c <= 'f' then
				Result := c.code - ('a').code + 10
			elseif c >= 'A' and c <= 'F' then
				Result := c.code - ('A').code + 10
			else
				Result := -1
			end
		end

feature {NONE} -- Arrays and objects

	parse_array: detachable CONVEX_JSON_VALUE
		local
			result_array: CONVEX_JSON_VALUE
			element: detachable CONVEX_JSON_VALUE
			done: BOOLEAN
		do
			if expect ('[') then
				create result_array.make_array
				skip_whitespace
				if not at_end and then current_character = ']' then
					position := position + 1
					Result := result_array
				else
					from until done
					loop
						skip_whitespace
						element := parse_value
						if element = Void then
							done := True
						else
							result_array.extend (element)
							skip_whitespace
							if at_end then
								last_error := "unterminated array"
								done := True
							elseif current_character = ',' then
								position := position + 1
							elseif current_character = ']' then
								position := position + 1
								Result := result_array
								done := True
							else
								last_error := "expected %',%' or %']%' at byte " + position.out
								done := True
							end
						end
					end
				end
			end
		end

	parse_object: detachable CONVEX_JSON_VALUE
		local
			result_object: CONVEX_JSON_VALUE
			key: detachable STRING
			value: detachable CONVEX_JSON_VALUE
			done: BOOLEAN
		do
			if expect ('{') then
				create result_object.make_object
				skip_whitespace
				if not at_end and then current_character = '}' then
					position := position + 1
					Result := result_object
				else
					from until done
					loop
						skip_whitespace
						if at_end or else current_character /= '"' then
							last_error := "expected object key at byte " + position.out
							done := True
						else
							key := parse_raw_string
							if key = Void then
								done := True
							else
								skip_whitespace
								if not expect (':') then
									done := True
								else
									skip_whitespace
									value := parse_value
									if value = Void then
										done := True
									else
										result_object.put_field (key, value)
										skip_whitespace
										if at_end then
											last_error := "unterminated object"
											done := True
										elseif current_character = ',' then
											position := position + 1
										elseif current_character = '}' then
											position := position + 1
											Result := result_object
											done := True
										else
											last_error := "expected %',%' or %'}%' at byte " + position.out
											done := True
										end
									end
								end
							end
						end
					end
				end
			end
		end

end
