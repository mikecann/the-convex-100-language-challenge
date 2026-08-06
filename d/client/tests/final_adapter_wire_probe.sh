#!/bin/bash
# All asserted lines below came from the real /out-adapter Output.writeLocked
# path, not JSON helper calls. Exact equality also proves omitted optionals do
# not become null fields on the wire.
set -euo pipefail

adapter_pid=
server_pid=
wire_server_log=/tmp/d-wire-server.log
wire_adapter_log=/tmp/d-wire-adapter.log
transport_gate=/tmp/d-live-transport-close

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if test -n "$adapter_pid"; then
        kill "$adapter_pid" >/dev/null 2>&1 || true
    fi
    if test -n "$server_pid"; then
        kill "$server_pid" >/dev/null 2>&1 || true
    fi
    if test "$status" -ne 0; then
        test ! -s "$wire_server_log" || cat "$wire_server_log" >&2
        test ! -s "$wire_adapter_log" || cat "$wire_adapter_log" >&2
    fi
    rm -f "$wire_server_log" "$wire_adapter_log" "$transport_gate"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
rm -f "$transport_gate"

expect_exact_line() {
    local expected_line=$1
    local actual_line
    if ! IFS= read -r actual_line <&4; then
        printf 'adapter output closed before expected wire line: %s\n' "$expected_line" >&2
        test ! -s "$wire_server_log" || cat "$wire_server_log" >&2
        test ! -s "$wire_adapter_log" || cat "$wire_adapter_log" >&2
        exit 1
    fi
    if test "$actual_line" != "$expected_line"; then
        printf 'unexpected adapter wire line\nexpected: %s\nactual:   %s\n' \
            "$expected_line" "$actual_line" >&2
        exit 1
    fi
    case "$actual_line" in
    *null*)
        printf 'optional adapter field was encoded as null: %s\n' "$actual_line" >&2
        exit 1
        ;;
    esac
}

/out-wire-adapter-server >"$wire_server_log" 2>&1 &
server_pid=$!
ADAPTER_LISTEN=127.0.0.1:18158 CONVEX_URL=http://127.0.0.1:18156 \
    /out-adapter 2>"$wire_adapter_log" &
adapter_pid=$!
sleep 0.1
exec 4<>/dev/tcp/127.0.0.1/18158
printf '%s\n' '{"id":"success","op":"query","path":"demo:state","args":{}}' >&4
expect_exact_line '{"id":"success","type":"result","value":{"count":1}}'
printf '%s\n' '{"id":"function-absent","op":"query","path":"demo:state","args":{}}' >&4
expect_exact_line '{"error":{"message":"function absent","name":"FunctionError"},"id":"function-absent","type":"error"}'
printf '%s\n' '{"id":"function-data","op":"query","path":"demo:state","args":{}}' >&4
expect_exact_line '{"error":{"data":{"code":"BAD"},"message":"function data","name":"FunctionError"},"id":"function-data","type":"error"}'
printf '%s\n' '{"id":"protocol","op":"unknown"}' >&4
expect_exact_line '{"error":{"message":"unknown adapter operation","name":"ProtocolError"},"id":"protocol","type":"error"}'
printf '%s\n' '{"id":"close","op":"close"}' >&4
expect_exact_line '{"id":"close","type":"closed"}'
exec 4>&-
wait "$adapter_pid"
adapter_pid=
wait "$server_pid"
server_pid=
rm -f "$wire_server_log" "$wire_adapter_log"

# A completed Live install followed by a WebSocket Close yields a deterministic
# subscription-scoped TransportError from the real adapter relay.
/out-live-transport-error-server >"$wire_server_log" 2>&1 &
server_pid=$!
ADAPTER_LISTEN=127.0.0.1:18161 CONVEX_URL=http://127.0.0.1:18160 \
    /out-adapter 2>"$wire_adapter_log" &
adapter_pid=$!
sleep 0.1
exec 4<>/dev/tcp/127.0.0.1/18161
printf '%s\n' '{"id":"transport-subscribe","op":"subscribe","subscriptionId":"transport-sub","path":"demo:state","args":{}}' >&4
expect_exact_line '{"id":"transport-subscribe","type":"ack"}'
touch "$transport_gate"
expect_exact_line '{"error":{"message":"server closed Live WebSocket","name":"TransportError"},"subscriptionId":"transport-sub","type":"subscription"}'
printf '%s\n' '{"id":"close","op":"close"}' >&4
expect_exact_line '{"id":"close","type":"closed"}'
exec 4>&-
wait "$adapter_pid"
adapter_pid=
wait "$server_pid"
server_pid=

/out-live-wire-error-server >"$wire_server_log" 2>&1 &
server_pid=$!
ADAPTER_LISTEN=127.0.0.1:18159 CONVEX_URL=http://127.0.0.1:18157 \
    /out-adapter 2>"$wire_adapter_log" &
adapter_pid=$!
sleep 0.1
exec 4<>/dev/tcp/127.0.0.1/18159
printf '%s\n' '{"id":"subscribe","op":"subscribe","subscriptionId":"sub","path":"demo:state","args":{}}' >&4
expect_exact_line '{"id":"subscribe","type":"ack"}'
expect_exact_line '{"error":{"message":"subscription failed","name":"FunctionError"},"subscriptionId":"sub","type":"subscription"}'
printf '%s\n' '{"id":"close","op":"close"}' >&4
expect_exact_line '{"id":"close","type":"closed"}'
exec 4>&-
wait "$adapter_pid"
adapter_pid=
wait "$server_pid"
server_pid=

printf '%s\n' 'final adapter wire probe: exact NDJSON envelopes observed'
