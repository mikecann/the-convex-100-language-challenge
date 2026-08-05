# Ada

This language client is planned as roster entry 26.

No implementation exists and no capabilities have been earned.

## Measured native transport blocker

I investigated the maintained Ada Web Server (AWS) transport stack because it
provides Ada HTTPS and RFC 6455 client APIs, so it would permit a genuinely
native Convex implementation rather than a Node, Python, curl, or SDK bridge.

The Docker-only trial used Debian Bookworm slim on `linux/amd64`, GNAT 12.2,
the complete AWS source tree pinned at
`1f709a218bd9a6d20f055a94e56d5e72fb585477`, and its pinned
`templates-parser` submodule. `make setup` completed. `make build` stopped at:

```text
ssl.gpr:24:06: imported project file "gnatcoll_core" not found
gprbuild: "tools/tools.gpr" processing failed
make: *** [Makefile:140: build-awsres-tool-native] Error 5
```

Bookworm's `libgnatcoll21-dev=23.0.0-3` supplies the older `gnatcoll` project,
not the required `gnatcoll_core` project. A follow-up must pin and build
GNATCOLL Core inside Docker before attempting the client. It must then still
provide real Live delivery, the restricted non-scratch runtime, and the
root-owned local and hosted conformance evidence.

- Selection tier: `ranked`
- Implementation status: `planned`, with the blocker recorded above
- Earned capabilities: none
