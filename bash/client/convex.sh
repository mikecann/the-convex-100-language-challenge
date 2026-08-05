#!/usr/bin/env bash
# A deliberately small Convex JSON HTTP client. jq is used for JSON correctness,
# while all Convex-specific request and response behaviour stays in Bash.

set -euo pipefail

CONVEX_AUTH_TOKEN=${CONVEX_AUTH_TOKEN:-}
CONVEX_CLIENT_VERSION=${CONVEX_CLIENT_VERSION:-bash-0.1.0}

require_convex_url() {
  : "${CONVEX_URL:?CONVEX_URL is required}"
  case "$CONVEX_URL" in http://*|https://*) ;; *) echo 'CONVEX_URL must be http(s)' >&2; return 2;; esac
}

convex_set_auth() { CONVEX_AUTH_TOKEN=$1; }

_convex_call() {
  local operation=$1 path=$2 args=$3 body response auth=()
  require_convex_url
  jq -e . >/dev/null <<<"$args" || { echo 'Convex args must be JSON' >&2; return 2; }
  body=$(jq -cn --arg path "$path" --argjson args "$args" '{path:$path,args:$args,format:"json"}')
  if [[ -n $CONVEX_AUTH_TOKEN ]]; then auth=(--header="Authorization: Bearer $CONVEX_AUTH_TOKEN"); fi
  response=$(wget -qO- --timeout=15 --header='Content-Type: application/json' --header="Convex-Client: $CONVEX_CLIENT_VERSION" "${auth[@]}" --post-data="$body" "${CONVEX_URL%/}/api/$operation") || { echo "$operation transport failed" >&2; return 1; }
  if jq -e '.status == "success" and has("value")' >/dev/null <<<"$response"; then jq -c '{value,logs:(.logLines // [])}' <<<"$response"; return; fi
  if jq -e '.status == "error"' >/dev/null <<<"$response"; then jq -c '{name:"FunctionError",message:(.errorMessage // "Convex function failed"),data:(.errorData // null),logs:(.logLines // [])}' <<<"$response" >&2; return 1; fi
  echo 'Convex returned an unknown JSON response' >&2; return 1
}

convex_query() { _convex_call query "$@" | jq -c .value; }
convex_mutation() { _convex_call mutation "$@" | jq -c .value; }
convex_action() { _convex_call action "$@" | jq -c .value; }
