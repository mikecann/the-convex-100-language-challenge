||| Entry point for `/usr/local/bin/convex-adapter`.
|||
||| It is deliberately trivial: everything the shared controller exercises
||| lives in `Conformance.Adapter`, which the adapter's own tests import, so the
||| binary the controller drives and the code the tests cover are the same code.
module Main

import Conformance.Adapter

main : IO ()
main = runAdapter
