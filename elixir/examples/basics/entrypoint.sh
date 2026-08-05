#!/bin/sh

set -eu

# The release starts the exact Convex.Example module in main.ex. Passing the
# room through an environment variable keeps ordinary CLI arguments out of the
# Erlang VM's own flags while preserving the shared first-argument contract.
export CONVEX_ENTRYPOINT=example
export CONVEX_EXAMPLE_ROOM=${1:-elixir-example}

exec /opt/convex/bin/convex_client start
