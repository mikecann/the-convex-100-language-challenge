(load "/project/client/load.lisp")
(load "/project/examples/basics/main.lisp")

(sb-ext:save-lisp-and-die "/out/convex-example"
                          :toplevel #'convex::example-main
                          :executable t
                          :save-runtime-options t
                          :purify t)
