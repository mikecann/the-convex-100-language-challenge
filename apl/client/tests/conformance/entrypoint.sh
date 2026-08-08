#!/bin/sh
# GNU APL's CLI takes a script only via "-f file", never as a bare
# positional argument (unlike most scripting-language interpreters), so
# the conformance adapter needs this tiny launcher as its entrypoint --
# the same shape unicon -o's own generated "#!/bin/sh" launcher uses for
# ../../icon's compiled binaries.
#
# It also filters one line of GNU APL's own, unsuppressible startup
# noise off stdout: )COPY's load_DUMP always writes "DUMPED <the copied
# file's mtime>" to COUT for any recognised library file, with no
# "silent" option exposed through the )COPY command itself (confirmed
# in GNU APL's own Command.cc: Workspace::copy_WS hardcodes
# silent=false). The adapter protocol's own contract reserves stdout
# for NDJSON events only, so that line cannot reach it -- this
# known-fixed-shape line is the only thing filtered; ConvexInit
# assigns away the *other* startup echo (the loaded native function's
# name) at the source instead, so filtering it here is not needed too.
# Known limitation: this pipeline loses the interpreter's own exit
# status; nothing here currently depends on it.
/usr/local/bin/apl -s -f /opt/convex/client/tests/conformance/adapter.apl -- "$@" | \
  while IFS= read -r line; do
    case $line in
      "DUMPED "*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
