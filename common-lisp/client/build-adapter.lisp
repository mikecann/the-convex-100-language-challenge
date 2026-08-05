(load "/project/client/load.lisp")
(load "/project/client/tests/conformance/adapter.lisp")

(sb-ext:save-lisp-and-die "/out/convex-adapter"
                          :toplevel #'convex::adapter-main
                          :executable t
                          :save-runtime-options t
                          :purify t)
