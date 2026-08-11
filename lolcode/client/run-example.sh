#!/bin/sh
set -eu

room=${1:-lolcode-demo}
export CONVEX_ROOM="$room"

exec /usr/local/bin/lci \
  /opt/lolcode/client/convex.lol \
  /opt/lolcode/client/live.lol \
  /opt/lolcode/examples/basics/main.lol
