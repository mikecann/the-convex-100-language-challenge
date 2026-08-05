# Pinned realtime protocol profiles

Convex realtime is an internal wire protocol, not a documented third-party API.
Every native implementation must therefore name one inspected upstream profile
and treat hosted compatibility drift as expected evidence.

## `convex-rs-0.10.4-unversioned-sync`

The Go pilot implements only this profile:

| Property | Pinned value |
| --- | --- |
| Upstream | `get-convex/convex-rs` |
| Version | `0.10.4` |
| Commit | `6f1df8a8ba1665084ec001e307ca841ca17074d7` |
| Endpoint | `/api/sync` |
| Transition chunks | Present in sync types, but not assembled by the pinned base client; Go treats one as profile drift |
| Timestamps | Opaque base64 strings |

The implementation covers query-set add/remove, atomic transition application,
initial and later query values, query failures, reconnect with active-query
rebuild, unsubscribe, and clean close.

The Go pilot does not combine this profile with Convex JavaScript 1.43.0. That
client uses `/api/1.43.0/sync`, retains different session state, and assembles
`TransitionChunk`. JavaScript 1.43.0 at commit
`8acd427d94ffb2ce9816283d791e74745fc89906` is used as a semantic oracle and
hosted drift comparison only.

Authentication rotation, WebSocket mutations/actions, mutation replay,
read-your-own-write commit timestamps, full Convex values, journals, optimistic
updates, and large-transition chunk assembly are outside the current HTTP and
Live scope.
