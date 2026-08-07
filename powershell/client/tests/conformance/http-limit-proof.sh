#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 RUNTIME_IMAGE CONTROLLER_IMAGE" >&2
  exit 2
fi

runtime_image=$1
controller_image=$2
proof_suffix="$$"
network_name="powershell-http-limit-${proof_suffix}"
adapter_name="powershell-http-limit-adapter-${proof_suffix}"
controller_name="powershell-http-limit-controller-${proof_suffix}"
state_dir=$(mktemp -d "/tmp/100cc-powershell-http-limit.${proof_suffix}.XXXXXX")
chmod 0777 "$state_dir"

cleanup() {
  docker rm -f "$adapter_name" "$controller_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  rm -rf "$state_dir"
}
trap cleanup EXIT INT TERM

docker network create "$network_name" >/dev/null
docker run -d \
  --name "$controller_name" \
  --platform linux/amd64 \
  --memory 256m \
  --memory-swap 256m \
  --pids-limit 64 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=32m \
  --network "$network_name" \
  --network-alias powershell-http-controller \
  --mount "type=bind,src=${state_dir},dst=/state" \
  --entrypoint pwsh \
  "$controller_image" \
  -NoLogo -NoProfile -File client/tests/conformance/http-limit-controller.ps1 >/dev/null

docker run -d \
  --name "$adapter_name" \
  --platform linux/amd64 \
  --memory 128m \
  --memory-swap 128m \
  --pids-limit 32 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /dev/shm:rw,nosuid,nodev,size=32m \
  --network "$network_name" \
  --network-alias powershell-http-adapter \
  --mount "type=bind,src=${state_dir},dst=/state" \
  --env ADAPTER_LISTEN=0.0.0.0:43145 \
  --env CONVEX_URL=http://powershell-http-controller:43144 \
  --entrypoint /bin/sh \
  "$runtime_image" \
  -c 'set +e; /usr/local/bin/convex-adapter; adapter_status=$?; peak=0; if test -r /sys/fs/cgroup/memory.peak; then read peak < /sys/fs/cgroup/memory.peak; elif test -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes; then read peak < /sys/fs/cgroup/memory/memory.max_usage_in_bytes; fi; printf "%s\n" "$adapter_status" > /state/http-adapter-status; printf "%s\n" "$peak" > /state/http-adapter-peak; exit "$adapter_status"' >/dev/null

deadline=$(( $(date +%s) + 20 ))
while [ ! -f "${state_dir}/http-controller-result" ] || [ ! -f "${state_dir}/http-adapter-status" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$controller_name" >&2 || true
    docker logs "$adapter_name" >&2 || true
    echo 'final adapter HTTP limit proof exceeded its bounded deadline' >&2
    exit 1
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$controller_name")" != true ] && [ ! -f "${state_dir}/http-controller-result" ]; then
    docker logs "$controller_name" >&2 || true
    echo 'HTTP limit controller exited before proving recovery and clean close' >&2
    exit 1
  fi
  sleep 0.02
done

adapter_status=$(tr -d '\r\n' < "${state_dir}/http-adapter-status")
peak_bytes=$(tr -d '\r\n' < "${state_dir}/http-adapter-peak")
controller_result=$(tr -d '\r\n' < "${state_dir}/http-controller-result")
oom_killed=$(docker inspect --format '{{.State.OOMKilled}}' "$adapter_name")

if [ "$controller_result" != PASS ]; then
  echo "HTTP limit controller result was ${controller_result}" >&2
  exit 1
fi
if [ "$adapter_status" -ne 0 ]; then
  docker logs "$adapter_name" >&2 || true
  echo "final adapter did not close cleanly after HTTP recovery: status ${adapter_status}" >&2
  exit 1
fi
if [ "$oom_killed" != false ]; then
  echo 'final adapter was OOM-killed by the slow over-limit HTTP peer' >&2
  exit 1
fi
if [ "$peak_bytes" -le 0 ] || [ "$peak_bytes" -ge 100663296 ]; then
  echo "final adapter HTTP peak was not comfortably below 128 MiB: ${peak_bytes} bytes" >&2
  exit 1
fi

printf 'PASS final PowerShell adapter bounded HTTP proof: peak=%s bytes status=%s recovery=clean-close\n' \
  "$peak_bytes" "$adapter_status"
