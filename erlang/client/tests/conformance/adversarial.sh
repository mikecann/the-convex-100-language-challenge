#!/bin/sh

# Exercise the exact final adapter under the shared 128 MiB limit. The fixture
# reads the subscribe acknowledgement and then stops reading TCP output while
# a real WebSocket peer sends 240 KiB updates. A bounded adapter closes cleanly;
# an unbounded one is OOM-killed, which this script reports as a hard failure.
set -eu

runtime_image=${ERLANG_RUNTIME_IMAGE:-100-convex-clients-erlang:local}
test_image=${ERLANG_TEST_IMAGE:-100-convex-clients-erlang:test}
network=erlang-pressure-$$
adapter=erlang-pressure-adapter-$$

cleanup() {
    docker rm --force "$adapter" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup 0 1 2 15

docker network create "$network" >/dev/null
docker run --detach \
    --name "$adapter" \
    --platform linux/amd64 \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 64 \
    --memory 128m \
    --cpus 0.5 \
    --ulimit nofile=256:256 \
    --network "$network" \
    --network-alias adapter \
    --user 65532:65532 \
    --env CONVEX_URL=http://fixture:8081 \
    --env ADAPTER_LISTEN=0.0.0.0:8080 \
    "$runtime_image" >/dev/null

docker run --rm \
    --platform linux/amd64 \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 64 \
    --memory 512m \
    --network "$network" \
    --network-alias fixture \
    --env ADAPTER_HOST=adapter \
    --entrypoint erl \
    "$test_image" \
    -noshell \
    -pa /app/test-ebin \
    -pa /app/_build/dev/lib/jsx/ebin \
    -pa /app/_build/dev/lib/gun/ebin \
    -pa /app/_build/dev/lib/cowlib/ebin \
    -s live_socket_test pressure_main \
    -s init stop

status=$(docker wait "$adapter")
oom_killed=$(docker inspect "$adapter" --format '{{.State.OOMKilled}}')
test "$status" -eq 0
test "$oom_killed" = false
printf '%s\n' "PASS final adapter bounded a stopped TCP reader below 128 MiB"
