(ns pressure-runner
  "Small AOT pressure harnesses for running the two allocation attacks under a
  container memory limit without loading the rest of clojure.test."
  (:gen-class)
  (:require [adapter]
            [clojure.data.json :as json]
            [clojure.string :as string]
            [convex.client :as convex]
            [raw-websocket-fixture :as ws])
  (:import [java.io ByteArrayOutputStream InputStream]
           [java.nio.charset StandardCharsets]
           [java.util.concurrent ArrayBlockingQueue ThreadPoolExecutor]
           [java.util.concurrent.atomic AtomicLong]))

(defn- ensure! [message condition]
  (when-not condition (throw (AssertionError. message))))

(defn- callback-attack! []
  (let [callback-count 20000
        fixture (ws/fixture
                 (fn [connection _]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   (dotimes [_ callback-count]
                     (ws/send-text! connection "{\"type\":\"Ping\"}"))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 1)
                                                 (ws/updated 0 {"count" callback-count})))))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})
              update (convex/next-update subscription 30000)
              queue (.getQueue ^ThreadPoolExecutor (:owner live))]
          (ensure! "20,000th callback was not delivered"
                   (= callback-count (get-in update [:value "count"])))
          (ensure! "Live owner queue is not bounded"
                   (and (instance? ArrayBlockingQueue queue)
                        (= 64 (+ (.size queue) (.remainingCapacity queue)))))))
      (finally (.close fixture))))
  (println "PASS 20,000 callback pressure attack"))

(defn- repeating-input [total byte-value ^AtomicLong consumed]
  (let [remaining (atom total)]
    (proxy [InputStream] []
      (read
        ([]
         (if (zero? @remaining)
           -1
           (do (swap! remaining dec)
               (.incrementAndGet consumed)
               byte-value)))
        ([buffer offset length]
         (if (zero? @remaining)
           -1
           (let [amount (int (min @remaining length))]
             (java.util.Arrays/fill ^bytes buffer offset (+ offset amount) (byte byte-value))
             (swap! remaining - amount)
             (.addAndGet consumed amount)
             amount)))))))

(defn- partial-line-attack! []
  (let [consumed (AtomicLong. 0)
        input (repeating-input (* 70 1024 1024) (int \{) consumed)
        output (ByteArrayOutputStream.)
        started (System/nanoTime)]
    (adapter/run-adapter! input output nil)
    (let [elapsed-ms (/ (- (System/nanoTime) started) 1000000.0)
          event (json/read-str (string/trim (.toString output StandardCharsets/UTF_8)))]
      (ensure! "oversized command did not return ProtocolError"
               (and (= "error" (get event "type"))
                    (= "ProtocolError" (get-in event ["error" "name"]))))
      (ensure! "adapter consumed the 70 MiB partial line"
               (< (.get consumed) (* 2 1024 1024)))
      (ensure! "oversized command rejection was not bounded" (< elapsed-ms 3000.0))))
  (println "PASS 70 MiB partial-line pressure attack"))

(defn -main [& [mode]]
  (case mode
    "callbacks" (callback-attack!)
    "partial-line" (partial-line-attack!)
    (throw (IllegalArgumentException. "expected callbacks or partial-line"))))
