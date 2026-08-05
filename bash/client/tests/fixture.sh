#!/usr/bin/env bash
# Deterministic HTTP + RFC6455 fixture. It speaks network protocols rather than
# mocking client functions, so tests exercise the same bytes as a deployment.
set -euo pipefail
state_dir=${BASH_FIXTURE_STATE:-/tmp/bash-convex-fixture}
mkdir -p "$state_dir"
exec 2>>"$state_dir/fixture.err"
if [[ ${BASH_FIXTURE_TRACE:-0} = 1 ]]; then
	exec 8>>"$state_dir/fixture.trace"
	BASH_XTRACEFD=8
	set -x
fi

write_byte() { printf '%b' "\\$(printf '%03o' "$1")"; }
server_frame() {
	local text=$1 opcode=${2:-1} final=${3:-1} n i length_code
	n=$(printf %s "$text" | wc -c | tr -d ' ')
	write_byte $((final * 128 | opcode))
	if ((n < 126)); then
		length_code=$n
		write_byte "$n"
	elif ((n < 65536)); then
		length_code=126
		write_byte 126
		write_byte $((n >> 8))
		write_byte $((n & 255))
	else
		length_code=127
		write_byte 127
		for i in 56 48 40 32 24 16 8 0; do write_byte $(((n >> i) & 255)); done
	fi
	printf '{"opcode":%s,"length":%s,"lengthCode":%s}\n' "$opcode" "$n" "$length_code" >>"$state_dir/server-frames.log"
	printf %s "$text"
}
client_frame() {
	local first=${1:-} second n i values=() masks=() bytes value out='' opcode raw
	# Convert bytes to decimal before Bash sees them. Command substitutions cannot
	# preserve NUL bytes, and stripping a random newline from a masking key made
	# this fixture intermittently reject perfectly valid client frames.
	if [[ -n $first ]]; then
		raw=$(dd bs=1 count=1 status=none | od -An -v -tu1)
		read -r -a values <<<"${raw//$'\n'/ }"
		((${#values[@]} == 1)) || return 3
		second=${values[0]}
	else
		raw=$(dd bs=1 count=2 status=none | od -An -v -tu1)
		read -r -a values <<<"${raw//$'\n'/ }"
		((${#values[@]} == 2)) || return 3
		first=${values[0]}
		second=${values[1]}
	fi
	n=$((second & 127))
	opcode=$((first & 15))
	((second & 128)) || {
		echo 'client frame was not masked'
		return 2
	}
	if ((n == 126)); then
		raw=$(dd bs=1 count=2 status=none | od -An -v -tu1)
		read -r -a values <<<"${raw//$'\n'/ }"
		((${#values[@]} == 2)) || return 3
		n=$((values[0] * 256 + values[1]))
	elif ((n == 127)); then
		raw=$(dd bs=1 count=8 status=none | od -An -v -tu1)
		read -r -a values <<<"${raw//$'\n'/ }"
		((${#values[@]} == 8)) || return 3
		n=0
		for value in "${values[@]}"; do n=$((n * 256 + value)); done
	fi
	raw=$(dd bs=1 count="$((n + 4))" status=none | od -An -v -tu1)
	read -r -a values <<<"${raw//$'\n'/ }"
	((${#values[@]} == n + 4)) || return 3
	masks=("${values[@]:0:4}")
	bytes=("${values[@]:4}")
	i=0
	for value in "${bytes[@]}"; do
		printf -v out '%s\\%03o' "$out" $((value ^ masks[i % 4]))
		((i++)) || true
	done
	printf '{"opcode":%s,"masked":true,"length":%s}\n' "$opcode" "$n" >>"$state_dir/frames.log"
	((opcode == 8)) && return 8
	printf '%b' "$out"
}
http_response() {
	local body=$1
	printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$(printf %s "$body" | wc -c | tr -d ' ')" "$body"
}

IFS= read -r request
request=${request%$'\r'}
length=0
key=
while IFS= read -r header; do
	header=${header%$'\r'}
	[[ -z $header ]] && break
	case ${header,,} in content-length:*)
		length=${header#*: }
		length=${length%$'\r'}
		;;
	sec-websocket-key:*)
		key=${header#*: }
		key=${key%$'\r'}
		;;
	esac
done
ws_path=${BASH_FIXTURE_WS_PATH:-/api/sync}
if [[ $request = "GET $ws_path HTTP/1.1" ]]; then
	printf '%s\n' "$request" >>"$state_dir/requests.log"
	handshake_attempts_file=$state_dir/handshake-attempts
	handshake_attempts=$(test -f "$handshake_attempts_file" && cat "$handshake_attempts_file" || printf 0)
	handshake_attempts=$((handshake_attempts + 1))
	printf '%s' "$handshake_attempts" >"$handshake_attempts_file"
	fail_after=${BASH_FIXTURE_FAIL_AFTER:-0}
	fail_count=${BASH_FIXTURE_FAIL_HANDSHAKES:-0}
	if ((handshake_attempts > fail_after && handshake_attempts <= fail_after + fail_count)); then exit 0; fi
	stall_after=${BASH_FIXTURE_STALL_AFTER:-0}
	if ((stall_after > 0 && handshake_attempts > stall_after)); then
		sleep 10
		exit 0
	fi
	accept=$(printf '%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11' "$key" | openssl dgst -sha1 -binary | openssl base64 -A)
	case ${BASH_FIXTURE_HANDSHAKE:-ok} in
	bad_accept) accept=definitely-wrong ;;
	bad_upgrade)
		printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: not-websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Accept: %s\r\n\r\n' "$accept"
		sleep 1
		exit 0
		;;
	many_headers)
		printf 'HTTP/1.1 101 Switching Protocols\r\n'
		for number in $(seq 1 65); do printf 'X-Fixture-%s: value\r\n' "$number"; done
		printf 'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' "$accept"
		sleep 1
		exit 0
		;;
	oversized_headers)
		printf 'HTTP/1.1 101 Switching Protocols\r\nX-Oversized: '
		dd if=/dev/zero bs=17000 count=1 status=none | tr '\0' x
		printf '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' "$accept"
		sleep 1
		exit 0
		;;
	no_terminator)
		printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n' "$accept"
		exit 0
		;;
	esac
	printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' "$accept"
	[[ ${BASH_FIXTURE_HANDSHAKE:-ok} = bad_accept ]] && {
		sleep 1
		exit 0
	}
	connect=$(client_frame)
	jq -e '.type=="Connect" and (.sessionId|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))' <<<"$connect" >/dev/null
	printf '%s\n' "$connect" >>"$state_dir/ws.log"
	drop_resub_after=${BASH_FIXTURE_DROP_RESUB_AFTER:-0}
	drop_resub_count=${BASH_FIXTURE_DROP_RESUB_COUNT:-0}
	if ((handshake_attempts > drop_resub_after && handshake_attempts <= drop_resub_after + drop_resub_count)); then exit 0; fi
	last=-1
	while modify=$(client_frame); do
		printf '%s\n' "$modify" >>"$state_dir/ws.log"
		mapfile -t modification_lines < <(jq -r '.modifications[] | [.type,.queryId,(.udfPath // ""),(.args|tojson)] | @tsv' <<<"$modify")
		for modification_line in "${modification_lines[@]}"; do
			IFS=$'\t' read -r kind q path args <<<"$modification_line"
			[[ $kind = Remove ]] && continue
			room=$(jq -r '.[0].room // "default"' <<<"$args")
			active_q=$q
			active_room=$room
			room_key=$(printf %s "$room" | sha256sum | cut -d' ' -f1)
			count_file="$state_dir/$room_key"
			count=$(test -f "$count_file" && cat "$count_file" || printf 0)
			last=$count
			if [[ $path = demo:requiresNonzero && $count = 0 ]]; then
				transition=$(jq -cn --argjson q "$q" '{type:"Transition",startVersion:{querySet:0,identity:0,ts:"AAAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},modifications:[{type:"QueryFailed",queryId:$q,errorMessage:"room is empty",errorData:{code:"ROOM_EMPTY"},logLines:["query demo:requiresNonzero"]}]}')
			else
				transition=$(jq -cn --argjson q "$q" --arg room "$room" --argjson count "$count" '{type:"Transition",startVersion:{querySet:0,identity:0,ts:"AAAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},modifications:[{type:"QueryUpdated",queryId:$q,value:{room:$room,count:$count,lastLanguage:(if $count > 0 then "Bash" else null end),latestRunId:(if $count > 0 then "fixture" else null end),updatedAt:(if $count > 0 then 1 else null end)},logLines:["query demo:state 世界 👋"]}]}')
			fi
			if [[ $path = fixture:partial && ! -f $state_dir/partial-sent ]]; then
				: >"$state_dir/partial-sent"
				# Resume the abandoned frame after the client's read deadline. The
				# client must reconnect before treating any later byte as a new header.
				write_byte 129
				sleep 0.4
				write_byte 1
				printf x
				exit 0
			fi
			if [[ $path = fixture:stall ]]; then
				write_byte 129
				sleep 5
				exit 0
			fi
			if [[ $path = fixture:close ]]; then
				server_frame "$(printf '\003\350')" 8 1
				client_frame >/dev/null || test $? = 8
				exit 0
			fi
			# A real control ping must receive a masked pong with the same payload.
			server_frame 'fixture-ping' 9 1
			pong=$(client_frame)
			[[ $pong = fixture-ping ]]
			# Exercise the valid 64-bit frame-length path once with a >64 KiB Ping.
			if [[ ! -f $state_dir/large-sent ]]; then
				: >"$state_dir/large-sent"
				padding=$(dd if=/dev/zero bs=1024 count=65 status=none | tr '\0' x)
				server_frame "$(jq -cn --arg padding "$padding" '{type:"Ping",padding:$padding}')"
			fi
			if [[ $path = fixture:continuous ]]; then
				for sequence in $(seq 1 200); do server_frame "$(jq -cn --argjson q "$q" --argjson count "$sequence" '{type:"Transition",modifications:[{type:"QueryUpdated",queryId:$q,value:{count:$count},logLines:[]}]}')" || exit 0; done
			else
				# Split after the first byte of 世, deliberately inside its UTF-8 sequence.
				prefix=${transition%%世界*}
				split=$(($(printf %s "$prefix" | wc -c | tr -d ' ') + 1))
				first_part=$(printf %s "$transition" | dd bs=1 count="$split" status=none)
				second_part=$(printf %s "$transition" | dd bs=1 skip="$split" status=none)
				server_frame "$first_part" 1 0
				server_frame "$second_part" 0 1
			fi
		done
		# Poll the room state while still accepting control frames.
		while :; do
			read_status=0
			first=$(timeout 0.02 dd bs=1 count=1 status=none | od -An -tu1 | tr -d ' \n') || read_status=$?
			if [[ -n $first ]]; then
				# Put the already-read first header byte back through a tiny decoder path.
				if modify=$(client_frame "$first"); then
					printf '%s\n' "$modify" >>"$state_dir/ws.log"
					break
				else
					frame_status=$?
					((frame_status == 8)) && exit 0
					exit "$frame_status"
				fi
			elif ((read_status == 0)); then
				# dd reached real EOF. A timeout is status 124 and leaves the connection
				# alive for the next state poll.
				printf 'peer-eof\n' >>"$state_dir/peer-eof.log"
				exit 0
			elif ((read_status != 124 && read_status != 143)); then
				exit "$read_status"
			fi
			count=$(test -f "$count_file" && cat "$count_file" || printf 0)
			if [[ $count != "$last" ]]; then
				last=$count
				transition=$(jq -cn --argjson q "$active_q" --arg room "$active_room" --argjson count "$count" '{type:"Transition",startVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AgAAAAAAAAA="},modifications:[{type:"QueryUpdated",queryId:$q,value:{room:$room,count:$count,lastLanguage:"Bash",latestRunId:"fixture",updatedAt:1},logLines:[]}]}')
				server_frame "$transition"
			fi
		done
	done
	exit 0
fi

# Content-Length is bytes, while Bash read -N counts locale characters. dd keeps
# UTF-8 request bodies byte-exact.
body=
((length)) && body=$(dd bs=1 count="$length" status=none)
path=$(jq -r .path <<<"$body")
args=$(jq -c .args <<<"$body")
case $path in
demo:echo) response=$(jq -cn --argjson value "$(jq -c .value <<<"$args")" '{status:"success",value:$value,logLines:["query demo:echo"]}') ;;
fixture:largeResponse)
	padding=$(dd if=/dev/zero bs=1024 count=2049 status=none | tr '\0' x)
	printf -v response '{"status":"success","value":{"padding":"%s"},"logLines":[]}' "$padding"
	;;
demo:fail) response=$(jq -cn --arg code "$(jq -r .code <<<"$args")" '{status:"error",errorMessage:"expected fixture error",errorData:{code:$code},logLines:["query demo:fail"]}') ;;
demo:greet) response='{"status":"success","value":{"message":"Convex is responding to Bash"},"logLines":[]}' ;;
demo:state | demo:increment)
	room=$(jq -r .room <<<"$args")
	room_key=$(printf %s "$room" | sha256sum | cut -d' ' -f1)
	count_file="$state_dir/$room_key"
	count=$(test -f "$count_file" && cat "$count_file" || printf 0)
	if [[ $path = demo:increment ]]; then
		count=$((count + 1))
		printf %s "$count" >"$count_file"
		response=$(jq -cn --argjson count "$count" '{status:"success",value:{applied:true,state:{count:$count}},logLines:[]}')
	else response=$(jq -cn --arg room "$room" --argjson count "$count" '{status:"success",value:{room:$room,count:$count,lastLanguage:null,latestRunId:null,updatedAt:null},logLines:[]}'); fi
	;;
*) response='{"status":"error","errorMessage":"unknown fixture path","errorData":{"code":"UNKNOWN"}}' ;;
esac
http_response "$response"
