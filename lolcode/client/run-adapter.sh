#!/bin/sh
set -eu

exec /usr/local/bin/lci \
  /opt/lolcode/client/convex.lol \
  /opt/lolcode/client/live.lol \
  /opt/lolcode/client/tests/conformance/main.lol
