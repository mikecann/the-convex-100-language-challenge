#!/bin/sh
set -eu

mkfifo /tmp/controller-input /tmp/controller-output
nc zig-memory-adapter 32100 </tmp/controller-input >/tmp/controller-output &
nc_pid=$!
exec 3>/tmp/controller-input
exec 4</tmp/controller-output

printf '%s\n' '{"protocolVersion":1,"id":"hello","op":"hello"}' >&3
IFS= read -r ready <&4
printf '%s\n' "$ready" | grep -q '"type":"ready"'
printf '%s\n' '{"id":"subscribe","op":"subscribe","subscriptionId":"memory","path":"demo:state","args":{"room":"memory"}}' >&3
IFS= read -r ack <&4
printf '%s\n' "$ack" | grep -q '"type":"ack"'

# Keep the TCP receive window and FIFO full for long enough to sample fresh RSS.
sleep 20
events_file=/tmp/events
if [ -d /evidence ]; then
  events_file=/evidence/events.ndjson
fi
cat <&4 >"$events_file" &
reader_pid=$!
sleep 3
printf '%s\n' '{"id":"close","op":"close"}' >&3
exec 3>&-
sleep 2
kill "$nc_pid" 2>/dev/null || true
wait "$nc_pid" 2>/dev/null || true
exec 4<&-
# BusyBox cat reports the forced FIFO teardown as an error on some releases.
# The transcript assertions below, not that helper's exit status, decide whether
# the adapter delivered a complete and correctly ordered close sequence.
wait "$reader_pid" 2>/dev/null || true

grep -q '"id":"close","type":"closed"' "$events_file"
grep -o '"sequence":[0-9]*' "$events_file" | cut -d: -f2 >/tmp/sequences
event_count=$(grep -c '"type":"subscription"' "$events_file")
encoded_bytes=$(wc -c <"$events_file" | tr -d ' ')
sequence_count=$(wc -l </tmp/sequences | tr -d ' ')
first_sequence=$(head -n 1 /tmp/sequences)
last_sequence=$(tail -n 1 /tmp/sequences)
test "$sequence_count" -eq "$event_count"
test "$event_count" -le 16
test "$encoded_bytes" -le 8388608
test "$last_sequence" -eq 39
awk 'NR == 1 { previous = $1; next } $1 <= previous { exit 1 } { previous = $1 } END { if (NR == 0) exit 1 }' /tmp/sequences
if [ -d /evidence ]; then
  printf 'stopped-reader events=%s bytes=%s first=%s last=%s\n' "$event_count" "$encoded_bytes" "$first_sequence" "$last_sequence" >/evidence/summary.txt
fi
printf 'stopped-reader events=%s bytes=%s first=%s last=%s\n' "$event_count" "$encoded_bytes" "$first_sequence" "$last_sequence"
