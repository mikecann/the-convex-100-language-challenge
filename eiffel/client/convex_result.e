note
	description: "[
		The outcome of one Convex HTTP call (query, mutation, or action):
		either a decoded success value with any function log lines, or a
		structured failure carrying the server's error message and, for a
		thrown `ConvexError', its typed `errorData'.
	]"

class
	CONVEX_RESULT

create
	make_success, make_failure

feature {NONE} -- Initialization

	make_success (a_value: CONVEX_JSON_VALUE; a_logs: ARRAYED_LIST [STRING])
		require
			a_value_attached: a_value /= Void
			a_logs_attached: a_logs /= Void
		do
			is_success := True
			value_cell := a_value
			logs := a_logs
		ensure
			is_success: is_success
		end

	make_failure (a_message: STRING; a_data: detachable CONVEX_JSON_VALUE; a_logs: ARRAYED_LIST [STRING])
		require
			a_message_attached: a_message /= Void
			a_logs_attached: a_logs /= Void
		do
			is_success := False
			error_message_cell := a_message
			error_data := a_data
			logs := a_logs
		ensure
			not_success: not is_success
		end

feature -- Access

	is_success: BOOLEAN

	value: CONVEX_JSON_VALUE
		require
			is_success: is_success
		do
			check attached value_cell as l_cell then
				Result := l_cell
			end
		end

	error_message: STRING
		require
			not_success: not is_success
		do
			check attached error_message_cell as l_cell then
				Result := l_cell
			end
		end

	error_data: detachable CONVEX_JSON_VALUE
			-- The thrown `ConvexError''s structured payload, if any. Only
			-- meaningful when not `is_success'.

	logs: ARRAYED_LIST [STRING]
			-- Function log lines, kept distinct from the return value.

feature {NONE} -- Implementation

	value_cell: detachable CONVEX_JSON_VALUE
	error_message_cell: detachable STRING

end
