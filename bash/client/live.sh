#!/usr/bin/env bash
# RFC6455 and the pinned Convex /api/sync profile, implemented in Bash. The
# transport helpers are only byte/TLS tools; query-set and state handling live here.
set -euo pipefail

LIVE_FD= LIVE_IN= LIVE_PID= LIVE_QUERY_SET=0 LIVE_CONNECTIONS=0 LIVE_CLOSED=0
declare -Ag LIVE_PATH LIVE_ARGS LIVE_SUB LIVE_QUEUE LIVE_ERRORS LIVE_LAST

_byte() { od -An -tu1 | tr -d ' \n'; }
_write_byte() { printf "\\$(printf '%03o' "$1")" >&"$LIVE_FD"; }
_ws_url() { local base=${CONVEX_URL%/}; printf '%s/api/sync' "${base/http:/ws:}" | sed 's#^https:#wss:#'; }

live_connect() {
  local url hostport host port key line session_hex session_id
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
  session_hex=$(openssl rand -hex 16)
  session_id=${session_hex:0:8}-${session_hex:8:4}-4${session_hex:13:3}-a${session_hex:17:3}-${session_hex:20:12}
  live_send "$(jq -cn --arg sid "$session_id" --argjson count "$LIVE_CONNECTIONS" '{type:"Connect",sessionId:$sid,connectionCount:$count,lastCloseReason:"InitialConnect",clientTs:0}')"
  ((LIVE_CONNECTIONS++)) || true
  live_resubscribe
}

live_send_frame() {
  local opcode=$1 text=$2 n i value mask=() bytes
  n=$(printf %s "$text" | wc -c | tr -d ' ')
  _write_byte $((128 | opcode))
  if ((n < 126)); then _write_byte $((128+n));
  elif ((n < 65536)); then _write_byte 254; _write_byte $((n >> 8)); _write_byte $((n & 255));
  else _write_byte 255; for i in 56 48 40 32 24 16 8 0; do _write_byte $(((n >> i) & 255)); done; fi
  read -r -a mask < <(openssl rand 4 | od -An -tu1)
  for i in 0 1 2 3; do _write_byte "${mask[$i]}"; done
  bytes=$(printf %s "$text" | od -An -v -tu1)
  i=0
  for value in $bytes; do _write_byte $((value ^ mask[i%4])); ((i++)) || true; done
}
live_send() { live_send_frame 1 "$1"; }

_read_byte() { dd bs=1 count=1 status=none <&"$LIVE_IN" | _byte; }
live_read() {
  local timeout=${1:-0} first second opcode final n=0 i part='' message=''
  while :; do
    local read_status=0
    IFS= read -r -N 1 -t "$timeout" first <&"$LIVE_IN" || read_status=$?
    if ((read_status)); then ((read_status > 128)) && return 4 || return 3; fi
    first=$(printf %s "$first" | _byte); second=$(_read_byte); opcode=$((first & 15)); final=$((first & 128)); n=$((second & 127))
    if ((n == 126)); then n=$(( $(_read_byte) * 256 + $(_read_byte) ));
    elif ((n == 127)); then n=0; for i in 1 2 3 4 5 6 7 8; do n=$((n * 256 + $(_read_byte))); done; fi
    ((second & 128)) && { echo 'server sent masked RFC6455 frame' >&2; return 2; }
    part=$(dd bs=1 count="$n" status=none <&"$LIVE_IN") || return 3
    case $opcode in
      8) return 3 ;;
      9) live_send_frame 10 "$part"; continue ;;
      10) continue ;;
      1) message=$part ;;
      0) message+=$part ;;
      *) echo "unsupported RFC6455 opcode $opcode" >&2; return 2 ;;
    esac
    ((final)) && { printf '%s\n' "$message"; return; }
    timeout=10
  done
}

live_modify() { local modifications=$1 new=$((LIVE_QUERY_SET+1)); live_send "$(jq -cn --argjson base "$LIVE_QUERY_SET" --argjson new "$new" --argjson mods "$modifications" '{type:"ModifyQuerySet",baseVersion:$base,newVersion:$new,modifications:$mods}')"; LIVE_QUERY_SET=$new; }
live_resubscribe() { local id mods='[]'; for id in "${!LIVE_PATH[@]}"; do mods=$(jq -cn --argjson old "$mods" --arg id "$id" --arg path "${LIVE_PATH[$id]}" --argjson args "${LIVE_ARGS[$id]}" '$old + [{type:"Add",queryId:($id|tonumber),udfPath:$path,args:[$args]}]'); done; if [[ $mods != '[]' ]]; then live_modify "$mods"; fi; return 0; }
live_add() { local id=$1 sub=$2 path=$3 args=$4; LIVE_SUB[$id]=$sub; LIVE_PATH[$id]=$path; LIVE_ARGS[$id]=$args; live_modify "$(jq -cn --argjson id "$id" --arg p "$path" --argjson a "$args" '[{type:"Add",queryId:$id,udfPath:$p,args:[$a]}]')"; }
live_remove() { local id=$1; unset 'LIVE_SUB[$id]' 'LIVE_PATH[$id]' 'LIVE_ARGS[$id]'; live_modify "$(jq -cn --argjson id "$id" '[{type:"Remove",queryId:$id}]')"; }
live_disconnect() { [[ -n ${LIVE_FD:-} ]] && eval "exec ${LIVE_FD}>&-" || true; LIVE_FD=; }
live_reconnect() {
  local attempts=0 delay_ms=100
  while ((attempts < 6)); do
    sleep "$(awk -v ms="$delay_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
    if live_connect; then return 0; fi
    live_disconnect; ((attempts++)) || true; delay_ms=$((delay_ms * 2)); ((delay_ms > 15000)) && delay_ms=15000
  done
  return 1
}

live_queue_push() {
  local id=$1 update=$2 queue
  queue=${LIVE_QUEUE[$id]:-[]}
  # Reactive updates describe current state, so overflow drops the oldest value.
  LIVE_QUEUE[$id]=$(jq -c --argjson update "$update" '(. + [$update]) | if length > 16 then .[-16:] else . end' <<<"$queue")
}
live_queue_shift() {
  local id=$1 queue
  queue=${LIVE_QUEUE[$id]:-[]}
  [[ $(jq length <<<"$queue") -gt 0 ]] || return 1
  LIVE_SHIFTED=$(jq -c '.[0]' <<<"$queue")
  LIVE_QUEUE[$id]=$(jq -c '.[1:]' <<<"$queue")
}
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
