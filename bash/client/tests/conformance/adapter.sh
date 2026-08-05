#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")/../.." && pwd)/convex.sh"

send() { jq -cn "$@"; }
failure() { local id=${1:-}; shift || true; jq -cn --arg id "$id" --arg message "$*" '{id:$id,type:"error",error:{name:"Error",message:$message}}'; }

while IFS= read -r line; do
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
    *) failure "$id" "unsupported operation $op" ;;
  esac
done
