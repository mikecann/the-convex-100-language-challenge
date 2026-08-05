(ns adapter
  "Test-only NDJSON adapter v1. stdout is exclusively protocol events."
  (:gen-class)
  (:require [clojure.data.json :as json]
            [clojure.string :as string]
            [convex.client :as convex])
  (:import [java.io BufferedInputStream ByteArrayOutputStream InputStream OutputStreamWriter PrintWriter]
           [java.net InetAddress InetSocketAddress ServerSocket]
           [java.nio ByteBuffer]
           [java.nio.charset CodingErrorAction StandardCharsets]
           [java.util.concurrent ConcurrentHashMap TimeUnit]
           [java.util.concurrent.atomic AtomicLong]))

(def ^:private max-command-bytes (* 1024 1024))

(def before-publish-hook (atom nil))
(def inside-publication-lock-hook (atom nil))

(defn reset-test-hooks! []
  (reset! before-publish-hook nil)
  (reset! inside-publication-lock-hook nil))

(defn- error-name [error]
  (case (:kind (ex-data error))
    :function "FunctionError"
    :protocol "ProtocolError"
    :transport "TransportError"
    :closed "ClosedError"
    "Error"))

(defn- error-event [id subscription-id error]
  (let [data (ex-data error)
        detail (cond-> {"name" (error-name error)
                        "message" (or (.getMessage ^Throwable error) "error")}
                 (contains? data :data) (assoc "data" (:data data)))]
    (cond-> {"type" (if subscription-id "subscription" "error")
             "error" detail}
      (and (nil? subscription-id) (seq id)) (assoc "id" id)
      (seq subscription-id) (assoc "subscriptionId" subscription-id)
      (seq (:logs data)) (assoc "logs" (vec (:logs data))))))

(defrecord LockedWriter [^PrintWriter output closed]
  java.lang.AutoCloseable
  (close [_] (reset! closed true)))

(defn- writer [output]
  (->LockedWriter (PrintWriter. (OutputStreamWriter. output StandardCharsets/UTF_8) true)
                  (atom false)))

(defn- write-event! [writer event]
  (locking writer
    (when-not @(:closed writer)
      (.println ^PrintWriter (:output writer) (json/write-str event))
      (.flush ^PrintWriter (:output writer)))))

(defn- write-if-current! [writer current? before-check event]
  (locking writer
    (when before-check (before-check))
    (when (and (not @(:closed writer)) (current?))
      (.println ^PrintWriter (:output writer) (json/write-str event))
      (.flush ^PrintWriter (:output writer)))))

(defn- close-writer! [writer event]
  (locking writer
    (when (compare-and-set! (:closed writer) false true)
      (.println ^PrintWriter (:output writer) (json/write-str event))
      (.flush ^PrintWriter (:output writer)))))

(defn- relay! [subscription-id registration registrations writer]
  (doto
   (Thread.
    (fn []
      (try
        (while @(:active (:subscription registration))
          (let [update (try
                         (convex/next-update (:subscription registration) 250)
                         (catch clojure.lang.ExceptionInfo error
                           (when-not (= "timed out waiting for Live update" (.getMessage error))
                             (throw error))
                           nil))]
            (when update
              (when-let [hook @before-publish-hook]
                (hook subscription-id (:generation registration) update))
              (let [event (if-let [detail (:error update)]
                            (error-event nil subscription-id
                                         (ex-info (:message detail)
                                                  {:kind (:kind detail)
                                                   :data (:data detail)
                                                   :logs (:logs update)}))
                            (cond-> {"type" "subscription"
                                     "subscriptionId" subscription-id
                                     "value" (:value update)}
                              (seq (:logs update)) (assoc "logs" (:logs update))))]
                (write-if-current!
                 writer
                 #(and (identical? registration (.get registrations subscription-id))
                       @(:active (:subscription registration)))
                 #(when-let [hook @inside-publication-lock-hook]
                    (hook subscription-id (:generation registration)))
                 event)))))
        (catch InterruptedException _ (.interrupt (Thread/currentThread)))
        (catch Throwable error
          (write-if-current!
           writer
           #(and (identical? registration (.get registrations subscription-id))
                 @(:active (:subscription registration)))
           nil
           (error-event nil subscription-id error))))))
    (.setName (str "convex-clojure-adapter-relay-" (:generation registration)))
    (.setDaemon true)
    (.start)))

(defn- ack [id] {"type" "ack" "id" id})

(defn- decode-command-line [^ByteArrayOutputStream bytes]
  (try
    (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
                    (.onMalformedInput CodingErrorAction/REPORT)
                    (.onUnmappableCharacter CodingErrorAction/REPORT))
          decoded (str (.decode decoder (ByteBuffer/wrap (.toByteArray bytes))))]
      (if (.endsWith decoded "\r")
        (subs decoded 0 (dec (count decoded)))
        decoded))
    (catch java.nio.charset.CharacterCodingException error
      (throw (ex-info "adapter command is not valid UTF-8"
                      {:kind :protocol :cause error})))))

(defn- read-command-line! [^InputStream input]
  ;; BufferedReader.readLine grows until newline. A hostile controller could
  ;; therefore allocate tens of megabytes before JSON decoding gets a chance to
  ;; reject anything. Count encoded bytes first and fail the connection at 1 MiB.
  (let [bytes (ByteArrayOutputStream. 8192)]
    (loop []
      (let [byte (.read input)]
        (cond
          (= -1 byte) (when (pos? (.size bytes)) (decode-command-line bytes))
          (= 10 byte) (decode-command-line bytes)
          (>= (.size bytes) max-command-bytes)
          (throw (ex-info (str "adapter command exceeds " max-command-bytes " encoded bytes")
                          {:kind :protocol :fatal true}))
          :else (do (.write bytes byte) (recur)))))))

(defn run-adapter! [input output deployment]
  (let [reader (BufferedInputStream. input 8192)
        out (writer output)
        client (atom nil)
        registrations (ConcurrentHashMap.)
        generation (AtomicLong. 1)]
    (letfn [(get-client []
              (or @client
                  (let [url (or deployment
                                (throw (ex-info "CONVEX_URL is required" {:kind :protocol})))
                        created (convex/client url)]
                    (when-let [token (System/getenv "CONVEX_AUTH_TOKEN")]
                      (when (seq token) (convex/set-auth! created token)))
                    (reset! client created)
                    created)))
            (process! [command]
              (let [id (get command "id") operation (get command "op")]
                (case operation
                  "hello"
                  (do
                    (when-not (= 1 (get command "protocolVersion"))
                      (throw (ex-info "unsupported adapter protocol version" {:kind :protocol})))
                    (write-event! out {"type" "ready" "id" id "protocolVersion" 1
                                       "language" "clojure" "implementation" "native-clojure-jdk21"
                                       "runtime" (System/getProperty "java.runtime.version")})
                    false)

                  ("query" "mutation" "action")
                  (let [result (convex/call (get-client) operation (get command "path")
                                            (get command "args" {}))]
                    (write-event! out (cond-> {"type" "result" "id" id "value" (:value result)}
                                        (seq (:logs result)) (assoc "logs" (:logs result))))
                    false)

                  "setAuth"
                  (do (convex/set-auth! (get-client) (get command "token" ""))
                      (write-event! out (ack id)) false)

                  "subscribe"
                  (let [subscription-id (get command "subscriptionId")
                        _ (when-not (seq subscription-id)
                            (throw (ex-info "subscriptionId is required" {:kind :protocol})))
                        old (.remove registrations subscription-id)]
                    ;; Closing the old generation before publishing ack is the replacement barrier.
                    (when old (.close ^java.lang.AutoCloseable (:subscription old)))
                    (let [subscription (convex/subscribe-client (get-client) (get command "path")
                                                                (get command "args" {}))
                          registration {:generation (.getAndIncrement generation)
                                        :subscription subscription}]
                      (.put registrations subscription-id registration)
                      (write-event! out (ack id))
                      (relay! subscription-id registration registrations out))
                    false)

                  "unsubscribe"
                  (do
                    (when-let [registration (.remove registrations (get command "subscriptionId"))]
                      (.close ^java.lang.AutoCloseable (:subscription registration)))
                    ;; The writer lock is shared with relay publication. Once ack is visible,
                    ;; no invalidated generation can publish another event.
                    (write-event! out (ack id))
                    false)

                  "debugDisconnect"
                  (do (convex/debug-disconnect-client! (get-client))
                      (write-event! out (ack id)) false)

                  "close"
                  (do
                    (doseq [registration (iterator-seq (.iterator (.values registrations)))]
                      (.close ^java.lang.AutoCloseable (:subscription registration)))
                    (.clear registrations)
                    (when @client (.close ^java.lang.AutoCloseable @client))
                    (close-writer! out {"type" "closed" "id" id})
                    true)

                  (throw (ex-info (str "unknown operation " operation) {:kind :protocol})))))]
      (try
        (loop []
          (let [line (try
                       (read-command-line! reader)
                       (catch clojure.lang.ExceptionInfo error
                         (write-event! out (error-event nil nil error))
                         ::fatal-input))]
            (cond
              (nil? line) nil
              (= ::fatal-input line) nil
              (string/blank? line) (recur)
              :else
              (let [command (try
                              (json/read-str line)
                              (catch Exception error
                                (write-event! out
                                              (error-event nil nil
                                                           (ex-info (str "decode command: " (.getMessage error))
                                                                    {:kind :protocol})))
                                nil))
                    stop? (if command
                            (try
                              (process! command)
                              (catch Throwable error
                                ;; Per-command failures retain correlation and the stream continues.
                                (write-event! out (error-event (get command "id") nil error))
                                false))
                            false)]
                (when-not stop? (recur))))))
        (finally
          (doseq [registration (iterator-seq (.iterator (.values registrations)))]
            (.close ^java.lang.AutoCloseable (:subscription registration)))
          (.clear registrations)
          (when @client (.close ^java.lang.AutoCloseable @client)))))))

(defn parse-listen-address [address]
  (let [split (.lastIndexOf ^String address ":")]
    (when (or (<= split 0) (= split (dec (count address))))
      (throw (IllegalArgumentException. "ADAPTER_LISTEN must be host:port")))
    [(subs address 0 split) (Integer/parseInt (subs address (inc split)))]))

(defn- bind [address]
  (let [[host port] (parse-listen-address address)
        server (ServerSocket.)]
    (.bind server (InetSocketAddress. (InetAddress/getByName host) port))
    server))

(defn -main [& _]
  (if-let [address (System/getenv "ADAPTER_LISTEN")]
    (with-open [server (bind address)
                socket (.accept server)]
      (run-adapter! (.getInputStream socket) (.getOutputStream socket)
                    (System/getenv "CONVEX_URL")))
    (run-adapter! System/in System/out (System/getenv "CONVEX_URL"))))
