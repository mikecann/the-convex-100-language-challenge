(ns live-test
  (:require [clojure.data.json :as json]
            [clojure.string :as string]
            [clojure.test :refer [deftest is testing]]
            [convex.client :as convex]
            [raw-websocket-fixture :as ws])
  (:import [java.net InetAddress ServerSocket]
           [java.nio.charset StandardCharsets]
           [java.util.concurrent ArrayBlockingQueue CountDownLatch ThreadPoolExecutor TimeUnit]
           [java.util.concurrent.atomic AtomicInteger]))

(defn- await! [message predicate]
  (let [deadline (+ (System/nanoTime) (.toNanos (java.time.Duration/ofSeconds 12)))]
    (loop []
      (if (predicate)
        true
        (if (< (System/nanoTime) deadline)
          (do (Thread/sleep 10) (recur))
          (throw (AssertionError. (if (fn? message) (message) message))))))))

(defn- ensure= [message expected actual]
  ;; Fixture handlers run on server threads, so clojure.test/is would report on
  ;; the wrong thread without failing the test. Throwing lets Fixture.close
  ;; deliver the failure back to the test thread deterministically.
  (when-not (= expected actual)
    (throw (AssertionError. (str message ": expected " (pr-str expected)
                                 ", got " (pr-str actual))))))

(defn- next-value [subscription]
  (loop []
    (let [update (convex/next-update subscription 12000)]
      (if (:error update) update (:value update)))))

(deftest fixture-thread-failures-return-to-the-test-thread
  (let [fixture (ws/fixture (fn [_ _] (throw (AssertionError. "fixture failure propagated"))))
        live (convex/live-client (ws/url fixture))]
    (try
      (convex/subscribe live "demo:state" {})
      (await! "fixture did not record its worker failure" #(some? @(:failure fixture)))
      (finally (.close live)))
    (is (= "fixture failure propagated"
           (try
             (.close fixture)
             "fixture close unexpectedly succeeded"
             (catch AssertionError error (.getMessage error)))))))

(deftest fragmented-multibyte-control-frames-query-failure-and-remove
  (let [remove-seen (CountDownLatch. 1)
        fixture (ws/fixture
                 (fn [connection _]
                   (ensure= "first client message" "Connect"
                            (get (ws/read-message! connection) "type"))
                   (let [add (ws/read-message! connection)]
                     (ensure= "subscription modification" "Add"
                              (get-in add ["modifications" 0 "type"])))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 1)
                                                 (ws/failed 0)))
                   (let [message (json/write-str
                                  (ws/transition (ws/version 1 1) (ws/version 1 2)
                                                 (ws/updated 0 {"count" 0 "label" "café"}
                                                             ["héllo"])))
                         bytes (.getBytes message StandardCharsets/UTF_8)
                         split (inc (.indexOf (vec bytes) (unchecked-byte 0xc3)))]
                     (ws/send-fragmented-text! connection message split))
                   (let [remove (ws/read-message! connection)]
                     (ensure= "unsubscribe modification" "Remove"
                              (get-in remove ["modifications" 0 "type"]))
                     (.countDown remove-seen))))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})
              failed (convex/next-update subscription 5000)
              recovered (convex/next-update subscription 5000)]
          (is (= :function (get-in failed [:error :kind])))
          (is (= {"code" "FIXTURE"} (get-in failed [:error :data])))
          (is (= {"count" 0 "label" "café"} (:value recovered)))
          (is (= ["héllo"] (:logs recovered)))
          (.close subscription)
          (is (.await remove-seen 3 TimeUnit/SECONDS))))
      (finally (.close fixture)))))

(deftest five-failed-handshakes-then-success-reset-backoff-and-metadata
  (let [connects (atom [])
        handshake-ready (CountDownLatch. 1)
        release-transition (CountDownLatch. 1)
        fixture (ws/fixture
                 {:reject-handshake? #(< % 5)}
                 (fn [connection index]
                   (ensure= "successful connection index" 5 index)
                   (let [connect (ws/read-message! connection)
                         add (ws/read-message! connection)]
                     (swap! connects conj connect)
                     (ensure= "reconnect subscription modification" "Add"
                              (get-in add ["modifications" 0 "type"]))
                     (.countDown handshake-ready)
                     (ensure= "transition release timed out"
                              true (.await release-transition 3 TimeUnit/SECONDS))
                     (ws/send-text! connection
                                    (ws/transition (ws/version 0 0) (ws/version 1 6)
                                                   (ws/updated 0 {"count" 1})))
                     (Thread/sleep 5000))))
        fixture-url (ws/url fixture)]
    (try
      (with-open [live (convex/live-client fixture-url)]
        (let [subscription (convex/subscribe live "demo:state" {})]
          (is (.await handshake-ready 10 TimeUnit/SECONDS))
          ;; No server message has been sent. The successful RFC 6455 handshake
          ;; itself must clear the exponential delay inherited from five failures.
          (is (= 100 (:backoff @(:state live))))
          (.countDown release-transition)
          (loop [errors 0]
            (let [update (convex/next-update subscription 12000)]
              (if (:error update)
                (recur (inc errors))
                (do
                  (is (= 5 errors))
                  (is (= {"count" 1} (:value update)))))))))
      (is (= 5 (get (first @connects) "connectionCount")))
      (is (string/includes? (get (first @connects) "lastCloseReason") "handshake"))
      (finally (.close fixture)))))

(deftest every-modification-is-strictly-validated-before-atomic-commit
  (let [invalid-items [["not-an-object"]
                       {"queryId" 0}
                       {"type" 7 "queryId" 0}
                       {"type" "QueryUpdated"}
                       {"type" "QueryUpdated" "queryId" -1 "value" nil}
                       {"type" "QueryUpdated" "queryId" "0" "value" nil}
                       {"type" "QueryUpdated" "queryId" 0}
                       {"type" "QueryUpdated" "queryId" 0 "value" nil "logLines" "bad"}
                       {"type" "QueryUpdated" "queryId" 0 "value" nil "logLines" ["ok" 7]}
                       {"type" "QueryFailed" "queryId" 0}
                       {"type" "QueryFailed" "queryId" 0 "errorMessage" 7}
                       {"type" "Unknown" "queryId" 0}]
        fixture (ws/fixture
                 (fn [connection index]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   (if (< index (count invalid-items))
                     ;; The valid-looking first update must not leak from a
                     ;; transaction whose later modification is malformed.
                     (ws/send-text! connection
                                    (ws/transition (ws/version 0 0) (ws/version 1 (inc index))
                                                   (ws/updated 0 {"count" 99})
                                                   (nth invalid-items index)))
                     (do
                       (ws/send-text! connection
                                      (ws/transition (ws/version 0 0) (ws/version 1 99)
                                                     (ws/updated 0 {"count" 1})))
                       (Thread/sleep 3000)))))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})]
          (loop [protocol-errors 0]
            (let [update (convex/next-update subscription 20000)]
              (if (:error update)
                (do
                  (is (= :protocol (get-in update [:error :kind])))
                  (recur (inc protocol-errors)))
                (do
                  (is (= (count invalid-items) protocol-errors))
                  (is (= {"count" 1} (:value update)))))))))
      (finally (.close fixture)))))

(deftest debug-disconnect-is-a-generation-barrier-and-deduplicates-hydration
  (let [connections (AtomicInteger. 0)
        fixture (ws/fixture
                 (fn [connection index]
                   (.incrementAndGet connections)
                   (let [connect (ws/read-message! connection)]
                     (ensure= "connection count" index (get connect "connectionCount"))
                     (when (pos? index)
                       ;; Reconnects carry the highest timestamp accepted from a
                       ;; complete transition, never a speculative partial one.
                       (ensure= "maximum observed timestamp"
                                ;; Connection five publishes one additional
                                ;; changed transition. If a very slow CI host lets
                                ;; the fixture's transport close first, the next
                                ;; automatic reconnect must carry that newer value.
                                (str "fixture-ts-" (if (>= index 6) (max index 7) index))
                                (get connect "maxObservedTimestamp"))))
                   (ws/read-message! connection)
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 (inc index))
                                                 (ws/updated 0 {"count" 0})))
                   (when (= index 5)
                     (ws/send-text! connection
                                    (ws/transition (ws/version 1 6) (ws/version 1 7)
                                                   (ws/updated 0 {"count" 1}))))
                   (Thread/sleep 30000)))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})]
          (is (= {"count" 0} (:value (convex/next-update subscription 5000))))
          (dotimes [attempt 5]
            (convex/debug-disconnect! live)
            (await! "debug reconnect did not become active"
                    #(and (= (+ attempt 2) (.get connections))
                          (some? (:socket @(:state live)))))
            (await! #(str "debug reconnect hydration did not become valid: "
                          (select-keys @(:state live)
                                       [:generation :connection-count :max-ts :remote-version
                                        :last-close-reason :socket :handshake]))
                    #(contains? (if (= attempt 4)
                                  #{"fixture-ts-6" "fixture-ts-7"}
                                  #{(str "fixture-ts-" (+ attempt 2))})
                                (:max-ts @(:state live)))))
          ;; Five unchanged rehydrations stay suppressed. Only the changed value crosses.
          (is (= {"count" 1} (:value (convex/next-update subscription 8000))))))
      (finally (.close fixture)))))

(deftest close-is-bounded-for-idle-continuous-and-partial-frame-peers
  (doseq [mode [:idle :continuous :partial]]
    (testing (name mode)
      (let [fixture (ws/fixture
                     ;; The client deliberately closes each peer while its handler is
                     ;; blocked or writing. EOF/SocketException is the expected outcome.
                     {:allow-peer-close? true}
                     (fn [connection _]
                       (ws/read-message! connection)
                       (ws/read-message! connection)
                       (case mode
                         :idle (Thread/sleep 10000)
                         :continuous (dotimes [_ 10000]
                                       (ws/send-frame! connection 9 true (.getBytes "x" StandardCharsets/UTF_8)))
                         :partial (do
                                    ;; Announce a 125-byte text frame, write one byte, then stall.
                                    (.write (:output connection)
                                            (byte-array [(unchecked-byte 0x81) (byte 125) (byte 123)]))
                                    (.flush (:output connection))
                                    (Thread/sleep 10000)))))]
        (try
          (let [live (convex/live-client (ws/url fixture))]
            (convex/subscribe live "demo:state" {})
            (await! "socket did not connect" #(some? (:socket @(:state live))))
            (let [started (System/nanoTime)]
              (.close live)
              (is (< (/ (- (System/nanoTime) started) 1000000.0) 1000.0))))
          (finally (.close fixture)))))))

(deftest stalled-handshake-unsubscribe-and-close-are-bounded
  (with-open [server (ServerSocket. 0 1 (InetAddress/getLoopbackAddress))]
    (let [accepted (CountDownLatch. 1)
          peer (future
                 (with-open [socket (.accept server)]
                   (.countDown accepted)
                   (Thread/sleep 10000)))
          live (convex/live-client (str "http://127.0.0.1:" (.getLocalPort server)))
          subscription (convex/subscribe live "demo:state" {})]
      (is (.await accepted 2 TimeUnit/SECONDS))
      (let [started (System/nanoTime)]
        (.close subscription)
        (.close live)
        (is (< (/ (- (System/nanoTime) started) 1000000.0) 1000.0)))
      (future-cancel peer))))

(deftest real-live-delivery-is-bounded-by-count-and-bytes
  (let [large (apply str (repeat 20000 "x"))
        fixture (ws/fixture
                 (fn [connection _]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   (let [updates (mapv #(ws/updated 0 {"count" % "payload" large}) (range 20))]
                     (ws/send-text! connection
                                    (apply ws/transition
                                           (ws/version 0 0) (ws/version 1 1) updates)))
                   (Thread/sleep 3000)))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})]
          (await! "bounded queue did not fill" #(>= (.size (:queue (:delivery subscription))) 10))
          (let [first-count (get-in (convex/next-update subscription 1000) [:value "count"])
                remaining (loop [values []]
                            (if-let [update (try (convex/next-update subscription 50)
                                                 (catch clojure.lang.ExceptionInfo _ nil))]
                              (recur (conj values (get-in update [:value "count"])))
                              values))]
            (is (pos? first-count))
            (is (= 19 (last remaining)))
            (is (<= (+ 1 (count remaining)) 16)))))
      (finally (.close fixture)))))

(deftest twenty-thousand-callbacks-use-demand-and-a-bounded-owner-queue
  (let [callback-count 20000
        fixture (ws/fixture
                 (fn [connection _]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   ;; The peer writes without waiting for the client. JDK demand
                   ;; must keep only one callback outstanding while owner catches up.
                   ;; Reuse the encoded protocol message so this pressure test
                   ;; measures callback/backpressure memory, not fixture JSON churn.
                   (dotimes [_ callback-count]
                     (ws/send-text! connection "{\"type\":\"Ping\"}"))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 1)
                                                 (ws/updated 0 {"count" callback-count})))
                   (Thread/sleep 3000)))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})
              update (convex/next-update subscription 30000)
              queue (.getQueue ^ThreadPoolExecutor (:owner live))]
          (is (= callback-count (get-in update [:value "count"])))
          (is (instance? ArrayBlockingQueue queue))
          (is (= 64 (+ (.size queue) (.remainingCapacity queue))))))
      (finally (.close fixture)))))

(deftest failed-send-retires-generation-and-recovers
  (let [fixture (ws/fixture
                 (fn [connection index]
                   (ws/read-message! connection)
                   (if (zero? index)
                     ;; Closing before Add completes forces the serialized send queue to fail.
                     (ws/close-transport! connection)
                     (do
                       (ws/read-message! connection)
                       (ws/send-text! connection
                                      (ws/transition (ws/version 0 0) (ws/version 1 2)
                                                     (ws/updated 0 {"count" 1})))
                       (Thread/sleep 3000)))))]
    (try
      (with-open [live (convex/live-client (ws/url fixture))]
        (let [subscription (convex/subscribe live "demo:state" {})
              recovered (loop [saw-transport? false]
                          (let [update (convex/next-update subscription 8000)]
                            (if (:error update)
                              (recur (or saw-transport? (= :transport (get-in update [:error :kind]))))
                              [saw-transport? update])))]
          (is (true? (first recovered)))
          (is (= {"count" 1} (:value (second recovered))))))
      (finally (.close fixture)))))
