#!/bin/sh
# GNU APL's CLI takes a script only via "-f file", never as a bare
# positional argument (unlike most scripting-language interpreters), so
# the conformance adapter needs this tiny launcher as its entrypoint --
# the same shape unicon -o's own generated "#!/bin/sh" launcher uses for
# ../../icon's compiled binaries.
#
# It also filters two fixed-shape pieces of GNU APL's own,
# unsuppressible non-protocol output off stdout:
#   - )COPY's load_DUMP always writes "DUMPED <the copied file's
#     mtime>" to COUT for any recognised library file, with no
#     "silent" option exposed through the )COPY command itself
#     (confirmed in GNU APL's own Command.cc: Workspace::copy_WS
#     hardcodes silent=false).
#   - ")OFF" (required to exit cleanly -- without it the interpreter
#     falls into its interactive ^D/end-of-input prompt loop instead,
#     confirmed by hand) adds one bare blank line to stdout right
#     before the process exits.
# The adapter protocol's own contract reserves stdout for NDJSON
# events only (in stdio mode; ADAPTER_LISTEN mode writes NDJSON to the
# accepted socket instead and barely touches real stdout at all), so
# neither can be allowed to reach it. ConvexInit assigns away the
# *other* startup echo (the loaded native function's name) at the
# source instead, so filtering it here is not needed too.
#
# The trailing blank line is dropped by holding the most recently read
# line back by one step: it is only flushed once another line is known
# to follow, so a genuine empty line at true end-of-input is dropped
# instead of printed, without touching a blank line anywhere else.
# Known limitation: this pipeline loses the interpreter's own exit
# status; nothing here currently depends on it.
/usr/local/bin/apl -s -f /opt/convex/client/tests/conformance/adapter.apl -- "$@" | \
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
