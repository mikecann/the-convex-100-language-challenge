#!/bin/sh
set -eu

adapter=${ADAPTER_BINARY:-/out/convex-adapter}
fixture=${PROCESS_FIXTURE_BINARY:-/out/convex-process-fixture}
backend_pid=
adapter_pid=

cleanup() {
  if [ -n "$adapter_pid" ]; then kill "$adapter_pid" 2>/dev/null || true; fi
  if [ -n "$backend_pid" ]; then kill "$backend_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

"$fixture" backend &
backend_pid=$!
sleep 1
CONVEX_URL=http://127.0.0.1:19091 ADAPTER_LISTEN=127.0.0.1:19092 "$adapter" &
adapter_pid=$!
"$fixture" controller
wait "$adapter_pid"
adapter_pid=

echo "PASS actual adapter TCP malformed/HTTP recovery/replace/unsubscribe/reconnect"
