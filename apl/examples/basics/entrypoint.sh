#!/bin/sh
# See client/tests/conformance/entrypoint.sh for why this launcher
# exists (GNU APL's CLI has no way to take a script as a bare
# positional argument, only via "-f file") and why it filters one
# fixed-shape line of GNU APL's own unsuppressible )COPY startup
# output ("DUMPED <mtime>") rather than passing stdout straight
# through: this project's shared example rules require this program's
# stdout to match _shared/examples/basics.expected.txt exactly, with
# no extra decoration.
/usr/local/bin/apl -s -f /opt/convex/examples/basics/main.apl -- "$@" | \
  while IFS= read -r line; do
    case $line in
      "DUMPED "*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
