#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")/../.." && pwd)/convex.sh"
source "$(cd -- "$(dirname -- "$0")/../.." && pwd)/live.sh"

send() { jq -cn "$@"; }
failure() { local id=${1:-}; shift || true; jq -cn --arg id "$id" --arg message "$*" '{id:$id,type:"error",error:{name:"Error",message:$message}}'; }

next_query=0
drain_live() {
  local raw query sub value error
  [[ -n ${LIVE_IN:-} ]] || return 0
  while raw=$(live_read 0.01); do
    while IFS=$'\t' read -r query value error; do
      sub=${LIVE_SUB[$query]:-}; [[ -z $sub ]] && continue
      if [[ -n $error && $error != null ]]; then jq -cn --arg s "$sub" --argjson e "$error" '{type:"subscription",subscriptionId:$s,error:{name:"FunctionError",message:"Convex query failed",data:$e}}';
      else jq -cn --arg s "$sub" --argjson v "$value" '{type:"subscription",subscriptionId:$s,value:$v,logs:[]}' ; fi
    done < <(jq -r '.modifications[]? | select(.type == "QueryUpdated" or .type == "QueryFailed") | [.queryId, (.value|tojson), (.errorData|tojson)] | @tsv' <<<"$raw")
  done
}
while IFS= read -r -t 0.05 line || [[ -n ${line:-} ]]; do
  drain_live
  [[ -z ${line:-} ]] && continue
  id=$(jq -r '.id // ""' <<<"$line" 2>/dev/null || true)
  op=$(jq -r '.op // ""' <<<"$line" 2>/dev/null || true)
  case "$op" in
    hello) send --arg id "$id" --arg runtime "bash-$BASH_VERSION" '{protocolVersion:1,id:$id,type:"ready",language:"bash",implementation:"native-bash-http",runtime:$runtime}' ;;
    setAuth) convex_set_auth "$(jq -r '.token' <<<"$line")"; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    query|mutation|action)
      path=$(jq -r .path <<<"$line"); args=$(jq -c .args <<<"$line")
      # Capture the transport diagnostic without relying on /tmp: runtime images
      # are deliberately exercised with a read-only filesystem.
      if result=$("convex_$op" "$path" "$args" 2>&1); then send --arg id "$id" --argjson value "$result" --argjson logs '[]' '{id:$id,type:"result",value:$value,logs:$logs}'; else failure "$id" "$result"; fi ;;
    close) send --arg id "$id" '{id:$id,type:"closed"}'; exit 0 ;;
    subscribe)
      [[ -n ${LIVE_FD:-} ]] || live_connect
      path=$(jq -r .path <<<"$line"); args=$(jq -c .args <<<"$line"); sub=$(jq -r .subscriptionId <<<"$line")
      # Replacing an id performs Remove before Add so same-id errors recover.
      for q in "${!LIVE_SUB[@]}"; do [[ ${LIVE_SUB[$q]} = "$sub" ]] && live_remove "$q"; done
      q=$next_query; ((next_query++)) || true; live_add "$q" "$sub" "$path" "$args"; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    unsubscribe)
      sub=$(jq -r .subscriptionId <<<"$line"); for q in "${!LIVE_SUB[@]}"; do [[ ${LIVE_SUB[$q]} = "$sub" ]] && live_remove "$q"; done; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    debugDisconnect)
      live_disconnect; sleep 0.1; live_connect; send --arg id "$id" '{id:$id,type:"ack"}' ;;
    *) failure "$id" "unsupported operation $op" ;;
  esac
done
