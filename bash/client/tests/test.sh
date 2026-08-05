#!/usr/bin/env bash
set -euo pipefail
trap 'printf "bash client test failed at line %s\n" "$LINENO" >&2' ERR
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
wait_for_listener() {
  local endpoint=$1 port=${1##*:}
  for _ in $(seq 1 100); do
    if netstat -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") { found=1 } END { exit(found ? 0 : 1) }'; then return 0; fi
    sleep 0.05
  done
  echo "listener did not become ready at $endpoint" >&2
  return 1
}
state=/tmp/bash-convex-fixture
mkdir -p "$state"; rm -f "$state/partial-sent"; : >"$state/ws.log"; : >"$state/frames.log"; : >"$state/server-frames.log"
BASH_FIXTURE_STATE=$state BASH_FIXTURE_TRACE=${BASH_FIXTURE_TRACE:-0} socat TCP-LISTEN:18080,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & fixture_pid=$!
bad_accept_state=/tmp/bash-convex-bad-accept; bad_upgrade_state=/tmp/bash-convex-bad-upgrade; no_terminator_state=/tmp/bash-convex-no-terminator
mkdir -p "$bad_accept_state" "$bad_upgrade_state" "$no_terminator_state"
BASH_FIXTURE_STATE=$bad_accept_state BASH_FIXTURE_HANDSHAKE=bad_accept socat TCP-LISTEN:18081,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & bad_accept_pid=$!
BASH_FIXTURE_STATE=$bad_upgrade_state BASH_FIXTURE_HANDSHAKE=bad_upgrade socat TCP-LISTEN:18082,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & bad_upgrade_pid=$!
BASH_FIXTURE_STATE=$no_terminator_state BASH_FIXTURE_HANDSHAKE=no_terminator socat TCP-LISTEN:18083,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & no_terminator_pid=$!
prefix_state=/tmp/bash-convex-prefix; mkdir -p "$prefix_state"; : >"$prefix_state/requests.log"
BASH_FIXTURE_STATE=$prefix_state BASH_FIXTURE_WS_PATH=/convex/api/sync socat TCP-LISTEN:18084,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & prefix_pid=$!
trap 'kill $fixture_pid $bad_accept_pid $bad_upgrade_pid $no_terminator_pid $prefix_pid ${outage_pid:-} ${tls_pid:-} ${adapter_pid:-} 2>/dev/null || true' EXIT
for endpoint in 127.0.0.1:18080 127.0.0.1:18081 127.0.0.1:18082 127.0.0.1:18083 127.0.0.1:18084; do wait_for_listener "$endpoint"; done
export CONVEX_URL=http://127.0.0.1:18080

source "$root/client/convex.sh"
source "$root/client/live.sh"
reset_live() { live_disconnect; LIVE_QUERY_SET=0; LIVE_CONNECTIONS=0; LIVE_LAST_CLOSE_REASON=InitialConnect; LIVE_RECONNECT_PENDING=0; LIVE_RECONNECT_DELAY_MS=$LIVE_RECONNECT_BASE_MS; LIVE_PATH=(); LIVE_ARGS=(); LIVE_SUB=(); LIVE_QUEUE=(); LIVE_LAST=(); LIVE_REHYDRATE=(); }

# Reject incomplete or forged RFC6455 upgrade responses.
CONVEX_URL=http://127.0.0.1:18081; if live_connect; then exit 1; fi
CONVEX_URL=http://127.0.0.1:18082; if live_connect; then exit 1; fi
CONVEX_URL=http://127.0.0.1:18083; if live_connect; then exit 1; fi

# Preserve a reverse proxy's deployment path in the RFC6455 request target.
CONVEX_URL=http://127.0.0.1:18084/convex; live_connect; live_disconnect
grep -Fx 'GET /convex/api/sync HTTP/1.1' "$prefix_state/requests.log" >/dev/null
reset_live

# WSS must validate both the issuing CA and the requested hostname.
tls_state=/tmp/bash-convex-tls; tls_dir=$tls_state/tls; mkdir -p "$tls_dir"
: >"$tls_state/large-sent"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Bash Fixture CA' -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$tls_dir/server.key" -out "$tls_dir/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$tls_dir/server.csr" -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial -extfile <(printf '%s\n' 'subjectAltName=DNS:localhost') -out "$tls_dir/server.crt" >/dev/null 2>&1
BASH_FIXTURE_STATE=$tls_state socat OPENSSL-LISTEN:18443,reuseaddr,fork,cert="$tls_dir/server.crt",key="$tls_dir/server.key",verify=0 EXEC:"bash $root/client/tests/fixture.sh" & tls_pid=$!
wait_for_listener 0.0.0.0:18443
CONVEX_URL=https://localhost:18443 CONVEX_CA_FILE=$tls_dir/ca.crt live_connect
live_add 0 tls demo:state '{"room":"tls-room"}'
tls_value=$(live_next_value 0); test "$(jq -r .count <<<"$tls_value")" = 0
live_disconnect
CONVEX_URL=https://127.0.0.1:18443 CONVEX_CA_FILE=$tls_dir/ca.crt; if live_connect; then exit 1; fi
CONVEX_URL=https://localhost:18443 CONVEX_CA_FILE=/etc/ssl/certs/ca-certificates.crt; if live_connect; then exit 1; fi

# Match the shared harness topology: TCP controller -> adapter -> WSS backend.
ADAPTER_LISTEN=127.0.0.1:19096 CONVEX_URL=https://localhost:18443 CONVEX_CA_FILE=$tls_dir/ca.crt /usr/local/bin/convex-adapter & adapter_pid=$!
wait_for_listener 127.0.0.1:19096; exec {tls_adapter_fd}<>/dev/tcp/127.0.0.1/19096
printf '%s\n' '{"id":"tls-sub","op":"subscribe","subscriptionId":"tls","path":"demo:state","args":{"room":"tls-adapter-room"}}' >&"$tls_adapter_fd"
IFS= read -r -t 5 event <&"$tls_adapter_fd"; jq -e '.id=="tls-sub" and .type=="ack"' <<<"$event" >/dev/null
IFS= read -r -t 5 event <&"$tls_adapter_fd"; jq -e '.type=="subscription" and .subscriptionId=="tls" and .value.count==0' <<<"$event" >/dev/null
printf '%s\n' '{"id":"tls-close","op":"close"}' >&"$tls_adapter_fd"; IFS= read -r -t 5 event <&"$tls_adapter_fd"
jq -e '.id=="tls-close" and .type=="closed"' <<<"$event" >/dev/null; wait "$adapter_pid"; unset adapter_pid
reset_live
export CONVEX_URL=http://127.0.0.1:18080

value='{"unicode":"Hello, 世界 👋","nested":{"number":42.5,"nil":null}}'
test "$(convex_query demo:echo "$(jq -cn --argjson value "$value" '{value:$value}')")" = "$value"
for invalid_args in '[]' 'true' 'null' '"text"'; do
  if _convex_call query demo:echo "$invalid_args" >/dev/null 2>"$state/invalid-args.err"; then exit 1; fi
  grep -F 'named JSON object' "$state/invalid-args.err" >/dev/null
done
if live_add 99 invalid demo:state '[]' >/dev/null 2>"$state/invalid-live-args.err"; then exit 1; fi
grep -F 'named JSON object' "$state/invalid-live-args.err" >/dev/null
if _convex_call query fixture:largeResponse '{}' >/dev/null 2>"$state/large-response.err"; then exit 1; fi
grep -F 'response exceeds 2 MiB' "$state/large-response.err" >/dev/null
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

# Feed a peer close frame through the real parser and inspect its masked reply.
printf '\210\002\003\350' >"$state/server-close.bin"
exec {close_in}<"$state/server-close.bin"; exec {close_out}>"$state/client-close.bin"
LIVE_IN=$close_in; LIVE_FD=$close_out; close_status=0; live_read 2 >/dev/null || close_status=$?; test "$close_status" = 3
eval "exec ${close_in}<&-"; eval "exec ${close_out}>&-"; LIVE_IN=; LIVE_FD=
read -r close_first close_second < <(od -An -tu1 -N2 "$state/client-close.bin")
test "$close_first" = 136; test $((close_second&128)) = 128

# Two individually valid fragments must not bypass the aggregate 2 MiB bound.
fragment_size=1048577
{
  printf '\001\177\000\000\000\000\000\020\000\001'; dd if=/dev/zero bs="$fragment_size" count=1 status=none | tr '\0' x
  printf '\200\177\000\000\000\000\000\020\000\001'; dd if=/dev/zero bs="$fragment_size" count=1 status=none | tr '\0' x
} >"$state/oversized-fragments.bin"
exec {fragment_in}<"$state/oversized-fragments.bin"; exec {fragment_out}>/dev/null
LIVE_IN=$fragment_in; LIVE_FD=$fragment_out; fragment_status=0; live_read 5 >/dev/null 2>"$state/fragment.err" || fragment_status=$?
test "$fragment_status" = 2; grep -F 'message exceeds 2 MiB' "$state/fragment.err" >/dev/null
eval "exec ${fragment_in}<&-"; eval "exec ${fragment_out}>&-"; LIVE_IN=; LIVE_FD=

# TCP mode must accept a controller immediately and preserve structured events.
ADAPTER_LISTEN=127.0.0.1:19090 CONVEX_URL=$CONVEX_URL ADAPTER_DIAGNOSTIC_FILE=$state/adapter.err ADAPTER_TRACE_FILE=${ADAPTER_TRACE_FILE:-} /usr/local/bin/convex-adapter & adapter_pid=$!
wait_for_listener 127.0.0.1:19090
exec {tcp_fd}<>/dev/tcp/127.0.0.1/19090
send_command() { printf '%s\n' "$1" >&"$tcp_fd"; }
next_event() { local event; IFS= read -r -t 5 event <&"$tcp_fd"; printf '%s\n' "$event"; }
next_for_id() { local wanted=$1 event; for _ in $(seq 1 64); do event=$(next_event); [[ $(jq -r '.id // ""' <<<"$event") = "$wanted" ]] && { printf '%s\n' "$event"; return; }; done; return 1; }
send_command '{"protocolVersion":1,"id":"hello","op":"hello"}'; jq -e '.type=="ready" and .language=="bash"' <<<"$(next_event)" >/dev/null
send_command "$(jq -cn --argjson value "$value" '{id:"echo",op:"query",path:"demo:echo",args:{value:$value}}')"; jq -e '.type=="result" and .value.unicode=="Hello, 世界 👋" and (.logs|length)==1' <<<"$(next_event)" >/dev/null
send_command '{"id":"fail","op":"query","path":"demo:fail","args":{"code":"EXPECTED"}}'; jq -e '.type=="error" and .error.data.code=="EXPECTED" and (.logs|length)==1' <<<"$(next_event)" >/dev/null
send_command '{"id":"sub","op":"subscribe","subscriptionId":"same","path":"demo:requiresNonzero","args":{"room":"fixture-room"}}'; test "$(jq -r .type <<<"$(next_event)")" = ack
event=$(next_event); jq -e '.type=="subscription" and .error.data.code=="ROOM_EMPTY"' <<<"$event" >/dev/null
send_command '{"id":"mut","op":"mutation","path":"demo:increment","args":{"room":"fixture-room","language":"Bash","runId":"fixture"}}'; jq -e '.type=="result" and .value.state.count==1' <<<"$(next_event)" >/dev/null
for _ in $(seq 1 20); do event=$(next_event); jq -e '.type=="subscription" and .value.count==1' <<<"$event" >/dev/null && break; done

# Use a clean room to prove reconnect rehydration does not leak a duplicate
# value between debugDisconnect's ACK and the next real backend change.
send_command '{"id":"drop-error","op":"unsubscribe","subscriptionId":"same"}'; test "$(jq -r .type <<<"$(next_for_id drop-error)")" = ack
send_command '{"id":"sub-reconnect","op":"subscribe","subscriptionId":"reconnect","path":"demo:state","args":{"room":"reconnect-room"}}'; test "$(jq -r .type <<<"$(next_for_id sub-reconnect)")" = ack
event=$(next_event); jq -e '.type=="subscription" and .value.count==0' <<<"$event" >/dev/null
for i in $(seq 1 5); do
  send_command "$(jq -cn --arg id "d$i" '{id:$id,op:"debugDisconnect"}')"
  test "$(jq -r .type <<<"$(next_event)")" = ack
  event=; if IFS= read -r -t 0.3 event <&"$tcp_fd"; then echo "unchanged reconnect replay leaked: $event" >&2; exit 1; fi
  increment=$(convex_mutation demo:increment "$(jq -cn --arg room reconnect-room --arg run "reconnect-$i" '{room:$room,language:"Bash",runId:$run}')")
  test "$(jq -r .state.count <<<"$increment")" = "$i"
  event=$(next_event); jq -e --argjson count "$i" '.type=="subscription" and .value.count==$count and (has("error")|not)' <<<"$event" >/dev/null || { echo "unexpected reconnect update: $event" >&2; exit 1; }
done
send_command '{"id":"unsub","op":"unsubscribe","subscriptionId":"reconnect"}'; test "$(jq -r .type <<<"$(next_for_id unsub)")" = ack
# The adapter ACKs after writing Remove; wait for the network fixture to record
# that frame before closing the socket and asserting the transport transcript.
for _ in $(seq 1 20); do [[ $(jq -s '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Remove")]|length' "$state/ws.log") -ge 2 ]] && break; sleep 0.05; done
send_command '{"id":"close","op":"close"}'; test "$(jq -r .type <<<"$(next_for_id close)")" = closed
wait "$adapter_pid"; unset adapter_pid
test ! -s "$state/adapter.err"

jq -se '[.[]|select(.type=="Connect")]|length >= 6' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="Connect")|.connectionCount] == [0,1,2,3,4,5]' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="Connect")|.lastCloseReason] == ["InitialConnect","DebugDisconnect","DebugDisconnect","DebugDisconnect","DebugDisconnect","DebugDisconnect"]' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Add")]|length == 7' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Remove")]|length == 2' "$state/ws.log" >/dev/null
jq -se 'all(.[]; .masked == true)' "$state/frames.log" >/dev/null
jq -se 'any(.[]; .opcode==10 and .masked)' "$state/frames.log" >/dev/null
jq -se 'any(.[]; .length>65535 and .lengthCode==127)' "$state/server-frames.log" >/dev/null
for _ in $(seq 1 40); do [[ $(grep -c '^peer-eof$' "$state/peer-eof.log" 2>/dev/null || true) -ge 5 ]] && break; sleep 0.05; done
test "$(grep -c '^peer-eof$' "$state/peer-eof.log")" -ge 5

# Seven failed replacement handshakes exceed the old finite retry budget. The
# active subscription must keep reconnecting and recover without blocking the
# controller connection or surfacing a permanent transport error.
outage_state=/tmp/bash-convex-outage; mkdir -p "$outage_state"; rm -f "$outage_state/handshake-attempts"; : >"$outage_state/ws.log"; : >"$outage_state/large-sent"
BASH_FIXTURE_STATE=$outage_state BASH_FIXTURE_FAIL_AFTER=1 BASH_FIXTURE_FAIL_HANDSHAKES=7 socat TCP-LISTEN:18085,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & outage_pid=$!
wait_for_listener 127.0.0.1:18085
ADAPTER_LISTEN=127.0.0.1:19095 CONVEX_URL=http://127.0.0.1:18085 BASH_LIVE_RECONNECT_BASE_MS=1 BASH_LIVE_RECONNECT_MAX_MS=2 /usr/local/bin/convex-adapter & adapter_pid=$!
wait_for_listener 127.0.0.1:19095; exec {outage_fd}<>/dev/tcp/127.0.0.1/19095
printf '%s\n' '{"id":"outage-sub","op":"subscribe","subscriptionId":"outage","path":"demo:state","args":{"room":"outage-room"}}' >&"$outage_fd"
IFS= read -r -t 5 event <&"$outage_fd"; test "$(jq -r .type <<<"$event")" = ack
IFS= read -r -t 5 event <&"$outage_fd"; jq -e '.type=="subscription" and .value.count==0' <<<"$event" >/dev/null
printf '%s\n' '{"id":"outage-drop","op":"debugDisconnect"}' >&"$outage_fd"
IFS= read -r -t 5 event <&"$outage_fd"; jq -e '.id=="outage-drop" and .type=="ack"' <<<"$event" >/dev/null
for _ in $(seq 1 100); do [[ $(jq -s '[.[]|select(.type=="Connect")]|length' "$outage_state/ws.log") -ge 2 ]] && break; sleep 0.05; done
test "$(cat "$outage_state/handshake-attempts")" -ge 9
jq -se '[.[]|select(.type=="Connect")|{connectionCount,lastCloseReason}] == [{"connectionCount":0,"lastCloseReason":"InitialConnect"},{"connectionCount":1,"lastCloseReason":"DebugDisconnect"}]' "$outage_state/ws.log" >/dev/null
outage_mutation=$(CONVEX_URL=http://127.0.0.1:18085 convex_mutation demo:increment '{"room":"outage-room","language":"Bash","runId":"outage"}')
test "$(jq -r .state.count <<<"$outage_mutation")" = 1
for _ in $(seq 1 20); do event=; IFS= read -r -t 1 event <&"$outage_fd" || true; [[ -n $event ]] && jq -e '.type=="subscription" and .subscriptionId=="outage" and .value.count==1' <<<"$event" >/dev/null && break; done
jq -e '.type=="subscription" and .value.count==1' <<<"$event" >/dev/null
printf '%s\n' '{"id":"outage-close","op":"close"}' >&"$outage_fd"; IFS= read -r -t 5 event <&"$outage_fd"
jq -e '.id=="outage-close" and .type=="closed"' <<<"$event" >/dev/null; wait "$adapter_pid"; unset adapter_pid

run_close_scenario() {
  local path=$1 port=$2 scenario_fd event started closed=0
  ADAPTER_LISTEN="127.0.0.1:$port" CONVEX_URL=$CONVEX_URL /usr/local/bin/convex-adapter & adapter_pid=$!
  wait_for_listener "127.0.0.1:$port"; exec {scenario_fd}<>"/dev/tcp/127.0.0.1/$port"
  printf '%s\n' "$(jq -cn --arg path "$path" '{id:"sub",op:"subscribe",subscriptionId:"busy",path:$path,args:{room:"busy-room"}}')" >&"$scenario_fd"
  IFS= read -r -t 5 event <&"$scenario_fd"; test "$(jq -r .type <<<"$event")" = ack
  started=$(date +%s); printf '%s\n' '{"id":"close-busy","op":"close"}' >&"$scenario_fd"
  while (( $(date +%s) - started < 2 )); do
    event=; IFS= read -r -t 0.2 event <&"$scenario_fd" || true
    [[ -n $event ]] && [[ $(jq -r .type <<<"$event") = closed ]] && { closed=1; break; }
  done
  test "$closed" = 1; wait "$adapter_pid"; unset adapter_pid
}

# Neither an endless stream nor a peer that sends one header byte and stalls
# may starve a TCP close command.
run_close_scenario fixture:continuous 19091
run_close_scenario fixture:stall 19092

# A peer resumes its partial frame after the deadline, while the adapter
# reconnects and receives a later complete update on the replacement socket.
ADAPTER_LISTEN=127.0.0.1:19094 CONVEX_URL=$CONVEX_URL /usr/local/bin/convex-adapter & adapter_pid=$!
wait_for_listener 127.0.0.1:19094; exec {partial_fd}<>/dev/tcp/127.0.0.1/19094
printf '%s\n' '{"id":"partial-sub","op":"subscribe","subscriptionId":"partial","path":"fixture:partial","args":{"room":"partial-room"}}' >&"$partial_fd"
IFS= read -r -t 5 event <&"$partial_fd"; test "$(jq -r .type <<<"$event")" = ack
recovered=0
for _ in $(seq 1 20); do event=; IFS= read -r -t 1 event <&"$partial_fd" || true; [[ -n $event ]] && jq -e '.type=="subscription" and .value.count==0' <<<"$event" >/dev/null && { recovered=1; break; }; done
test "$recovered" = 1
printf '%s\n' '{"id":"partial-close","op":"close"}' >&"$partial_fd"
for _ in $(seq 1 20); do IFS= read -r -t 1 event <&"$partial_fd"; [[ $(jq -r '.id // ""' <<<"$event") = partial-close ]] && break; done
test "$(jq -r .type <<<"$event")" = closed; wait "$adapter_pid"; unset adapter_pid
jq -se 'any(.[]; .type=="Connect" and .lastCloseReason=="TransportError")' "$state/ws.log" >/dev/null

# The TCP adapter must bind the requested address, not every interface sharing
# the requested port.
ADAPTER_LISTEN=127.0.0.2:19093 CONVEX_URL=$CONVEX_URL /usr/local/bin/convex-adapter & adapter_pid=$!
wait_for_listener 127.0.0.2:19093
if { exec {wrong_bind_fd}<>/dev/tcp/127.0.0.1/19093; } 2>/dev/null; then exit 1; fi
exec {bound_fd}<>/dev/tcp/127.0.0.2/19093
printf '%s\n' '{"id":"bound-close","op":"close"}' >&"$bound_fd"; IFS= read -r -t 2 event <&"$bound_fd"
jq -e '.id=="bound-close" and .type=="closed"' <<<"$event" >/dev/null; wait "$adapter_pid"; unset adapter_pid

# Execute the canonical source against the real HTTP/WebSocket fixture.
mapfile -t example_lines < <(CONVEX_URL=$CONVEX_URL bash "$root/examples/basics/main.sh" fixture-example)
test "${#example_lines[@]}" = 6
test "${example_lines[5]}" = 'verified count: 0 -> 1'

# A reused room must fail before mutation instead of presenting a 1 -> 2 run as
# the canonical transcript.
reused_room=fixture-example-reused; reused_key=$(printf %s "$reused_room" | sha256sum | cut -d' ' -f1); printf 1 >"$state/$reused_key"
if reused_output=$(CONVEX_URL=$CONVEX_URL bash "$root/examples/basics/main.sh" "$reused_room" 2>"$state/reused-example.err"); then exit 1; fi
test -z "$reused_output"; grep -F 'expected room to start at 0, got 1' "$state/reused-example.err" >/dev/null
test "$(cat "$state/$reused_key")" = 1

# Closing stdin while no Live bytes arrive must not leave a blocked reader.
timeout 2 bash "$root/client/tests/conformance/adapter.sh" <<<'{"id":"close","op":"close"}' | jq -e '.type=="closed"' >/dev/null
printf '%s\n' 'PASS Bash HTTP, RFC6455, queue, reconnect, and TCP fixtures'
