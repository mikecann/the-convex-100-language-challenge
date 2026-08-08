#!/bin/sh
# Entry point of the example runtime image.
#
# The first argument is the verifier's unique room identifier and is passed
# straight through to the saved image's convex-example command. Running the
# image by hand with no argument falls back to a friendly default room.
set -eu
SQUEAK_PLUGINS=/opt/pharo/lib
LD_LIBRARY_PATH=/opt/pharo/lib
export SQUEAK_PLUGINS LD_LIBRARY_PATH
exec /opt/pharo/lib/pharo --headless /opt/convex-example.image convex-example "$@"
