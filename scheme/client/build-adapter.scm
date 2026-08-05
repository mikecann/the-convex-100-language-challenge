;; Compile the public module and its conformance entrypoint into one native
;; executable. Keeping the wrapper tiny makes the final image independent of a
;; CHICKEN repository or runtime source tree.
(include "client/convex.scm")
(include "client/tests/conformance/adapter.scm")
