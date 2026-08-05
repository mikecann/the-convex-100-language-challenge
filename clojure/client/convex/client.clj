(ns convex.client
  "Educational native Clojure Convex HTTP and pinned Live sync-profile client."
  (:require [clojure.data.json :as json]
            [clojure.string :as string])
  (:import [java.math BigInteger]
           [java.net URI]
           [java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers WebSocket WebSocket$Listener]
           [java.nio ByteBuffer]
           [java.nio.charset StandardCharsets]
           [java.time Duration]
           [java.util ArrayDeque Base64 LinkedHashMap UUID]
           [java.util.concurrent ArrayBlockingQueue Callable CompletableFuture CompletionException ExecutionException Executors RejectedExecutionException ScheduledExecutorService ThreadFactory ThreadPoolExecutor ThreadPoolExecutor$AbortPolicy TimeUnit TimeoutException]
           [java.util.function BiConsumer]))

(def ^:private max-http-bytes (* 2 1024 1024))
(def ^:private max-update-count 16)
(def ^:private max-update-bytes (* 4 1024 1024))
(def ^:private max-owner-events 64)
(def ^:private max-pending-sends 64)
(def ^:private max-live-message-bytes (* 2 1024 1024))
(def ^:private initial-timestamp "AAAAAAAAAAA=")
(def ^:private initial-backoff-ms 100)
(def ^:private max-backoff-ms 15000)

;; Language-local barrier tests pause after a real JDK send future completes.
;; Normal clients leave this nil; it never changes wire behavior.
(def send-completion-hook (atom nil))

(defn reset-test-hooks! [] (reset! send-completion-hook nil))

(defn- failure [kind message & [fields]]
  (ex-info message (merge {:kind kind} fields)))

(defn- unwrap-error [error]
  (loop [current error]
    (if (and (or (instance? CompletionException current)
                 (instance? ExecutionException current))
             (.getCause ^Throwable current))
      (recur (.getCause ^Throwable current))
      current)))

(defn- deployment-url [raw]
  (let [uri (URI/create raw)]
    (when-not (and (#{"http" "https"} (.getScheme uri))
                   (.getHost uri)
                   (nil? (.getUserInfo uri)))
      (throw (failure :protocol "Convex deployment URL must be an absolute HTTP(S) URL without user information")))
    (string/replace (str (URI. (.getScheme uri) nil (.getHost uri) (.getPort uri)
                               (.getPath uri) nil nil)) #"/+$" "")))

(defrecord Client [url ^HttpClient http token closed live]
  java.lang.AutoCloseable
  (close [_]
    (when (compare-and-set! closed false true)
      (when-let [manager @live] (.close ^java.lang.AutoCloseable manager))
      (.shutdownNow http)
      (.close http))))

(defn client [url]
  (->Client (deployment-url url)
            (-> (HttpClient/newBuilder)
                (.connectTimeout (Duration/ofSeconds 10))
                (.build))
            (atom "") (atom false) (atom nil)))

(defn set-auth! [client token]
  (when @(:closed client) (throw (failure :closed "Convex client is closed")))
  (reset! (:token client) (or token "")))

(defn call [client operation path args]
  (when @(:closed client) (throw (failure :closed "Convex client is closed")))
  (when-not (and (string? path) (seq path))
    (throw (failure :protocol "Convex function path is required")))
  (when-not (map? args)
    (throw (failure :protocol "Convex arguments must be a named JSON object")))
  (let [body (json/write-str {"path" path "args" args "format" "json"})
        builder (-> (HttpRequest/newBuilder (URI/create (str (:url client) "/api/" operation)))
                    (.timeout (Duration/ofSeconds 30))
                    (.header "Content-Type" "application/json")
                    (.header "Accept" "application/json")
                    (.header "Convex-Client" "clojure-0.1.0"))
        builder (if (seq @(:token client))
                  (.header builder "Authorization" (str "Bearer " @(:token client)))
                  builder)
        request (-> builder
                    (.POST (HttpRequest$BodyPublishers/ofString body StandardCharsets/UTF_8))
                    (.build))
        response (try
                   (.send ^HttpClient (:http client) request (HttpResponse$BodyHandlers/ofByteArray))
                   (catch Exception error
                     (throw (failure :transport (or (.getMessage error) "HTTP transport failed")
                                     {:operation operation :cause error}))))
        bytes (.body response)]
    (when (> (alength ^bytes bytes) max-http-bytes)
      (throw (failure :transport (str "response exceeds " max-http-bytes " bytes")
                      {:operation operation})))
    (let [decoded (try
                    (json/read-str (String. ^bytes bytes StandardCharsets/UTF_8))
                    (catch Exception error
                      (throw (failure :transport
                                      (str "HTTP " (.statusCode response) " returned non-Convex JSON")
                                      {:operation operation :cause error}))))
          raw-logs (get decoded "logLines" [])
          _ (when-not (and (vector? raw-logs) (every? string? raw-logs))
              (throw (failure :protocol "HTTP response logLines must be an array of strings"
                              {:operation operation})))
          logs raw-logs]
      (case (get decoded "status")
        "success" (if (contains? decoded "value")
                    {:value (get decoded "value") :logs logs}
                    (throw (failure :protocol "success response omitted value")))
        "error" (throw (failure :function (get decoded "errorMessage" "Convex function failed")
                                {:operation operation :data (get decoded "errorData") :logs logs}))
        (throw (failure :protocol
                        (str "HTTP " (.statusCode response) " response has an unknown status")))))))

(defn query [client path args] (call client "query" path args))
(defn mutation [client path args] (call client "mutation" path args))
(defn action [client path args] (call client "action" path args))

;; Every subscription shares one budget. Otherwise many slow subscriptions can
;; each retain their own allowance and defeat what looks like a bounded client.
(defrecord DeliveryBudget [entries count bytes])
(defrecord DeliveryItem [delivery update size active])
(defrecord DeliveryQueue [^ArrayBlockingQueue queue budget]
  java.lang.AutoCloseable
  (close [this]
    (locking budget
      (doseq [^DeliveryItem item (iterator-seq (.iterator queue))]
        (when (compare-and-set! (:active item) true false)
          (.remove ^ArrayDeque (:entries budget) item)
          (swap! (:count budget) dec)
          (swap! (:bytes budget) - (:size item))))
      (.clear queue))))

(defn- delivery-budget []
  (->DeliveryBudget (ArrayDeque.) (atom 0) (atom 0)))

(defn- delivery-queue [budget]
  (->DeliveryQueue (ArrayBlockingQueue. max-update-count) budget))

(defn- update-size [update]
  (alength (.getBytes (json/write-str update) StandardCharsets/UTF_8)))

(defn- offer-update! [delivery update]
  (let [size (update-size update)
        budget (:budget delivery)]
    (locking budget
      (when (<= size max-update-bytes)
        (while (or (= max-update-count @(:count budget))
                   (> (+ @(:bytes budget) size) max-update-bytes))
          (when-let [^DeliveryItem oldest (.pollFirst ^ArrayDeque (:entries budget))]
            (when (compare-and-set! (:active oldest) true false)
              (.remove ^ArrayBlockingQueue (:queue (:delivery oldest)) oldest)
              (swap! (:count budget) dec)
              (swap! (:bytes budget) - (:size oldest)))))
        (let [item (->DeliveryItem delivery update size (atom true))]
          (.addLast ^ArrayDeque (:entries budget) item)
          (.offer ^ArrayBlockingQueue (:queue delivery) item)
          (swap! (:count budget) inc)
          (swap! (:bytes budget) + size))))))

(defn- poll-update! [delivery timeout-ms]
  (let [deadline (+ (System/nanoTime) (* timeout-ms 1000000))
        budget (:budget delivery)]
    (loop []
      (let [remaining (max 0 (- deadline (System/nanoTime)))
            ^DeliveryItem item (.poll ^ArrayBlockingQueue (:queue delivery)
                                      remaining TimeUnit/NANOSECONDS)]
        (when item
          (if (compare-and-set! (:active item) true false)
            (do
              (locking budget
                (.remove ^ArrayDeque (:entries budget) item)
                (swap! (:count budget) dec)
                (swap! (:bytes budget) - (:size item)))
              (:update item))
            (when (pos? (- deadline (System/nanoTime))) (recur))))))))

(declare unsubscribe! close-live! debug-disconnect!)

(defrecord Subscription [manager id path args delivery active]
  java.lang.AutoCloseable
  (close [this] (unsubscribe! manager this)))

(defn next-update [subscription timeout-ms]
  (or (poll-update! (:delivery subscription) timeout-ms)
      (throw (failure :transport "timed out waiting for Live update"))))

(defn- version-zero [] {"querySet" 0 "identity" 0 "ts" initial-timestamp})

(defn- websocket-url [url]
  (let [uri (URI/create url)]
    (str (if (= "https" (.getScheme uri)) "wss" "ws") "://"
         (.getAuthority uri) (or (.getPath uri) "") "/api/sync")))

(defrecord LiveClient [url ^HttpClient http ^ThreadPoolExecutor owner
                       ^ScheduledExecutorService scheduler state]
  java.lang.AutoCloseable
  (close [this] (close-live! this)))

(defn- runnable [f] (reify Runnable (run [_] (f))))
(defn- callable [f] (reify Callable (call [_] (f))))
(defn- bi-consumer [f] (reify BiConsumer (accept [_ value error] (f value error))))

(defn- dispatch! [live f]
  (try
    (.execute ^ThreadPoolExecutor (:owner live) (runnable f))
    true
    (catch RejectedExecutionException _ false)))

(defn- on-owner [live f]
  (if (= "convex-clojure-live" (.getName (Thread/currentThread)))
    (f)
    (.get (.submit (:owner live) (callable f)) 5 TimeUnit/SECONDS)))

(defn- deliver! [subscription update]
  (when @(:active subscription) (offer-update! (:delivery subscription) update)))

(defn- publish-error! [live kind operation error]
  (let [value {:error {:kind kind :message (or (.getMessage ^Throwable error) (name kind))
                       :operation operation :data (:data (ex-data error))}
               :logs (vec (:logs (ex-data error)))}]
    (doseq [[_ entry] (:subscriptions @(:state live))]
      (deliver! (:subscription entry) value))))

(declare schedule-reconnect! connect! enqueue-send! start-next-send! retire! receive-message!)

(defn- increase-backoff! [live]
  (swap! (:state live) update :backoff #(min max-backoff-ms (* 2 %))))

(defn- cancel-reconnect! [live]
  (when-let [pending (:reconnect @(:state live))] (.cancel pending false))
  (swap! (:state live) assoc :reconnect nil))

(defn- schedule-reconnect! [live delay-ms]
  (let [state @(:state live)]
    (when (and (not (:closed state)) (seq (:subscriptions state))
               (nil? (:reconnect state)) (nil? (:handshake state)))
      (let [future (.schedule (:scheduler live)
                              (runnable #(dispatch! live (fn []
                                                           (swap! (:state live) assoc :reconnect nil)
                                                           (connect! live))))
                              delay-ms TimeUnit/MILLISECONDS)]
        (swap! (:state live) assoc :reconnect future)))))

(defn- add-message [subscription]
  {"type" "Add" "queryId" (:id subscription) "udfPath" (:path subscription)
   "args" [(:args subscription)]})

(defn- completed-future []
  (CompletableFuture/completedFuture nil))

(defn- fail-completion! [pending error]
  (.completeExceptionally ^CompletableFuture (:completion pending) error))

(defn- send-failure [operation]
  (failure :transport (str operation " was cancelled because the Live generation retired")))

(defn- finish-send! [live in-flight pending error]
  (when (identical? in-flight (:in-flight @(:state live)))
    (swap! (:state live) assoc :in-flight nil)
    (if error
      (let [cause (unwrap-error error)]
        (fail-completion! pending cause)
        (publish-error! live :transport (:operation pending) cause)
        (retire! live (str (:operation pending) " send failed") true))
      (do
        (when-let [hook @send-completion-hook]
          (hook (:operation pending)))
        (.complete ^CompletableFuture (:completion pending) nil)
        (start-next-send! live)))))

(defn- start-next-send! [live]
  (when (nil? (:in-flight @(:state live)))
    (loop []
      (let [state @(:state live)]
        (when-let [pending (.pollFirst ^ArrayDeque (:pending-sends state))]
          (if (or (:closed state) (not (identical? (:socket pending) (:socket state)))
                  (not= (:generation pending) (:generation state)))
            (do
              (fail-completion! pending (send-failure (:operation pending)))
              (recur))
            (try
              (let [transport ((:action pending) (:socket pending))
                    in-flight {:transport transport :pending pending}]
                (swap! (:state live) assoc :in-flight in-flight)
                (.whenComplete ^CompletableFuture transport
                               (bi-consumer
                                (fn [_ error]
                                  (when-not (dispatch! live #(finish-send! live in-flight pending error))
                                    (fail-completion! pending
                                                      (send-failure (:operation pending))))))))
              (catch Throwable error
                (fail-completion! pending error)
                (publish-error! live :transport (:operation pending) error)
                (retire! live (str (:operation pending) " send failed") true)))))))))

(defn- enqueue-send! [live operation action]
  (let [state @(:state live)
        completion (CompletableFuture.)]
    (if-let [socket (:socket state)]
      (if (>= (.size ^ArrayDeque (:pending-sends state)) max-pending-sends)
        (let [error (failure :transport "Live write queue is full")]
          (.completeExceptionally completion error)
          (publish-error! live :transport operation error)
          (retire! live "Live write queue is full" true))
        (do
          (.addLast ^ArrayDeque (:pending-sends state)
                    {:operation operation :socket socket :generation (:generation state)
                     :action action :completion completion})
          (start-next-send! live)))
      (.complete completion nil))
    completion))

(defn- send-json!
  ([live value] (send-json! live "live write" value))
  ([live operation value]
   (let [payload (json/write-str value)]
     (enqueue-send! live operation #(.sendText ^WebSocket % payload true)))))

(defn- modify! [live modifications]
  (if (and (seq modifications) (:socket @(:state live)))
    (let [version (:query-version @(:state live))
          completion (send-json! live "modify query set"
                                 {"type" "ModifyQuerySet" "baseVersion" version
                                  "newVersion" (inc version)
                                  "modifications" (vec modifications)})]
      (swap! (:state live) update :query-version inc)
      completion)
    (completed-future)))

(defn- decode-timestamp [timestamp]
  ;; Convex timestamps are canonical base64 encodings of one little-endian
  ;; uint64. Decode numerically: lexical or raw-byte ordering gets 255 -> 256
  ;; wrong because the least-significant byte comes first.
  (when-not (and (string? timestamp) (= 12 (count timestamp)))
    (throw (failure :protocol "Live timestamp must canonically encode eight bytes")))
  (let [decoded (try
                  (.decode (Base64/getDecoder) ^String timestamp)
                  (catch IllegalArgumentException _ nil))]
    (when-not (and decoded
                   (= 8 (alength ^bytes decoded))
                   (= timestamp (.encodeToString (Base64/getEncoder) ^bytes decoded)))
      (throw (failure :protocol "Live timestamp is not canonical eight-byte base64")))
    (reduce (fn [^BigInteger result index]
              (.or result
                   (.shiftLeft (BigInteger/valueOf (bit-and 0xff (aget ^bytes decoded index)))
                               (* 8 index))))
            BigInteger/ZERO
            (range 8))))

(defn- valid-version [value]
  (when-not (and (map? value)
                 (contains? value "querySet") (integer? (get value "querySet"))
                 (not (neg? (get value "querySet")))
                 (contains? value "identity") (integer? (get value "identity"))
                 (not (neg? (get value "identity")))
                 (contains? value "ts") (string? (get value "ts")))
    (throw (failure :protocol "Live state version is malformed")))
  [value (decode-timestamp (get value "ts"))])

(defn- modification-logs [item]
  (if (contains? item "logLines")
    (let [logs (get item "logLines")]
      (when-not (and (vector? logs) (every? string? logs))
        (throw (failure :protocol "Transition modification logLines must be an array of strings")))
      logs)
    []))

(defn- parse-modification [item]
  (when-not (map? item)
    (throw (failure :protocol "Transition modification must be an object")))
  (let [id (get item "queryId")
        type (get item "type")
        logs (modification-logs item)]
    (when-not (and (contains? item "queryId") (integer? id) (not (neg? id)))
      (throw (failure :protocol "Transition modification has invalid queryId")))
    (when-not (and (contains? item "type") (string? type) (seq type))
      (throw (failure :protocol "Transition modification omitted type")))
    [id
     (case type
       "QueryUpdated"
       (do
         (when-not (contains? item "value")
           (throw (failure :protocol "QueryUpdated omitted value")))
         {:value (get item "value") :logs logs})

       "QueryFailed"
       (let [message (get item "errorMessage")]
         (when-not (and (contains? item "errorMessage") (string? message))
           (throw (failure :protocol "QueryFailed omitted string errorMessage")))
         {:error {:kind :function :message message :data (get item "errorData")}
          :logs logs})

       "QueryRemoved" ::removed
       (throw (failure :protocol (str "unknown Transition modification " type))))]))

(defn- same-value? [previous update]
  (and previous (nil? (:error previous)) (nil? (:error update))
       (= (:value previous) (:value update)) (= (:logs previous) (:logs update))))

(defn- apply-transition! [live message]
  (let [state @(:state live)
        [start start-timestamp] (valid-version (get message "startVersion"))
        _ (when-not (= start (:remote-version state))
            (throw (failure :protocol "Transition start version does not match local version")))
        modifications (get message "modifications")
        _ (when-not (vector? modifications)
            (throw (failure :protocol "Transition modifications must be an array")))
        [end end-timestamp] (valid-version (get message "endVersion"))
        _ (when (or (< (get end "querySet") (get start "querySet"))
                    (< (get end "identity") (get start "identity"))
                    (neg? (.compareTo ^BigInteger end-timestamp ^BigInteger start-timestamp)))
            (throw (failure :protocol "Transition end version moved backwards")))
        parsed (mapv parse-modification modifications)
        ;; A transaction may update one query more than once. Commit only its
        ;; final state so observers never see an intermediate value that was not
        ;; the transaction's result.
        parsed-by-id (reduce (fn [latest [id update]] (assoc latest id update))
                             (sorted-map) parsed)
        staged (reduce
                (fn [{:keys [subscriptions deliveries] :as result} [id update]]
                  (if-let [entry (get subscriptions id)]
                    (if (= ::removed update)
                      (assoc result :subscriptions (assoc-in subscriptions [id :last] nil))
                      (if (same-value? (:last entry) update)
                        result
                        {:subscriptions (assoc-in subscriptions [id :last] update)
                         :deliveries (conj deliveries [(:subscription entry) update])}))
                    result))
                {:subscriptions (:subscriptions state) :deliveries []}
                parsed-by-id)
        newer-maximum? (or (nil? (:max-ts-value state))
                           (pos? (.compareTo ^BigInteger end-timestamp
                                             ^BigInteger (:max-ts-value state))))
        committed (cond-> (assoc state
                                 :remote-version end
                                 :backoff initial-backoff-ms
                                 :subscriptions (:subscriptions staged))
                    newer-maximum?
                    (assoc :max-ts (get end "ts") :max-ts-value end-timestamp))]
    ;; Validate and stage the entire transaction before one state commit. Relays
    ;; cannot observe a half-applied multi-query transition.
    (reset! (:state live) committed)
    (doseq [[subscription update] (:deliveries staged)]
      (deliver! subscription update))))

(defn- receive-message! [live text]
  (let [message (json/read-str text)
        type (when (map? message) (get message "type"))]
    (when-not (and (map? message) (string? type) (seq type))
      (throw (failure :protocol "Live message omitted string type")))
    (case type
      "Transition" (apply-transition! live message)
      "Ping" (swap! (:state live) assoc :backoff initial-backoff-ms)
      ("MutationResponse" "ActionResponse")
      (swap! (:state live) assoc :backoff initial-backoff-ms)
      (throw (failure :protocol (str "unsupported Live message " type))))))

(defn- current-socket? [live socket generation]
  (let [state @(:state live)]
    (and (not (:closed state))
         (= generation (:generation state))
         (identical? socket (:socket state)))))

(defn- socket-event! [live socket generation request-next? f]
  (when-not
   (dispatch!
    live
    (fn []
      (when (current-socket? live socket generation)
        (try
          (f)
          (catch Throwable error
            (publish-error! live :protocol "live read" error)
            (retire! live (or (.getMessage error) "protocol failure") true)))
        (when (and request-next? (current-socket? live socket generation))
          (.request ^WebSocket socket 1)))))
   ;; Rejection is only possible during shutdown or a violated owner bound.
   ;; Aborting is safer than letting the JDK continue outside owner control.
    (.abort ^WebSocket socket)))

(defn- listener [live generation]
  (let [text (StringBuilder.)
        encoded-bytes (long-array 1)]
    (proxy [WebSocket$Listener] []
      (onOpen [_] nil)
      (onText [socket data last]
        (let [chunk (str data)]
          (socket-event!
           live socket generation true
           (fn []
             (let [next-size (+ (aget encoded-bytes 0)
                                (alength (.getBytes chunk StandardCharsets/UTF_8)))]
               (when (> next-size max-live-message-bytes)
                 (throw (failure :protocol
                                 (str "Live message exceeds " max-live-message-bytes " bytes"))))
               (aset-long encoded-bytes 0 next-size)
               (.append text chunk)
               (when last
                 (let [complete (.toString text)]
                   (.setLength text 0)
                   (aset-long encoded-bytes 0 0)
                   (receive-message! live complete)))))))
        (CompletableFuture/completedFuture nil))
      (onBinary [socket _ _]
        (socket-event! live socket generation true
                       #(throw (failure :protocol "binary Live messages are unsupported")))
        (CompletableFuture/completedFuture nil))
      (onPing [socket payload]
        (let [copy (byte-array (.remaining ^ByteBuffer payload))]
          (.get ^ByteBuffer payload copy)
          (socket-event!
           live socket generation false
           (fn []
             (let [completion (enqueue-send! live "live pong"
                                             (fn [active]
                                               (.sendPong ^WebSocket active (ByteBuffer/wrap copy))))]
               (.whenComplete
                ^CompletableFuture completion
                (bi-consumer
                 (fn [_ error]
                   (when-not error
                     (when-not (dispatch! live #(when (current-socket? live socket generation)
                                                  (.request ^WebSocket socket 1)))
                       (.abort ^WebSocket socket))))))))))
        (CompletableFuture/completedFuture nil))
      (onPong [socket _]
        (socket-event! live socket generation true (constantly nil))
        (CompletableFuture/completedFuture nil))
      (onClose [socket code reason]
        (dispatch! live #(when (and (= generation (:generation @(:state live)))
                                    (identical? socket (:socket @(:state live))))
                           (let [error (failure :transport (str "WebSocket closed " code ": " reason))]
                             (publish-error! live :transport "live read" error)
                             (retire! live (str "close " code ": " reason) true))))
        (CompletableFuture/completedFuture nil))
      (onError [socket error]
        (dispatch! live #(when (and (= generation (:generation @(:state live)))
                                    (identical? socket (:socket @(:state live))))
                           (publish-error! live :transport "live read" error)
                           (retire! live (str "read: " (.getMessage error)) true)))))))

(defn- connect! [live]
  (let [state @(:state live)]
    (when (and (not (:closed state)) (seq (:subscriptions state))
               (nil? (:socket state)) (nil? (:handshake state)))
      (let [generation (inc (:generation state))
            future (-> (.newWebSocketBuilder ^HttpClient (:http live))
                       (.connectTimeout (Duration/ofSeconds 2))
                       (.header "Convex-Client" "clojure-0.1.0")
                       (.buildAsync (URI/create (websocket-url (:url live))) (listener live generation)))]
        (swap! (:state live) assoc :generation generation :handshake future)
        (.whenComplete ^CompletableFuture future
                       (bi-consumer
                        (fn [socket error]
                          (dispatch! live
                                     (fn []
                                       (let [current @(:state live)]
                                         (when (identical? future (:handshake current))
                                           (swap! (:state live) assoc :handshake nil))
                                         (cond
                                           (or (:closed current)
                                               (not= generation (:generation current)))
                                           (when socket (.abort ^WebSocket socket))

                                           error
                                           (let [cause (unwrap-error error)]
                                             (publish-error! live :transport "live handshake" cause)
                                             (swap! (:state live)
                                                    (fn [s]
                                                      (-> s
                                                          (update :connection-count inc)
                                                          (assoc :last-close-reason
                                                                 (str "handshake: " (.getMessage ^Throwable cause))
                                                                 :query-version 0
                                                                 :remote-version (version-zero)))))
                                             (schedule-reconnect! live (:backoff @(:state live)))
                                             (increase-backoff! live))

                                           :else
                                           (do
                                             (swap! (:state live) assoc
                                                    :socket socket
                                                    :query-version 0
                                                    :remote-version (version-zero)
                                                    ;; A completed RFC 6455 handshake is healthy
                                                    ;; transport traffic, so old failure delay must
                                                    ;; not leak into this generation.
                                                    :backoff initial-backoff-ms)
                                             (let [connected @(:state live)]
                                               (send-json!
                                                live
                                                (cond-> {"type" "Connect"
                                                         "sessionId" (str (UUID/randomUUID))
                                                         "connectionCount" (:connection-count connected)
                                                         "lastCloseReason" (:last-close-reason connected)
                                                         "clientTs" 0}
                                                  (:max-ts connected)
                                                  (assoc "maxObservedTimestamp" (:max-ts connected)))))
                                             (modify! live
                                                      (mapv (comp add-message :subscription second)
                                                            (:subscriptions @(:state live))))
                                             ;; Demand begins only after owner has installed the
                                             ;; generation and queued Connect/Add writes.
                                             (.request ^WebSocket socket 1)))))))))))))

(defn- retire! [live reason reconnect?]
  (let [before @(:state live)
        old (:socket before)
        error (send-failure reason)]
    (when-let [in-flight (:in-flight before)]
      (.cancel ^CompletableFuture (:transport in-flight) true)
      (fail-completion! (:pending in-flight) error))
    (loop []
      (when-let [pending (.pollFirst ^ArrayDeque (:pending-sends before))]
        (fail-completion! pending error)
        (recur)))
    (swap! (:state live)
           (fn [state]
             (-> state
                 (assoc :socket nil :in-flight nil :query-version 0 :remote-version (version-zero)
                        :last-close-reason reason)
                 (update :generation inc)
                 (cond-> old (update :connection-count inc)))))
    (when old (.abort ^WebSocket old))
    (when reconnect?
      (schedule-reconnect! live (:backoff @(:state live)))
      (increase-backoff! live))))

(defn live-client [url]
  (let [thread-factory (reify ThreadFactory
                         (newThread [_ task]
                           (doto (Thread. task "convex-clojure-live") (.setDaemon true))))
        ;; Executors/newSingleThreadExecutor hides an unbounded LinkedBlockingQueue.
        ;; Demand-gated callbacks should keep this queue near zero, while the hard
        ;; capacity makes a future regression fail closed instead of growing memory.
        owner (ThreadPoolExecutor. 1 1 0 TimeUnit/MILLISECONDS
                                   (ArrayBlockingQueue. max-owner-events)
                                   thread-factory (ThreadPoolExecutor$AbortPolicy.))
        scheduler (Executors/newSingleThreadScheduledExecutor
                   (reify ThreadFactory
                     (newThread [_ task]
                       (doto (Thread. task "convex-clojure-reconnect") (.setDaemon true)))))]
    (->LiveClient (deployment-url url)
                  (-> (HttpClient/newBuilder) (.connectTimeout (Duration/ofSeconds 2)) (.build))
                  owner scheduler
                  (atom {:socket nil :handshake nil :reconnect nil :pending-sends (ArrayDeque.)
                         :in-flight nil :closed false :next-id 0 :query-version 0
                         :remote-version (version-zero) :connection-count 0
                         :last-close-reason "InitialConnect" :max-ts nil :max-ts-value nil
                         :backoff initial-backoff-ms :generation 0
                         :delivery-budget (delivery-budget)
                         :subscriptions (sorted-map)}))))

(defn- await-send! [completion]
  (try
    (.get ^CompletableFuture completion 5 TimeUnit/SECONDS)
    (catch ExecutionException error
      (throw (unwrap-error error)))
    (catch TimeoutException error
      (throw (failure :transport "timed out waiting for Live write completion"
                      {:cause error})))))

(defn subscribe [live path args]
  (when-not (and (string? path) (seq path))
    (throw (failure :protocol "Convex function path is required")))
  (when-not (map? args)
    (throw (failure :protocol "Convex arguments must be a named JSON object")))
  (let [{:keys [subscription completion]}
        (on-owner live
                  (fn []
                    (when (:closed @(:state live))
                      (throw (failure :closed "Convex Live client is closed")))
                    (let [id (:next-id @(:state live))
                          subscription (->Subscription live id path args
                                                       (delivery-queue (:delivery-budget @(:state live)))
                                                       (atom true))
                          _ (swap! (:state live)
                                   (fn [state]
                                     (-> state
                                         (update :next-id inc)
                                         (assoc-in [:subscriptions id]
                                                   {:subscription subscription :last nil}))))
                          completion (if (:socket @(:state live))
                                       (modify! live [(add-message subscription)])
                                       (do (schedule-reconnect! live 0) (completed-future)))]
                      {:subscription subscription :completion completion})))]
    (try
      (await-send! completion)
      subscription
      (catch Throwable error
        (reset! (:active subscription) false)
        (on-owner live #(do
                          (swap! (:state live) update :subscriptions dissoc (:id subscription))
                          (.close ^DeliveryQueue (:delivery subscription))))
        (throw error)))))

(defn unsubscribe! [live subscription]
  (when (compare-and-set! (:active subscription) true false)
    (let [completion
          (on-owner live
                    (fn []
                      ;; Invalidation precedes both the relay barrier and the
                      ;; transport completion returned to the controller.
                      (let [removed (get-in @(:state live) [:subscriptions (:id subscription)])
                            _ (swap! (:state live) update :subscriptions dissoc (:id subscription))
                            _ (.close ^DeliveryQueue (:delivery subscription))
                            completion (if (and removed (:socket @(:state live)))
                                         (modify! live [{"type" "Remove"
                                                         "queryId" (:id subscription)}])
                                         (completed-future))]
                        (when (empty? (:subscriptions @(:state live)))
                          (cancel-reconnect! live)
                          (when-let [handshake (:handshake @(:state live))]
                            (swap! (:state live) update :generation inc)
                            (.cancel ^CompletableFuture handshake true)
                            (swap! (:state live) assoc :handshake nil)))
                        completion)))]
      (await-send! completion)))
  true)

(defn debug-disconnect! [live]
  (on-owner live
            (fn []
              (when (:closed @(:state live)) (throw (failure :closed "Convex Live client is closed")))
              (when-not (:socket @(:state live))
                (throw (failure :transport "Live WebSocket is not connected")))
              ;; Retiring the generation is the acknowledgement barrier.
              (retire! live "DebugDisconnect" true)
              true)))

(defn close-live! [live]
  (when-not (.isShutdown (:owner live))
    (try
      (on-owner live
                (fn []
                  (when-not (:closed @(:state live))
                    (swap! (:state live) assoc :closed true)
                    (cancel-reconnect! live)
                    (when-let [handshake (:handshake @(:state live))]
                      (.cancel ^CompletableFuture handshake true))
                    (retire! live "client closed" false)
                    (doseq [[_ entry] (:subscriptions @(:state live))]
                      (reset! (:active (:subscription entry)) false)
                      (.close ^DeliveryQueue (:delivery (:subscription entry))))
                    (swap! (:state live) assoc :socket nil :handshake nil :subscriptions (sorted-map)))))
      (catch TimeoutException _ nil)))
  (.shutdownNow (:scheduler live))
  (.shutdownNow ^HttpClient (:http live))
  (.close ^HttpClient (:http live))
  (.shutdownNow (:owner live)))

(defn subscribe-client [client path args]
  (when @(:closed client) (throw (failure :closed "Convex client is closed")))
  (let [live (or @(:live client)
                 (let [created (live-client (:url client))]
                   (if (compare-and-set! (:live client) nil created) created
                       (do (.close ^LiveClient created) @(:live client)))))]
    (subscribe live path args)))

(defn debug-disconnect-client! [client]
  (if-let [live @(:live client)] (debug-disconnect! live)
          (throw (failure :transport "Live WebSocket has not been started"))))
