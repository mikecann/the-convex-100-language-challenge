#!/bin/sh
# See client/tests/conformance/entrypoint.sh for why this launcher
# exists (GNU APL's CLI has no way to take a script as a bare
# positional argument, only via "-f file") and why it filters one
# fixed-shape line of GNU APL's own unsuppressible )COPY startup
# output ("DUMPED <mtime>") rather than passing stdout straight
# through: this project's shared example rules require this program's
# stdout to match _shared/examples/basics.expected.txt exactly, with
# no extra decoration.
#
# GNU APL's own script-exit path (reached via ")OFF", required --
# without it the interpreter falls into its interactive ^D/end-of-
# input prompt loop instead of exiting cleanly, confirmed by hand) adds
# one more unsuppressible bare blank line to stdout after the script's
# own last real line of output, independent of anything this client
# prints. The loop below buffers the line it just read behind one
# variable so it can hold the final line back until it knows whether
# another line follows; at true end-of-input it only flushes that
# held-back line if it is non-empty, dropping exactly that one
# trailing blank line without touching a blank line anywhere else in
# real output.
/usr/local/bin/apl -s -f /opt/convex/examples/basics/main.apl -- "$@" | \
  {
    held=""
    have_held=0
    while IFS= read -r line; do
      if [ "$have_held" = 1 ]; then
        case $held in
          "DUMPED "*) ;;
          *) printf '%s\n' "$held" ;;
        esac
      fi
      held=$line
      have_held=1
    done
    if [ "$have_held" = 1 ] && [ -n "$held" ]; then
      case $held in
        "DUMPED "*) ;;
        *) printf '%s\n' "$held" ;;
      esac
    fi
  }
