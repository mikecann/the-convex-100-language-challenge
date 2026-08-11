"""Regressions for the canonical example's Convex number decoding."""

(import math os sys)
(sys.path.insert 0 (os.environ.get "CONVEX_EXAMPLE_PATH" "/work/examples/basics"))
(import main [whole])

(assert (= (whole 0 "integer") 0))
(assert (= (whole 1.0 "integral decimal") 1))

(for [invalid [True 1.5 "1" math.inf math.nan]]
  (try
    (whole invalid "invalid")
    (raise (AssertionError (+ "accepted invalid count " (repr invalid))))
    (except [RuntimeError] None)))

(print "PASS Hy canonical example number decoding")
