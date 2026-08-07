#!/bin/sh
set -eu

adapter_image=${1:?adapter image is required}
controller_image=${2:?controller image is required}
probe_id="crystal-memory-$$"
network_name="$probe_id-network"
adapter_name="$probe_id-adapter"
controller_name="$probe_id-controller"

cleanup() {
  docker rm -f "$controller_name" "$adapter_name" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create "$network_name" >/dev/null
docker run -d --name "$adapter_name" --network "$network_name" --network-alias adapter \
  --memory 128m --memory-swap 128m --read-only --cap-drop ALL --security-opt no-new-privileges \
  --cpus 0.5 --pids-limit 64 --user 65532:65532 \
  -e CONVEX_URL=http://controller:8080 -e ADAPTER_LISTEN=0.0.0.0:9000 \
  "$adapter_image" >/dev/null
docker run -d --name "$controller_name" --network "$network_name" --network-alias controller \
  --memory 64m --memory-swap 64m --read-only --cap-drop ALL --security-opt no-new-privileges \
  --cpus 0.5 --pids-limit 64 --user 65532:65532 \
  "$controller_image" >/dev/null

attempt=0
until docker logs "$controller_name" 2>&1 | grep -q '^STOPPED$'; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    docker logs "$controller_name" >&2
    exit 1
  fi
  sleep 0.05
done

adapter_pid=$(docker inspect --format '{{.State.Pid}}' "$adapter_name")
peak_cgroup_mib=0
peak_rss_mib=0
sample=0
while [ "$sample" -lt 20 ]; do
  if [ "$(docker inspect --format '{{.State.Running}}' "$adapter_name")" != true ]; then
    break
  fi
  usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$adapter_name") || break
  resident=${usage%% / *}
  value=${resident%???}
  unit=${resident#"$value"}
  mib=$(awk -v value="$value" -v unit="$unit" 'BEGIN {
    if (unit == "KiB") print value / 1024;
    else if (unit == "MiB") print value;
    else if (unit == "GiB") print value * 1024;
    else exit 1;
  }')
  rss_kib=$(ps -o rss= -p "$adapter_pid" 2>/dev/null | tr -d ' ' || true)
  rss_kib=${rss_kib:-0}
  rss_mib=$(awk -v value="$rss_kib" 'BEGIN { print value / 1024 }')
  peak_cgroup_mib=$(awk -v old="$peak_cgroup_mib" -v current="$mib" 'BEGIN { print (current > old ? current : old) }')
  peak_rss_mib=$(awk -v old="$peak_rss_mib" -v current="$rss_mib" 'BEGIN { print (current > old ? current : old) }')
  sample=$((sample + 1))
  sleep 0.05
done

awk -v peak="$peak_cgroup_mib" 'BEGIN { if (peak >= 96) exit 1 }'
awk -v peak="$peak_rss_mib" 'BEGIN { if (peak >= 96) exit 1 }'

# The controller is intentionally still alive and has never resumed reading.
# The adapter itself must hit its cumulative output deadline, release the
# terminal waiter, and stop without relying on controller cooperation.
test "$(docker inspect --format '{{.State.Running}}' "$controller_name")" = true
attempt=0
while [ "$(docker inspect --format '{{.State.Running}}' "$adapter_name")" = true ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    docker logs "$adapter_name" >&2
    exit 1
  fi
  sleep 0.05
done
adapter_status=$(docker inspect --format '{{.State.ExitCode}}' "$adapter_name")
test "$adapter_status" -ne 0
test "$(docker inspect --format '{{.State.OOMKilled}}' "$adapter_name")" = false
docker logs "$controller_name" | grep -Fx 'STOPPED'
docker logs "$controller_name" | grep -Fx 'REQUESTS=17'
docker logs "$adapter_name" 2>&1 | grep -F 'adapter output deadline exceeded'
printf 'peak_rss_mib=%s peak_cgroup_mib=%s limit_mib=128 safety_gate_mib=96\n' "$peak_rss_mib" "$peak_cgroup_mib"
