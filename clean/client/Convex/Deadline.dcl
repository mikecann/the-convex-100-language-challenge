definition module Convex.Deadline

// A small absolute-deadline helper shared by the transport, HTTP, and
// WebSocket layers. Every network operation in this client is bounded by one
// absolute deadline covering the whole operation, rather than a per-syscall
// timeout a trickling peer could keep resetting forever. Reading the clock is
// a real effect (a `ccall` to `clock_gettime`), so every function here
// threads `*World`.

:: Deadline = { atMs :: !Int }

deadlineIn :: !Int !*World -> (!Deadline, !*World)
remainingMs :: !Deadline !*World -> (!Int, !*World)
isExpired :: !Deadline !*World -> (!Bool, !*World)
nowMs :: !*World -> (!Int, !*World)
