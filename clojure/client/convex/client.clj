(ns convex.client
  "Educational native Clojure Convex HTTP and pinned Live sync-profile client."
  (:require [clojure.data.json :as json]
            [clojure.string :as string])
  (:import [java.net URI]
           [java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers WebSocket WebSocket$Listener]
           [java.time Duration]
           [java.util UUID]
           [java.util.concurrent ArrayBlockingQueue CompletableFuture TimeUnit]))

(defn- fail [kind message & [data]]
  (throw (ex-info message (merge {:kind kind} (or data {})))))

(defn- base-uri [url]
  (let [parsed (URI/create url)]
    (when-not (and (#{"http" "https"} (.getScheme parsed)) (.getHost parsed) (nil? (.getUserInfo parsed)))
      (fail :protocol "Convex deployment URL must be http(s), have a host, and omit user info"))
    (str (URI/create (string/replace url #"/+$" "")))))

(defrecord Client [url http token closed]
  java.lang.AutoCloseable
  (close [_] (reset! closed true)))

(defn client [url]
  (->Client (base-uri url) (.build (HttpClient/newBuilder)) (atom "") (atom false)))

(defn set-auth! [client token]
  (when @(:closed client) (fail :protocol "Convex client is closed"))
  (reset! (:token client) (or token "")))

(defn call [client operation path args]
  (when @(:closed client) (fail :protocol "Convex client is closed"))
  (when (or (not (string? path)) (empty? path)) (fail :protocol "Convex function path is required"))
  (when-not (map? args) (fail :protocol "Convex arguments must be a named JSON object"))
  (try
    (let [body (json/write-str {"path" path "args" args "format" "json"})
          builder (-> (HttpRequest/newBuilder (URI/create (str (:url client) "/api/" operation)))
                      (.timeout (Duration/ofSeconds 30))
                      (.header "Content-Type" "application/json")
                      (.header "Accept" "application/json")
                      (.header "Convex-Client" "clojure-0.1.0"))
          builder (if (empty? @(:token client)) builder (.header builder "Authorization" (str "Bearer " @(:token client))))
          response (.send (:http client) (.POST builder (HttpRequest$BodyPublishers/ofString body)) (HttpResponse$BodyHandlers/ofString))
          decoded (json/read-str (.body response))]
      (case (get decoded "status")
        "success" (if (contains? decoded "value") {:value (get decoded "value") :logs (vec (get decoded "logLines" []))}
                      (fail :protocol "success response omitted value"))
        "error" (fail :function (get decoded "errorMessage" "Convex function failed") {:data (get decoded "errorData") :logs (get decoded "logLines" []) :operation operation})
        (fail :protocol (str "HTTP " (.statusCode response) " response has unknown status"))))
    (catch clojure.lang.ExceptionInfo error (throw error))
    (catch Exception error (fail :transport (or (.getMessage error) "HTTP transport failed") {:operation operation :cause error}))))

(defn query [client path args] (call client "query" path args))
(defn mutation [client path args] (call client "mutation" path args))
(defn action [client path args] (call client "action" path args))

(defn- zero-version [] {"querySet" 0 "identity" 0 "ts" "AAAAAAAAAAA="})
(defn- live-uri [url] (let [base (URI/create url)] (str (if (= "https" (.getScheme base)) "wss" "ws") "://" (.getAuthority base) (or (.getPath base) "") "/api/sync")))
(defrecord Subscription [id path args queue active]
  java.lang.AutoCloseable
  (close [_] (reset! active false)))

(defn offer-newest! [^ArrayBlockingQueue queue update]
  (when-not (.offer queue update) (.poll queue) (.offer queue update)))

(defrecord LiveClient [url http state]
  java.lang.AutoCloseable
  (close [_]
    (swap! state assoc :closed true)
    (when-let [socket (:socket @state)] (.abort ^WebSocket socket))))

(defn live-client [url]
  (->LiveClient (base-uri url) (.build (HttpClient/newBuilder))
                (atom {:socket nil :subscriptions {} :next-id 0 :query-version 0 :remote-version (zero-version)
                       :connection-count 0 :last-close-reason "InitialConnect" :max-observed-timestamp nil :closed false :frames ""})))

(declare connect! send! modify!)
(defn- deliver-transition! [live message]
  (let [s (:state live) before (:remote-version @s)]
    (when-not (= before (get message "startVersion")) (fail :protocol "Live transition version mismatch"))
    (swap! s assoc :remote-version (get message "endVersion") :max-observed-timestamp (get-in message ["endVersion" "ts"]))
    (doseq [change (get message "modifications" [])]
      (when-let [subscription (get-in @s [:subscriptions (get change "queryId")])]
        (when @(:active subscription)
          (case (get change "type")
            "QueryUpdated" (offer-newest! (:queue subscription) {:value (get change "value") :logs (vec (get change "logLines" []))})
            "QueryFailed" (offer-newest! (:queue subscription) {:error {:kind :function :message (get change "errorMessage") :data (get change "errorData")} :logs (vec (get change "logLines" []))})
            "QueryRemoved" nil
            (fail :protocol (str "unknown Transition modification: " (get change "type")))))))))

(defn- listener [live]
  (proxy [WebSocket$Listener] []
    (onOpen [socket] (.request socket 1))
    (onText [socket data last]
      (try
        (let [message (when last (json/read-str (str (:frames @(:state live)) data)))]
          (swap! (:state live) update :frames #(if last "" (str % data)))
          (when message (when (= "Transition" (get message "type")) (deliver-transition! live message))))
        (catch Exception error
          (doseq [[_ subscription] (:subscriptions @(:state live))]
            (offer-newest! (:queue subscription) {:error {:kind :protocol :message (.getMessage error)}})))
        (finally (.request socket 1)))
      (CompletableFuture/completedFuture nil))
    (onClose [socket _ reason]
      (swap! (:state live) assoc :socket nil :last-close-reason (str "ServerClosed:" reason) :remote-version (zero-version))
      (CompletableFuture/completedFuture nil))
    (onError [_ error]
      (doseq [[_ subscription] (:subscriptions @(:state live))]
        (offer-newest! (:queue subscription) {:error {:kind :transport :message (.getMessage error)}})))))

(defn- send! [live value]
  (if-let [socket (:socket @(:state live))]
    (.get (.sendText ^WebSocket socket (json/write-str value) true) 10 TimeUnit/SECONDS)
    (fail :transport "Live WebSocket is not connected")))

(defn- add-modification [subscription] {"type" "Add" "queryId" (:id subscription) "udfPath" (:path subscription) "args" [(:args subscription)]})
(defn- modify! [live changes]
  (let [version (:query-version @(:state live))]
    (send! live {"type" "ModifyQuerySet" "baseVersion" version "newVersion" (inc version) "modifications" changes})
    (swap! (:state live) update :query-version inc)))
(defn- connect! [live]
  (let [s (:state live) socket (.get (.buildAsync (.header (.connectTimeout (.newWebSocketBuilder (:http live)) (Duration/ofSeconds 10)) "Convex-Client" "clojure-0.1.0") (URI/create (live-uri (:url live))) (listener live)) 10 TimeUnit/SECONDS)]
    (swap! s assoc :socket socket :query-version 0 :remote-version (zero-version))
    (send! live (cond-> {"type" "Connect" "sessionId" (str (UUID/randomUUID)) "connectionCount" (:connection-count @s) "lastCloseReason" (:last-close-reason @s) "clientTs" 0}
                  (:max-observed-timestamp @s) (assoc "maxObservedTimestamp" (:max-observed-timestamp @s))))
    (when-let [subscriptions (seq (vals (:subscriptions @s)))] (modify! live (mapv add-modification subscriptions)))))

(defn subscribe [live path args]
  (when-not (map? args) (fail :protocol "Convex arguments must be a named JSON object"))
  (let [id (:next-id @(:state live)) subscription (->Subscription id path args (ArrayBlockingQueue. 16) (atom true))]
    (swap! (:state live) (fn [state] (-> state (assoc-in [:subscriptions id] subscription) (update :next-id inc))))
    (if (:socket @(:state live)) (modify! live [(add-modification subscription)]) (connect! live))
    subscription))

(defn unsubscribe! [live subscription]
  ;; Remove it from state before acknowledging callers, so a dequeued stale relay cannot escape.
  (reset! (:active subscription) false)
  (swap! (:state live) update :subscriptions dissoc (:id subscription))
  (when (:socket @(:state live)) (modify! live [{"type" "Remove" "queryId" (:id subscription)}]))
  true)

(defn next-update [subscription timeout-ms]
  (let [event (.poll ^ArrayBlockingQueue (:queue subscription) timeout-ms TimeUnit/MILLISECONDS)]
    (when-not event (fail :transport "timed out waiting for Live update"))
    event))

(defn debug-disconnect! [live]
  (when-let [socket (:socket @(:state live))]
    (swap! (:state live) assoc :socket nil :connection-count (inc (:connection-count @(:state live))) :last-close-reason "DebugDisconnect" :remote-version (zero-version))
    (.abort ^WebSocket socket)
    ;; Reconnect synchronously for the adapter barrier: old socket is retired before this returns.
    (connect! live))
  true)
