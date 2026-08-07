#!/bin/sh
set -u

fixture_log=/tmp/memory-fixture.log
adapter_log=/tmp/memory-adapter.log
controller_log=/tmp/memory-controller.log
fixture_pid=
adapter_pid=
controller_pid=
fixture_active=false
adapter_active=false
controller_active=false
fixture_status=not-waited
adapter_status=not-waited
controller_status=not-waited

listener_present() {
  port_hex=$1
  awk -v port=":$port_hex" '
    $2 ~ port "$" && $4 == "0A" { found = 1 }
    END { exit !found }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

process_state() {
  label=$1
  pid=$2
  if test -n "$pid" && test -r "/proc/$pid/status"; then
    state=$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status")
    printf '%s_pid=%s state=%s\n' "$label" "$pid" "$state" >&2
  else
    printf '%s_pid=%s state=gone\n' "$label" "${pid:-unset}" >&2
  fi
}

listener_state() {
  label=$1
  port_hex=$2
  if listener_present "$port_hex"; then
    printf '%s_listener=ready port_hex=%s\n' "$label" "$port_hex" >&2
  else
    printf '%s_listener=absent port_hex=%s\n' "$label" "$port_hex" >&2
  fi
}

socket_state() {
  printf 'socket_state (local remote state):\n' >&2
  matches=$(awk '
    $2 ~ /:(7D64|7D65)$/ || $3 ~ /:(7D64|7D65)$/ {
      print $2, $3, $4
    }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null || true)
  if test -n "$matches"; then
    printf '%s\n' "$matches" >&2
  else
    printf 'none\n' >&2
  fi
}

bounded_file() {
  label=$1
  path=$2
  printf '%s:\n' "$label" >&2
  if test -f "$path"; then
    printf 'bytes=%s\n' "$(wc -c <"$path" | tr -d ' ')" >&2
    tail -c 4096 "$path" >&2 || true
  else
    printf 'missing\n' >&2
  fi
}

cleanup() {
  test "$controller_active" = false || kill "$controller_pid" 2>/dev/null || true
  test "$adapter_active" = false || kill "$adapter_pid" 2>/dev/null || true
  test "$fixture_active" = false || kill "$fixture_pid" 2>/dev/null || true
}

reap_children() {
  cleanup
  if test "$controller_active" = true; then
    controller_status=0
    wait "$controller_pid" || controller_status=$?
    controller_active=false
  fi
  if test "$adapter_active" = true; then
    adapter_status=0
    wait "$adapter_pid" || adapter_status=$?
    adapter_active=false
  fi
  if test "$fixture_active" = true; then
    fixture_status=0
    wait "$fixture_pid" || fixture_status=$?
    fixture_active=false
  fi
}

report_failure() {
  status=$1
  printf 'stopped-reader docker probe failed status=%s fixture_status=%s adapter_status=%s controller_status=%s\n' \
    "$status" "$fixture_status" "$adapter_status" "$controller_status" >&2
  process_state fixture "$fixture_pid"
  process_state adapter "$adapter_pid"
  process_state controller "$controller_pid"
  listener_state fixture 7D65
  listener_state adapter 7D64
  socket_state
  bounded_file fixture_log "$fixture_log"
  bounded_file adapter_log "$adapter_log"
  bounded_file controller_log "$controller_log"
  bounded_file events /tmp/events
}

fail() {
  reason=$1
  printf 'cause=%s\n' "$reason" >&2
  exit 1
}

wait_for_listener() {
  label=$1
  pid=$2
  port_hex=$3
  attempts=0
  while test "$attempts" -lt 100; do
    if listener_present "$port_hex"; then
      printf '%s listener ready pid=%s port_hex=%s\n' "$label" "$pid" "$port_hex" >&2
      return 0
    fi
    if test ! -r "/proc/$pid/status"; then
      fail "$label exited before its listener became ready"
    fi
    state=$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status")
    if test "$state" = Z; then
      fail "$label exited before its listener became ready"
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  fail "$label listener readiness timed out"
}

wait_for_exit() {
  label=$1
  pid=$2
  attempts=0
  while test "$attempts" -lt 100; do
    if test ! -r "/proc/$pid/status"; then
      return 0
    fi
    state=$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status")
    if test "$state" = Z; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  fail "$label did not exit within ten seconds"
}

process_finished() {
  pid=$1
  if test ! -r "/proc/$pid/status"; then
    return 0
  fi
  test "$(awk '$1 == "State:" { print $2 }' "/proc/$pid/status")" = Z
}

trap 'status=$?; trap - EXIT INT TERM; if test "$status" -ne 0; then report_failure "$status"; fi; reap_children; if test "$status" -ne 0; then printf "final_exit_statuses fixture=%s adapter=%s controller=%s\n" "$fixture_status" "$adapter_status" "$controller_status" >&2; fi; exit "$status"' EXIT INT TERM

/out/convex-memory-fixture >"$fixture_log" 2>&1 &
fixture_pid=$!
fixture_active=true
wait_for_listener fixture "$fixture_pid" 7D65

CONVEX_URL=http://127.0.0.1:32101 ADAPTER_LISTEN=127.0.0.1:32100 \
  /out/convex-adapter >"$adapter_log" 2>&1 &
adapter_pid=$!
adapter_active=true
wait_for_listener adapter "$adapter_pid" 7D64

# Both single-use listeners are now in LISTEN. A failed speculative netcat can
# consume the hello from its FIFO before connect(2) reports failure, so the
# checked-in Docker gate deliberately permits exactly one attempt after this
# process-level readiness barrier.
ADAPTER_HOST=127.0.0.1 ADAPTER_CONNECT_ATTEMPTS=1 \
  timeout -s TERM 45 sh client/tests/conformance/stopped_reader_controller.sh >"$controller_log" 2>&1 &
controller_pid=$!
controller_active=true

controller_status=0
wait "$controller_pid" || controller_status=$?
controller_active=false
if test "$controller_status" -ne 0; then
  if process_finished "$adapter_pid"; then
    adapter_status=0
    wait "$adapter_pid" || adapter_status=$?
    adapter_active=false
    fail "adapter exited status=$adapter_status before controller completed"
  fi
  if process_finished "$fixture_pid"; then
    fixture_status=0
    wait "$fixture_pid" || fixture_status=$?
    fixture_active=false
    fail "fixture exited status=$fixture_status before controller completed"
  fi
  fail "controller exited before a complete stopped-reader transcript"
fi

wait_for_exit adapter "$adapter_pid"
adapter_status=0
wait "$adapter_pid" || adapter_status=$?
adapter_active=false
if test "$adapter_status" -ne 0; then
  fail "adapter exited non-zero after controller success"
fi

wait_for_exit fixture "$fixture_pid"
fixture_status=0
wait "$fixture_pid" || fixture_status=$?
fixture_active=false
if test "$fixture_status" -ne 0; then
  fail "fixture exited non-zero after controller success"
fi

cat "$controller_log"
printf 'stopped-reader docker probe passed fixture_status=%s adapter_status=%s controller_status=%s\n' \
  "$fixture_status" "$adapter_status" "$controller_status"
trap - EXIT INT TERM
