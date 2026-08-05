#!/usr/bin/env bash
# A deliberately small Convex JSON HTTP client. jq is used for JSON correctness,
# while all Convex-specific request and response behaviour stays in Bash.

set -euo pipefail

CONVEX_AUTH_TOKEN=${CONVEX_AUTH_TOKEN:-}
CONVEX_CLIENT_VERSION=${CONVEX_CLIENT_VERSION:-bash-0.1.0}
CONVEX_MAX_RESPONSE_BYTES=2097152

require_convex_url() {
	: "${CONVEX_URL:?CONVEX_URL is required}"
	case "$CONVEX_URL" in http://* | https://*) ;; *)
		echo 'CONVEX_URL must be http(s)' >&2
		return 2
		;;
	esac
}

convex_set_auth() { CONVEX_AUTH_TOKEN=$1; }

_convex_call() {
	local operation=$1 path=$2 args=$3 body response response_envelope transport_status LC_ALL=C auth=()
	require_convex_url
	printf '%s\n' "$args" | jq -e 'type == "object"' >/dev/null || {
		echo 'Convex args must be a named JSON object' >&2
		return 2
	}
	# Keep request JSON on stdin. Linux limits each exec argument to much less
	# than our 2 MiB protocol bound, so --argjson would reject valid large args.
	body=$(printf '%s\n' "$args" | jq -c --arg path "$path" '{path:$path,args:.,format:"json"}')
	if [[ -n $CONVEX_AUTH_TOKEN ]]; then auth=(--header="Authorization: Bearer $CONVEX_AUTH_TOKEN"); fi
	# A raw record-separator byte cannot occur in valid JSON. Append wget's exit
	# status after one, then read only enough bytes to enforce the response limit
	# before the payload ever becomes a Bash variable.
	response_envelope=
	LC_ALL=C IFS= read -r -N "$((CONVEX_MAX_RESPONSE_BYTES + 5))" response_envelope < <(
		set +e
		printf %s "$body" | wget -qO- --timeout=15 --header='Content-Type: application/json' --header="Convex-Client: $CONVEX_CLIENT_VERSION" "${auth[@]}" --post-file=/dev/stdin "${CONVEX_URL%/}/api/$operation"
		printf '\036%s' "$?"
	) || true
	[[ $response_envelope == *$'\036'* ]] || {
		echo "$operation response exceeds 2 MiB" >&2
		return 1
	}
	transport_status=${response_envelope##*$'\036'}
	response=${response_envelope%$'\036'*}
	[[ $transport_status =~ ^[0-9]+$ ]] || {
		echo "$operation returned an invalid transport status" >&2
		return 1
	}
	((transport_status == 0)) || {
		echo "$operation transport failed" >&2
		return 1
	}
	((${#response} <= CONVEX_MAX_RESPONSE_BYTES)) || {
		echo "$operation response exceeds 2 MiB" >&2
		return 1
	}
	if printf '%s\n' "$response" | jq -e '.status == "success" and has("value")' >/dev/null; then
		printf '%s\n' "$response" | jq -c '{value,logs:(.logLines // [])}'
		return
	fi
	if printf '%s\n' "$response" | jq -e '.status == "error"' >/dev/null; then
		printf '%s\n' "$response" | jq -c '{name:"FunctionError",message:(.errorMessage // "Convex function failed"),data:(.errorData // null),logs:(.logLines // [])}' >&2
		return 1
	fi
	echo 'Convex returned an unknown JSON response' >&2
	return 1
}

convex_query() { _convex_call query "$@" | jq -c .value; }
convex_mutation() { _convex_call mutation "$@" | jq -c .value; }
convex_action() { _convex_call action "$@" | jq -c .value; }

# Convex JSON numbers are represented as decimals. Teaching examples need a
# stable whole-number transcript, including the valid 0.0 representation.
convex_whole_number() {
	printf '%s\n' "$1" | jq -er 'if type == "number" and floor == . then tostring | sub("\\.0$"; "") else error("expected a whole JSON number") end'
}
