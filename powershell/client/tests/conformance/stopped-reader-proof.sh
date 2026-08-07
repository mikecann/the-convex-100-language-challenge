#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 RUNTIME_IMAGE CONTROLLER_IMAGE" >&2
  exit 2
fi

runtime_image=$1
controller_image=$2
proof_suffix="$$"
network_name="powershell-stopped-reader-${proof_suffix}"
adapter_name="powershell-stopped-reader-adapter-${proof_suffix}"
controller_name="powershell-stopped-reader-controller-${proof_suffix}"
state_dir=$(mktemp -d "/tmp/100cc-powershell-stopped-reader.${proof_suffix}.XXXXXX")
chmod 0777 "$state_dir"

cleanup() {
  : > "${state_dir}/stop-controller"
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
  --network-alias powershell-controller \
  --mount "type=bind,src=${state_dir},dst=/state" \
  --entrypoint pwsh \
  "$controller_image" \
  -NoLogo -NoProfile -File client/tests/conformance/stopped-reader-controller.ps1 >/dev/null

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
  --network-alias powershell-adapter \
  --mount "type=bind,src=${state_dir},dst=/state" \
  --env ADAPTER_LISTEN=0.0.0.0:43140 \
  --env CONVEX_URL=http://powershell-controller:43138 \
  --entrypoint /bin/sh \
  "$runtime_image" \
  -c 'set +e; /usr/local/bin/convex-adapter; adapter_status=$?; peak=0; if test -r /sys/fs/cgroup/memory.peak; then read peak < /sys/fs/cgroup/memory.peak; elif test -r /sys/fs/cgroup/memory/memory.max_usage_in_bytes; then read peak < /sys/fs/cgroup/memory/memory.max_usage_in_bytes; fi; printf "%s\n" "$adapter_status" > /state/adapter-status; printf "%s\n" "$peak" > /state/adapter-peak; exit "$adapter_status"' >/dev/null

ready_deadline=$(( $(date +%s) + 10 ))
while [ ! -f "${state_dir}/commands-sent" ]; do
  if [ "$(date +%s)" -ge "$ready_deadline" ]; then
    docker logs "$controller_name" >&2 || true
    docker logs "$adapter_name" >&2 || true
    echo 'stopped-reader controller did not send commands before deadline' >&2
    exit 1
  fi
  sleep 0.02
done

started_ms=$(date +%s%3N)
exit_deadline=$(( $(date +%s) + 4 ))
while [ ! -f "${state_dir}/adapter-status" ]; do
  if [ "$(date +%s)" -ge "$exit_deadline" ]; then
    docker logs "$adapter_name" >&2 || true
    echo 'stopped-reader adapter exceeded the bounded failure deadline' >&2
    exit 1
  fi
  sleep 0.02
done
elapsed_ms=$(( $(date +%s%3N) - started_ms ))

if [ ! -f "${state_dir}/near-maximum-served" ]; then
  echo 'fixture did not serve a near-maximum schema-valid result' >&2
  exit 1
fi

if [ "$(docker inspect --format '{{.State.Running}}' "$controller_name")" != true ]; then
  docker logs "$controller_name" >&2 || true
  echo 'controller exited before adapter outcome was captured' >&2
  exit 1
fi
adapter_status=$(tr -d '\r\n' < "${state_dir}/adapter-status")
peak_bytes=$(tr -d '\r\n' < "${state_dir}/adapter-peak")
oom_killed=$(docker inspect --format '{{.State.OOMKilled}}' "$adapter_name")
adapter_logs=$(docker logs "$adapter_name" 2>&1 || true)

if [ "$adapter_status" -eq 0 ]; then
  echo 'stopped-reader adapter exited successfully instead of enforcing backpressure' >&2
  exit 1
fi
if [ "$oom_killed" != false ]; then
  echo 'stopped-reader adapter was OOM-killed' >&2
  exit 1
fi
if [ "$peak_bytes" -le 0 ] || [ "$peak_bytes" -ge 100663296 ]; then
  echo "stopped-reader peak RSS was not comfortably below 128 MiB: ${peak_bytes} bytes" >&2
  exit 1
fi
if [ "$elapsed_ms" -ge 3500 ]; then
  echo "stopped-reader failure exceeded host allowance: ${elapsed_ms} ms" >&2
  exit 1
fi
printf '%s\n' "$adapter_logs" | grep -F 'adapter controller output failed within 1000 ms; reserved output bytes after release: 0' >/dev/null

printf 'PASS final PowerShell adapter stopped-reader proof: peak=%s bytes elapsed=%s ms status=%s controller=connected\n' \
  "$peak_bytes" "$elapsed_ms" "$adapter_status"
