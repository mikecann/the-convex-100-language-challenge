/-
`Convex` is the whole educational client: HTTP calls, Live subscriptions, and
the value and error types they hand back.

It is a demonstration of what a Convex client looks like in Lean 4, not an
official SDK.
-/

import Convex.Bytes
import Convex.Json
import Convex.Error
import Convex.Ffi
import Convex.Stream
import Convex.Http
import Convex.WebSocket
import Convex.Sync
import Convex.Live
import Convex.Client
