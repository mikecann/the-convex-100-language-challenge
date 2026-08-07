/-
Entry point for the conformance executable installed as
`/usr/local/bin/convex-adapter`.

The adapter itself lives in `Adapter.lean` so the language-local tests can
import and drive its internals -- the output queue and the relay barriers --
without starting a process.
-/

import Tests.Conformance.Adapter

def main (arguments : List String) : IO UInt32 := Tests.Conformance.adapterMain arguments
