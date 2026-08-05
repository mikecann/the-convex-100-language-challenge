#!/usr/bin/env bash
set -euo pipefail
[[ -n ${ADAPTER_DIAGNOSTIC_FILE:-} ]] && exec 2>>"$ADAPTER_DIAGNOSTIC_FILE"
if [[ -n ${ADAPTER_TRACE_FILE:-} ]]; then
	exec 8>>"$ADAPTER_TRACE_FILE"
	BASH_XTRACEFD=8
	set -x
fi
adapter_dir=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ -f $adapter_dir/../../convex.sh ]]; then
	client_root=$(cd -- "$adapter_dir/../.." && pwd)
else
	# Final images copy this one test-only entrypoint out of the source test tree.
	client_root=/opt/convex/client
fi
# shellcheck source=/dev/null
source "$client_root/convex.sh"
# shellcheck source=/dev/null
source "$client_root/live.sh"

send() { jq -cn "$@"; }
failure() {
	local id=${1:-}
	shift || true
	jq -cn --arg id "$id" --arg message "$*" '{id:$id,type:"error",error:{name:"Error",message:$message}}'
}

worker_queue_live_error() {
	local name=$1 message=$2 query
	for query in "${!LIVE_SUB[@]}"; do
		live_queue_push "$query" "$(jq -cn --arg name "$name" --arg message "$message" '{error:{name:$name,message:$message}}')"
	done
}

worker_drain_live() {
	local raw modification query update expected read_status frames=0 delivered=0 was_connected=0
	[[ -n ${LIVE_IN:-} ]] && was_connected=1
	if [[ -z ${LIVE_IN:-} ]]; then
		live_reconnect_tick
		if [[ -n ${LIVE_IN:-} ]] && ((was_connected == 0)); then jq -cn '{internal:"connected"}'; fi
		return 0
	fi
	# One frame per worker turn prevents a hot subscription from starving its
	# own command pipe. Controller commands are handled by the separate parent.
	while ((frames < 1)); do
		read_status=0
		live_read 0.1 >/dev/null || read_status=$?
		raw=$LIVE_READ
		if ((read_status)); then
			if ((read_status == 2)); then
				worker_queue_live_error ProtocolError 'invalid RFC6455 or Convex Live frame'
				live_disconnect
				live_schedule_reconnect ProtocolError
				jq -cn '{internal:"disconnected"}'
			elif ((read_status == 3)); then
				live_disconnect
				live_schedule_reconnect TransportError
				jq -cn '{internal:"disconnected"}'
			fi
			break
		fi
		if ! printf '%s\n' "$raw" | jq -e '.type == "Transition" or .type == "Ping"' >/dev/null 2>&1; then
			worker_queue_live_error ProtocolError 'unsupported or malformed Convex Live message'
			live_disconnect
			live_schedule_reconnect ProtocolError
			jq -cn '{internal:"disconnected"}'
			break
		fi
		((frames++)) || true
		while IFS= read -r modification; do
			query=$(printf '%s\n' "$modification" | jq -r .queryId)
			update=$(printf '%s\n' "$modification" | jq -c 'if .type == "QueryFailed" then {error:{name:"FunctionError",message:(.errorMessage // "Live query failed"),data:.errorData},logs:(.logLines // [])} else {value:.value,logs:(.logLines // [])} end')
			[[ -n ${LIVE_SUB[$query]:-} ]] || continue
			if [[ -n ${LIVE_REHYDRATE["$query"]+present} ]]; then
				expected=${LIVE_REHYDRATE["$query"]}
				unset 'LIVE_REHYDRATE[$query]'
				# A reconnect replays current query state. Suppress only an exact
				# rehydration of the last delivered result.
				if [[ -n $expected ]] && jq -ne --argjson current "$update" --argjson prior "$expected" '$current.value == $prior.value and $current.error == $prior.error' >/dev/null; then continue; fi
			fi
			live_queue_push "$query" "$update"
		done < <(printf '%s\n' "$raw" | jq -c '.modifications[]? | select(.type == "QueryUpdated" or .type == "QueryFailed")')
	done
	for query in "${!LIVE_QUEUE[@]}"; do
		[[ -n ${LIVE_SUB[$query]:-} ]] || continue
		delivered=0
		while ((delivered < 16)) && live_queue_shift "$query"; do
			update=$LIVE_SHIFTED
			# shellcheck disable=SC2034
			LIVE_LAST["$query"]=$update
			jq -cn --argjson query "$query" --argjson update "$update" '{internal:"subscription",queryId:$query} + $update'
			((delivered++)) || true
		done
	done
}

live_worker_main() {
	local line status op query path args add_status
	trap 'live_close' EXIT
	trap 'exit 0' INT TERM
	while :; do
		line=
		status=0
		IFS= read -r -t 0.05 line || status=$?
		worker_drain_live
		if [[ -z $line ]]; then
			((status == 1)) && break
			continue
		fi
		op=$(printf '%s\n' "$line" | jq -r '.internal // ""')
		case $op in
		subscribe)
			query=$(printf '%s\n' "$line" | jq -r .queryId)
			path=$(printf '%s\n' "$line" | jq -r .path)
			args=$(printf '%s\n' "$line" | jq -c .args)
			add_status=0
			live_add "$query" "$query" "$path" "$args" || add_status=$?
			if ((add_status)); then
				jq -cn --argjson query "$query" '{internal:"subscription",queryId:$query,error:{name:"TransportError",message:"failed to add Live query"}}'
				live_disconnect
				live_schedule_reconnect TransportError
			elif [[ -z ${LIVE_FD:-} ]] && ((LIVE_RECONNECT_PENDING == 0)); then
				live_schedule_reconnect InitialConnect 0
			fi
			;;
		unsubscribe)
			query=$(printf '%s\n' "$line" | jq -r .queryId)
			live_remove "$query" || true
			;;
		debugDisconnect)
			if [[ -n ${LIVE_FD:-} ]]; then
				live_disconnect
				live_schedule_reconnect DebugDisconnect 0
				jq -cn '{internal:"disconnected"}'
			fi
			;;
		close) break ;;
		esac
	done
}

if [[ ${1:-} = --live-worker ]]; then
	live_worker_main
	exit 0
fi

next_query=0
worker_in='' worker_out='' worker_pid='' worker_connected=0
declare -Ag ADAPTER_SUB

start_live_worker() {
	local coproc_in coproc_out
	if [[ -n $worker_pid ]] && kill -0 "$worker_pid" 2>/dev/null; then return 0; fi
	coproc BASH_LIVE_WORKER { bash "$0" --live-worker; }
	coproc_out=${BASH_LIVE_WORKER[0]}
	coproc_in=${BASH_LIVE_WORKER[1]}
	worker_pid=$BASH_LIVE_WORKER_PID
	# Coprocess descriptors are close-on-exec. Ordinary duplicates let jq and
	# the worker process inherit only the descriptors they actually need.
	exec {worker_out}<&"$coproc_out"
	exec {worker_in}>&"$coproc_in"
	eval "exec ${coproc_out}<&-"
	eval "exec ${coproc_in}>&-"
	worker_connected=0
}

send_worker() {
	start_live_worker
	printf '%s\n' "$1" >&"$worker_in"
}

stop_live_worker() {
	if [[ -n $worker_pid ]]; then
		printf '%s\n' '{"internal":"close"}' 1>&"$worker_in" 2>/dev/null || true
		kill "$worker_pid" 2>/dev/null || true
		wait "$worker_pid" 2>/dev/null || true
	fi
	if [[ -n $worker_in ]]; then eval "exec ${worker_in}>&-"; fi
	if [[ -n $worker_out ]]; then eval "exec ${worker_out}<&-"; fi
	worker_in=
	worker_out=
	worker_pid=
	worker_connected=0
}

drain_worker() {
	local event status=0 internal query sub delivered=0
	[[ -n $worker_out ]] || return 0
	while ((delivered < 16)); do
		event=
		status=0
		IFS= read -r -t 0.001 event <&"$worker_out" || status=$?
		if [[ -z $event ]]; then
			((status == 1)) && stop_live_worker
			break
		fi
		internal=$(printf '%s\n' "$event" | jq -r '.internal // ""')
		case $internal in
		connected) worker_connected=1 ;;
		disconnected) worker_connected=0 ;;
		subscription)
			query=$(printf '%s\n' "$event" | jq -r .queryId)
			sub=${ADAPTER_SUB[$query]:-}
			[[ -n $sub ]] && jq -cn --arg sub "$sub" --argjson update "$(printf '%s\n' "$event" | jq -c 'del(.internal,.queryId)')" '{type:"subscription",subscriptionId:$sub} + $update'
			;;
		esac
		((delivered++)) || true
	done
}

trap 'stop_live_worker' EXIT INT TERM
while :; do
	line=
	status=0
	IFS= read -r -t 0.05 line || status=$?
	drain_worker
	if [[ -z $line ]]; then
		((status == 1)) && break
		continue
	fi
	id=$(printf '%s\n' "$line" | jq -r '.id // ""' 2>/dev/null || true)
	op=$(printf '%s\n' "$line" | jq -r '.op // ""' 2>/dev/null || true)
	case "$op" in
	hello) send --arg id "$id" --arg runtime "bash-$BASH_VERSION" '{protocolVersion:1,id:$id,type:"ready",language:"bash",implementation:"native-bash-http-rfc6455",runtime:$runtime}' ;;
	setAuth)
		convex_set_auth "$(printf '%s\n' "$line" | jq -r '.token')"
		send --arg id "$id" '{id:$id,type:"ack"}'
		;;
	query | mutation | action)
		path=$(printf '%s\n' "$line" | jq -r .path)
		args=$(printf '%s\n' "$line" | jq -c .args)
		# Capture the transport diagnostic without relying on /tmp: runtime images
		# are deliberately exercised with a read-only filesystem.
		if result=$(_convex_call "$op" "$path" "$args" 2>&1); then
			send --arg id "$id" --argjson result "$result" '{id:$id,type:"result",value:$result.value} + (if ($result.logs|length)>0 then {logs:$result.logs} else {} end)'
		elif printf '%s\n' "$result" | jq -e '.name' >/dev/null 2>&1; then
			send --arg id "$id" --argjson error "$result" '{id:$id,type:"error",error:($error|del(.logs))} + (if ($error.logs|length)>0 then {logs:$error.logs} else {} end)'
		else jq -cn --arg id "$id" --arg message "$result" '{id:$id,type:"error",error:{name:"TransportError",message:$message}}'; fi
		;;
	close)
		stop_live_worker
		send --arg id "$id" '{id:$id,type:"closed"}'
		exit 0
		;;
	subscribe)
		path=$(printf '%s\n' "$line" | jq -r .path)
		args=$(printf '%s\n' "$line" | jq -c .args)
		sub=$(printf '%s\n' "$line" | jq -r .subscriptionId)
		if ! printf '%s\n' "$args" | jq -e 'type == "object"' >/dev/null; then
			failure "$id" 'Live query args must be a named JSON object'
			continue
		fi
		# Stop routing the old query immediately. A delayed worker event cannot
		# cross the replacement ACK barrier under the reused subscription id.
		for q in "${!ADAPTER_SUB[@]}"; do
			if [[ ${ADAPTER_SUB[$q]} = "$sub" ]]; then
				unset 'ADAPTER_SUB[$q]'
				send_worker "$(jq -cn --argjson query "$q" '{internal:"unsubscribe",queryId:$query}')"
			fi
		done
		q=$next_query
		((next_query++)) || true
		ADAPTER_SUB[$q]=$sub
		if send_worker "$(jq -cn --argjson query "$q" --arg path "$path" --argjson args "$args" '{internal:"subscribe",queryId:$query,path:$path,args:$args}')"; then
			send --arg id "$id" '{id:$id,type:"ack"}'
		else
			unset 'ADAPTER_SUB[$q]'
			failure "$id" 'Live worker is unavailable'
		fi
		;;
	unsubscribe)
		sub=$(printf '%s\n' "$line" | jq -r .subscriptionId)
		for q in "${!ADAPTER_SUB[@]}"; do
			if [[ ${ADAPTER_SUB[$q]} = "$sub" ]]; then
				unset 'ADAPTER_SUB[$q]'
				send_worker "$(jq -cn --argjson query "$q" '{internal:"unsubscribe",queryId:$query}')" || true
			fi
		done
		send --arg id "$id" '{id:$id,type:"ack"}'
		;;
	debugDisconnect)
		if ((worker_connected == 0)); then
			failure "$id" 'Live WebSocket is not connected'
		elif send_worker '{"internal":"debugDisconnect"}'; then
			worker_connected=0
			send --arg id "$id" '{id:$id,type:"ack"}'
		else
			failure "$id" 'Live worker is unavailable'
		fi
		;;
	*) failure "$id" "unsupported operation $op" ;;
	esac
done
