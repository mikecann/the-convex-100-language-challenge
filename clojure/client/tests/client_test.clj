(ns client-test (:require [clojure.test :refer [deftest is]] [convex.client :as convex]))
(deftest live-uri-and-bounded-queue
  (let [subscription (convex/->Subscription 1 "demo:state" {} (java.util.concurrent.ArrayBlockingQueue. 16) (atom true))]
    (doseq [value (range 20)] (convex/offer-newest! (:queue subscription) {:value value}))
    (is (= 4 (:value (convex/next-update subscription 1))))))
(deftest closed-client-is-rejected
  (let [client (convex/client "https://example.convex.cloud")]
    (.close client)
    (is (= :protocol (:kind (ex-data (try (convex/query client "demo:state" {}) (catch Exception error error))))))))
