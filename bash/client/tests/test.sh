#!/usr/bin/env bash
set -euo pipefail
trap 'printf "bash client test failed at line %s\n" "$LINENO" >&2' ERR
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
state=/tmp/bash-convex-fixture
mkdir -p "$state"; rm -f "$state/partial-sent"; : >"$state/ws.log"; : >"$state/frames.log"; : >"$state/server-frames.log"
BASH_FIXTURE_STATE=$state BASH_FIXTURE_TRACE=${BASH_FIXTURE_TRACE:-0} socat TCP-LISTEN:18080,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & fixture_pid=$!
bad_accept_state=/tmp/bash-convex-bad-accept; bad_upgrade_state=/tmp/bash-convex-bad-upgrade; no_terminator_state=/tmp/bash-convex-no-terminator
mkdir -p "$bad_accept_state" "$bad_upgrade_state" "$no_terminator_state"
BASH_FIXTURE_STATE=$bad_accept_state BASH_FIXTURE_HANDSHAKE=bad_accept socat TCP-LISTEN:18081,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & bad_accept_pid=$!
BASH_FIXTURE_STATE=$bad_upgrade_state BASH_FIXTURE_HANDSHAKE=bad_upgrade socat TCP-LISTEN:18082,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & bad_upgrade_pid=$!
BASH_FIXTURE_STATE=$no_terminator_state BASH_FIXTURE_HANDSHAKE=no_terminator socat TCP-LISTEN:18083,reuseaddr,fork EXEC:"bash $root/client/tests/fixture.sh" & no_terminator_pid=$!
trap 'kill $fixture_pid $bad_accept_pid $bad_upgrade_pid $no_terminator_pid ${tls_pid:-} ${adapter_pid:-} 2>/dev/null || true' EXIT
sleep 0.1
export CONVEX_URL=http://127.0.0.1:18080

source "$root/client/convex.sh"
source "$root/client/live.sh"
reset_live() { live_disconnect; LIVE_QUERY_SET=0; LIVE_CONNECTIONS=0; LIVE_PATH=(); LIVE_ARGS=(); LIVE_SUB=(); LIVE_QUEUE=(); LIVE_LAST=(); LIVE_REHYDRATE=(); }

# Reject incomplete or forged RFC6455 upgrade responses.
CONVEX_URL=http://127.0.0.1:18081; if live_connect; then exit 1; fi
CONVEX_URL=http://127.0.0.1:18082; if live_connect; then exit 1; fi
CONVEX_URL=http://127.0.0.1:18083; if live_connect; then exit 1; fi

# WSS must validate both the issuing CA and the requested hostname.
tls_state=/tmp/bash-convex-tls; tls_dir=$tls_state/tls; mkdir -p "$tls_dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Bash Fixture CA' -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$tls_dir/server.key" -out "$tls_dir/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$tls_dir/server.csr" -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial -extfile <(printf '%s\n' 'subjectAltName=DNS:localhost') -out "$tls_dir/server.crt" >/dev/null 2>&1
BASH_FIXTURE_STATE=$tls_state socat OPENSSL-LISTEN:18443,reuseaddr,fork,cert="$tls_dir/server.crt",key="$tls_dir/server.key",verify=0 EXEC:"bash $root/client/tests/fixture.sh" & tls_pid=$!
sleep 0.1
CONVEX_URL=https://localhost:18443 CONVEX_CA_FILE=$tls_dir/ca.crt live_connect; live_disconnect
CONVEX_URL=https://127.0.0.1:18443 CONVEX_CA_FILE=$tls_dir/ca.crt; if live_connect; then exit 1; fi
CONVEX_URL=https://localhost:18443 CONVEX_CA_FILE=/etc/ssl/certs/ca-certificates.crt; if live_connect; then exit 1; fi
reset_live
export CONVEX_URL=http://127.0.0.1:18080

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

# Feed a peer close frame through the real parser and inspect its masked reply.
printf '\210\002\003\350' >"$state/server-close.bin"
exec {close_in}<"$state/server-close.bin"; exec {close_out}>"$state/client-close.bin"
LIVE_IN=$close_in; LIVE_FD=$close_out; close_status=0; live_read 2 >/dev/null || close_status=$?; test "$close_status" = 3
eval "exec ${close_in}<&-"; eval "exec ${close_out}>&-"; LIVE_IN=; LIVE_FD=
read -r close_first close_second < <(od -An -tu1 -N2 "$state/client-close.bin")
test "$close_first" = 136; test $((close_second&128)) = 128

# TCP mode must accept a controller immediately and preserve structured events.
ADAPTER_LISTEN=127.0.0.1:19090 CONVEX_URL=$CONVEX_URL ADAPTER_DIAGNOSTIC_FILE=$state/adapter.err ADAPTER_TRACE_FILE=${ADAPTER_TRACE_FILE:-} /usr/local/bin/convex-adapter & adapter_pid=$!
sleep 0.2
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
send_command '{"id":"close","op":"close"}'; test "$(jq -r .type <<<"$(next_for_id close)")" = closed
wait "$adapter_pid"; unset adapter_pid
test ! -s "$state/adapter.err"

jq -se '[.[]|select(.type=="Connect")]|length >= 6' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="Connect")|.connectionCount] == [0,1,2,3,4,5]' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Add")]|length == 7' "$state/ws.log" >/dev/null
jq -se '[.[]|select(.type=="ModifyQuerySet")|.modifications[]|select(.type=="Remove")]|length == 2' "$state/ws.log" >/dev/null
jq -se 'all(.[]; .masked == true)' "$state/frames.log" >/dev/null
jq -se 'any(.[]; .opcode==10 and .masked)' "$state/frames.log" >/dev/null
jq -se 'any(.[]; .length>65535 and .lengthCode==127)' "$state/server-frames.log" >/dev/null

run_close_scenario() {
  local path=$1 port=$2 scenario_fd event started closed=0
  ADAPTER_LISTEN="127.0.0.1:$port" CONVEX_URL=$CONVEX_URL /usr/local/bin/convex-adapter & adapter_pid=$!
  sleep 0.2; exec {scenario_fd}<>"/dev/tcp/127.0.0.1/$port"
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
sleep 0.2; exec {partial_fd}<>/dev/tcp/127.0.0.1/19094
printf '%s\n' '{"id":"partial-sub","op":"subscribe","subscriptionId":"partial","path":"fixture:partial","args":{"room":"partial-room"}}' >&"$partial_fd"
IFS= read -r -t 5 event <&"$partial_fd"; test "$(jq -r .type <<<"$event")" = ack
recovered=0
for _ in $(seq 1 20); do event=; IFS= read -r -t 1 event <&"$partial_fd" || true; [[ -n $event ]] && jq -e '.type=="subscription" and .value.count==0' <<<"$event" >/dev/null && { recovered=1; break; }; done
test "$recovered" = 1
printf '%s\n' '{"id":"partial-close","op":"close"}' >&"$partial_fd"
for _ in $(seq 1 20); do IFS= read -r -t 1 event <&"$partial_fd"; [[ $(jq -r '.id // ""' <<<"$event") = partial-close ]] && break; done
test "$(jq -r .type <<<"$event")" = closed; wait "$adapter_pid"; unset adapter_pid

# The TCP adapter must bind the requested address, not every interface sharing
# the requested port.
ADAPTER_LISTEN=127.0.0.2:19093 CONVEX_URL=$CONVEX_URL /usr/local/bin/convex-adapter & adapter_pid=$!
sleep 0.2
if { exec {wrong_bind_fd}<>/dev/tcp/127.0.0.1/19093; } 2>/dev/null; then exit 1; fi
exec {bound_fd}<>/dev/tcp/127.0.0.2/19093
printf '%s\n' '{"id":"bound-close","op":"close"}' >&"$bound_fd"; IFS= read -r -t 2 event <&"$bound_fd"
jq -e '.id=="bound-close" and .type=="closed"' <<<"$event" >/dev/null; wait "$adapter_pid"; unset adapter_pid

# Execute the canonical source against the real HTTP/WebSocket fixture.
mapfile -t example_lines < <(CONVEX_URL=$CONVEX_URL bash "$root/examples/basics/main.sh" fixture-example)
test "${#example_lines[@]}" = 6
test "${example_lines[5]}" = 'verified count: 0 -> 1'

# Closing stdin while no Live bytes arrive must not leave a blocked reader.
timeout 2 bash "$root/client/tests/conformance/adapter.sh" <<<'{"id":"close","op":"close"}' | jq -e '.type=="closed"' >/dev/null
printf '%s\n' 'PASS Bash HTTP, RFC6455, queue, reconnect, and TCP fixtures'
