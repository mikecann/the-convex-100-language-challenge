(ns client-test
  (:require [clojure.data.json :as json]
            [clojure.test :refer [deftest is testing]]
            [convex.client :as convex])
  (:import [com.sun.net.httpserver HttpHandler HttpServer]
           [java.net InetAddress InetSocketAddress]
           [java.nio.charset StandardCharsets]
           [java.util.concurrent Executors]))

(defn- http-fixture [handler]
  (let [server (HttpServer/create (InetSocketAddress. (InetAddress/getLoopbackAddress) 0) 0)]
    (.createContext server "/"
                    (reify HttpHandler
                      (handle [_ exchange]
                        (let [body (.readAllBytes (.getRequestBody exchange))
                              response (handler exchange (json/read-str (String. body StandardCharsets/UTF_8)))
                              bytes (.getBytes ^String (:body response) StandardCharsets/UTF_8)]
                          (.sendResponseHeaders exchange (:status response) (alength bytes))
                          (with-open [output (.getResponseBody exchange)] (.write output bytes))))))
    (.setExecutor server (Executors/newCachedThreadPool))
    (.start server)
    {:server server :url (str "http://127.0.0.1:" (.getPort (.getAddress server)))}))

(defn- stop-http! [fixture] (.stop ^HttpServer (:server fixture) 0))

(deftest http-builds-exact-requests-and-preserves-json-semantics
  (let [seen (atom [])
        fixture (http-fixture
                 (fn [exchange body]
                   (swap! seen conj {:path (.getPath (.getRequestURI exchange))
                                     :auth (.getFirst (.getRequestHeaders exchange) "Authorization")
                                     :client (.getFirst (.getRequestHeaders exchange) "Convex-Client")
                                     :body body})
                   {:status 200
                    :body (json/write-str {"status" "success" "value" nil
                                           "logLines" ["héllo ✓"]})}))]
    (try
      (with-open [client (convex/client (:url fixture))]
        (convex/set-auth! client "secret-token")
        (let [result (convex/query client "demo:écho" {"text" "café ☕"})]
          (is (contains? result :value))
          (is (nil? (:value result)))
          (is (= ["héllo ✓"] (:logs result)))))
      (is (= [{:path "/api/query" :auth "Bearer secret-token"
               :client "clojure-0.1.0"
               :body {"path" "demo:écho" "args" {"text" "café ☕"} "format" "json"}}]
             @seen))
      (finally (stop-http! fixture)))))

(deftest http-success-error-logs-and-auth-replacement
  (let [auth-values (atom [])
        fixture (http-fixture
                 (fn [exchange body]
                   (swap! auth-values conj (.getFirst (.getRequestHeaders exchange) "Authorization"))
                   (if (= "demo:fail" (get body "path"))
                     {:status 560 :body (json/write-str {"status" "error"
                                                         "errorMessage" "nope"
                                                         "errorData" {"code" "NOPE"}
                                                         "logLines" ["failed"]})}
                     {:status 200 :body (json/write-str {"status" "success"
                                                         "value" {"count" 1}
                                                         "logLines" ["ok"]})})))]
    (try
      (with-open [client (convex/client (:url fixture))]
        (is (= {:value {"count" 1} :logs ["ok"]}
               (convex/mutation client "demo:increment" {})))
        (convex/set-auth! client "one")
        (is (= {"count" 1} (:value (convex/action client "demo:action" {}))))
        (convex/set-auth! client "two")
        (let [error (try (convex/query client "demo:fail" {})
                         (catch clojure.lang.ExceptionInfo failure failure))]
          (is (= :function (:kind (ex-data error))))
          (is (= {"code" "NOPE"} (:data (ex-data error))))
          (is (= ["failed"] (:logs (ex-data error))))))
      (is (= [nil "Bearer one" "Bearer two"] @auth-values))
      (finally (stop-http! fixture)))))

(deftest malformed-and-oversized-http-responses-are-transport-errors
  (doseq [body ["not-json" (str "{\"status\":\"success\",\"value\":\""
                                (apply str (repeat (+ (* 2 1024 1024) 1) "x")) "\"}")]]
    (let [fixture (http-fixture (fn [_ _] {:status 200 :body body}))]
      (try
        (with-open [client (convex/client (:url fixture))]
          (let [error (try (convex/query client "demo:state" {})
                           (catch clojure.lang.ExceptionInfo failure failure))]
            (is (= :transport (:kind (ex-data error))))))
        (finally (stop-http! fixture))))))
