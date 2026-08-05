(ns adapter
  "Test-only NDJSON adapter v1. Its stdout is exclusively protocol events."
  (:require [clojure.data.json :as json] [clojure.string :as string] [convex.client :as convex])
  (:import [java.io BufferedReader InputStreamReader OutputStreamWriter PrintWriter]
           [java.net InetAddress InetSocketAddress ServerSocket]
           [java.nio.charset StandardCharsets]
           [java.util.concurrent ConcurrentHashMap]))

(defn- write! [^PrintWriter out value] (locking out (.println out (json/write-str value)) (.flush out)))
(defn- error-value [id error]
  (cond-> {"type" "error" "error" {"name" (name (or (:kind (ex-data error)) :protocol)) "message" (or (.getMessage error) "error")}}
    (seq id) (assoc "id" id)))
(defn- result-value [id result]
  (cond-> {"type" "result" "id" id "value" (:value result)} (seq (:logs result)) (assoc "logs" (:logs result))))

(defn- relay! [subscription-id subscription subscriptions out]
  (future
    (loop []
      (when (and @(:active subscription) (identical? subscription (.get subscriptions subscription-id)))
        (let [update (convex/next-update subscription 86400000)]
          (when (and @(:active subscription) (identical? subscription (.get subscriptions subscription-id)))
            (write! out (cond-> {"type" "subscription" "subscriptionId" subscription-id}
                          (:error update) (assoc "error" {"name" (name (get-in update [:error :kind])) "message" (get-in update [:error :message])})
                          (not (:error update)) (assoc "value" (:value update))
                          (seq (:logs update)) (assoc "logs" (:logs update)))))
        (recur))))))

(defn- process! [command deployment client live subscriptions out]
  (let [id (get command "id") op (get command "op")]
    (case op
      "hello" (do (when-not (= 1 (get command "protocolVersion")) (throw (ex-info "unsupported adapter protocol version" {})))
                  (write! out {"type" "ready" "id" id "protocolVersion" 1 "language" "clojure" "implementation" "native-clojure-1.12" "runtime" (clojure-version)}) false)
      "close" (do (doseq [subscription (iterator-seq (.iterator (.values subscriptions)))] (.close ^java.lang.AutoCloseable subscription))
                  (when @live (.close ^java.lang.AutoCloseable @live)) (when @client (.close ^java.lang.AutoCloseable @client))
                  (write! out {"type" "closed" "id" id}) true)
      (do (when-not (seq deployment) (throw (ex-info "CONVEX_URL is required" {})))
          (when-not @client (reset! client (convex/client deployment)))
          (case op
            "setAuth" (do (convex/set-auth! @client (get command "token")) (write! out {"type" "ack" "id" id}))
            ("query" "mutation" "action") (write! out (result-value id (convex/call @client op (get command "path") (get command "args" {}))))
            "subscribe" (do (when-not @live (reset! live (convex/live-client deployment)))
                            (let [subscription-id (get command "subscriptionId") old (.remove subscriptions subscription-id)]
                              (when old (convex/unsubscribe! @live old))
                              (let [subscription (convex/subscribe @live (get command "path") (get command "args" {}))]
                                (.put subscriptions subscription-id subscription) (write! out {"type" "ack" "id" id}) (relay! subscription-id subscription subscriptions out))))
            "unsubscribe" (do (when-let [subscription (.remove subscriptions (get command "subscriptionId"))] (convex/unsubscribe! @live subscription)) (write! out {"type" "ack" "id" id}))
            "debugDisconnect" (do (convex/debug-disconnect! @live) (write! out {"type" "ack" "id" id}))
            (throw (ex-info (str "unknown operation: " op) {}))) false))))

(defn run! [input output deployment]
  (let [reader (BufferedReader. (InputStreamReader. input StandardCharsets/UTF_8)) out (PrintWriter. (OutputStreamWriter. output StandardCharsets/UTF_8) true)
        client (atom nil) live (atom nil) subscriptions (ConcurrentHashMap.)]
    (try
      (loop []
        (when-let [line (.readLine reader)]
          (let [command (json/read-str line)]
            (if (process! command deployment client live subscriptions out) nil (recur)))))
      (catch Exception error (write! out (error-value nil error)))
      (finally (when @live (.close ^java.lang.AutoCloseable @live)) (when @client (.close ^java.lang.AutoCloseable @client))))))

(defn- bind [address]
  (let [[host port] (string/split address #":(?=[^:]+$)") server (ServerSocket.)]
    (.bind server (InetSocketAddress. (InetAddress/getByName host) (Integer/parseInt port))) server))
(defn -main []
  (if-let [address (System/getenv "ADAPTER_LISTEN")]
    (with-open [server (bind address) socket (.accept server)] (run! (.getInputStream socket) (.getOutputStream socket) (System/getenv "CONVEX_URL")))
    (run! System/in System/out (System/getenv "CONVEX_URL"))))
