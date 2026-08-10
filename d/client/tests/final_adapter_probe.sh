#!/bin/sh
# This command is the test image's only runtime command. Docker gives it a
# fresh cgroup, so memory.peak belongs to the actual adapter run below.
set -eu

adapter_pid=
server_pid=
input_keeper_pid=
live_input=/tmp/d-live-input
live_output=/tmp/d-live-output
peak_file=/sys/fs/cgroup/memory.peak
adapter_log=/tmp/d-live-adapter.log
server_log=/tmp/d-live-server.log

cleanup() {
    if test -n "$adapter_pid"; then
        kill "$adapter_pid" >/dev/null 2>&1 || true
    fi
    if test -n "$server_pid"; then
        kill "$server_pid" >/dev/null 2>&1 || true
    fi
    if test -n "$input_keeper_pid"; then
        kill "$input_keeper_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$live_input" "$live_output" \
        "$adapter_log" "$server_log" \
        /tmp/d-live-count-start /tmp/d-live-count-first-sent /tmp/d-live-count-burst \
        /tmp/d-live-count-done /tmp/d-live-byte-start /tmp/d-live-byte-first-sent \
        /tmp/d-live-byte-burst /tmp/d-live-byte-done /tmp/d-live-finish
}
trap cleanup EXIT HUP INT TERM

wait_for_file() {
    wait_path=$1
    wait_limit=${2:-500}
    wait_attempt=0
    while test ! -e "$wait_path"; do
        wait_attempt=$((wait_attempt + 1))
        test "$wait_attempt" -lt "$wait_limit"
        sleep 0.02
    done
}

expect_exact_line() {
    expected_line=$1
    if ! IFS= read -r actual_line <&5; then
        printf 'adapter output closed before expected wire line: %s\n' "$expected_line" >&2
        if ! kill -0 "$adapter_pid" 2>/dev/null; then
            wait "$adapter_pid" || printf 'adapter exited with status %s\n' "$?" >&2
        fi
        test ! -s "$server_log" || cat "$server_log" >&2
        test ! -s "$adapter_log" || cat "$adapter_log" >&2
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

test -r "$peak_file"
if (printf 0 > "$peak_file") 2>/dev/null; then
    peak_mode=reset
else
    # Docker mounts this cgroup read-only on Bruce. This is still a new
    # container, so the following high-water mark is isolated to this probe.
    peak_mode=fresh-container
fi

/out-live-stopped-reader-server >"$server_log" 2>&1 &
server_pid=$!
sleep 0.1
mkfifo "$live_input" "$live_output"
exec 3<>"$live_input"
# The adapter makes stdout nonblocking so its physical write deadline is
# enforceable. A dup of this read-write FIFO descriptor would share that flag,
# and dash then reports EAGAIN from `read` as a failed read. Keep fd 4 only as
# the adapter's write-side open file description and open fd 5 independently
# for this controller's blocking reads.
exec 4<>"$live_output"
ADAPTER_TEST_OUTPUT_DEADLINE_MS=20000 CONVEX_URL=http://127.0.0.1:18155 \
    /out-adapter <&3 >&4 4>&- 2>"$adapter_log" &
adapter_pid=$!
exec 5<"$live_output"
exec 4>&-
sleep 30 >"$live_input" &
input_keeper_pid=$!
test "$(cat "/proc/$adapter_pid/cgroup")" = "$(cat /proc/self/cgroup)"
printf '%s\n' '{"id":"retained","op":"subscribe","subscriptionId":"retained","path":"demo:state","args":{}}' >&3
expect_exact_line '{"id":"retained","type":"ack"}'

# A 1.75 MiB first event physically blocks this controller pipe. While reads
# are paused, 17 small values arrive, so the real 16-item queue evicts sequence 2.
touch /tmp/d-live-count-start
wait_for_file /tmp/d-live-count-first-sent
sleep 0.05
touch /tmp/d-live-count-burst
wait_for_file /tmp/d-live-count-done
exec 5>&-
/out-final-adapter-controller count <"$live_output"

# Pause again, then send five valid 1.75 MiB Live frames. Sequence 102 is
# evicted by the client's actual 8 MiB encoded-byte queue budget.
touch /tmp/d-live-byte-start
wait_for_file /tmp/d-live-byte-first-sent
sleep 0.05
touch /tmp/d-live-byte-burst
wait_for_file /tmp/d-live-byte-done 1500
/out-final-adapter-controller bytes <"$live_output"

exec 5<"$live_output"
printf '%s\n' '{"id":"close","op":"close"}' >&3
touch /tmp/d-live-finish
expect_exact_line '{"id":"close","type":"closed"}'
exec 3>&-
exec 5>&-
kill "$input_keeper_pid"
wait "$input_keeper_pid" || true
input_keeper_pid=
wait "$adapter_pid"
adapter_pid=
wait "$server_pid"
server_pid=

peak_bytes=$(cat "$peak_file")
# This image-level gate shares the cgroup with its fixture and controller.
# The remote isolated-cgroup probe measures the adapter alone against 96 MiB.
test "$peak_bytes" -lt $((128 * 1024 * 1024))
printf 'final adapter Live probe: count and byte eviction observed; shared memory.peak=%s bytes (%s)\n' \
    "$peak_bytes" "$peak_mode"
