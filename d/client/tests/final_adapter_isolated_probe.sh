#!/bin/sh
# Run the final adapter retention proof with the adapter isolated from its
# fixture and controller cgroups. This is intentionally a host-side Docker
# orchestration command, not code that runs inside a client container.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
test_image=100-convex-clients-d:isolated-proof-test
runtime_image=100-convex-clients-d:isolated-proof-runtime
name_prefix=d-final-adapter-proof-$$
adapter_name=$name_prefix-adapter
controller_name=$name_prefix-controller
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/d-final-adapter-proof.XXXXXX")
controller_log=$log_dir/controller.log
adapter_output_dir=$log_dir/adapter
adapter_started=
controller_started=

cleanup()
{
    status=$?
    trap - EXIT HUP INT TERM
    if test "$status" -ne 0; then
        printf '%s\n' "final adapter isolated proof failed" >&2
        test ! -s "$controller_log" || cat "$controller_log" >&2
        if test -n "$controller_started"; then
            docker logs "$controller_name" >&2 2>/dev/null || true
        fi
        if test -n "$adapter_started"; then
            docker logs "$adapter_name" >&2 2>/dev/null || true
            if test -e "$adapter_output_dir/adapter.stdout"; then
                printf '%s\n' "adapter stdout:" >&2
                cat "$adapter_output_dir/adapter.stdout" >&2
            fi
            if test -e "$adapter_output_dir/adapter.stderr"; then
                printf '%s\n' "adapter stderr:" >&2
                cat "$adapter_output_dir/adapter.stderr" >&2
            fi
        fi
    fi
    if test -n "$controller_started"; then
        docker rm -f "$controller_name" >/dev/null 2>&1 || true
    fi
    if test -n "$adapter_started"; then
        docker rm -f "$adapter_name" >/dev/null 2>&1 || true
    fi
    rm -rf "$log_dir"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "building exact D test artifact"
docker buildx build \
    --load \
    --platform linux/amd64 \
    --provenance=false \
    --target test \
    --tag "$test_image" \
    "$repo_root/d"

printf '%s\n' "building exact D runtime artifact"
docker buildx build \
    --load \
    --platform linux/amd64 \
    --provenance=false \
    --target runtime \
    --tag "$runtime_image" \
    "$repo_root/d"

test "$(docker image inspect "$test_image" --format '{{.Os}}/{{.Architecture}}')" = linux/amd64
test "$(docker image inspect "$runtime_image" --format '{{.Os}}/{{.Architecture}}')" = linux/amd64
test "$(docker image inspect "$runtime_image" --format '{{.Config.User}}')" = 65532:65532

runtime_output=$(printf '%s\n' \
    '{"protocolVersion":1,"id":"hello","op":"hello"}' \
    '{"id":"close","op":"close"}' |
    docker run --rm \
        -i \
        --platform linux/amd64 \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --pids-limit 32 \
        --memory 128m \
        --cpus 0.5 \
        --ulimit nofile=256:256 \
        --user 65532:65532 \
        "$runtime_image")
printf '%s\n' "$runtime_output" | grep -F '"type":"ready"' >/dev/null
printf '%s\n' "$runtime_output" | grep -F '"type":"closed"' >/dev/null
if printf '%s\n' "$runtime_output" | grep -Fq 'null'; then
    printf '%s\n' "runtime adapter emitted an unexpected null field" >&2
    exit 1
fi

mkdir "$adapter_output_dir"
chmod 777 "$adapter_output_dir"
adapter_started=1
docker run -d \
    --name "$adapter_name" \
    --platform linux/amd64 \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,noexec \
    --mount type=bind,src="$adapter_output_dir",dst=/probe-data \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 32 \
    --memory 128m \
    --cpus 0.5 \
    --ulimit nofile=256:256 \
    --user 65532:65532 \
    --env ADAPTER_LISTEN=127.0.0.1:18162 \
    --env ADAPTER_TEST_OUTPUT_DEADLINE_MS=20000 \
    --env ADAPTER_TEST_SOCKET_SNDBUF=4096 \
    --env CONVEX_URL=http://127.0.0.1:18155 \
    --entrypoint /bin/sh \
    "$test_image" \
    -eu -c '
        peak_file=/sys/fs/cgroup/memory.peak
        test -r "$peak_file"
        if printf 0 > "$peak_file" 2>/dev/null; then
            peak_mode=reset
        else
            peak_mode=fresh-container
        fi
        set +e
        /out-adapter > /probe-data/adapter.stdout 2> /probe-data/adapter.stderr
        adapter_status=$?
        set -e
        cat "$peak_file" > /probe-data/adapter-memory-peak
        printf "%s\n" "$peak_mode" > /probe-data/adapter-memory-peak-mode
        printf "%s\n" "$adapter_status" > /probe-data/adapter-exit-status
        exit "$adapter_status"
    '

adapter_memory=$(docker inspect "$adapter_name" --format '{{.HostConfig.Memory}}')
adapter_id=$(docker inspect "$adapter_name" --format '{{.Id}}')
test "$adapter_memory" -eq $((128 * 1024 * 1024))
test "$(docker inspect "$adapter_name" --format '{{.HostConfig.NetworkMode}}')" != host

controller_started=1
docker run -d \
    --name "$controller_name" \
    --platform linux/amd64 \
    --network "container:$adapter_name" \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,noexec \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 32 \
    --memory 256m \
    --cpus 0.5 \
    --ulimit nofile=256:256 \
    --user 65532:65532 \
    --entrypoint /bin/sh \
    "$test_image" \
    -eu -c '
        /out-live-stopped-reader-server > /tmp/live-fixture.log 2>&1 &
        server_pid=$!
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            test -e /tmp/d-live-server-ready && break
            sleep 0.05
        done
        test -e /tmp/d-live-server-ready
        set +e
        /out-final-adapter-tcp-controller
        controller_status=$?
        set -e
        set +e
        wait "$server_pid"
        server_status=$?
        set -e
        if test "$controller_status" -ne 0 || test "$server_status" -ne 0; then
            cat /tmp/live-fixture.log >&2 2>/dev/null || true
            exit 1
        fi
    ' >"$controller_log" 2>&1

set +e
controller_status=$(docker wait "$controller_name")
set -e
docker logs "$controller_name" >"$controller_log" 2>&1 || true

adapter_status=$(docker wait "$adapter_name")
peak_bytes=$(sed -n '1p' "$adapter_output_dir/adapter-memory-peak")
peak_mode=$(sed -n '1p' "$adapter_output_dir/adapter-memory-peak-mode")
controller_memory=$(docker inspect "$controller_name" --format '{{.HostConfig.Memory}}')
controller_network=$(docker inspect "$controller_name" --format '{{.HostConfig.NetworkMode}}')

printf '%s\n' "controller cgroup memory: $controller_memory bytes"
printf '%s\n' "controller network: $controller_network"
printf '%s\n' "adapter cgroup memory.peak: $peak_bytes bytes ($peak_mode)"
printf '%s\n' "controller exit status: $controller_status"
printf '%s\n' "adapter exit status: $adapter_status"
test "$controller_status" -eq 0
test "$adapter_status" -eq 0
test "$controller_memory" -gt "$adapter_memory"
test "$controller_network" = "container:$adapter_id"
test "$peak_bytes" -lt $((96 * 1024 * 1024))
printf '%s\n' "final adapter isolated proof: retained sequences and close verified"
