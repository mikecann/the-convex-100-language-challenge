#!/usr/bin/env bash
# RFC6455 and the pinned Convex /api/sync profile, implemented in Bash. The
# transport helpers are only byte/TLS tools; query-set and state handling live here.
set -euo pipefail

LIVE_FD= LIVE_PID= LIVE_QUERY_SET=0 LIVE_CONNECTIONS=0 LIVE_CLOSED=0
declare -Ag LIVE_PATH LIVE_ARGS LIVE_SUB LIVE_QUEUE LIVE_ERRORS

_byte() { od -An -tu1 | tr -d ' \n'; }
_write_byte() { printf "\\$(printf '%03o' "$1")" >&"$LIVE_FD"; }
_ws_url() { local base=${CONVEX_URL%/}; printf '%s/api/sync' "${base/http:/ws:}" | sed 's#^https:#wss:#'; }

live_connect() {
  local url hostport host port key line
  url=$(_ws_url); hostport=${url#ws://}; hostport=${hostport#wss://}; hostport=${hostport%%/*}
  host=${hostport%%:*}; port=${hostport#*:}; [[ $port = "$hostport" ]] && { [[ $url = wss:* ]] && port=443 || port=80; }
  if [[ $url = wss:* ]]; then
    coproc LIVE_TLS ( openssl s_client -quiet -connect "$host:$port" -servername "$host" 2>/dev/null )
    LIVE_FD=${LIVE_TLS[1]}; LIVE_IN=${LIVE_TLS[0]}; LIVE_PID=$LIVE_TLS_PID
  else
    exec {LIVE_FD}<>"/dev/tcp/$host/$port"; LIVE_IN=$LIVE_FD
  fi
  key=$(openssl rand -base64 16)
  printf 'GET /api/sync HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nConvex-Client: %s\r\n\r\n' "$hostport" "$key" "$CONVEX_CLIENT_VERSION" >&"$LIVE_FD"
  IFS= read -r line <&"$LIVE_IN" || return 1; [[ $line = *'101'* ]] || return 1
  while IFS= read -r line <&"$LIVE_IN"; do [[ $line = $'\r' || -z $line ]] && break; done
  LIVE_QUERY_SET=0
  live_send "$(jq -cn --arg sid "bash-$$-$RANDOM" --argjson count "$LIVE_CONNECTIONS" '{type:"Connect",sessionId:$sid,connectionCount:$count,lastCloseReason:"InitialConnect",clientTs:0}')"
  ((LIVE_CONNECTIONS++)) || true
  live_resubscribe
}

live_send() {
  local text=$1 n i c mask=() value
  n=$(printf %s "$text" | wc -c | tr -d ' '); (( n < 126 )) || { echo 'live frame too large' >&2; return 1; }
  _write_byte 129; _write_byte $((128+n))
  for i in 0 1 2 3; do mask[$i]=$((RANDOM % 256)); _write_byte "${mask[$i]}"; done
  for ((i=0;i<n;i++)); do c=${text:i:1}; printf -v value '%d' "'$c"; _write_byte $((value ^ mask[i%4])); done
}

live_read() {
  local a b n i payload='' c
  IFS= read -r -N 1 -t "${1:-0}" c <&"$LIVE_IN" || return 1; a=$(printf %s "$c" | _byte)
  IFS= read -r -N 1 c <&"$LIVE_IN" || return 1; b=$(printf %s "$c" | _byte); n=$((b & 127)); (( n < 126 )) || return 1
  for ((i=0;i<n;i++)); do IFS= read -r -N 1 c <&"$LIVE_IN" || return 1; payload+=$c; done
  [[ $a = 129 ]] && printf '%s\n' "$payload"
}

live_modify() { local modifications=$1 new=$((LIVE_QUERY_SET+1)); live_send "$(jq -cn --argjson base "$LIVE_QUERY_SET" --argjson new "$new" --argjson mods "$modifications" '{type:"ModifyQuerySet",baseVersion:$base,newVersion:$new,modifications:$mods}')"; LIVE_QUERY_SET=$new; }
live_resubscribe() { local id mods='[]'; for id in "${!LIVE_PATH[@]}"; do mods=$(jq -c --argjson old "$mods" --arg id "$id" --arg path "${LIVE_PATH[$id]}" --argjson args "${LIVE_ARGS[$id]}" '$old + [{type:"Add",queryId:($id|tonumber),udfPath:$path,args:[$args]}]'); done; [[ $mods != '[]' ]] && live_modify "$mods"; }
live_add() { local id=$1 sub=$2 path=$3 args=$4; LIVE_SUB[$id]=$sub; LIVE_PATH[$id]=$path; LIVE_ARGS[$id]=$args; live_modify "$(jq -cn --argjson id "$id" --arg p "$path" --argjson a "$args" '[{type:"Add",queryId:$id,udfPath:$p,args:[$a]}]')"; }
live_remove() { local id=$1; unset 'LIVE_SUB[$id]' 'LIVE_PATH[$id]' 'LIVE_ARGS[$id]'; live_modify "$(jq -cn --argjson id "$id" '[{type:"Remove",queryId:$id}]')"; }
live_disconnect() { [[ -n ${LIVE_FD:-} ]] && eval "exec ${LIVE_FD}>&-" || true; LIVE_FD=; }
live_next_value() {
  # Ignore unrelated Transition messages and surface the selected query's next
  # value. QueryFailed stays structured for adapter callers to serialise.
  local id=$1 raw value
  while raw=$(live_read 10); do
    value=$(jq -ce --argjson id "$id" '.modifications[]? | select(.queryId == $id and .type == "QueryUpdated") | .value' <<<"$raw" 2>/dev/null || true)
    [[ -n $value ]] && { printf '%s\n' "$value"; return; }
    jq -e --argjson id "$id" '.modifications[]? | select(.queryId == $id and .type == "QueryFailed")' <<<"$raw" >/dev/null && { echo 'Live query failed' >&2; return 1; }
  done
  echo 'timed out waiting for Live update' >&2; return 1
}
