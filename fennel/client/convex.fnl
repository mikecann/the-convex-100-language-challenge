;; Fennel owns Convex's request construction and response semantics. The Lua
;; dependencies below only provide ordinary HTTP/TLS framing and JSON.
(local http-request (require :http.request))
(local json (require :json))
(local Live (require :live))

(local max-response-bytes (* 2 1024 1024))
(local Convex {})
(set Convex.__index Convex)

(fn fail [name message data logs]
  (values nil {: name : message : data : logs}))

(fn valid-url? [url]
  (and (= (type url) :string)
       (not (= nil (string.match url "^https?://[^/%?#]+")))))

(fn Convex.new [deployment-url options]
  (if (not (valid-url? deployment-url))
      (fail :ProtocolError
            "Convex deployment URL must use http or https and include a host")
      (not (= nil (string.match deployment-url "^https?://[^/]+@")))
      (fail :ProtocolError
            "Convex deployment URL must not include user information")
      (let [options (or options {})]
        (setmetatable {:deployment-url (string.gsub deployment-url "/+$" "")
                       :bearer-token (or (. options :bearer-token) "")
                       :client-version (or (. options :client-version)
                                           :fennel-0.1.0)
                       :live-cq options.cq
                       :request-factory (or options.request-factory
                                            http-request.new_from_uri)
                       :websocket-factory options.websocket-factory
                       :live nil
                       :closed false} Convex))))

(fn Convex.set-auth [self token]
  (if self.closed
      (fail :ClosedError "Convex client is closed")
      (do
        (set self.bearer-token (or token "")) true)))

(fn Convex.close [self]
  (if self.live (: self.live :close))
  (set self.closed true)
  true)

(fn Convex.subscribe [self path args]
  (if self.closed
      (fail :ClosedError "Convex client is closed")
      (not (and (= (type path) :string) (> (length path) 0)))
      (fail :ProtocolError "Convex function path is required")
      (and (not (= args nil)) (not (= (type args) :table)))
      (fail :ProtocolError "Convex arguments must be a named JSON object")
      (do
        (if (not self.live)
            (set self.live
                 (Live.Manager.new self.deployment-url self.client-version
                                   {:cq self.live-cq
                                    :websocket-factory self.websocket-factory})))
        (: self.live :subscribe path (or args {})))))

(fn Convex.debug-disconnect-for-adapter [self]
  (if self.live (: self.live :debug-disconnect)
      (fail :TransportError "Live WebSocket is not connected")))

(fn Convex.call [self operation path args]
  (if self.closed
      (fail :ClosedError "Convex client is closed")
      (not (or (= operation :query) (= operation :mutation)
               (= operation :action)))
      (fail :ProtocolError
            (.. "unknown Convex operation " (tostring operation)))
      (not (and (= (type path) :string) (> (length path) 0)))
      (fail :ProtocolError "Convex function path is required")
      (and (not (= args nil)) (not (= (type args) :table)))
      (fail :ProtocolError "Convex arguments must be a named JSON object")
      (let [call-args (or args {})]
        (json.object call-args)
        (let [(body body-error) (json.encode {: path
                                              :args call-args
                                              :format :json})]
          (if (not body)
              (fail :ProtocolError
                    (.. "encode Convex request: " (tostring body-error)))
              (let [request (self.request-factory (.. self.deployment-url
                                                      :/api/ operation))]
                (: request.headers :upsert ":method" :POST)
                (: request.headers :upsert :content-type :application/json)
                (: request.headers :upsert :accept :application/json)
                (: request.headers :upsert :convex-client self.client-version)
                (if (not (= self.bearer-token ""))
                    (: request.headers :upsert :authorization
                       (.. "Bearer " self.bearer-token)))
                (: request :set_body body)
                (let [(headers stream request-errno) (: request :go 30)]
                  (if (not headers)
                      (fail :TransportError
                            (.. "Convex " operation " request failed: "
                                (tostring (or stream request-errno))))
                      (let [(response read-error) (: stream :get_body_as_string
                                                     30)]
                        (if (not response)
                            (fail :TransportError
                                  (.. "read Convex " operation " response: "
                                      (tostring read-error)))
                            (> (length response) max-response-bytes)
                            (fail :TransportError
                                  (.. "response exceeds " max-response-bytes
                                      " bytes"))
                            (let [(decoded decode-error) (json.decode response)]
                              (if (not decoded)
                                  (fail :TransportError
                                        (.. "HTTP "
                                            (tostring (: headers :get ":status"))
                                            " returned a non-Convex response: "
                                            (tostring decode-error)))
                                  (= decoded.status :success)
                                  (if (= decoded.value nil)
                                      (fail :ProtocolError
                                            "success response omitted value")
                                      {:value decoded.value
                                       :logs (or decoded.logLines {})})
                                  (= decoded.status :error)
                                  (fail :FunctionError
                                        (or decoded.errorMessage
                                            "Convex function failed")
                                        decoded.errorData
                                        (or decoded.logLines {}))
                                  (fail :ProtocolError
                                        (.. "HTTP response has unknown status "
                                            (tostring decoded.status)))))))))))))))

(fn Convex.query [self path args] (Convex.call self :query path args))
(fn Convex.mutation [self path args] (Convex.call self :mutation path args))
(fn Convex.action [self path args] (Convex.call self :action path args))
(set Convex.array json.array)
(set Convex.object json.object)
(set Convex.null json.null)
Convex
