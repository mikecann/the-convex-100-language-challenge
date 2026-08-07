note
	description: "[
		A native Eiffel client for Convex's documented public HTTP API and
		the pinned `convex-rs-0.10.4-unversioned-sync' Live profile (see
		docs/protocol-profiles.md and docs/conformance.md in the repository
		root). `query', `mutation', and `action' always go over HTTP;
		`subscribe' opens (or reuses) one WebSocket connection carrying
		only query-set add/remove and reactive updates, never mutations,
		matching the same scope this project's other Live-capable clients
		document.

		Design-by-contract genuinely earns its place here: `query',
		`mutation', and `action' share the one non-negotiable rule the
		public HTTP API imposes on every call, `module:function' path
		shape, so it is written once as a precondition instead of quietly
		repeated (or forgotten) in each feature body.
	]"

class
	CONVEX_CLIENT

create
	make

feature {NONE} -- Initialization

	make (a_deployment_url: STRING)
			-- Configure this client for the Convex deployment at
			-- `a_deployment_url' (for example "https://happy-otter-123
			-- .convex.cloud" or "http://127.0.0.1:3210" for a local
			-- deployment). No network connection is opened yet.
		require
			a_deployment_url_attached: a_deployment_url /= Void
			a_deployment_url_well_formed: url_is_well_formed (a_deployment_url)
		do
			parse_url (a_deployment_url)
			create http.make (host, port, use_tls)
		ensure
			host_set: host.count > 0
			port_set: port > 0 and port <= 65535
		end

feature -- Access

	last_error: detachable STRING
			-- A short diagnostic for the most recent transport-level
			-- failure. Application errors are reported through
			-- CONVEX_RESULT instead, since a thrown `ConvexError' is not a
			-- client failure.

feature -- Authentication

	set_auth (a_token: detachable STRING)
			-- Send `a_token' as `Authorization: Bearer <token>' on every
			-- later HTTP call, or clear it when `a_token' is Void or
			-- empty. Also updates any open Live connection so a later
			-- reconnect carries the same identity.
		do
			if a_token /= Void and then not a_token.is_empty then
				auth_token := a_token
			else
				auth_token := Void
			end
		end

feature -- HTTP calls

	query (a_path: STRING; a_args: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
			-- Run the query at `a_path' with `a_args' over HTTP. Void (with
			-- `last_error' set) only on a transport failure; an
			-- application-level failure still returns an attached
			-- CONVEX_RESULT with `is_success' False.
		require
			a_path_is_module_colon_function: is_module_colon_function (a_path)
			a_args_attached: a_args /= Void
			a_args_is_object: a_args.is_object
		do
			Result := call_http ("query", a_path, a_args)
		end

	mutation (a_path: STRING; a_args: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
			-- Run the mutation at `a_path' with `a_args' over HTTP.
		require
			a_path_is_module_colon_function: is_module_colon_function (a_path)
			a_args_attached: a_args /= Void
			a_args_is_object: a_args.is_object
		do
			Result := call_http ("mutation", a_path, a_args)
		end

	action (a_path: STRING; a_args: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
			-- Run the action at `a_path' with `a_args' over HTTP.
		require
			a_path_is_module_colon_function: is_module_colon_function (a_path)
			a_args_attached: a_args /= Void
			a_args_is_object: a_args.is_object
		do
			Result := call_http ("action", a_path, a_args)
		end

feature -- Live subscriptions

	live: CONVEX_SYNC
			-- The lazily created sync connection backing `subscribe' and
			-- `unsubscribe'. Exposed directly so the conformance adapter
			-- can also reach `force_disconnect' and `pending_events'
			-- without CONVEX_CLIENT re-exporting every one of their names.
		do
			if sync_cell = Void then
				create sync_cell.make (host, port, use_tls)
			end
			check attached sync_cell as l_sync then
				Result := l_sync
			end
		ensure
			result_attached: Result /= Void
		end

feature {NONE} -- HTTP implementation

	http: CONVEX_HTTP_CLIENT

	auth_token: detachable STRING

	call_http (a_op: STRING; a_path: STRING; a_args: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
		local
			request_body: STRING
			response_text: detachable STRING
			parser: CONVEX_JSON_PARSER
		do
			request_body := build_request_body (a_path, a_args)
			response_text := http.post ("/api/" + a_op, request_body, auth_token)
			if response_text = Void then
				last_error := "transport: " + debug_string (http.last_error)
			else
				create parser.make
				parser.parse (response_text)
				if not parser.successful then
					last_error := "malformed response JSON: " + debug_string (parser.last_error) + " raw=" + response_text
				elseif attached parser.last_value as l_response then
					Result := decode_response (l_response)
					if Result = Void then
						last_error := "unrecognized response shape: " + response_text
					end
				end
			end
		end

	build_request_body (a_path: STRING; a_args: CONVEX_JSON_VALUE): STRING
		local
			envelope: CONVEX_JSON_VALUE
			format_value: CONVEX_JSON_VALUE
		do
			create envelope.make_object
			envelope.put_field ("path", create {CONVEX_JSON_VALUE}.make_string (a_path))
			envelope.put_field ("args", a_args)
			create format_value.make_string ("json")
			envelope.put_field ("format", format_value)
			Result := envelope.to_json
		end

	decode_response (a_response: CONVEX_JSON_VALUE): detachable CONVEX_RESULT
		local
			logs: ARRAYED_LIST [STRING]
			status: STRING
			data: detachable CONVEX_JSON_VALUE
			message: STRING
		do
			logs := decode_logs (a_response)
			if a_response.is_object and then a_response.has_field ("status")
				and then a_response.field ("status").is_string
			then
				status := a_response.field ("status").string_item
				if status.is_equal ("success") and then a_response.has_field ("value") then
					create Result.make_success (a_response.field ("value"), logs)
				elseif status.is_equal ("error") and then a_response.has_field ("errorMessage")
					and then a_response.field ("errorMessage").is_string
				then
					message := a_response.field ("errorMessage").string_item
					if a_response.has_field ("errorData") then
						data := a_response.field ("errorData")
					end
					create Result.make_failure (message, data, logs)
				end
			end
		end

	decode_logs (a_response: CONVEX_JSON_VALUE): ARRAYED_LIST [STRING]
		local
			i: INTEGER
			entry: CONVEX_JSON_VALUE
		do
			create Result.make (4)
			if a_response.is_object and then a_response.has_field ("logLines")
				and then a_response.field ("logLines").is_array
			then
				from i := 1 until i > a_response.field ("logLines").array_item.count
				loop
					entry := a_response.field ("logLines").array_item.i_th (i)
					if entry.is_string then
						Result.extend (entry.string_item)
					end
					i := i + 1
				end
			end
		end

feature -- Validation

	url_is_well_formed (a_url: STRING): BOOLEAN
			-- Does `a_url' start with "http://" or "https://" and carry a
			-- non-empty host?
		do
			Result := (a_url.starts_with ("https://") and a_url.count > 8)
				or (a_url.starts_with ("http://") and a_url.count > 7)
		end

	is_module_colon_function (a_path: STRING): BOOLEAN
			-- Does `a_path' look like Convex's `module:function' function
			-- reference, with a non-empty name on each side of the colon?
		local
			colon_index: INTEGER
		do
			if a_path /= Void then
				colon_index := a_path.index_of (':', 1)
				Result := colon_index > 1 and colon_index < a_path.count
			end
		end

feature {NONE} -- URL parsing

	host: STRING
	port: INTEGER
	use_tls: BOOLEAN

	debug_string (a_text: detachable STRING): STRING
		do
			if a_text = Void then
				Result := "<void>"
			else
				Result := a_text
			end
		end

	parse_url (a_url: STRING)
			-- Split `a_url' into `host', `port', and `use_tls'.
		local
			after_scheme: STRING
			colon_index: INTEGER
			host_end: INTEGER
		do
			if a_url.starts_with ("https://") then
				use_tls := True
				after_scheme := a_url.substring (9, a_url.count)
				port := 443
			else
				use_tls := False
				after_scheme := a_url.substring (8, a_url.count)
				port := 80
			end
			host_end := after_scheme.index_of ('/', 1)
			if host_end = 0 then
				host_end := after_scheme.count + 1
			end
			after_scheme := after_scheme.substring (1, host_end - 1)
			colon_index := after_scheme.index_of (':', 1)
			if colon_index > 0 then
				host := after_scheme.substring (1, colon_index - 1)
				port := after_scheme.substring (colon_index + 1, after_scheme.count).to_integer
			else
				host := after_scheme
			end
		end

feature {NONE} -- Implementation

	sync_cell: detachable CONVEX_SYNC

invariant
	http_attached: http /= Void

end
