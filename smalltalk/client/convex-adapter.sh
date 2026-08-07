#!/bin/sh
# Entry point of the conformance runtime image.
#
# The Pharo virtual machine lives outside PATH and is never a user-facing
# command: this launcher is the only way to start it, and the saved image it
# runs has had its evaluate, file-in, save, test and package handlers removed,
# so it answers exactly one command name.
set -eu
SQUEAK_PLUGINS=/opt/pharo/lib
LD_LIBRARY_PATH=/opt/pharo/lib
export SQUEAK_PLUGINS LD_LIBRARY_PATH
exec /opt/pharo/lib/pharo --headless /opt/convex-adapter.image convex-adapter "$@"
