(ns run-tests (:require [clojure.test :as test] [client-test] [adapter-test]))
(let [result (test/run-tests 'client-test 'adapter-test)] (System/exit (if (test/successful? result) 0 1)))
