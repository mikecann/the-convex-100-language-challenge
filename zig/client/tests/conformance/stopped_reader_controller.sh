#!/bin/sh
set -eu

adapter_host=${ADAPTER_HOST:-zig-memory-adapter}
connect_attempts=${ADAPTER_CONNECT_ATTEMPTS:-100}
nc_pid=
reader_pid=

cleanup_controller() {
  test -z "$reader_pid" || kill "$reader_pid" 2>/dev/null || true
  test -z "$nc_pid" || kill "$nc_pid" 2>/dev/null || true
}
trap cleanup_controller EXIT INT TERM

mkfifo /tmp/controller-input /tmp/controller-output
(
  attempts=0
  while [ "$attempts" -lt "$connect_attempts" ]; do
    if nc "$adapter_host" 32100; then
      exit 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  exit 1
) </tmp/controller-input >/tmp/controller-output &
nc_pid=$!
exec 3>/tmp/controller-input
exec 4</tmp/controller-output

printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' >&3
if ! IFS= read -r ready <&4; then
  printf 'controller cause=early EOF waiting for ready adapter_host=%s nc_pid=%s\n' "$adapter_host" "$nc_pid" >&2
  exit 1
fi
printf '%s\n' "$ready" | grep -q '"type":"ready"'
printf '%s\n' '{"id":"subscribe","op":"subscribe","subscriptionId":"memory","path":"demo:state","args":{"room":"memory"}}' >&3
if ! IFS= read -r ack <&4; then
  printf 'controller cause=early EOF waiting for subscribe ack adapter_host=%s nc_pid=%s\n' "$adapter_host" "$nc_pid" >&2
  exit 1
fi
printf '%s\n' "$ack" | grep -q '"type":"ack"'

# Keep the TCP receive window and FIFO full for long enough to sample fresh RSS.
hold_ticks=0
while test "$hold_ticks" -lt 200; do
  if test ! -r "/proc/$nc_pid/status" || test "$(awk '$1 == "State:" { print $2 }' "/proc/$nc_pid/status")" = Z; then
    closed_pid=$nc_pid
    nc_status=0
    wait "$nc_pid" || nc_status=$?
    nc_pid=
    printf 'controller cause=adapter stream closed during stopped-reader hold nc_pid=%s nc_status=%s\n' "$closed_pid" "$nc_status" >&2
    exit 1
  fi
  hold_ticks=$((hold_ticks + 1))
  sleep 0.1
done
events_file=/tmp/events
if [ -d /evidence ]; then
  events_file=/evidence/events.ndjson
fi
# The reader must not inherit fd 3, the FIFO write end feeding netcat. If it
# does, closing fd 3 in the controller never produces EOF for netcat: netcat
# waits for input while this reader waits for netcat's output, and an otherwise
# clean adapter close is misreported as a timeout.
cat <&4 3>&- >"$events_file" &
reader_pid=$!
sleep 3
printf '%s\n' '{"id":"close","op":"close"}' >&3
exec 3>&-
attempts=0
# A close queued while the owner is part-way through a maximum-size frame may
# first consume the final runtime's five-second frame deadline, then the
# output relay's one-second close grace. Ten seconds keeps that combined bound
# strict while leaving room for linux/amd64 emulation to schedule both workers.
while kill -0 "$nc_pid" 2>/dev/null && [ "$attempts" -lt 100 ]; do
  attempts=$((attempts + 1))
  sleep 0.1
done
if kill -0 "$nc_pid" 2>/dev/null; then
  kill "$nc_pid" 2>/dev/null || true
  exit 1
fi
wait "$nc_pid" 2>/dev/null || true
nc_pid=
exec 4<&-
# BusyBox cat reports the forced FIFO teardown as an error on some releases.
# The transcript assertions below, not that helper's exit status, decide whether
# the adapter delivered a complete and correctly ordered close sequence.
wait "$reader_pid" 2>/dev/null || true
reader_pid=

grep -q '"id":"close","type":"closed"' "$events_file"
grep -o '"sequence":[0-9]*' "$events_file" | cut -d: -f2 >/tmp/sequences
event_count=$(grep -c '"type":"subscription"' "$events_file")
encoded_bytes=$(wc -c <"$events_file" | tr -d ' ')
sequence_count=$(wc -l </tmp/sequences | tr -d ' ')
first_sequence=$(head -n 1 /tmp/sequences)
last_sequence=$(tail -n 1 /tmp/sequences)
printf 'stopped-reader observed events=%s bytes=%s first=%s last=%s\n' "$event_count" "$encoded_bytes" "$first_sequence" "$last_sequence" >&2
test "$sequence_count" -eq "$event_count"
test "$event_count" -le 16
# The drained transcript may contain one record already accepted by the TCP
# buffers plus the records still covered by Zig's reservation budget. It is a
# cumulative delivery bound, not a claim that all these bytes lived on Zig's
# heap at once. The independent 128 MiB cgroup probe measures that separately.
max_live_queue_bytes=$((8 * 1024 * 1024))
max_adapter_record_bytes=$((2 * 1024 * 1024 + 64 * 1024 + 1))
max_drained_transcript_bytes=$((max_live_queue_bytes + max_adapter_record_bytes))
test "$encoded_bytes" -le "$max_drained_transcript_bytes"
# With near-maximum records, the byte budget binds long before the sixteen
# event count: four can stay reserved while one has reached the TCP buffers.
test "$event_count" -le 5
test "$last_sequence" -eq 39
awk 'NR == 1 { previous = $1; next } $1 <= previous { exit 1 } { previous = $1 } END { if (NR == 0) exit 1 }' /tmp/sequences
if [ -d /evidence ]; then
  printf 'stopped-reader events=%s bytes=%s first=%s last=%s\n' "$event_count" "$encoded_bytes" "$first_sequence" "$last_sequence" >/evidence/summary.txt
fi
printf 'stopped-reader events=%s bytes=%s first=%s last=%s\n' "$event_count" "$encoded_bytes" "$first_sequence" "$last_sequence"
trap - EXIT INT TERM
