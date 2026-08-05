#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
state=/tmp/bash-convex-fixture
mkdir -p "$state"; : >"$state/ws.log"
BASH_FIXTURE_STATE=$state BASH_FIXTURE_TRACE=${BASH_FIXTURE_TRACE:-0} socat TCP-LISTEN:18080,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & fixture_pid=$!
trap 'kill $fixture_pid ${adapter_pid:-} 2>/dev/null || true' EXIT
sleep 0.1
export CONVEX_URL=http://127.0.0.1:18080

source "$root/client/convex.sh"
source "$root/client/live.sh"
value='{"unicode":"Hello, 世界 👋","nested":{"number":42.5,"nil":null}}'
test "$(convex_query demo:echo "$(jq -cn --argjson value "$value" '{value:$value}')")" = "$value"
if _convex_call query demo:fail '{"code":"EXPECTED"}' 2>"$state/error"; then exit 1; fi
jq -e '.data.code == "EXPECTED" and (.logs|length)==1' "$state/error" >/dev/null

# Queue overflow retains exactly the newest sixteen reactive values.
for i in $(seq 0 19); do live_queue_push 7 "$(jq -cn --argjson n "$i" '{value:$n}')"; done
test "$(jq length <<<"${LIVE_QUEUE[7]}")" = 16
test "$(jq -r '.[0].value' <<<"${LIVE_QUEUE[7]}")" = 4
test "$(jq -r '.[15].value' <<<"${LIVE_QUEUE[7]}")" = 19
unset 'LIVE_QUEUE[7]'
test "$(convex_whole_number '0.0')" = 0
if convex_whole_number '0.5' >/dev/null 2>&1; then exit 1; fi

# TCP mode must accept a controller immediately and preserve structured events.
ADAPTER_LISTEN=127.0.0.1:19090 CONVEX_URL=$CONVEX_URL ADAPTER_DIAGNOSTIC_FILE=$state/adapter.err ADAPTER_TRACE_FILE=${ADAPTER_TRACE_FILE:-} /usr/local/bin/convex-adapter & adapter_pid=$!
sleep 0.2
exec {tcp_fd}<>/dev/tcp/127.0.0.1/19090
send_command() { printf '%s\n' "$1" >&"$tcp_fd"; }
next_event() { local event; IFS= read -r -t 5 event <&"$tcp_fd"; printf '%s\n' "$event"; }
send_command '{"protocolVersion":1,"id":"hello","op":"hello"}'; jq -e '.type=="ready" and .language=="bash"' <<<"$(next_event)" >/dev/null
send_command "$(jq -cn --argjson value "$value" '{id:"echo",op:"query",path:"demo:echo",args:{value:$value}}')"; jq -e '.type=="result" and .value.unicode=="Hello, 世界 👋" and (.logs|length)==1' <<<"$(next_event)" >/dev/null
send_command '{"id":"fail","op":"query","path":"demo:fail","args":{"code":"EXPECTED"}}'; jq -e '.type=="error" and .error.data.code=="EXPECTED" and (.logs|length)==1' <<<"$(next_event)" >/dev/null
send_command '{"id":"sub","op":"subscribe","subscriptionId":"same","path":"demo:requiresNonzero","args":{"room":"fixture-room"}}'; test "$(jq -r .type <<<"$(next_event)")" = ack
event=$(next_event); jq -e '.type=="subscription" and .error.data.code=="ROOM_EMPTY"' <<<"$event" >/dev/null
send_command '{"id":"mut","op":"mutation","path":"demo:increment","args":{"room":"fixture-room","language":"Bash","runId":"fixture"}}'; jq -e '.type=="result" and .value.state.count==1' <<<"$(next_event)" >/dev/null
for _ in $(seq 1 20); do event=$(next_event); jq -e '.type=="subscription" and .value.count==1' <<<"$event" >/dev/null && break; done

for i in $(seq 1 5); do
  send_command "$(jq -cn --arg id "d$i" '{id:$id,op:"debugDisconnect"}')"
  test "$(jq -r .type <<<"$(next_event)")" = ack
  event=$(next_event)
  jq -e '.type=="subscription" and .value.count==1 and (has("error")|not)' <<<"$event" >/dev/null
done
send_command '{"id":"unsub","op":"unsubscribe","subscriptionId":"same"}'; test "$(jq -r .type <<<"$(next_event)")" = ack
send_command '{"id":"close","op":"close"}'; test "$(jq -r .type <<<"$(next_event)")" = closed
wait "$adapter_pid"; unset adapter_pid
test ! -s "$state/adapter.err"

jq -se '[.[]|select(.type=="Connect")]|length >= 6' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="Connect")|.connectionCount] == [0,1,2,3,4,5]' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Add")]|length == 6' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Remove")]|length == 1' "$state/ws.log" >/dev/null

# Execute the canonical source against the real HTTP/WebSocket fixture.
mapfile -t example_lines < <(CONVEX_URL=$CONVEX_URL bash "$root/examples/basics/main.sh" fixture-example)
test "${#example_lines[@]}" = 6
test "${example_lines[5]}" = 'verified count: 0 -> 1'

# Closing stdin while no Live bytes arrive must not leave a blocked reader.
timeout 2 bash "$root/client/tests/conformance/adapter.sh" <<<'{"id":"close","op":"close"}' | jq -e '.type=="closed"' >/dev/null
printf '%s\n' 'PASS Bash HTTP, RFC6455, queue, reconnect, and TCP fixtures'
