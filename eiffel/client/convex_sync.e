note
	description: "[
		The client side of the pinned `convex-rs-0.10.4-unversioned-sync'
		realtime profile (see docs/protocol-profiles.md in the repository
		root): one WebSocket connection to `/api/sync' carrying `Connect'
		and `ModifyQuerySet' client messages and `Transition' server
		messages. Mutations and actions are deliberately never sent over
		this connection; CONVEX_CLIENT always runs those over HTTP, the
		same choice this project's other Live-capable clients already
		document.

		This class owns the socket exclusively: the adapter's single I/O
		owner is expected to call `poll' only after learning (through
		CONVEX_POLL, watching `descriptor' alongside its control stream)
		that a message may be waiting, and to call `ensure_connected'
		whenever it notices `is_connected' has gone False. No other thread
		or subscription touches the connection directly, which is what
		makes the reconnect and unsubscribe bookkeeping below safe without
		locks.
	]"

class
	CONVEX_SYNC

create
	make

feature {NONE} -- Initialization

	make (a_host: STRING; a_port: INTEGER; a_use_tls: BOOLEAN)
			-- Configure (without yet connecting to) the sync endpoint at
			-- `a_host':`a_port'. Call `ensure_connected' to open it.
		require
			a_host_attached: a_host /= Void
			a_port_valid: a_port > 0 and a_port <= 65535
		do
			host := a_host
			port := a_port
			use_tls := a_use_tls
			session_id := fresh_session_id
			connection_count := 0
			next_query_id := 1
			create subscription_to_query.make (8)
			create query_to_subscription.make (8)
			create query_path.make (8)
			create query_args.make (8)
			create last_signature.make (8)
			create pending_events.make (4)
			last_close_reason := "InitialConnect"
		end

feature -- Access

	is_connected: BOOLEAN
			-- Is the WebSocket currently open?
		do
			Result := attached connection as l_connection and then l_connection.is_open
		end

	last_error: detachable STRING

	descriptor: INTEGER
			-- The active connection's file descriptor, for the adapter's
			-- outer `select'. Only meaningful when `is_connected'.
		require
			is_connected: is_connected
		do
			check attached connection as l_connection then
				Result := l_connection.descriptor
			end
		end

	has_pending_bytes: BOOLEAN
			-- Does the transport already hold bytes a `select' loop must
			-- drain before waiting on `descriptor' again?
		do
			Result := attached connection as l_connection and then l_connection.has_pending_bytes
		end

	is_subscribed (a_subscription_id: STRING): BOOLEAN
			-- Is `a_subscription_id' currently an active subscription?
		require
			a_subscription_id_attached: a_subscription_id /= Void
		do
			Result := subscription_to_query.has (a_subscription_id)
		end

	pending_events: ARRAYED_LIST [CONVEX_SYNC_EVENT]
			-- Events produced by `poll' since the caller last drained this
			-- list. The caller empties it after reading.

feature -- Connection lifecycle

	ensure_connected
			-- Open the connection if it is not already open, replaying
			-- every currently active subscription as one `ModifyQuerySet'
			-- so the server rebuilds exactly the query set the caller
			-- believes is active. Idempotent when already connected.
		local
			new_connection: CONVEX_WEBSOCKET
		do
			if not is_connected then
				connection_count := connection_count + 1
				create new_connection.make (host, port, sync_path, use_tls)
				if not new_connection.is_open then
					last_error := new_connection.last_error
				else
					connection := new_connection
					query_set_version := 0
					if send_connect_message then
						rebuild_query_set
					end
				end
			end
		end

	force_disconnect
			-- Test-only fault injection for the adapter's `debugDisconnect'
			-- command: sever the transport immediately, without a clean
			-- WebSocket close, so the next `ensure_connected' call performs
			-- a real reconnect. Safe to call whether or not a connection is
			-- currently open.
		do
			if attached connection as l_connection then
				l_connection.close ("debugDisconnect")
			end
			connection := Void
			last_close_reason := "debugDisconnect"
		end

feature -- Subscriptions

	add_subscription (a_subscription_id: STRING; a_path: STRING; a_args: CONVEX_JSON_VALUE): BOOLEAN
			-- Start a reactive query for `a_path' with `a_args', routing
			-- its future updates to `a_subscription_id'. False (with
			-- `last_error' set) if the request could not be sent; the
			-- caller should still treat the subscription as pending and
			-- rely on the next `ensure_connected' to establish it.
		require
			a_subscription_id_attached: a_subscription_id /= Void
			not_already_subscribed: not is_subscribed (a_subscription_id)
			a_path_attached: a_path /= Void
			a_args_attached: a_args /= Void
		local
			query_id: INTEGER
			args_json: STRING
		do
			query_id := next_query_id
			next_query_id := next_query_id + 1
			args_json := single_element_array (a_args)
			subscription_to_query.put (query_id, a_subscription_id)
			query_to_subscription.put (a_subscription_id, query_id)
			query_path.put (a_path, query_id)
			query_args.put (args_json, query_id)
			if is_connected then
				Result := send_modify_query_set (<<add_modification (query_id, a_path, args_json)>>)
			else
				Result := True
			end
		end

	remove_subscription (a_subscription_id: STRING): BOOLEAN
			-- Stop the reactive query behind `a_subscription_id'.
		require
			a_subscription_id_attached: a_subscription_id /= Void
			already_subscribed: is_subscribed (a_subscription_id)
		local
			query_id: INTEGER
		do
			query_id := subscription_to_query.definite_item (a_subscription_id)
			if is_connected then
				Result := send_modify_query_set (<<remove_modification (query_id)>>)
			else
				Result := True
			end
			subscription_to_query.remove (a_subscription_id)
			query_to_subscription.remove (query_id)
			query_path.remove (query_id)
			query_args.remove (query_id)
			if last_signature.has (query_id) then
				last_signature.remove (query_id)
			end
		end

feature -- Polling

	poll (a_timeout_ms: INTEGER)
			-- Receive and process at most one sync message, appending any
			-- resulting subscription updates to `pending_events'. A closed
			-- or failed connection here is not reported as an error: it
			-- simply leaves `is_connected' False for the caller's next
			-- `ensure_connected' to repair.
		require
			is_connected: is_connected
			a_timeout_non_negative: a_timeout_ms >= 0
		local
			text: detachable STRING
			parser: CONVEX_JSON_PARSER
		do
			check attached connection as l_connection then
				text := l_connection.try_receive_message (a_timeout_ms)
				if text /= Void then
					create parser.make
					parser.parse (text)
					if parser.successful and then attached parser.last_value as l_message then
						handle_server_message (l_message)
					end
				end
			end
		end

feature {NONE} -- Message construction

	sync_path: STRING = "/api/sync"

	fresh_session_id: STRING
			-- A syntactically valid (hyphenated, lowercase hex) UUID-like
			-- string. The server only requires this to parse as a UUID; it
			-- does not need cryptographic unpredictability (see
			-- convex_random_seed's header comment in convex_native.h).
		local
			hex: STRING
			i, seed: INTEGER
			groups: ARRAY [INTEGER]
		do
			seed := c_random_seed
			create hex.make (32)
			from i := 1 until i > 32
			loop
				seed := (seed * 1103515245 + 12345 + i).abs \\ 2147483647
				hex.append_character (hex_digit (seed \\ 16))
				i := i + 1
			end
			groups := <<8, 4, 4, 4, 12>>
			create Result.make (36)
			i := 1
			across groups as group
			loop
				if Result.count > 0 then
					Result.append_character ('-')
				end
				Result.append (hex.substring (i, i + group.item - 1))
				i := i + group.item
			end
		end

	hex_digit (a_value: INTEGER): CHARACTER
		require
			in_range: a_value >= 0 and a_value <= 15
		do
			if a_value < 10 then
				Result := (('0').code + a_value).to_character_8
			else
				Result := (('a').code + a_value - 10).to_character_8
			end
		end

	single_element_array (a_args: CONVEX_JSON_VALUE): STRING
			-- The sync protocol's `SerializedArgs' is a JSON array holding
			-- exactly the one args object Convex functions take.
		local
			wrapper: CONVEX_JSON_VALUE
		do
			create wrapper.make_array
			wrapper.extend (a_args)
			Result := wrapper.to_json
		end

	add_modification (a_query_id: INTEGER; a_path: STRING; a_args_json: STRING): STRING
		do
			Result := "{%"type%":%"Add%",%"queryId%":" + a_query_id.out
				+ ",%"udfPath%":%"" + a_path + "%",%"args%":" + a_args_json + "}"
		end

	remove_modification (a_query_id: INTEGER): STRING
		do
			Result := "{%"type%":%"Remove%",%"queryId%":" + a_query_id.out + "}"
		end

	send_connect_message: BOOLEAN
		local
			message: STRING
		do
			message := "{%"type%":%"Connect%",%"sessionId%":%"" + session_id
				+ "%",%"connectionCount%":" + connection_count.out
				+ ",%"lastCloseReason%":%"" + json_escaped (last_close_reason) + "%"}"
			check attached connection as l_connection then
				Result := l_connection.send_text (message)
				if not Result then
					last_error := l_connection.last_error
				end
			end
		end

	send_modify_query_set (a_modifications: ARRAY [STRING]): BOOLEAN
		local
			message, body: STRING
			i: INTEGER
			base_version: INTEGER
		do
			base_version := query_set_version
			query_set_version := query_set_version + 1
			create body.make (64)
			from i := 1 until i > a_modifications.count
			loop
				if i > 1 then
					body.append_character (',')
				end
				body.append (a_modifications.item (i))
				i := i + 1
			end
			message := "{%"type%":%"ModifyQuerySet%",%"baseVersion%":" + base_version.out
				+ ",%"newVersion%":" + query_set_version.out
				+ ",%"modifications%":[" + body + "]}"
			check attached connection as l_connection then
				Result := l_connection.send_text (message)
				if not Result then
					last_error := l_connection.last_error
				end
			end
		end

	rebuild_query_set
			-- After a fresh connection, resend every still-active
			-- subscription as one `ModifyQuerySet' so the server's query
			-- set matches what the caller believes is active. The server
			-- has no memory of a previous connection's query set (each
			-- connection starts that version counter at zero), so this is
			-- not an optimisation: without it, a reconnected client would
			-- simply stop receiving updates for its existing subscriptions.
		local
			modifications: ARRAYED_LIST [STRING]
			ignored_result: BOOLEAN
		do
			create modifications.make (query_path.count)
			across query_path.current_keys as key_cursor
			loop
				modifications.extend (add_modification (key_cursor.item, query_path.definite_item (key_cursor.item), query_args.definite_item (key_cursor.item)))
			end
			if not modifications.is_empty then
				ignored_result := send_modify_query_set (modifications.to_array)
			end
		end

feature {NONE} -- Server message handling

	handle_server_message (a_message: CONVEX_JSON_VALUE)
		local
			message_type: STRING
		do
			if a_message.is_object and then a_message.has_field ("type")
				and then a_message.field ("type").is_string
			then
				message_type := a_message.field ("type").string_item
				if message_type.is_equal ("Transition") then
					handle_transition (a_message)
				elseif message_type.is_equal ("FatalError") then
					last_error := "server FatalError"
					if attached connection as l_connection then
						l_connection.close ("fatal")
					end
					connection := Void
				end
				-- Ping, AuthError, MutationResponse, ActionResponse, and
				-- TransitionChunk need no handling: this client never
				-- authenticates or mutates over the sync socket, and its
				-- test payloads stay far below the size that would trigger
				-- chunking (see docs/protocol-profiles.md).
			end
		end

	handle_transition (a_message: CONVEX_JSON_VALUE)
		local
			modifications: CONVEX_JSON_VALUE
			i: INTEGER
			modification: CONVEX_JSON_VALUE
			kind: STRING
			query_id: INTEGER
		do
			if a_message.has_field ("modifications") and then a_message.field ("modifications").is_array then
				modifications := a_message.field ("modifications")
				from i := 1 until i > modifications.array_item.count
				loop
					modification := modifications.array_item.i_th (i)
					if modification.is_object and then modification.has_field ("type")
						and then modification.field ("type").is_string
						and then modification.has_field ("queryId")
						and then modification.field ("queryId").is_number
					then
						kind := modification.field ("type").string_item
						query_id := modification.field ("queryId").integer_item.to_integer_32
						if query_to_subscription.has (query_id) then
							dispatch_modification (kind, query_id, modification)
						end
					end
					i := i + 1
				end
			end
		end

	dispatch_modification (a_kind: STRING; a_query_id: INTEGER; a_modification: CONVEX_JSON_VALUE)
			-- Reconnecting resends every active query, and the server's
			-- reply is an ordinary `Transition' the same as any other
			-- update, even when nothing actually changed. Deliver an event
			-- only when the decoded state differs from what this
			-- subscription last reported, so a same-value rehydration
			-- after `debugDisconnect' never masquerades as (or delays) a
			-- real change: the caller must still see exactly initial
			-- value, then the next genuine update, with nothing stale
			-- in between.
		local
			subscription_id: STRING
			data: detachable CONVEX_JSON_VALUE
			signature: STRING
		do
			subscription_id := query_to_subscription.definite_item (a_query_id)
			if a_kind.is_equal ("QueryUpdated") and then a_modification.has_field ("value") then
				signature := "V:" + a_modification.field ("value").to_json
				if not signature_unchanged (a_query_id, signature) then
					pending_events.extend (create {CONVEX_SYNC_EVENT}.make_value (subscription_id, a_modification.field ("value")))
				end
			elseif a_kind.is_equal ("QueryFailed") and then a_modification.has_field ("errorMessage")
				and then a_modification.field ("errorMessage").is_string
			then
				if a_modification.has_field ("errorData") then
					data := a_modification.field ("errorData")
				end
				signature := "E:" + a_modification.field ("errorMessage").string_item
				if not signature_unchanged (a_query_id, signature) then
					pending_events.extend (create {CONVEX_SYNC_EVENT}.make_error (
						subscription_id, a_modification.field ("errorMessage").string_item, data))
				end
			end
			-- QueryRemoved needs no event: the adapter already stopped
			-- expecting updates once it asked to unsubscribe.
		end

	signature_unchanged (a_query_id: INTEGER; a_signature: STRING): BOOLEAN
			-- Has `a_query_id' already reported exactly `a_signature'?
			-- Records `a_signature' as the new last-known state either way.
		do
			Result := last_signature.has (a_query_id) and then last_signature.definite_item (a_query_id).is_equal (a_signature)
			last_signature.force (a_signature, a_query_id)
		end

	json_escaped (a_text: STRING): STRING
			-- Escape `a_text' for embedding inside a hand-built JSON string
			-- literal (used only for the small, non-user-controlled
			-- `lastCloseReason' values this class itself produces).
		local
			i: INTEGER
		do
			create Result.make (a_text.count)
			from i := 1 until i > a_text.count
			loop
				if a_text.item (i) = '"' or a_text.item (i) = '\' then
					Result.append_character ('\')
				end
				Result.append_character (a_text.item (i))
				i := i + 1
			end
		end

feature {NONE} -- Externals

	c_random_seed: INTEGER
		external
			"C signature (): unsigned int use %"convex_native.h%""
		alias
			"convex_random_seed"
		end

feature {NONE} -- Implementation

	host: STRING
	port: INTEGER
	use_tls: BOOLEAN
	connection: detachable CONVEX_WEBSOCKET
	session_id: STRING
	connection_count: INTEGER
	query_set_version: INTEGER
	next_query_id: INTEGER
	last_close_reason: STRING

	subscription_to_query: HASH_TABLE [INTEGER, STRING]
	query_to_subscription: HASH_TABLE [STRING, INTEGER]
	query_path: HASH_TABLE [STRING, INTEGER]
	query_args: HASH_TABLE [STRING, INTEGER]
	last_signature: HASH_TABLE [STRING, INTEGER]

end
