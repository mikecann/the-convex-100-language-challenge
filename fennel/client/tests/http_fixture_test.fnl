;; Deterministic transport fixtures validate request construction and every
;; response class without relying on a hosted deployment.
(local Convex (require :convex))
(local json (require :json))

(fn expect [condition message]
  (if (not condition) (error message)))

(fn fixture-factory [responses captured]
  (fn [url]
    (let [response (table.remove responses 1)
          headers {:values {}}
          request {: url : headers}]
      (fn headers.upsert [self name value] (set (. self.values name) value))

      (fn headers.get [_ name]
        (if (= name ":status") (or response.status :200)))

      (fn request.set_body [self body] (set self.body body))

      (fn request.go [self _]
        (table.insert captured self)
        (if response.transport-error
            (values nil response.transport-error)
            (let [stream {}]
              (fn stream.get_body_as_string [_ _]
                (if response.read-error (values nil response.read-error)
                    response.body))

              (values headers stream nil))))

      request)))

(let [responses [{:body "{\"status\":\"success\",\"value\":{\"count\":1},\"logLines\":[]}"}
                 {:body "{\"status\":\"error\",\"errorMessage\":\"fixture failed\",\"errorData\":{\"code\":\"FIXTURE\"},\"logLines\":[\"fixture log\"]}"}
                 {:status :502 :body "not json"}
                 {:transport-error "fixture connect failed"}
                 {:read-error "fixture body failed"}]
      captured []
      client (assert (Convex.new "https://fixture.invalid/"
                                 {:bearer-token :secret
                                  :client-version :fennel-fixture
                                  :request-factory (fixture-factory responses
                                                                    captured)}))]
  (let [result (assert (: client :query "demo:state" {:room :fixture}))
        sent (. captured 1)
        decoded (assert (json.decode sent.body))]
    (expect (= result.value.count 1) "success value was not decoded")
    (expect (= sent.url "https://fixture.invalid/api/query")
            "query endpoint was wrong")
    (expect (= (. sent.headers.values :authorization) "Bearer secret")
            "authorization header was omitted")
    (expect (= decoded.path "demo:state") "request path was wrong")
    (expect (= decoded.args.room :fixture) "request arguments were wrong"))
  (let [(result err) (: client :mutation "demo:increment" {})]
    (expect (= result nil) "function failure became a success")
    (expect (= err.name :FunctionError) "function error was not structured")
    (expect (= err.data.code :FIXTURE) "function error data was lost")
    (expect (= (. err.logs 1) "fixture log") "function logs were lost"))
  (let [(result err) (: client :query "demo:state" {})]
    (expect (= result nil) "non-JSON response became success")
    (expect (= err.name :TransportError) "non-JSON response was misclassified"))
  (let [(result err) (: client :query "demo:state" {})]
    (expect (= result nil) "transport failure became success")
    (expect (= err.name :TransportError) "transport failure was misclassified"))
  (let [(result err) (: client :query "demo:state" {})]
    (expect (= result nil) "body read failure became success")
    (expect (= err.name :TransportError) "body read failure was misclassified"))
  (: client :close))

(let [(client err) (Convex.new :not-a-url)]
  (expect (= client nil) "invalid deployment URL was accepted")
  (expect (= err.name :ProtocolError) "invalid URL was misclassified"))

(print "http fixture tests passed")
