#!/bin/sh
# Exercise the exact final adapter under its real 128 MiB cgroup while a
# separate controller stops reading near-maximum messages. Run this only on a
# Linux Docker host whose daemon shares /proc and /sys/fs/cgroup with the shell.
set -eu

repo_root=${REPO_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)}
run_id=${RUN_ID:-"manual"}
# The PID stays in the prefix even when a caller supplies a friendly run ID,
# so two legitimate probes never clean up each other's containers or images.
prefix="gleam-pressure-$run_id-$$"
runtime_image="$prefix-runtime"
fixture_image="$prefix-fixture"
controller_image="$prefix-controller"
network="$prefix-network"
evidence_dir=${EVIDENCE_DIR:-"/tmp/$prefix-evidence"}
memory_limit=134217728
memory_ceiling=125829120

mkdir -p "$evidence_dir"

cleanup() {
    docker rm -f \
        "$prefix-near-command-controller" "$prefix-near-command-adapter" \
        "$prefix-recover-controller" "$prefix-recover-adapter" "$prefix-recover-fixture" \
        "$prefix-deadline-controller" "$prefix-deadline-adapter" "$prefix-deadline-fixture" \
        >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker image rm "$controller_image" "$fixture_image" "$runtime_image" \
        >/dev/null 2>&1 || true
}

run_near_command_case() {
    mode=near-command
    adapter="$prefix-$mode-adapter"
    controller="$prefix-$mode-controller"
    peak_file="$evidence_dir/$mode-memory.peak"
    adapter_log="$evidence_dir/$mode-adapter.log"
    controller_log="$evidence_dir/$mode-controller.log"

    docker run -d --platform linux/amd64 \
        --name "$adapter" --network "$network" \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 128m --memory-swap 128m \
        -e ADAPTER_LISTEN=0.0.0.0:8080 \
        -e CONVEX_URL=http://127.0.0.1:9 \
        -e ADAPTER_TEST_SEND_BUFFER=4096 \
        -e ADAPTER_RESERVATION_DIAGNOSTIC=1 \
        "$runtime_image" >/dev/null

    sample_peak "$adapter" "$peak_file" &
    sampler_pid=$!
    docker run --platform linux/amd64 --name "$controller" \
        --network "container:$adapter" \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 256m --memory-swap 256m \
        -e PRESSURE_MODE="$mode" -e ADAPTER_HOST=127.0.0.1 \
        "$controller_image" >"$controller_log" 2>&1

    attempts=0
    while docker inspect --format '{{.State.Running}}' "$adapter" | grep -Fxq true; do
        attempts=$((attempts + 1))
        test "$attempts" -lt 200 || {
            printf '%s\n' "the near-command adapter did not stop within 20 seconds" >&2
            return 1
        }
        sleep 0.1
    done
    wait "$sampler_pid"
    docker logs "$adapter" >"$adapter_log" 2>&1
    test "$(docker inspect --format '{{.State.ExitCode}}' "$adapter")" -eq 0
    test "$(docker inspect --format '{{.State.OOMKilled}}' "$adapter")" = false
    grep -Fq 'remaining_count=0 remaining_bytes=0' "$adapter_log"
    grep -Fq 'near-command probe passed' "$controller_log"
    peak=$(cat "$peak_file")
    test "$peak" -gt 0
    test "$peak" -lt "$memory_ceiling"
    docker rm "$controller" "$adapter" >/dev/null 2>&1 || true
    printf '%s adapter memory.peak=%s bytes\n' "$mode" "$peak"
}
trap cleanup EXIT INT TERM

docker buildx build --platform linux/amd64 --target runtime \
    --load -t "$runtime_image" "$repo_root/gleam"
docker buildx build --platform linux/amd64 --target adapter-pressure-fixture \
    --load -t "$fixture_image" "$repo_root/gleam"
docker buildx build --platform linux/amd64 --target adapter-pressure-controller \
    --load -t "$controller_image" "$repo_root/gleam"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$runtime_image")" \
    = '["/usr/local/bin/convex-adapter"]'
test "$(docker image inspect --format '{{.Config.User}}' "$runtime_image")" = '65532:65532'
docker network create "$network" >/dev/null

read_cgroup_path() {
    container=$1
    pid=$(docker inspect --format '{{.State.Pid}}' "$container")
    test "$pid" -gt 1
    relative=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
    test -n "$relative"
    cgroup_path="/sys/fs/cgroup$relative"
    test -r "$cgroup_path/memory.max"
    printf '%s\n' "$cgroup_path"
}

sample_peak() {
    container=$1
    output=$2
    cgroup_path=$(read_cgroup_path "$container")
    test "$(cat "$cgroup_path/memory.max")" = "$memory_limit"
    peak=0
    while docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null \
        | grep -Fxq true; do
        if test -r "$cgroup_path/memory.peak"; then
            observed=$(cat "$cgroup_path/memory.peak")
            if test "$observed" -gt "$peak"; then peak=$observed; fi
        fi
        sleep 0.05
    done
    if test -r "$cgroup_path/memory.peak"; then
        observed=$(cat "$cgroup_path/memory.peak")
        if test "$observed" -gt "$peak"; then peak=$observed; fi
    fi
    printf '%s\n' "$peak" >"$output"
}

run_case() {
    mode=$1
    fixture="$prefix-$mode-fixture"
    adapter="$prefix-$mode-adapter"
    controller="$prefix-$mode-controller"
    peak_file="$evidence_dir/$mode-memory.peak"
    adapter_log="$evidence_dir/$mode-adapter.log"
    controller_log="$evidence_dir/$mode-controller.log"
    fixture_log="$evidence_dir/$mode-fixture.log"
    adapter_inspect="$evidence_dir/$mode-adapter-inspect.json"
    controller_inspect="$evidence_dir/$mode-controller-inspect.json"
    fixture_inspect="$evidence_dir/$mode-fixture-inspect.json"

    docker run -d --platform linux/amd64 \
        --name "$fixture" --network "$network" --network-alias fixture \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 192m --memory-swap 192m -e PRESSURE_MODE="$mode" \
        "$fixture_image" >/dev/null
    docker run -d --platform linux/amd64 \
        --name "$adapter" --network "$network" --network-alias adapter \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 128m --memory-swap 128m \
        -e ADAPTER_LISTEN=0.0.0.0:8080 \
        -e CONVEX_URL=http://fixture:8081 \
        -e ADAPTER_TEST_SEND_BUFFER=4096 \
        -e ADAPTER_RESERVATION_DIAGNOSTIC=1 \
        "$runtime_image" >/dev/null

    sample_peak "$adapter" "$peak_file" &
    sampler_pid=$!
    set +e
    # The adapter intentionally binds its test control socket to loopback. The
    # controller shares only that network namespace, not the adapter cgroup,
    # so it can reach 127.0.0.1 without contaminating memory.peak evidence.
    docker run --platform linux/amd64 --name "$controller" \
        --network "container:$adapter" \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --memory 256m --memory-swap 256m \
        -e PRESSURE_MODE="$mode" -e ADAPTER_HOST=127.0.0.1 \
        "$controller_image" >"$controller_log" 2>&1
    controller_status=$?
    set -e

    if test "$controller_status" -ne 0; then
        docker logs "$adapter" >"$adapter_log" 2>&1 || true
        docker logs "$fixture" >"$fixture_log" 2>&1 || true
        docker inspect "$adapter" >"$adapter_inspect" 2>&1 || true
        docker inspect "$controller" >"$controller_inspect" 2>&1 || true
        docker inspect "$fixture" >"$fixture_inspect" 2>&1 || true
        printf '%s\n' "the $mode pressure controller failed; evidence is in $evidence_dir" >&2
        return 1
    fi

    attempts=0
    while docker inspect --format '{{.State.Running}}' "$adapter" | grep -Fxq true; do
        attempts=$((attempts + 1))
        if test "$attempts" -ge 200; then
            docker logs "$adapter" >"$adapter_log" 2>&1 || true
            printf '%s\n' "the $mode adapter did not stop within 20 seconds" >&2
            return 1
        fi
        sleep 0.1
    done
    wait "$sampler_pid"
    adapter_status=$(docker inspect --format '{{.State.ExitCode}}' "$adapter")
    docker logs "$adapter" >"$adapter_log" 2>&1
    docker logs "$fixture" >"$fixture_log" 2>&1 || true
    test "$adapter_status" -eq 0
    test "$(docker inspect --format '{{.State.OOMKilled}}' "$adapter")" = false
    grep -Fq 'remaining_count=0 remaining_bytes=0' "$adapter_log"

    peak=$(cat "$peak_file")
    test "$peak" -gt 0
    test "$peak" -lt "$memory_ceiling"
    case "$mode" in
        recover)
            grep -Fq 'recovery probe passed' "$controller_log"
            ! grep -Fq 'controller output failed:' "$adapter_log"
            ;;
        deadline)
            grep -Fq 'deadline probe passed' "$controller_log"
            grep -Fq 'controller output failed: timeout' "$adapter_log"
            ;;
    esac

    docker rm "$controller" "$adapter" "$fixture" >/dev/null 2>&1 || true
    printf '%s adapter memory.peak=%s bytes\n' "$mode" "$peak"
}

run_near_command_case
run_case recover
run_case deadline
printf '%s\n' "final Gleam adapter stopped-reader proof passed"
