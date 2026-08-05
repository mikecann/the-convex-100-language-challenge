#!/usr/bin/env bash
# RFC6455 and the pinned Convex /api/sync profile, implemented in Bash. The
# transport helpers are only byte/TLS tools; query-set and state handling live here.
set -euo pipefail

LIVE_FD='' LIVE_IN='' LIVE_PID='' LIVE_QUERY_SET=0 LIVE_CONNECTIONS=0 LIVE_READ=''
LIVE_LAST_CLOSE_REASON=InitialConnect LIVE_RECONNECT_PENDING=0 LIVE_RECONNECT_AT_MS=0
LIVE_RECONNECT_BASE_MS=${BASH_LIVE_RECONNECT_BASE_MS:-100}
LIVE_RECONNECT_MAX_MS=${BASH_LIVE_RECONNECT_MAX_MS:-15000}
LIVE_RECONNECT_DELAY_MS=$LIVE_RECONNECT_BASE_MS
LIVE_HANDSHAKE_TIMEOUT_MS=${BASH_LIVE_HANDSHAKE_TIMEOUT_MS:-5000}
LIVE_HANDSHAKE_MAX_HEADERS=64
LIVE_HANDSHAKE_MAX_BYTES=16384
# These arrays and shifted values are public state for the adapter process that
# sources this library, so they are intentionally assigned across file boundaries.
# shellcheck disable=SC2034
declare -Ag LIVE_PATH LIVE_ARGS LIVE_SUB LIVE_QUEUE LIVE_LAST LIVE_REHYDRATE

_byte() { od -An -tu1 | tr -d ' \n'; }
_write_byte() {
	# shellcheck disable=SC2059 # The generated octal escape is the byte format.
	printf "\\$(printf '%03o' "$1")" >&"$LIVE_FD"
}
_ws_url() {
	local base=${CONVEX_URL%/}
	printf '%s/api/sync' "${base/http:/ws:}" | sed 's#^https:#wss:#'
}
_live_now_ms() {
	local seconds=${EPOCHREALTIME%.*} micros=${EPOCHREALTIME#*.}
	printf '%s\n' "$((10#$seconds * 1000 + 10#${micros:0:3}))"
}

_live_read_handshake_line() {
	local deadline_ms=$1 max_bytes=$2 now_ms remaining_ms timeout_seconds line status=0
	now_ms=$(_live_now_ms)
	remaining_ms=$((deadline_ms - now_ms))
	((remaining_ms > 0 && max_bytes > 0)) || return 1
	printf -v timeout_seconds '%d.%03d' "$((remaining_ms / 1000))" "$((remaining_ms % 1000))"
	IFS= read -r -t "$timeout_seconds" -n "$((max_bytes + 1))" line || status=$?
	((status == 0)) || return 1
	((${#line} <= max_bytes)) || return 1
	LIVE_HANDSHAKE_LINE=$line
}

live_connect() {
	local url authority_path hostport request_target host port key line session_hex session_id expected_accept status_line
	local tls_read tls_write tls_coproc_read tls_coproc_write
	local upgrade_header='' connection_header='' accept_header='' handshake_complete=0 deadline_ms header_count=0 header_bytes=0 remaining_bytes
	local LC_ALL=C
	url=$(_ws_url)
	authority_path=${url#*://}
	hostport=${authority_path%%/*}
	request_target=/${authority_path#*/}
	host=${hostport%%:*}
	port=${hostport#*:}
	[[ $port = "$hostport" ]] && { [[ $url = wss:* ]] && port=443 || port=80; }
	if [[ $url = wss:* ]]; then
		coproc LIVE_TLS (
			openssl s_client -quiet -connect "$host:$port" -servername "$host" \
				-verify_return_error -verify_hostname "$host" \
				-CAfile "${CONVEX_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}" 2>/dev/null
		)
		# Bash marks the descriptors created for a coprocess as close-on-exec.
		# Duplicate them onto ordinary descriptors because frame reads use dd under
		# a deadline, and that child process must inherit the TLS input stream.
		tls_coproc_write=${LIVE_TLS[1]}
		tls_coproc_read=${LIVE_TLS[0]}
		LIVE_PID=$LIVE_TLS_PID
		exec {tls_write}>&"$tls_coproc_write"
		exec {tls_read}<&"$tls_coproc_read"
		eval "exec ${tls_coproc_write}>&-"
		eval "exec ${tls_coproc_read}<&-"
		LIVE_FD=$tls_write
		LIVE_IN=$tls_read
	else
		if ! exec {LIVE_FD}<>"/dev/tcp/$host/$port"; then
			live_disconnect
			return 1
		fi
		LIVE_IN=$LIVE_FD
	fi
	key=$(openssl rand -base64 16)
	expected_accept=$(printf '%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11' "$key" | openssl dgst -sha1 -binary | openssl base64 -A)
	printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nConvex-Client: %s\r\n\r\n' "$request_target" "$hostport" "$key" "$CONVEX_CLIENT_VERSION" >&"$LIVE_FD"
	deadline_ms=$(($(_live_now_ms) + LIVE_HANDSHAKE_TIMEOUT_MS))
	_live_read_handshake_line "$deadline_ms" "$LIVE_HANDSHAKE_MAX_BYTES" <&"$LIVE_IN" || {
		live_disconnect
		return 1
	}
	status_line=$LIVE_HANDSHAKE_LINE
	header_bytes=$((${#status_line} + 1))
	status_line=${status_line%$'\r'}
	[[ $status_line = 'HTTP/1.1 101 Switching Protocols' ]] || {
		live_disconnect
		return 1
	}
	while :; do
		remaining_bytes=$((LIVE_HANDSHAKE_MAX_BYTES - header_bytes))
		_live_read_handshake_line "$deadline_ms" "$remaining_bytes" <&"$LIVE_IN" || {
			live_disconnect
			return 1
		}
		line=$LIVE_HANDSHAKE_LINE
		header_bytes=$((header_bytes + ${#line} + 1))
		((header_bytes <= LIVE_HANDSHAKE_MAX_BYTES)) || {
			live_disconnect
			return 1
		}
		line=${line%$'\r'}
		[[ -z $line ]] && {
			handshake_complete=1
			break
		}
		((header_count++)) || true
		((header_count <= LIVE_HANDSHAKE_MAX_HEADERS)) || {
			live_disconnect
			return 1
		}
		case ${line,,} in
		upgrade:*) upgrade_header=${line#*: } ;;
		connection:*) connection_header=${line#*: } ;;
		sec-websocket-accept:*) accept_header=${line#*: } ;;
		esac
	done
	((handshake_complete)) || {
		live_disconnect
		return 1
	}
	[[ ${upgrade_header,,} = websocket ]] || {
		live_disconnect
		return 1
	}
	connection_header=${connection_header,,}
	connection_header=${connection_header// /}
	[[ ,$connection_header, = *,upgrade,* ]] || {
		live_disconnect
		return 1
	}
	[[ $accept_header = "$expected_accept" ]] || {
		live_disconnect
		return 1
	}
	LIVE_QUERY_SET=0
	session_hex=$(openssl rand -hex 16)
	session_id=${session_hex:0:8}-${session_hex:8:4}-4${session_hex:13:3}-a${session_hex:17:3}-${session_hex:20:12}
	live_send "$(jq -cn --arg sid "$session_id" --argjson count "$LIVE_CONNECTIONS" --arg reason "$LIVE_LAST_CLOSE_REASON" '{type:"Connect",sessionId:$sid,connectionCount:$count,lastCloseReason:$reason,clientTs:0}')" || {
		live_disconnect
		return 1
	}
	live_resubscribe || {
		live_disconnect
		return 1
	}
	((LIVE_CONNECTIONS++)) || true
	LIVE_RECONNECT_PENDING=0
	LIVE_RECONNECT_DELAY_MS=$LIVE_RECONNECT_BASE_MS
}

live_send_frame() {
	local opcode=$1 text=$2 n i value mask=() bytes
	n=$(printf %s "$text" | wc -c | tr -d ' ')
	_write_byte $((128 | opcode))
	if ((n < 126)); then
		_write_byte $((128 + n))
	elif ((n < 65536)); then
		_write_byte 254
		_write_byte $((n >> 8))
		_write_byte $((n & 255))
	else
		_write_byte 255
		for i in 56 48 40 32 24 16 8 0; do _write_byte $(((n >> i) & 255)); done
	fi
	read -r -a mask < <(openssl rand 4 | od -An -tu1)
	for i in 0 1 2 3; do _write_byte "${mask[$i]}"; done
	bytes=$(printf %s "$text" | od -An -v -tu1)
	i=0
	for value in $bytes; do
		_write_byte $((value ^ mask[i % 4]))
		((i++)) || true
	done
}
live_send_frame_hex() {
	local opcode=$1 hex=$2 n i value mask=()
	[[ $hex =~ ^([[:xdigit:]]{2})*$ ]] || return 2
	n=$((${#hex} / 2))
	((n <= 125)) || return 2
	_write_byte $((128 | opcode))
	_write_byte $((128 + n))
	read -r -a mask < <(openssl rand 4 | od -An -tu1)
	for i in 0 1 2 3; do _write_byte "${mask[$i]}"; done
	for ((i = 0; i < n; i++)); do
		value=$((16#${hex:i*2:2}))
		_write_byte $((value ^ mask[i % 4]))
	done
}
live_send() { live_send_frame 1 "$1"; }

_read_byte_deadline() {
	local deadline=$1 value read_status=0
	value=$(timeout "$deadline" dd bs=1 count=1 status=none <&"$LIVE_IN" | od -An -tu1 | tr -d ' \n') || read_status=$?
	((read_status == 124 || read_status == 143)) && return 4
	# These descriptors are blocking. A successful zero-byte read is peer EOF,
	# while the timeout helper reports an idle connection as status 124/143.
	[[ -n $value ]] || return 3
	LIVE_BYTE=$value
}
_read_payload_deadline() {
	local count=$1 deadline=$2 read_status=0 value
	value=$(timeout "$deadline" dd bs=1 count="$count" status=none <&"$LIVE_IN") || read_status=$?
	((read_status == 124 || read_status == 143)) && return 4
	[[ $(printf %s "$value" | wc -c | tr -d ' ') -eq $count ]] || return 3
	LIVE_PAYLOAD=$value
}
_read_payload_hex_deadline() {
	local count=$1 deadline=$2 read_status=0 value
	value=$(timeout "$deadline" dd bs=1 count="$count" status=none <&"$LIVE_IN" | od -An -v -tx1 | tr -d ' \n') || read_status=$?
	((read_status == 124 || read_status == 143)) && return 4
	((read_status == 0)) || return 3
	((${#value} == count * 2)) || return 3
	LIVE_PAYLOAD_HEX=$value
}
_read_required_byte() {
	local status=0
	_read_byte_deadline "$1" || status=$?
	((status == 4)) && return 3
	return "$status"
}
_read_required_payload() {
	local status=0
	_read_payload_deadline "$1" "$2" || status=$?
	((status == 4)) && return 3
	return "$status"
}
live_read() {
	local timeout=${1:-0} first second opcode final length_code n=0 i part='' message='' message_bytes=0 expect_continuation=0
	while :; do
		if ((expect_continuation)); then _read_required_byte "$timeout" || return $?; else _read_byte_deadline "$timeout" || return $?; fi
		first=$LIVE_BYTE
		_read_required_byte "$timeout" || return $?
		second=$LIVE_BYTE
		((first & 112)) && {
			echo 'unsupported RFC6455 extension bits' >&2
			return 2
		}
		opcode=$((first & 15))
		final=$((first & 128))
		length_code=$((second & 127))
		n=$length_code
		((second & 128)) && {
			echo 'server sent masked RFC6455 frame' >&2
			return 2
		}
		if ((opcode >= 8)); then
			((final)) || {
				echo 'fragmented RFC6455 control frame' >&2
				return 2
			}
			((length_code <= 125)) || {
				echo 'RFC6455 control frame exceeds 125 bytes' >&2
				return 2
			}
			if ((n)); then _read_payload_hex_deadline "$n" "$timeout" || return $?; else LIVE_PAYLOAD_HEX=; fi
			case $opcode in
			8)
				live_send_frame_hex 8 "$LIVE_PAYLOAD_HEX" || true
				return 3
				;;
			9)
				live_send_frame_hex 10 "$LIVE_PAYLOAD_HEX"
				continue
				;;
			10) continue ;;
			*)
				echo "unsupported RFC6455 opcode $opcode" >&2
				return 2
				;;
			esac
		fi
		if ((n == 126)); then
			_read_required_byte "$timeout" || return $?
			n=$((LIVE_BYTE * 256))
			_read_required_byte "$timeout" || return $?
			n=$((n + LIVE_BYTE))
		elif ((n == 127)); then
			n=0
			for i in 1 2 3 4 5 6 7 8; do
				_read_required_byte "$timeout" || return $?
				n=$((n * 256 + LIVE_BYTE))
			done
		fi
		((n <= 2097152)) || {
			echo 'RFC6455 frame exceeds 2 MiB' >&2
			return 2
		}
		if ((opcode == 2)); then
			# Binary messages are outside the pinned Convex JSON profile, but consume
			# their arbitrary bytes without ever storing NUL in a Bash string.
			if ((n)); then _read_payload_hex_deadline "$n" "$timeout" || return $?; fi
			echo 'unsupported RFC6455 opcode 2' >&2
			return 2
		fi
		case $opcode in
		1)
			((expect_continuation == 0)) || {
				echo 'RFC6455 data message restarted before its continuation' >&2
				return 2
			}
			message_bytes=$n
			;;
		0)
			((expect_continuation == 1)) || {
				echo 'unexpected RFC6455 continuation frame' >&2
				return 2
			}
			message_bytes=$((message_bytes + n))
			;;
		esac
		((message_bytes <= 2097152)) || {
			echo 'RFC6455 message exceeds 2 MiB' >&2
			return 2
		}
		if ((n)); then
			_read_required_payload "$n" "$timeout" || return $?
			part=$LIVE_PAYLOAD
		else part=''; fi
		case $opcode in
		1)
			message=$part
			expect_continuation=1
			;;
		0) message+=$part ;;
		*)
			echo "unsupported RFC6455 opcode $opcode" >&2
			return 2
			;;
		esac
		((final)) && {
			LIVE_READ=$message
			printf '%s\n' "$message"
			return
		}
		timeout=10
	done
}

live_modify() {
	local modifications=$1 new=$((LIVE_QUERY_SET + 1))
	live_send "$(jq -cn --argjson base "$LIVE_QUERY_SET" --argjson new "$new" --argjson mods "$modifications" '{type:"ModifyQuerySet",baseVersion:$base,newVersion:$new,modifications:$mods}')" || return
	LIVE_QUERY_SET=$new
}
live_resubscribe() {
	local id mods='[]'
	for id in "${!LIVE_PATH[@]}"; do mods=$(jq -cn --argjson old "$mods" --arg id "$id" --arg path "${LIVE_PATH[$id]}" --argjson args "${LIVE_ARGS[$id]}" '$old + [{type:"Add",queryId:($id|tonumber),udfPath:$path,args:[$args]}]'); done
	if [[ $mods != '[]' ]]; then live_modify "$mods" || return; fi
	return 0
}
live_add() {
	local id=$1 sub=$2 path=$3 args=$4
	printf '%s\n' "$args" | jq -e 'type == "object"' >/dev/null || {
		echo 'Live query args must be a named JSON object' >&2
		return 2
	}
	# shellcheck disable=SC2034
	LIVE_SUB[$id]=$sub
	LIVE_PATH[$id]=$path
	LIVE_ARGS[$id]=$args
	if [[ -n ${LIVE_FD:-} ]]; then live_modify "$(jq -cn --argjson id "$id" --arg p "$path" --argjson a "$args" '[{type:"Add",queryId:$id,udfPath:$p,args:[$a]}]')" || return; fi
}
live_remove() {
	local id=$1
	unset "LIVE_SUB[$id]" "LIVE_PATH[$id]" "LIVE_ARGS[$id]" "LIVE_LAST[$id]" "LIVE_REHYDRATE[$id]" "LIVE_QUEUE[$id]"
	if [[ -n ${LIVE_FD:-} ]]; then live_modify "$(jq -cn --argjson id "$id" '[{type:"Remove",queryId:$id}]')" || return; fi
	((${#LIVE_PATH[@]})) || LIVE_RECONNECT_PENDING=0
	return 0
}
live_disconnect() {
	local output_fd=${LIVE_FD:-} input_fd=${LIVE_IN:-}
	if [[ -n $output_fd ]]; then eval "exec ${output_fd}>&-"; fi
	if [[ -n $input_fd && $input_fd != "$output_fd" ]]; then eval "exec ${input_fd}<&-"; fi
	if [[ -n ${LIVE_PID:-} ]]; then kill "$LIVE_PID" 2>/dev/null || true; fi
	LIVE_FD=
	LIVE_IN=
	LIVE_PID=
}
live_close() {
	LIVE_RECONNECT_PENDING=0
	if [[ -n ${LIVE_FD:-} ]]; then live_send_frame 8 '' || true; fi
	live_disconnect
}
live_schedule_reconnect() {
	local reason=$1 initial_delay=${2:-$LIVE_RECONNECT_BASE_MS} id
	LIVE_LAST_CLOSE_REASON=$reason
	for id in "${!LIVE_LAST[@]}"; do
		# shellcheck disable=SC2034
		LIVE_REHYDRATE["$id"]=${LIVE_LAST["$id"]}
	done
	if ((${#LIVE_PATH[@]})); then
		LIVE_RECONNECT_PENDING=1
		LIVE_RECONNECT_DELAY_MS=$LIVE_RECONNECT_BASE_MS
		LIVE_RECONNECT_AT_MS=$(($(_live_now_ms) + initial_delay))
	fi
}
live_reconnect_tick() {
	local now
	((LIVE_RECONNECT_PENDING)) || return 0
	((${#LIVE_PATH[@]})) || {
		LIVE_RECONNECT_PENDING=0
		return 0
	}
	now=$(_live_now_ms)
	((now >= LIVE_RECONNECT_AT_MS)) || return 0
	if live_connect; then return 0; fi
	live_disconnect
	LIVE_RECONNECT_DELAY_MS=$((LIVE_RECONNECT_DELAY_MS * 2))
	((LIVE_RECONNECT_DELAY_MS > LIVE_RECONNECT_MAX_MS)) && LIVE_RECONNECT_DELAY_MS=$LIVE_RECONNECT_MAX_MS
	LIVE_RECONNECT_AT_MS=$((now + LIVE_RECONNECT_DELAY_MS))
}

live_queue_push() {
	local id=$1 update=$2 queue
	queue=${LIVE_QUEUE[$id]:-[]}
	# Reactive updates describe current state, so overflow drops the oldest value.
	LIVE_QUEUE[$id]=$(printf '%s\n' "$queue" | jq -c --argjson update "$update" '(. + [$update]) | if length > 16 then .[-16:] else . end')
}
live_queue_shift() {
	local id=$1 queue
	queue=${LIVE_QUEUE[$id]:-[]}
	[[ $(printf '%s\n' "$queue" | jq length) -gt 0 ]] || return 1
	# shellcheck disable=SC2034
	LIVE_SHIFTED=$(printf '%s\n' "$queue" | jq -c '.[0]')
	LIVE_QUEUE[$id]=$(printf '%s\n' "$queue" | jq -c '.[1:]')
}
live_next_value() {
	# Ignore unrelated Transition messages and surface the selected query's next
	# value. QueryFailed stays structured for adapter callers to serialise.
	local id=$1 raw value
	# Run the parser in this shell. A command-substitution subshell can remap the
	# numeric socket descriptor, which would swallow required Pong/Close replies.
	while live_read 10 >/dev/null; do
		raw=$LIVE_READ
		value=$(printf '%s\n' "$raw" | jq -ce --argjson id "$id" '.modifications[]? | select(.queryId == $id and .type == "QueryUpdated") | .value' 2>/dev/null || true)
		[[ -n $value ]] && {
			printf '%s\n' "$value"
			return
		}
		printf '%s\n' "$raw" | jq -e --argjson id "$id" '.modifications[]? | select(.queryId == $id and .type == "QueryFailed")' >/dev/null && {
			echo 'Live query failed' >&2
			return 1
		}
	done
	echo 'timed out waiting for Live update' >&2
	return 1
}
