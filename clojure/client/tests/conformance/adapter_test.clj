(ns adapter-test
  (:require [adapter :as adapter]
            [clojure.data.json :as json]
            [clojure.string :as string]
            [clojure.test :refer [deftest is]]
            [raw-websocket-fixture :as ws])
  (:import [com.sun.net.httpserver HttpHandler HttpServer]
           [java.io BufferedReader ByteArrayInputStream ByteArrayOutputStream InputStreamReader PipedInputStream PipedOutputStream]
           [java.net InetAddress InetSocketAddress ServerSocket Socket]
           [java.nio.charset StandardCharsets]
           [java.util.concurrent ArrayBlockingQueue CountDownLatch TimeUnit]))

(defn- http-fixture []
  (let [server (HttpServer/create (InetSocketAddress. (InetAddress/getLoopbackAddress) 0) 0)]
    (.createContext server "/"
                    (reify HttpHandler
                      (handle [_ exchange]
                        (let [command (json/read-str
                                       (String. (.readAllBytes (.getRequestBody exchange))
                                                StandardCharsets/UTF_8))
                              failed? (= "demo:fail" (get command "path"))
                              body (json/write-str
                                    (if failed?
                                      {"status" "error" "errorMessage" "nope"
                                       "errorData" {"code" "NOPE"} "logLines" ["failed"]}
                                      {"status" "success" "value" {"count" 1}
                                       "logLines" ["ok"]}))
                              bytes (.getBytes body StandardCharsets/UTF_8)]
                          (.sendResponseHeaders exchange (if failed? 560 200) (alength bytes))
                          (with-open [output (.getResponseBody exchange)] (.write output bytes))))))
    (.start server)
    {:server server :url (str "http://127.0.0.1:" (.getPort (.getAddress server)))}))

(defn- command [id operation & [fields]]
  (merge {"id" id "op" operation} fields))

(defn- run-string [commands deployment]
  (let [input (str (string/join "\n" (map json/write-str commands)) "\n")
        output (ByteArrayOutputStream.)]
    (adapter/run-adapter! (ByteArrayInputStream. (.getBytes input StandardCharsets/UTF_8))
                          output deployment)
    (mapv json/read-str (remove string/blank?
                                (string/split-lines (.toString output StandardCharsets/UTF_8))))))

(defrecord AdapterHarness [controller-output controller-input adapter-input adapter-output
                           events running reader]
  java.lang.AutoCloseable
  (close [_]
    (.close ^PipedOutputStream controller-output)
    (deref running 2000 nil)
    (.close ^PipedOutputStream adapter-output)
    (.close ^PipedInputStream controller-input)
    (.close ^PipedInputStream adapter-input)
    (future-cancel reader)))

(defn- adapter-harness [deployment]
  (let [controller-output (PipedOutputStream.)
        adapter-input (PipedInputStream. controller-output)
        adapter-output (PipedOutputStream.)
        controller-input (PipedInputStream. adapter-output)
        events (ArrayBlockingQueue. 32)
        running (future (adapter/run-adapter! adapter-input adapter-output deployment))
        reader (future
                 (with-open [lines (BufferedReader.
                                    (InputStreamReader. controller-input StandardCharsets/UTF_8))]
                   (loop []
                     (when-let [line (.readLine lines)]
                       (.put events (json/read-str line))
                       (recur)))))]
    (->AdapterHarness controller-output controller-input adapter-input adapter-output
                      events running reader)))

(defn- send-command! [harness value]
  (.write ^PipedOutputStream (:controller-output harness)
          (.getBytes (str (json/write-str value) "\n") StandardCharsets/UTF_8))
  (.flush ^PipedOutputStream (:controller-output harness)))

(defn- next-event [harness & [timeout-ms]]
  (or (.poll ^ArrayBlockingQueue (:events harness) (or timeout-ms 3000) TimeUnit/MILLISECONDS)
      (throw (AssertionError. "adapter event timed out"))))

(defn- no-event? [harness]
  (nil? (.poll ^ArrayBlockingQueue (:events harness) 250 TimeUnit/MILLISECONDS)))

(defn- ensure! [message condition]
  ;; Raw fixture callbacks execute off the test thread. Throw so Fixture.close
  ;; carries a failed server-side expectation back into clojure.test.
  (when-not condition (throw (AssertionError. message))))

(deftest command-errors-are-correlated-structured-and-stream-continues
  (let [fixture (http-fixture)]
    (try
      (let [events (run-string
                    [(command "h" "hello" {"protocolVersion" 1})
                     (command "q" "query" {"path" "demo:state" "args" {}})
                     (command "f" "query" {"path" "demo:fail" "args" {}})
                     (command "bad" "wat")
                     (command "q2" "query" {"path" "demo:state" "args" {}})
                     (command "c" "close")]
                    (:url fixture))]
        (is (= ["ready" "result" "error" "error" "result" "closed"]
               (mapv #(get % "type") events)))
        (is (= ["f" "bad"] (mapv #(get % "id") (subvec events 2 4))))
        (is (= "FunctionError" (get-in events [2 "error" "name"])))
        (is (= {"code" "NOPE"} (get-in events [2 "error" "data"])))
        (is (= ["failed"] (get-in events [2 "logs"])))
        (is (= "ProtocolError" (get-in events [3 "error" "name"])))
        (is (= {"count" 1} (get-in events [4 "value"])))
        (is (every? #(not-any? nil? (vals %)) events)))
      (finally (.stop ^HttpServer (:server fixture) 0)))))

(deftest partial-stdin-lines-flush-before-eof-and-clean-eof-stops
  (let [controller (PipedOutputStream.)
        adapter-input (PipedInputStream. controller)
        adapter-output (PipedOutputStream.)
        controller-input (PipedInputStream. adapter-output)
        reader (BufferedReader. (InputStreamReader. controller-input StandardCharsets/UTF_8))
        running (future (adapter/run-adapter! adapter-input adapter-output nil))
        hello (json/write-str (command "h" "hello" {"protocolVersion" 1}))]
    (.write controller (.getBytes (subs hello 0 8) StandardCharsets/UTF_8))
    (.flush controller)
    (is (nil? (.poll (java.util.concurrent.ArrayBlockingQueue. 1))))
    (.write controller (.getBytes (str (subs hello 8) "\n") StandardCharsets/UTF_8))
    (.flush controller)
    (is (= "ready" (get (json/read-str (.readLine reader)) "type")))
    ;; EOF without a close command still terminates and cleans up.
    (.close controller)
    (is (not= ::timeout (deref running 2000 ::timeout)))
    (.close adapter-output)
    (.close controller-input)))

(deftest tcp-stream-uses-the-same-partial-ndjson-and-flushes
  (is (= ["127.0.0.1" 3210] (adapter/parse-listen-address "127.0.0.1:3210")))
  (with-open [server (ServerSocket. 0 1 (InetAddress/getLoopbackAddress))]
    (let [running (future
                    (with-open [peer (.accept server)]
                      (adapter/run-adapter! (.getInputStream peer) (.getOutputStream peer) nil)))]
      (with-open [controller (Socket. (InetAddress/getLoopbackAddress) (.getLocalPort server))]
        (let [output (.getOutputStream controller)
              reader (BufferedReader. (InputStreamReader. (.getInputStream controller) StandardCharsets/UTF_8))
              hello (str (json/write-str (command "h" "hello" {"protocolVersion" 1})) "\n")]
          (.write output (.getBytes (subs hello 0 5) StandardCharsets/UTF_8))
          (.flush output)
          (.write output (.getBytes (subs hello 5) StandardCharsets/UTF_8))
          (.flush output)
          (is (= "ready" (get (json/read-str (.readLine reader)) "type")))
          (.write output (.getBytes (str (json/write-str (command "c" "close")) "\n") StandardCharsets/UTF_8))
          (.flush output)
          (is (= "closed" (get (json/read-str (.readLine reader)) "type")))))
      (is (not= ::timeout (deref running 2000 ::timeout))))))

(deftest live-function-error-data-is-preserved-and-recovers
  (let [fixture (ws/fixture
                 (fn [connection _]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 1)
                                                 (ws/failed 0)))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 1 1) (ws/version 1 2)
                                                 (ws/updated 0 {"count" 1})))
                   (Thread/sleep 3000)))
        harness (adapter-harness (ws/url fixture))]
    (try
      (send-command! harness (command "s" "subscribe"
                                      {"subscriptionId" "sub" "path" "demo:state" "args" {}}))
      (is (= "ack" (get (next-event harness) "type")))
      (let [failed (next-event harness)
            recovered (next-event harness)]
        (is (= "FunctionError" (get-in failed ["error" "name"])))
        (is (= {"code" "FIXTURE"} (get-in failed ["error" "data"])))
        (is (= 1 (get-in recovered ["value" "count"]))))
      (send-command! harness (command "c" "close"))
      (is (= "closed" (get (next-event harness) "type")))
      (finally (.close harness) (.close fixture)))))

(deftest replacement-and-unsubscribe-acks-are-stale-relay-barriers
  (let [send-old (CountDownLatch. 1)
        send-new (CountDownLatch. 1)
        send-blocked (CountDownLatch. 1)
        fixture (ws/fixture
                 (fn [connection _]
                   (ws/read-message! connection)
                   (ws/read-message! connection)
                   (ensure! "old-value gate timed out" (.await send-old 3 TimeUnit/SECONDS))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 0 0) (ws/version 1 1)
                                                 (ws/updated 0 {"count" 1})))
                   (ensure! "replacement did not remove the old query"
                            (= "Remove" (get-in (ws/read-message! connection)
                                                ["modifications" 0 "type"])))
                   (ensure! "replacement did not add the new query"
                            (= "Add" (get-in (ws/read-message! connection)
                                             ["modifications" 0 "type"])))
                   (ensure! "new-value gate timed out" (.await send-new 3 TimeUnit/SECONDS))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 1 1) (ws/version 3 2)
                                                 (ws/updated 1 {"count" 2})))
                   (ensure! "blocked-value gate timed out"
                            (.await send-blocked 3 TimeUnit/SECONDS))
                   (ws/send-text! connection
                                  (ws/transition (ws/version 3 2) (ws/version 3 3)
                                                 (ws/updated 1 {"count" 3})))
                   (ws/read-message! connection)
                   (Thread/sleep 2000)))
        harness (adapter-harness (ws/url fixture))]
    (try
      (let [old-dequeued (CountDownLatch. 1)
            release-old (CountDownLatch. 1)]
        (reset! adapter/before-publish-hook
                (fn [_ generation _]
                  (when (= 1 generation)
                    (.countDown old-dequeued)
                    (.await release-old))))
        (send-command! harness (command "one" "subscribe"
                                        {"subscriptionId" "sub" "path" "demo:old" "args" {}}))
        (is (= "ack" (get (next-event harness) "type")))
        (.countDown send-old)
        (is (.await old-dequeued 3 TimeUnit/SECONDS))
        (send-command! harness (command "two" "subscribe"
                                        {"subscriptionId" "sub" "path" "demo:new" "args" {}}))
        (is (= "ack" (get (next-event harness) "type")))
        (.countDown release-old)
        (is (no-event? harness))

        (reset! adapter/before-publish-hook nil)
        (.countDown send-new)
        (is (= 2 (get-in (next-event harness) ["value" "count"])))

        (let [inside-lock (CountDownLatch. 1)
              release-lock (CountDownLatch. 1)]
          (reset! adapter/inside-publication-lock-hook
                  (fn [_ generation]
                    (when (= 2 generation)
                      (.countDown inside-lock)
                      (.await release-lock))))
          (.countDown send-blocked)
          (is (.await inside-lock 3 TimeUnit/SECONDS))
          (send-command! harness (command "three" "unsubscribe" {"subscriptionId" "sub"}))
          (is (no-event? harness))
          (.countDown release-lock)
          (is (= "ack" (get (next-event harness) "type")))
          (is (no-event? harness)))

        (send-command! harness (command "close" "close"))
        (is (= "closed" (get (next-event harness) "type"))))
      (finally
        (adapter/reset-test-hooks!)
        (.close harness)
        (.close fixture)))))
