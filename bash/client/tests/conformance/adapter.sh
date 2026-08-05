#!/usr/bin/env bash
set -euo pipefail
[[ -n ${ADAPTER_DIAGNOSTIC_FILE:-} ]] && exec 2>>"$ADAPTER_DIAGNOSTIC_FILE"
if [[ -n ${ADAPTER_TRACE_FILE:-} ]]; then exec 8>>"$ADAPTER_TRACE_FILE"; BASH_XTRACEFD=8; set -x; fi
source "$(cd -- "$(dirname -- "$0")/../.." && pwd)/convex.sh"
source "$(cd -- "$(dirname -- "$0")/../.." && pwd)/live.sh"

send() { jq -cn "$@"; }
failure() { local id=${1:-}; shift || true; jq -cn --arg id "$id" --arg message "$*" '{id:$id,type:"error",error:{name:"Error",message:$message}}'; }

next_query=0
queue_live_error() {
  local name=$1 message=$2 query
  for query in "${!LIVE_SUB[@]}"; do live_queue_push "$query" "$(jq -cn --arg name "$name" --arg message "$message" '{error:{name:$name,message:$message}}')"; done
}
drain_live() {
  local raw query sub update read_status
  [[ -n ${LIVE_IN:-} ]] || return 0
  while :; do
    read_status=0; raw=$(live_read 0.01) || read_status=$?
    if ((read_status)); then
      if ((read_status == 2)); then queue_live_error ProtocolError 'invalid RFC6455 or Convex Live frame'; live_disconnect
      elif ((read_status == 3)); then live_disconnect; live_reconnect || queue_live_error TransportError 'Live transport closed and reconnect failed'
      fi
      break
    fi
    if ! jq -e '.type == "Transition" or .type == "Ping"' >/dev/null 2>&1 <<<"$raw"; then queue_live_error ProtocolError 'unsupported or malformed Convex Live message'; live_disconnect; break; fi
    while IFS=$'\t' read -r query update; do
      sub=${LIVE_SUB[$query]:-}; [[ -z $sub ]] && continue
      live_queue_push "$query" "$update"
    done < <(jq -r '.modifications[]? | select(.type == "QueryUpdated" or .type == "QueryFailed") | [.queryId, (if .type == "QueryFailed" then {error:{name:"FunctionError",message:(.errorMessage // "Live query failed"),data:.errorData},logs:(.logLines // [])} else {value:.value,logs:(.logLines // [])} end | tojson)] | @tsv' <<<"$raw")
  done
  for query in "${!LIVE_QUEUE[@]}"; do
    sub=${LIVE_SUB[$query]:-}; [[ -z $sub ]] && continue
    while live_queue_shift "$query"; do update=$LIVE_SHIFTED; jq -cn --arg s "$sub" --argjson u "$update" '{type:"subscription",subscriptionId:$s} + $u'; done
  done
}
while :; do
  line=; status=0; IFS= read -r -t 0.05 line || status=$?
  drain_live
  if [[ -z $line ]]; then ((status == 1)) && break; continue; fi
  id=$(jq -r '.id // ""' <<<"$line" 2>/dev/null || true)
  op=$(jq -r '.op // ""' <<<"$line" 2>/dev/null || true)
  case "$op" in
    hello) send --arg id "$id" --arg runtime "bash-$BASH_VERSION" '{protocolVersion:1,id:$id,type:"ready",language:"bash",implementation:"native-bash-http-rfc6455",runtime:$runtime}' ;;
    setAuth) convex_set_auth "$(jq -r '.token' <<<"$line")"; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    query|mutation|action)
      path=$(jq -r .path <<<"$line"); args=$(jq -c .args <<<"$line")
      # Capture the transport diagnostic without relying on /tmp: runtime images
      # are deliberately exercised with a read-only filesystem.
      if result=$(_convex_call "$op" "$path" "$args" 2>&1); then send --arg id "$id" --argjson result "$result" '{id:$id,type:"result",value:$result.value} + (if ($result.logs|length)>0 then {logs:$result.logs} else {} end)';
      elif jq -e '.name' >/dev/null 2>&1 <<<"$result"; then send --arg id "$id" --argjson error "$result" '{id:$id,type:"error",error:($error|del(.logs))} + (if ($error.logs|length)>0 then {logs:$error.logs} else {} end)';
      else jq -cn --arg id "$id" --arg message "$result" '{id:$id,type:"error",error:{name:"TransportError",message:$message}}'; fi ;;
    close) live_disconnect; send --arg id "$id" '{id:$id,type:"closed"}'; exit 0 ;;
    subscribe)
      [[ -n ${LIVE_FD:-} ]] || live_connect
      path=$(jq -r .path <<<"$line"); args=$(jq -c .args <<<"$line"); sub=$(jq -r .subscriptionId <<<"$line")
      # Replacing an id performs Remove before Add so same-id errors recover.
      for q in "${!LIVE_SUB[@]}"; do [[ ${LIVE_SUB[$q]} = "$sub" ]] && live_remove "$q"; done
      q=$next_query; ((next_query++)) || true; live_add "$q" "$sub" "$path" "$args"; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    unsubscribe)
      sub=$(jq -r .subscriptionId <<<"$line"); for q in "${!LIVE_SUB[@]}"; do [[ ${LIVE_SUB[$q]} = "$sub" ]] && live_remove "$q"; done; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    debugDisconnect)
      if [[ -z ${LIVE_FD:-} ]]; then failure "$id" 'Live WebSocket is not connected'; else live_disconnect; if live_reconnect; then send --arg id "$id" '{id:$id,type:"ack"}'; else failure "$id" 'Live reconnect failed'; fi; fi ;;
    *) failure "$id" "unsupported operation $op" ;;
  esac
done
