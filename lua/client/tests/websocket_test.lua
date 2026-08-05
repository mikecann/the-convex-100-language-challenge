package.path = "./client/?.lua;" .. package.path
local socket = require("socket")
local Live = require("live")

local HOST = "127.0.0.1"
local PORT = 19091

local function frame(fin, opcode, payload)
	payload = payload or ""
	local first = opcode + (fin and 128 or 0)
	if #payload < 126 then
		return string.char(first, #payload) .. payload
	end
	assert(#payload <= 65535, "fixture only emits 16-bit frames")
	return string.char(first, 126, math.floor(#payload / 256), #payload % 256) .. payload
end

local function websocket_handshake(peer)
	local key
	while true do
		local line = assert(peer:receive("*l"))
		if line == "" then
			break
		end
		local name, value = line:match("^([^:]+):%s*(.*)$")
		if name and name:lower() == "sec-websocket-key" then
			key = value
		end
	end
	assert(key, "client handshake omitted Sec-WebSocket-Key")
	local basexx = require("basexx")
	local digest = require("openssl.digest")
	local accept = basexx.to_base64(digest.new("sha1"):final(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	assert(peer:send("HTTP/1.1 101 Switching Protocols\r\n"))
	assert(peer:send("Upgrade: websocket\r\nConnection: Upgrade\r\n"))
	assert(peer:send("Sec-WebSocket-Accept: " .. accept .. "\r\n\r\n"))
end

local function read_client_frame(peer)
	local header = assert(peer:receive(2))
	local first, second = header:byte(1, 2)
	local length = second % 128
	assert(second >= 128, "client fixture frame must be masked")
	if length == 126 then
		local extended = assert(peer:receive(2))
		local high, low = extended:byte(1, 2)
		length = high * 256 + low
	elseif length == 127 then
		error("fixture does not accept 64-bit client frames")
	end
	local mask = { assert(peer:receive(4)):byte(1, 4) }
	local payload = assert(peer:receive(length))
	local decoded = {}
	local bit = require("http.bit")
	for index = 1, #payload do
		decoded[index] = string.char(bit.bxor(payload:byte(index), mask[(index - 1) % 4 + 1]))
	end
	return first % 16, table.concat(decoded)
end

local function begin_live_subscription(peer)
	local json = require("cjson.safe")
	local _, connect_payload = read_client_frame(peer)
	assert(assert(json.decode(connect_payload)).type == "Connect", "Live client omitted Connect")
	local _, modify_payload = read_client_frame(peer)
	local modify = assert(json.decode(modify_payload))
	assert(modify.type == "ModifyQuerySet", "Live client omitted ModifyQuerySet")
	local add = modify.modifications[1]
	assert(add and add.type == "Add", "Live client omitted Add")
	local transition = assert(json.encode({
		type = "Transition",
		startVersion = { querySet = 0, identity = 0, ts = "AAAAAAAAAAA=" },
		endVersion = { querySet = modify.newVersion, identity = 0, ts = "AQAAAAAAAAA=" },
		modifications = {
			{ type = "QueryUpdated", queryId = add.queryId, value = { count = 0 }, logLines = {} },
		},
	}))
	assert(peer:send(frame(true, 1, transition)))
end

local function run_server()
	local listener = assert(socket.bind(HOST, PORT))
	for scenario = 1, 8 do
		local peer = assert(listener:accept())
		peer:settimeout(2)
		websocket_handshake(peer)
		if scenario == 1 then
			-- Split a UTF-8 codepoint between text fragments and interleave a
			-- control frame. A correct parser validates only the reassembled text.
			local snowman = "\226\152\131"
			assert(peer:send(frame(false, 1, '{"note":"snowman ' .. snowman:sub(1, 1))))
			assert(peer:send(frame(true, 9, "fixture")))
			assert(peer:send(frame(true, 0, snowman:sub(2) .. '"}')))
			local opcode, pong = read_client_frame(peer)
			assert(opcode == 10 and pong == "fixture", "client did not answer fragmented-message ping")
		elseif scenario == 2 then
			-- Time out after consuming a partial extended-length header, then
			-- finish the same frame. Restarting at a false boundary corrupts it.
			assert(peer:send(string.char(129, 126, 0)))
			socket.sleep(0.2)
			assert(peer:send(string.char(126) .. string.rep("p", 126)))
		elseif scenario == 3 then
			-- Stay completely idle while the client initiates close.
			socket.sleep(1)
		elseif scenario == 4 then
			-- Stall after the extended-length marker and one length byte. This
			-- forces a timeout after the parser has already consumed frame bytes.
			assert(peer:send(string.char(129, 126, 0)))
			socket.sleep(1)
		elseif scenario == 5 then
			-- Keep the peer readable while the client closes. A bounded close
			-- must not wait forever for a quiet point in the incoming stream.
			peer:settimeout(0)
			for count = 1, 1000 do
				local ok = peer:send(frame(true, 1, tostring(count)))
				if not ok then
					break
				end
				socket.sleep(0.001)
			end
		else
			begin_live_subscription(peer)
			if scenario == 6 then
				-- Leave the manager's real WebSocket idle during unsubscribe.
				socket.sleep(1)
			elseif scenario == 7 then
				-- Make the owner time out halfway through an extended header while
				-- the controller asks it to remove the active query.
				assert(peer:send(string.char(129, 126, 0)))
				socket.sleep(1)
			else
				-- Keep valid server traffic arriving throughout unsubscribe.
				peer:settimeout(0)
				for _ = 1, 1000 do
					local ok = peer:send(frame(true, 1, '{"type":"Ping"}'))
					if not ok then
						break
					end
					socket.sleep(0.001)
				end
			end
		end
		peer:close()
	end
	listener:close()
end

local function connected_websocket()
	local websocket = require("http.websocket").new_from_uri(string.format("ws://%s:%d/fixture", HOST, PORT))
	assert(websocket:connect(2))
	return websocket
end

local function run_client()
	local cqueues = require("cqueues")
	local cq = cqueues.new()
	cq:wrap(function()
		local fragmented = connected_websocket()
		local payload, kind = fragmented:receive(1)
		assert(kind == "text" and payload == '{"note":"snowman \226\152\131"}', "fragmented UTF-8 changed")
		fragmented:close(1000, "fixture complete", 0.25)

		local partial = connected_websocket()
		local before_timeout = cqueues.monotime()
		local payload_after_partial, _, receive_errno = partial:receive(0.1)
		assert(payload_after_partial == nil and receive_errno, "partial frame did not time out")
		assert(cqueues.monotime() - before_timeout < 0.5, "partial-frame receive ignored its deadline")
		local resumed_payload, resumed_kind = partial:receive(1)
		assert(resumed_kind == "text" and resumed_payload == string.rep("p", 126), "partial frame lost parser state")
		partial:close(1000, "parser fixture", 0.25)

		local idle = connected_websocket()
		local before_idle_close = cqueues.monotime()
		assert(idle:close(1000, "idle fixture", 0.25))
		assert(cqueues.monotime() - before_idle_close < 0.75, "idle-peer close exceeded its deadline")

		partial = connected_websocket()
		payload_after_partial = partial:receive(0.1)
		assert(payload_after_partial == nil, "stalled partial frame unexpectedly completed")
		local before_partial_close = cqueues.monotime()
		assert(partial:close(1000, "partial fixture", 0.25))
		assert(cqueues.monotime() - before_partial_close < 0.75, "partial-frame close exceeded its deadline")

		local continuous = connected_websocket()
		local before_continuous_close = cqueues.monotime()
		assert(continuous:close(1000, "continuous fixture", 0.25))
		assert(cqueues.monotime() - before_continuous_close < 0.75, "continuous-peer close exceeded its deadline")

		for _, peer_state in ipairs({ "idle", "partial", "continuous" }) do
			local manager = Live.Manager.new(string.format("http://%s:%d", HOST, PORT), "lua-test", { cq = cq })
			local subscription = assert(manager:subscribe("demo:state", { room = "unsubscribe-" .. peer_state }))
			assert(assert(subscription:next_update(2)).value.count == 0)
			cqueues.sleep(0.15) -- let the owner enter the hostile receive state
			local before_unsubscribe = cqueues.monotime()
			assert(subscription:close())
			assert(cqueues.monotime() - before_unsubscribe < 0.75, peer_state .. " unsubscribe exceeded its deadline")
			assert(manager:close())
		end
	end)
	assert(cq:loop())
end

if arg[1] == "server" then
	run_server()
elseif arg[1] == "client" then
	run_client()
else
	error("expected server or client mode")
end
