note
	description: "[
		One reactive update for a Live subscription, decoded from a
		`QueryUpdated' or `QueryFailed' sync-protocol modification and
		carrying the adapter subscription id it belongs to.
	]"

class
	CONVEX_SYNC_EVENT

create
	make_value, make_error

feature {NONE} -- Initialization

	make_value (a_subscription_id: STRING; a_value: CONVEX_JSON_VALUE)
		require
			a_subscription_id_attached: a_subscription_id /= Void
			a_value_attached: a_value /= Void
		do
			subscription_id := a_subscription_id
			is_error := False
			value_cell := a_value
		ensure
			not_error: not is_error
		end

	make_error (a_subscription_id: STRING; a_message: STRING; a_data: detachable CONVEX_JSON_VALUE)
		require
			a_subscription_id_attached: a_subscription_id /= Void
			a_message_attached: a_message /= Void
		do
			subscription_id := a_subscription_id
			is_error := True
			error_message_cell := a_message
			error_data := a_data
		ensure
			is_error: is_error
		end

feature -- Access

	subscription_id: STRING

	is_error: BOOLEAN

	value: CONVEX_JSON_VALUE
			-- The updated query result. Only meaningful when not `is_error'.
		require
			not_error: not is_error
		do
			check attached value_cell as l_cell then
				Result := l_cell
			end
		end

	error_message: STRING
			-- The reactive query's failure message. Only meaningful when
			-- `is_error'.
		require
			is_error: is_error
		do
			check attached error_message_cell as l_cell then
				Result := l_cell
			end
		end

	error_data: detachable CONVEX_JSON_VALUE
			-- The structured `ConvexError' payload, when the failure was a
			-- typed application error. Only meaningful when `is_error'.

feature {NONE} -- Implementation

	value_cell: detachable CONVEX_JSON_VALUE
	error_message_cell: detachable STRING

end
