(ns convex.example.main
  (:require [convex.client :as convex])
  (:import [java.util UUID]))

(defn- count-of [state operation]
  (let [count (get state "count")]
    (when-not (integer? count)
      (throw (ex-info (str operation " did not return a whole count") {})))
    count))

(defn- print-transcript [before initial applied mutation updated]
  (println (str "current count: " before))
  (println (str "live initial count: " initial))
  (println (str "mutation applied: " applied))
  (println (str "mutation count: " mutation))
  (println (str "live updated count: " updated))
  (println (str "verified count: " before " -> " updated)))

(defn -main [& args]
  ;; Read configuration from the verifier rather than baking a deployment into the image.
  (let [url (or (System/getenv "CONVEX_URL") (throw (ex-info "CONVEX_URL is required" {})))
        ;; A unique room keeps this demonstration independent from every other run.
        room (or (first args) "clojure-example")
        room-args {"room" room}]
    ;; The native Clojure HTTP client and Live worker are always closed, including on failure.
    (with-open [client (convex/client url) live (convex/live-client url)]
      ;; Ask Convex's HTTP query endpoint for the counter before subscribing.
      (let [before (count-of (:value (convex/query client "demo:state" room-args)) "current query")
            ;; Start Live before the mutation, so its first value is our observation point.
            subscription (convex/subscribe live "demo:state" room-args)
            initial (count-of (:value (convex/next-update subscription 10000)) "initial Live value")]
        (when-not (= before initial) (throw (ex-info "Live initial value disagreed" {})))
        ;; runId is the mutation's idempotency key, preventing a retry from incrementing twice.
        (let [mutation (:value (convex/mutation client "demo:increment" (assoc room-args "language" "clojure" "runId" (str (UUID/randomUUID)))))]
          (when-not (true? (get mutation "applied")) (throw (ex-info "mutation was not applied" {})))
          (let [after (count-of (get mutation "state") "mutation")
                ;; Consume the update from the existing subscription rather than polling HTTP again.
                updated (count-of (:value (convex/next-update subscription 10000)) "updated Live value")]
            (when-not (= after updated) (throw (ex-info "Live update disagreed" {})))
            (print-transcript before initial true after updated)))))))
