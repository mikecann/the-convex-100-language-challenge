(ns convex.client
  "Educational native Clojure Convex HTTP and pinned Live sync-profile client."
  (:require [clojure.data.json :as json]
            [clojure.string :as string])
  (:import [java.net URI]
           [java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers WebSocket WebSocket$Listener]
           [java.nio ByteBuffer]
           [java.nio.charset StandardCharsets]
           [java.time Duration]
           [java.util ArrayDeque LinkedHashMap UUID]
           [java.util.concurrent ArrayBlockingQueue Callable CompletableFuture CompletionException ExecutionException Executors RejectedExecutionException ScheduledExecutorService ThreadFactory TimeUnit TimeoutException]
           [java.util.function BiConsumer]))

(def ^:private max-http-bytes (* 2 1024 1024))
(def ^:private max-update-count 16)
(def ^:private max-update-bytes (* 256 1024))
(def ^:private initial-timestamp "AAAAAAAAAAA=")
(def ^:private initial-backoff-ms 100)
(def ^:private max-backoff-ms 15000)

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
          logs (vec (get decoded "logLines" []))]
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

;; A slow consumer gets recent snapshots, bounded by both count and encoded bytes.
(defrecord DeliveryQueue [^ArrayBlockingQueue queue sizes bytes]
  java.lang.AutoCloseable
  (close [_] (.clear queue) (reset! sizes clojure.lang.PersistentQueue/EMPTY) (reset! bytes 0)))

(defn- delivery-queue [] (->DeliveryQueue (ArrayBlockingQueue. max-update-count)
                                          (atom clojure.lang.PersistentQueue/EMPTY)
                                          (atom 0)))

(defn- update-size [update]
  (alength (.getBytes (json/write-str update) StandardCharsets/UTF_8)))

(defn- offer-update! [delivery update]
  (let [size (update-size update)]
    (locking delivery
      (when (<= size max-update-bytes)
        (while (or (= max-update-count (.size ^ArrayBlockingQueue (:queue delivery)))
                   (> (+ @(:bytes delivery) size) max-update-bytes))
          (.poll ^ArrayBlockingQueue (:queue delivery))
          (let [removed (peek @(:sizes delivery))]
            (swap! (:sizes delivery) pop)
            (swap! (:bytes delivery) - removed)))
        (.offer ^ArrayBlockingQueue (:queue delivery) update)
        (swap! (:sizes delivery) conj size)
        (swap! (:bytes delivery) + size)))))

(defn- poll-update! [delivery timeout-ms]
  (when-let [update (.poll ^ArrayBlockingQueue (:queue delivery) timeout-ms TimeUnit/MILLISECONDS)]
    (locking delivery
      (when-let [size (peek @(:sizes delivery))]
        (swap! (:sizes delivery) pop)
        (swap! (:bytes delivery) - size)))
    update))

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

(defrecord LiveClient [url ^HttpClient http owner ^ScheduledExecutorService scheduler state]
  java.lang.AutoCloseable
  (close [this] (close-live! this)))

(defn- runnable [f] (reify Runnable (run [_] (f))))
(defn- callable [f] (reify Callable (call [_] (f))))
(defn- bi-consumer [f] (reify BiConsumer (accept [_ value error] (f value error))))

(defn- dispatch! [live f]
  (try (.execute (:owner live) (runnable f))
       (catch RejectedExecutionException _ nil)))

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

(defn- start-next-send! [live]
  (let [state @(:state live)]
    (when (nil? (:in-flight state))
      (loop []
        (when-let [pending (.pollFirst ^ArrayDeque (:pending-sends state))]
          (if (or (:closed state) (not (identical? (:socket pending) (:socket state)))
                  (not= (:generation pending) (:generation state)))
            (recur)
            (try
              (let [future ((:action pending) (:socket pending))]
                (swap! (:state live) assoc :in-flight future)
                (.whenComplete ^CompletableFuture future
                               (bi-consumer
                                (fn [_ error]
                                  (dispatch! live
                                             (fn []
                                               (when (identical? future (:in-flight @(:state live)))
                                                 (swap! (:state live) assoc :in-flight nil)
                                                 (if error
                                                   (do (publish-error! live :transport (:operation pending) (unwrap-error error))
                                                       (retire! live (str (:operation pending) " send failed") true))
                                                   (start-next-send! live)))))))))
              (catch Throwable error
                (publish-error! live :transport (:operation pending) error)
                (retire! live (str (:operation pending) " send failed") true)))))))))

(defn- enqueue-send! [live operation action]
  (let [state @(:state live)]
    (when-let [socket (:socket state)]
      (.addLast ^ArrayDeque (:pending-sends state)
                {:operation operation :socket socket :generation (:generation state) :action action})
      (start-next-send! live))))

(defn- send-json! [live value]
  (let [payload (json/write-str value)]
    (enqueue-send! live "live write" #(.sendText ^WebSocket % payload true))))

(defn- modify! [live modifications]
  (when (seq modifications)
    (let [version (:query-version @(:state live))]
      (send-json! live {"type" "ModifyQuerySet" "baseVersion" version
                        "newVersion" (inc version) "modifications" (vec modifications)})
      (swap! (:state live) update :query-version inc))))

(defn- valid-version [value]
  (when-not (and (map? value) (integer? (get value "querySet"))
                 (integer? (get value "identity")) (string? (get value "ts")))
    (throw (failure :protocol "Live state version is malformed")))
  value)

(defn- same-value? [previous update]
  (and previous (nil? (:error previous)) (nil? (:error update))
       (= (:value previous) (:value update)) (= (:logs previous) (:logs update))))

(defn- apply-transition! [live message]
  (let [state @(:state live)
        start (valid-version (get message "startVersion"))
        _ (when-not (= start (:remote-version state))
            (throw (failure :protocol "Transition start version does not match local version")))
        modifications (get message "modifications")
        _ (when-not (vector? modifications)
            (throw (failure :protocol "Transition modifications must be an array")))
        parsed (mapv (fn [item]
                       (let [id (get item "queryId") type (get item "type")
                             logs (vec (get item "logLines" []))]
                         (when-not (integer? id)
                           (throw (failure :protocol "Transition modification omitted queryId")))
                         [id (case type
                               "QueryUpdated" {:value (get item "value") :logs logs}
                               "QueryFailed" {:error {:kind :function
                                                      :message (get item "errorMessage" "query failed")
                                                      :data (get item "errorData")}
                                              :logs logs}
                               "QueryRemoved" ::removed
                               (throw (failure :protocol (str "unknown Transition modification " type))))]))
                     modifications)
        end (valid-version (get message "endVersion"))]
    ;; Nothing is committed or delivered until the complete transition validates.
    (swap! (:state live) assoc :remote-version end :max-ts (get end "ts")
           :backoff initial-backoff-ms)
    (doseq [[id update] (sort-by first parsed)]
      (when-let [entry (get (:subscriptions @(:state live)) id)]
        (if (= ::removed update)
          (swap! (:state live) assoc-in [:subscriptions id :last] nil)
          (when-not (same-value? (:last entry) update)
            (swap! (:state live) assoc-in [:subscriptions id :last] update)
            (deliver! (:subscription entry) update)))))))

(defn- receive-message! [live generation text]
  (dispatch! live
             (fn []
               (let [state @(:state live)]
                 (when (and (not (:closed state)) (= generation (:generation state)) (:socket state))
                   (try
                     (let [message (json/read-str text)]
                       (case (get message "type")
                         "Transition" (apply-transition! live message)
                         "Ping" (swap! (:state live) assoc :backoff initial-backoff-ms)
                         ("MutationResponse" "ActionResponse") (swap! (:state live) assoc :backoff initial-backoff-ms)
                         (throw (failure :protocol (str "unsupported Live message " (get message "type"))))))
                     (catch Throwable error
                       (publish-error! live :protocol "live read" error)
                       (retire! live (or (.getMessage error) "protocol failure") true))))))))

(defn- listener [live generation]
  (let [text (StringBuilder.)]
    (proxy [WebSocket$Listener] []
      (onOpen [socket] (.request socket 1))
      (onText [socket data last]
        (.append text data)
        (when last
          (let [complete (.toString text)]
            (.setLength text 0)
            (receive-message! live generation complete)))
        (.request socket 1)
        (CompletableFuture/completedFuture nil))
      (onBinary [socket _ _]
        (dispatch! live #(when (= generation (:generation @(:state live)))
                           (let [error (failure :protocol "binary Live messages are unsupported")]
                             (publish-error! live :protocol "live read" error)
                             (retire! live (.getMessage error) true))))
        (.request socket 1)
        (CompletableFuture/completedFuture nil))
      (onPing [socket payload]
        (let [copy (byte-array (.remaining ^ByteBuffer payload))]
          (.get ^ByteBuffer payload copy)
          (dispatch! live #(when (= generation (:generation @(:state live)))
                             (enqueue-send! live "live pong"
                                            (fn [active]
                                              (.sendPong ^WebSocket active (ByteBuffer/wrap copy)))))))
        (.request socket 1)
        (CompletableFuture/completedFuture nil))
      (onPong [socket _] (.request socket 1) (CompletableFuture/completedFuture nil))
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
                                                    :remote-version (version-zero))
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
                                                            (:subscriptions @(:state live))))))))))))))))

(defn- retire! [live reason reconnect?]
  (let [old (:socket @(:state live))]
    (swap! (:state live)
           (fn [state]
             (when-let [in-flight (:in-flight state)] (.cancel ^CompletableFuture in-flight true))
             (.clear ^ArrayDeque (:pending-sends state))
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
  (let [owner (Executors/newSingleThreadExecutor
               (reify ThreadFactory
                 (newThread [_ task]
                   (doto (Thread. task "convex-clojure-live") (.setDaemon true)))))
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
                         :last-close-reason "InitialConnect" :max-ts nil
                         :backoff initial-backoff-ms :generation 0 :subscriptions (sorted-map)}))))

(defn subscribe [live path args]
  (when-not (and (string? path) (seq path))
    (throw (failure :protocol "Convex function path is required")))
  (when-not (map? args)
    (throw (failure :protocol "Convex arguments must be a named JSON object")))
  (on-owner live
            (fn []
              (when (:closed @(:state live)) (throw (failure :closed "Convex Live client is closed")))
              (let [id (:next-id @(:state live))
                    subscription (->Subscription live id path args (delivery-queue) (atom true))]
                (swap! (:state live) (fn [state] (-> state
                                                     (update :next-id inc)
                                                     (assoc-in [:subscriptions id]
                                                               {:subscription subscription :last nil}))))
                (if (:socket @(:state live))
                  (modify! live [(add-message subscription)])
                  (schedule-reconnect! live 0))
                subscription))))

(defn unsubscribe! [live subscription]
  (when (compare-and-set! (:active subscription) true false)
    (on-owner live
              (fn []
                ;; The generation becomes inactive before this barrier returns.
                (let [removed (get-in @(:state live) [:subscriptions (:id subscription)])]
                  (swap! (:state live) update :subscriptions dissoc (:id subscription))
                  (.close ^DeliveryQueue (:delivery subscription))
                  (when (and removed (:socket @(:state live)))
                    (modify! live [{"type" "Remove" "queryId" (:id subscription)}]))
                  (when (empty? (:subscriptions @(:state live)))
                    (cancel-reconnect! live)
                    (when-let [handshake (:handshake @(:state live))]
                      (swap! (:state live) update :generation inc)
                      (.cancel ^CompletableFuture handshake true)
                      (swap! (:state live) assoc :handshake nil)))))))
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
                    (swap! (:state live) update :generation inc)
                    (cancel-reconnect! live)
                    (when-let [handshake (:handshake @(:state live))]
                      (.cancel ^CompletableFuture handshake true))
                    (when-let [socket (:socket @(:state live))] (.abort ^WebSocket socket))
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
