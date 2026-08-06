#!/bin/sh
set -eu

# Run one Zig test command against a real TLS 1.2+ WebSocket peer. OpenSSL is
# only a byte-level test fixture here; the Zig client still performs the TLS
# handshake, certificate and hostname verification, HTTP 101 validation, and
# WebSocket parsing itself.
test "$#" -gt 0
fixture_dir=$(mktemp -d)
port=${ZIG_TLS_FIXTURE_PORT:-32102}
server_pid=
responder_pid=

cleanup() {
  test -z "$responder_pid" || kill "$responder_pid" 2>/dev/null || true
  test -z "$server_pid" || kill "$server_pid" 2>/dev/null || true
  rm -rf "$fixture_dir"
}
trap cleanup EXIT INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost \
  -keyout "$fixture_dir/server.key" \
  -out "$fixture_dir/server.crt" >/dev/null 2>&1

mkfifo "$fixture_dir/to-server" "$fixture_dir/from-server"
# Holding both FIFOs open read/write prevents the server and responder from
# deadlocking while each side opens its first endpoint.
exec 3<>"$fixture_dir/to-server"
exec 4<>"$fixture_dir/from-server"
openssl s_server -quiet -4 -naccept 1 -accept "$port" \
  -cert "$fixture_dir/server.crt" -key "$fixture_dir/server.key" \
  <&3 >&4 2>"$fixture_dir/server.log" &
server_pid=$!

respond() {
  websocket_key=
  while IFS= read -r line <&4; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in
      Sec-WebSocket-Key:*) websocket_key=${line#*: } ;;
      '') break ;;
    esac
  done
  test -n "$websocket_key"
  websocket_accept=$(printf '%s' "${websocket_key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" |
    openssl dgst -sha1 -binary | openssl base64 -A)
  # One write encourages OpenSSL to coalesce the upgrade and both data frames
  # into one application record, proving readiness sees buffered TLS plaintext.
  printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n\201\003one\201\003two' \
    "$websocket_accept" >&3
}
respond &
responder_pid=$!

ZIG_TLS_FIXTURE_CA="$fixture_dir/server.crt" \
  ZIG_TLS_FIXTURE_PORT="$port" \
  "$@"
wait "$responder_pid"
responder_pid=
