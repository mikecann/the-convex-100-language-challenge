# HTTP and Convex envelope regressions.
#
# Every response here is delivered over a real loopback connection by the
# client's own reader, so a failure means the parser is wrong rather than that
# a mock disagreed with it.

(import ./check :as check)
(import ./fixture :as fixture)
(import ../convex :as convex)
(import ../http :as http)
(import ../json :as json)
(import transport :as transport)

(defn- with-response
  "Pre-arm `raw` on the server end and hand the client end to `body`.

  The response fits inside the socket buffer, so the client can read it back
  without anything else running concurrently."
  [raw body &opt keep-open]
  (def [client server] (fixture/pair))
  (fixture/write-all! server raw)
  # Closing the server end first is what makes end-of-stream framing testable;
  # keeping it open is what makes a stalled peer testable.
  (unless keep-open (transport/close server))
  (def result (body client server))
  (transport/close client)
  (transport/close server)
  result)

#
# URL parsing
#

(def parsed (http/parse-url "https://usable-reindeer-44.convex.cloud/"))
(check/check= (get parsed :host) "usable-reindeer-44.convex.cloud" "the host is extracted")
(check/check= (get parsed :port) 443 "https defaults to port 443")
(check/check= (get parsed :tls) true "https implies TLS")
(check/check= (get parsed :path) "" "a trailing slash does not become part of the target")

(def plain (http/parse-url "http://backend:3210"))
(check/check= (get plain :port) 3210 "an explicit port is used")
(check/check= (get plain :tls) false "http does not imply TLS")
(check/check= (get plain :authority) "backend:3210" "the Host header keeps the port")

(check/check= (get (http/parse-url "http://[::1]:8080") :host) "::1"
              "an IPv6 literal loses only its URL brackets")

(each bad ["ftp://example.test" "example.test" "https://" "https://user:pw@example.test"
           "http://example.test:0" "http://example.test:99999" "http://exa mple.test"
           "http://example.test\r\nX: 1"]
  (check/check-raises "ProtocolError" (fn [] (http/parse-url bad))
                      (string "refuses an unusable deployment URL: " bad)))

# A token or room name that could inject a header must be refused before it is
# ever written, not sanitised into something that still reaches the socket.
(check/check (http/valid-header-value? "Bearer abc.def") "an ordinary token is accepted")
(check/check (not (http/valid-header-value? "abc\r\nX-Injected: 1")) "CRLF is refused")
(check/check (not (http/valid-header-value? "abc\ndef")) "a bare newline is refused")
(check/check-raises "ProtocolError"
                    (fn [] (http/build-request "POST" "/api/query" "host"
                                               @[["X" "a\r\nY: b"]] "{}"))
                    "a request refuses to serialize an injected header")

#
# Response reading
#

(with-response
  (fixture/http-response 200 `{"status":"success","value":1}`)
  (fn [client server]
    (def response (http/read-response client (buffer/new 64) (http/deadline-in 2000)))
    (check/check= (get response :status) 200 "a Content-Length response reports its status")
    (check/check= (get response :body) `{"status":"success","value":1}`
                  "a Content-Length response returns exactly its body")))

(with-response
  (fixture/chunked-response 200 [`{"status":"suc` `cess","value":` `[1,2]}`])
  (fn [client server]
    (def response (http/read-response client (buffer/new 64) (http/deadline-in 2000)))
    (check/check= (get response :body) `{"status":"success","value":[1,2]}`
                  "chunks are reassembled in order")))

(with-response
  (string "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" `{"status":"success","value":0}`)
  (fn [client server]
    (def response (http/read-response client (buffer/new 64) (http/deadline-in 2000)))
    (check/check= (get response :body) `{"status":"success","value":0}`
                  "a body framed only by end of stream is read")))

(each [raw description]
  [[(string "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc")
    "a repeated Content-Length is refused"]
   [(string "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nabc")
    "an unsupported transfer encoding is refused"]
   [(string "HTTP/1.1 200 OK\r\nContent-Length: 3000000\r\n\r\nabc")
    "a body larger than the limit is refused before it is read"]
   [(string "HTTP/1.1 200 OK\r\nX-A: 1\r\n\tfolded\r\n\r\n")
    "obsolete header folding is refused"]
   [(string "HTTP/1.1 200 OK\r\nBadHeader\r\n\r\n")
    "a header without a colon is refused"]
   [(string "NOTHTTP 200 OK\r\n\r\n")
    "a non-HTTP status line is refused"]
   [(string "HTTP/1.1 20 OK\r\n\r\n")
    "a malformed status code is refused"]
   [(string "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
    "a non-hexadecimal chunk size is refused"]
   [(string "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2ee000\r\n")
    "a chunk larger than the limit is refused"]]
  (with-response raw
    (fn [client server]
      (check/check-raises "ProtocolError"
                          (fn [] (http/read-response client (buffer/new 64)
                                                     (http/deadline-in 2000)))
                          description))))

# A peer that sends part of a body and then stops must hit the deadline rather
# than hold the caller open. The server end stays open so this is a real stall.
(with-response
  (string "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonlyten12")
  (fn [client server]
    (def started (http/now-ms))
    (check/check-raises "TransportError"
                        (fn [] (http/read-response client (buffer/new 64)
                                                   (http/deadline-in 300)))
                        "a stalled body hits the absolute deadline")
    (def elapsed (- (http/now-ms) started))
    (check/check (< elapsed 2000)
                 (string "the stalled read returned promptly, took " elapsed "ms")))
  true)

#
# A full request and response exchange
#

(with-response
  (fixture/http-response
    200
    `{"status":"success","value":{"count":0},"logLines":["[LOG] demo:echo"]}`)
  (fn [client server]
    (def parts (http/parse-url "http://backend:3210"))
    (def response (http/exchange client parts "/api/query"
                                 @[["Content-Type" "application/json"]
                                   ["Convex-Client" "janet-0.1.0"]
                                   ["Authorization" "Bearer secret-token"]]
                                 `{"path":"demo:state","args":{},"format":"json"}`
                                 (http/deadline-in 2000)))
    (check/check= (get response :status) 200 "the exchange reports the status")
    (def result (convex/classify-envelope (get response :status) (get response :body)))
    (check/check= (get-in result [:value "count"]) 0 "the envelope value is decoded")
    (check/check= (get result :logs) @["[LOG] demo:echo"] "log lines are carried through")

    # Now read back what the client actually put on the wire.
    (def request (buffer/new 512))
    (repeat 4 (fixture/read-available! server request 50))
    (def text (string request))
    (check/check (string/has-prefix? "POST /api/query HTTP/1.1\r\n" text)
                 "the request line targets the Convex endpoint")
    (check/check (string/find "Host: backend:3210\r\n" text) "the Host header carries the port")
    (check/check (string/find "Convex-Client: janet-0.1.0\r\n" text)
                 "the Convex-Client header identifies this client")
    (check/check (string/find "Authorization: Bearer secret-token\r\n" text)
                 "the bearer token is sent when one is configured")
    (check/check (string/find "Content-Length: 47\r\n" text)
                 "the body length is declared")
    (check/check (string/has-suffix? `{"path":"demo:state","args":{},"format":"json"}` text)
                 "the JSON body is sent unchanged"))
  true)

#
# Convex envelope classification
#

(def success (convex/classify-envelope 200 `{"status":"success","value":null}`))
(check/check (json/null? (get success :value))
             "a null Convex value stays null rather than becoming absent")

(def structured-error-body
  `{"status":"error","errorMessage":"nope","errorData":{"code":"X"}}`)

(check/check-raises "FunctionError"
                    (fn []
                      (convex/classify-envelope 560 structured-error-body))
                    "a structured function error survives HTTP 560")

(def function-error
  (check/raises (fn [] (convex/classify-envelope 560 structured-error-body))))
(check/check= (get-in function-error [:data "code"]) "X"
              "the function error keeps its structured data")
(check/check= (get function-error :message) "nope" "the function error keeps its message")

(check/check-raises "TransportError"
                    (fn [] (convex/classify-envelope 500 `{"status":"success","value":0}`))
                    "a success-shaped body under HTTP 500 is not a result")
(check/check-raises "TransportError"
                    (fn [] (convex/classify-envelope 502 "<html>gateway</html>"))
                    "a non-Convex error page is a transport failure")
(check/check-raises "ProtocolError"
                    (fn [] (convex/classify-envelope 200 "[]"))
                    "a JSON array is not a Convex envelope")
(check/check-raises "ProtocolError"
                    (fn [] (convex/classify-envelope 200 `{"status":"pending"}`))
                    "an unknown envelope status is refused")
(check/check-raises "ProtocolError"
                    (fn [] (convex/classify-envelope 200 `{"status":"success"}`))
                    "a success envelope without a value is refused")
(check/check-raises "ProtocolError"
                    (fn [] (convex/classify-envelope 200 `{"status":"error"}`))
                    "an error envelope without a message is refused")
(check/check-raises "ProtocolError"
                    (fn []
                      (convex/classify-envelope
                        200 `{"status":"success","value":0,"logLines":[1]}`))
                    "log lines that are not strings are refused")

#
# Client-level argument and token validation
#

(def client (convex/new-client "http://backend:3210"))
(check/check-raises "ProtocolError" (fn [] (convex/query client "" @{}))
                    "an empty function path is refused")
(check/check-raises "ProtocolError" (fn [] (convex/query client "demo:state" @[]))
                    "arguments that are not a named object are refused")
(check/check-raises "ProtocolError"
                    (fn [] (convex/set-auth! client "bad\r\nX: 1"))
                    "a header-injecting token is refused")
(convex/set-auth! client "")
(check/check= (get client :token) nil "an empty token clears authentication")
(convex/close! client)
(check/check-raises "ProtocolError" (fn [] (convex/query client "demo:state" @{}))
                    "a closed client refuses further calls")

(check/report "janet http")
