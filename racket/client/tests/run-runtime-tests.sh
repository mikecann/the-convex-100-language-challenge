#!/bin/sh

set -eu

server_pid=
adapter_pid=
monitor_pid=
watchdog_pid=

cleanup() {
  for process_id in "$watchdog_pid" "$monitor_pid" "$adapter_pid" "$server_pid"; do
    if test -n "$process_id"; then
      kill "$process_id" >/dev/null 2>&1 || true
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
  rm -f /tmp/racket-backpressure-*.log /tmp/racket-backpressure-*.state \
    /tmp/racket-barrier-*.log /tmp/racket-barrier-*.state
}
trap cleanup 0 1 2 15

# Exercise the compiled adapter's actual relay threads, not only the gate unit
# tests. The state file is a deterministic signal that a stale update has been
# dequeued and is paused immediately before publication.
rm -f /tmp/racket-barrier.state
/usr/local/bin/backpressure-fixture barrier-server \
  >/tmp/racket-barrier-server.log 2>&1 &
server_pid=$!

while ! grep -Fxq READY /tmp/racket-barrier-server.log; do
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    cat /tmp/racket-barrier-server.log >&2
    exit 1
  fi
  sleep 0.05
done

CONVEX_URL=http://127.0.0.1:9101 \
ADAPTER_LISTEN=127.0.0.1:9102 \
ADAPTER_TEST_RELAY_DELAY_MS=1000 \
ADAPTER_TEST_RELAY_STATE_FILE=/tmp/racket-barrier.state \
  /usr/local/bin/convex-adapter \
  >/tmp/racket-barrier-adapter.log 2>&1 &
adapter_pid=$!

(
  sleep 15
  printf '%s\n' "runtime acknowledgement-barrier test exceeded 15 seconds" \
    >/tmp/racket-barrier-failure.state
  kill "$adapter_pid" "$server_pid" >/dev/null 2>&1 || true
) &
watchdog_pid=$!

ADAPTER_HOST=127.0.0.1 \
RELAY_STATE_FILE=/tmp/racket-barrier.state \
  /usr/local/bin/backpressure-fixture barrier-controller \
  >/tmp/racket-barrier-controller.log 2>&1
wait "$adapter_pid"
adapter_pid=
wait "$server_pid"
server_pid=

kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" >/dev/null 2>&1 || true
watchdog_pid=

if test -e /tmp/racket-barrier-failure.state; then
  cat /tmp/racket-barrier-failure.state >&2
  exit 1
fi
if test -s /tmp/racket-barrier-adapter.log; then
  cat /tmp/racket-barrier-adapter.log >&2
  exit 1
fi
if test -s /tmp/racket-barrier-controller.log; then
  cat /tmp/racket-barrier-controller.log >&2
  exit 1
fi
printf '%s\n' "PASS compiled adapter unsubscribe and replacement barriers"

/usr/local/bin/backpressure-fixture server \
  >/tmp/racket-backpressure-server.log 2>&1 &
server_pid=$!

while ! grep -Fxq READY /tmp/racket-backpressure-server.log; do
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    cat /tmp/racket-backpressure-server.log >&2
    exit 1
  fi
  sleep 0.05
done

CONVEX_URL=http://127.0.0.1:9101 \
ADAPTER_LISTEN=127.0.0.1:9102 \
  /usr/local/bin/convex-adapter \
  >/tmp/racket-backpressure-adapter.log 2>&1 &
adapter_pid=$!

# Enforce the process side of the 128 MiB policy inside `./run test`. The
# separate final-image audit applies Docker's cgroup limit, while this catches a
# regression in the exact executable even when the repository test wrapper does
# not provide a per-container memory flag.
(
  peak_kib=0
  while kill -0 "$adapter_pid" >/dev/null 2>&1; do
    # The process can exit between kill -0 and opening status. Treat that as a
    # normal end-of-sample instead of making the monitor itself flaky.
    resident_kib=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$adapter_pid/status" \
      2>/dev/null || true)
    if test -n "$resident_kib" && test "$resident_kib" -gt "$peak_kib"; then
      peak_kib=$resident_kib
      printf '%s\n' "$peak_kib" >/tmp/racket-backpressure-peak.state
    fi
    if test -n "$resident_kib" && test "$resident_kib" -gt 131072; then
      printf '%s\n' "adapter RSS exceeded 128 MiB: ${resident_kib} KiB" \
        >/tmp/racket-backpressure-failure.state
      kill "$adapter_pid" >/dev/null 2>&1 || true
      exit 1
    fi
    sleep 0.05
  done
) &
monitor_pid=$!

# No fixture should be able to leave the Docker test hanging indefinitely.
(
  sleep 30
  printf '%s\n' "runtime backpressure test exceeded 30 seconds" \
    >/tmp/racket-backpressure-failure.state
  kill "$adapter_pid" "$server_pid" >/dev/null 2>&1 || true
) &
watchdog_pid=$!

ADAPTER_HOST=127.0.0.1 /usr/local/bin/backpressure-fixture controller \
  >/tmp/racket-backpressure-controller.log 2>&1
wait "$adapter_pid"
adapter_pid=
wait "$monitor_pid"
monitor_pid=

kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" >/dev/null 2>&1 || true
watchdog_pid=

if test -e /tmp/racket-backpressure-failure.state; then
  cat /tmp/racket-backpressure-failure.state >&2
  exit 1
fi
if test -s /tmp/racket-backpressure-adapter.log; then
  cat /tmp/racket-backpressure-adapter.log >&2
  exit 1
fi

peak_kib=$(cat /tmp/racket-backpressure-peak.state)
printf '%s\n' "PASS final adapter stopped-reader stress, peak RSS ${peak_kib} KiB"
