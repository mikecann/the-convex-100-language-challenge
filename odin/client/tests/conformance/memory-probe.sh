#!/bin/sh
set -eu

# This target is intentionally run, not merely built:
#   docker build --platform linux/amd64 --target memory-probe -t odin-memory-probe odin
#   docker run --rm --memory=128m --memory-swap=128m --pids-limit=64 odin-memory-probe
# The cgroup assertion makes an uncapped run fail instead of producing false
# confidence from a host with abundant memory.
limit=$(cat /sys/fs/cgroup/memory.max)
if [ "$limit" = max ] || [ "$limit" -gt 134217728 ]; then
  echo "memory-probe requires a cgroup limit at or below 128 MiB" >&2
  exit 1
fi

adapter=${ADAPTER_BINARY:-/out/convex-adapter}
fixture=${PROCESS_FIXTURE_BINARY:-/out/convex-process-fixture}
backend_pid=
adapter_pid=
cleanup() {
  if [ -n "$adapter_pid" ]; then kill "$adapter_pid" 2>/dev/null || true; fi
  if [ -n "$backend_pid" ]; then kill "$backend_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

"$fixture" large-backend &
backend_pid=$!
sleep 1
CONVEX_URL=http://127.0.0.1:19091 ADAPTER_LISTEN=127.0.0.1:19092 "$adapter" &
adapter_pid=$!
timeout 30 "$fixture" stopped-controller
wait "$adapter_pid" || true
adapter_pid=

usage_file=/sys/fs/cgroup/memory.peak
if [ ! -r "$usage_file" ]; then usage_file=/sys/fs/cgroup/memory.current; fi
usage=$(cat "$usage_file")
if ! grep -q '^oom_kill 0$' /sys/fs/cgroup/memory.events; then
  echo "the cgroup killed a process for exceeding its memory limit" >&2
  exit 1
fi
if [ "$usage" -ge "$limit" ]; then
  echo "adapter reached its cgroup memory ceiling: $usage / $limit" >&2
  exit 1
fi
echo "PASS stopped TCP reader remained below cgroup limit: $usage / $limit"
