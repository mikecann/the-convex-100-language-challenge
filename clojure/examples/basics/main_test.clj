(ns main-test
  (:require [clojure.test :refer [deftest is testing]]
            [main]))

(defn- decode [value]
  (#'main/count-of {"count" value} "test value"))

(defn- rejected? [value]
  (try
    (decode value)
    false
    (catch clojure.lang.ExceptionInfo _ true)))

(deftest count-decoding-accepts-only-in-range-integral-json-numbers
  (testing "Convex may encode mathematically integral JSON values with a decimal point"
    (is (= 0 (decode 0)))
    (is (= 1 (decode 1.0)))
    (is (= -2 (decode -2.0M))))
  (testing "unsafe representations are rejected rather than rounded or saturated"
    (is (rejected? 1.5))
    (is (rejected? "1"))
    (is (rejected? Double/NaN))
    (is (rejected? Double/POSITIVE_INFINITY))
    (is (rejected? 9223372036854775808N))))
