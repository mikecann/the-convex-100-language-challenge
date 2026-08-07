#!/bin/sh
set -eu

exec 9>/tmp/100cc-docker-build.slot
flock 9

cd "$(dirname "$0")/../../../.."

docker run --rm -v "$PWD/crystal:/work" \
  crystallang/crystal:1.14.1-alpine@sha256:e99593ba1bb7cec5bc686d46523217c09617e3b935588841b7f7961fc710a3ce \
  crystal tool format /work/client /work/examples
./run test crystal
./run build crystal
docker buildx build --load --platform linux/amd64 --target example-runtime --provenance=false \
  --tag 100-convex-clients-crystal-example:final crystal
docker buildx build --load --platform linux/amd64 --target memory-controller --provenance=false \
  --tag 100-convex-clients-crystal-memory:final crystal
sh crystal/client/tests/conformance/stopped_reader_probe.sh \
  100-convex-clients-crystal:local 100-convex-clients-crystal-memory:final

docker image inspect 100-convex-clients-crystal:local \
  --format 'runtime={{.Architecture}} user={{.Config.User}} entry={{json .Config.Entrypoint}}'
docker image inspect 100-convex-clients-crystal-example:final \
  --format 'example={{.Architecture}} user={{.Config.User}} entry={{json .Config.Entrypoint}}'

constraints='--rm --read-only --cap-drop ALL --security-opt no-new-privileges --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 --user 65532:65532'
# shellcheck disable=SC2086
docker run $constraints --entrypoint /bin/sh 100-convex-clients-crystal:local -ec '
  test -x /usr/local/bin/convex-adapter
  test -r /etc/ssl/cert.pem
  test -r /etc/ssl/openssl.cnf
  test ! -e /sbin/apk
  for command in crystal shards apk npm npx node python python3 pip pip3 curl convex gcc cc clang make; do
    ! command -v "$command"
  done
'

applets=$(docker run --rm --entrypoint /bin/busybox 100-convex-clients-crystal:local --list)
test "$applets" = "$(printf '%s\n' '[' '[[' ash grep id sh test)"
for forbidden in wget nc ftpget ftpput telnet tftp; do
  if printf '%s\n' "$applets" | grep -Fxq "$forbidden"; then
    printf 'forbidden_busybox_applet=%s\n' "$forbidden" >&2
    exit 1
  fi
done

printf '%s\n' \
  '{"protocolVersion":1,"id":"hello","op":"hello"}' \
  '{"id":"close","op":"close"}' |
  # shellcheck disable=SC2086
  docker run -i $constraints -e CONVEX_URL=http://127.0.0.1 100-convex-clients-crystal:local

printf '%s\n' \
  '{"id":"tls","op":"query","path":"demo:state","args":{}}' \
  '{"id":"close","op":"close"}' |
  # shellcheck disable=SC2086
  docker run -i $constraints -e CONVEX_URL=https://example.com 100-convex-clients-crystal:local

set +e
# shellcheck disable=SC2086
docker run $constraints -e CONVEX_URL=https://example.com \
  100-convex-clients-crystal-example:final crystal-final-probe \
  >/tmp/crystal-example-final.out 2>/tmp/crystal-example-final.err
example_status=$?
set -e
test "$example_status" -eq 1
grep -F 'Unexpected char' /tmp/crystal-example-final.err
printf 'example_probe_exit=%s\n' "$example_status"
