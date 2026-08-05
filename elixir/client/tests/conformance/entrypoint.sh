#!/bin/sh

set -eu

# Start only the test adapter inside the release. The adapter still calls the
# real Convex.Client for every operation and exits after the controller closes.
export CONVEX_ENTRYPOINT=adapter

exec /opt/convex/bin/convex_client start
