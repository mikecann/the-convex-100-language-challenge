definition module Convex.Mem

from System._Pointer import :: Pointer

// World-threaded wrappers around the Clean distribution's own
// `System._Pointer` byte-level memory access and `System._Posix`
// malloc/free, used everywhere this client marshals a C struct by hand for
// a `ccall` (sockaddr, pollfd, hostent, the OpenSSL and getaddrinfo
// boundaries).
//
// This indirection exists because of two real, measured hazards against
// this exact Clean 3.1 toolchain, both arising from the fact that
// `System._Pointer`'s functions are plain functions of a `Pointer`
// (`Pointer :== Int`), with no `*World` and, for the writers, no forced use
// of their own result:
//
// 1. A read placed after a mutating `ccall` (`poll`, `getaddrinfo`) can
//    read back stale, pre-call bytes: nothing ties its evaluation to occur
//    after the effect it depends on, so the optimizer is free to schedule
//    it as early as its `Pointer` argument is available — immediately
//    after the `mallocSt` that produced the buffer, before the `ccall`
//    that fills it. A strict `#!` let does not fix this; it only forces
//    *that* thunk eagerly, not its position relative to unrelated pure
//    computations.
// 2. A write whose returned `Pointer` is discarded (bound to `_`, or to a
//    name never used again) can be dropped entirely: with nothing
//    observably depending on it, it looks like dead code to the optimizer,
//    even under `#!`.
//
// Every function below closes both holes by threading *and using* two
// things through every call: the `Pointer` itself (each write consumes the
// previous write's *returned* pointer, so no write's result is ever dead)
// and `*World` (unique, so the type checker — not a convention — forbids
// reordering it around the `ccall` whose effect a read depends on).

readByteW :: !Pointer !Int !*World -> (!Int, !*World)
writeByteW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)

readU16LEW :: !Pointer !Int !*World -> (!Int, !*World)
writeU16LEW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)

readU32LEW :: !Pointer !Int !*World -> (!Int, !*World)
writeU32LEW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)

// Reads a native machine word (the pointer width on this platform, 8 bytes
// on linux/amd64), matching what a C struct field declared as a pointer or
// `long` actually holds.
readWordW :: !Pointer !Int !*World -> (!Int, !*World)

zeroBytesW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)

mallocW :: !Int !*World -> (!Pointer, !*World)
freeW :: !Pointer !*World -> *World
