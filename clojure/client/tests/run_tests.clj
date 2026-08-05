(ns run-tests
  (:require [adapter-test]
            [client-test]
            [clojure.test :as test]
            [live-test]
            [main-test]))

(let [result (test/run-tests 'client-test 'live-test 'adapter-test 'main-test)]
  (System/exit (if (test/successful? result) 0 1)))
