#!/bin/sh
# See client/tests/conformance/entrypoint.sh for why this launcher
# exists: GNU APL's CLI has no way to take a script as a bare
# positional argument, only via "-f file".
exec /usr/local/bin/apl -s -f /opt/convex/examples/basics/main.apl -- "$@"
