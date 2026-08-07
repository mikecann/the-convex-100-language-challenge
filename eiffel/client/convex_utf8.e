note
	description: "[
		UTF-8 encoding for a single Unicode code point, used only where the
		JSON parser must turn a `\uXXXX' escape (or a surrogate pair of
		them) back into raw bytes. Ordinary unescaped text never passes
		through here: CONVEX_JSON_VALUE stores and re-emits it as the raw
		UTF-8 bytes it already is.
	]"

class
	CONVEX_UTF8

feature -- Encoding

	append_code_point (a_buffer: STRING; a_code: NATURAL_32)
			-- Append the UTF-8 byte encoding of Unicode code point `a_code'
			-- to `a_buffer'.
		require
			a_buffer_attached: a_buffer /= Void
			valid_code_point: a_code <= 0x10FFFF
		do
			if a_code <= 0x7F then
				a_buffer.append_character (a_code.to_integer_32.to_character_8)
			elseif a_code <= 0x7FF then
				a_buffer.append_character (byte ((0xC0).bit_or (shifted_right (a_code, 6))))
				a_buffer.append_character (byte ((0x80).bit_or (a_code.bit_and (0x3F))))
			elseif a_code <= 0xFFFF then
				a_buffer.append_character (byte ((0xE0).bit_or (shifted_right (a_code, 12))))
				a_buffer.append_character (byte ((0x80).bit_or (shifted_right (a_code, 6).bit_and (0x3F))))
				a_buffer.append_character (byte ((0x80).bit_or (a_code.bit_and (0x3F))))
			else
				a_buffer.append_character (byte ((0xF0).bit_or (shifted_right (a_code, 18))))
				a_buffer.append_character (byte ((0x80).bit_or (shifted_right (a_code, 12).bit_and (0x3F))))
				a_buffer.append_character (byte ((0x80).bit_or (shifted_right (a_code, 6).bit_and (0x3F))))
				a_buffer.append_character (byte ((0x80).bit_or (a_code.bit_and (0x3F))))
			end
		end

feature {NONE} -- Implementation

	shifted_right (a_value: NATURAL_32; a_bits: INTEGER): NATURAL_32
		do
			Result := a_value.bit_shift_right (a_bits)
		end

	byte (a_value: NATURAL_32): CHARACTER
		do
			Result := a_value.to_integer_32.to_character_8
		end

end
