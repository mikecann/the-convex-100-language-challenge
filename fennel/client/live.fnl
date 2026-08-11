;; The Live manager has one cqueues worker as the exclusive WebSocket owner.
;; Callers submit commands to it and never read, write, or reconnect a socket
;; themselves. This makes query-set versions and reconnect state serial.
(local json (require :json))
(local cqueues (require :cqueues))
(local condition (require :cqueues.condition))
(local errno (require :cqueues.errno))
(local websocket (require :http.websocket))
(local random (require :openssl.rand))
(local basexx (require :basexx))

(local Live {})
(local initial-timestamp :AAAAAAAAAAA=)
(local initial-backoff 0.1)
(local max-backoff 15)
(local max-buffered-updates 16)
(local max-buffered-update-bytes (* 3 1024 1024))
(local buffered-update-overhead 256)
(local max-websocket-message-bytes (* 2 1024 1024))

(fn failure [name message data logs]
  {: name : message : data :logs (or logs {})})

(fn copy-json [value]
  (if (= value nil) nil
      (let [(encoded encode-error) (json.encode value)]
        (if (not encoded) (error encode-error)
            (let [(decoded decode-error) (json.decode encoded)]
              (if decoded decoded (error decode-error)))))))

(fn same-value? [left right]
  (if (= left right) true
      (not (= (type left) (type right))) false
      (not (= (type left) :table)) false
      (not (= (. (getmetatable left) :__jsontype)
              (. (getmetatable right) :__jsontype))) false
      (let [matches true]
        (var all-match matches)
        (each [key value (pairs left)]
          (if (not (same-value? value (. right key))) (set all-match false)))
        (each [key _ (pairs right)]
          (if (= (. left key) nil) (set all-match false)))
        all-match)))

(fn zero-version [] {:querySet 0 :identity 0 :ts initial-timestamp})

(fn valid-version? [version]
  (and (= (type version) :table) (= (type version.querySet) :number)
       (>= version.querySet 0) (= (% version.querySet 1) 0)
       (= (type version.identity) :number) (>= version.identity 0)
       (= (% version.identity 1) 0) (= (type version.ts) :string)
       (let [(ok decoded) (pcall basexx.from_base64 version.ts)]
         (and ok (= (type decoded) :string) (= (length decoded) 8)))))

(fn versions-equal? [left right]
  (and left right (= left.querySet right.querySet)
       (= left.identity right.identity) (= left.ts right.ts)))

(fn compare-timestamps [left right]
  (let [left-bytes (basexx.from_base64 left)
        right-bytes (basexx.from_base64 right)]
    ;; Convex timestamps are little-endian uint64 values. Stop at the first
    ;; unequal most-significant byte so a larger low byte cannot outweigh a
    ;; smaller high byte.
    (var ordering 0)
    (var index 8)
    (while (and (>= index 1) (= ordering 0))
      (let [left-byte (string.byte left-bytes index)
            right-byte (string.byte right-bytes index)]
        (if (< left-byte right-byte) (set ordering -1)
            (> left-byte right-byte) (set ordering 1)))
      (set index (- index 1)))
    ordering))

(fn later-timestamp [left right]
  (if (or (not left) (< (compare-timestamps left right) 0)) right left))

(fn session-id []
  (let [raw (random.bytes 16)]
    ;; UUID formatting is a protocol-safe opaque session identifier.
    (string.format "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
                   (string.byte raw 1) (string.byte raw 2) (string.byte raw 3)
                   (string.byte raw 4) (string.byte raw 5) (string.byte raw 6)
                   (+ 64 (% (string.byte raw 7) 16)) (string.byte raw 8)
                   (+ 128 (% (string.byte raw 9) 64)) (string.byte raw 10)
                   (string.byte raw 11) (string.byte raw 12)
                   (string.byte raw 13) (string.byte raw 14)
                   (string.byte raw 15) (string.byte raw 16))))

(local Subscription {})
(set Subscription.__index Subscription)

(fn Subscription.new [manager query-id]
  (setmetatable {: manager
                 : query-id
                 :updates []
                 :update-bytes 0
                 :changed (condition.new)
                 :closed false
                 :finished false} Subscription))

(fn Subscription.deliver [self update]
  (if (not self.finished)
      (let [(encoded encode-error) (json.encode update)]
        (if (not encoded) (error encode-error))
        (let [bytes (+ (length encoded) buffered-update-overhead)]
          ;; Keep at least the newest update, but bound both retained event count
          ;; and bytes. A count limit alone is not a memory limit.
          (while (and (> (length self.updates) 0)
                      (or (>= (length self.updates) max-buffered-updates)
                          (> (+ self.update-bytes bytes)
                             max-buffered-update-bytes)))
            (let [removed (table.remove self.updates 1)]
              (set self.update-bytes (- self.update-bytes removed.bytes))))
          (table.insert self.updates {:update update :bytes bytes})
          (set self.update-bytes (+ self.update-bytes bytes))
          (: self.changed :signal 1)))))

(fn Subscription.finish [self]
  (if (not self.finished)
      (do
        (set self.finished true) (set self.updates []) (set self.update-bytes 0)
        (: self.changed :signal 1))))

(fn Subscription.try-next-update [self]
  (if (> (length self.updates) 0)
      (let [entry (table.remove self.updates 1)]
        (set self.update-bytes (- self.update-bytes entry.bytes))
        entry.update)
      nil))

(fn Subscription.next-update [self timeout]
  (let [deadline (and timeout (+ (cqueues.monotime) timeout))]
    (var wait-error nil)
    (while (and (= (length self.updates) 0) (not self.finished)
                (not wait-error))
      (let [remaining (and deadline (- deadline (cqueues.monotime)))]
        (if (and remaining (<= remaining 0))
            (set wait-error
                 (failure :TransportError "timed out waiting for Live update"))
            (cqueues.running)
            (: self.changed :wait remaining)
            (let [(ok err) (: self.manager.cq :step remaining)]
              (if (and (not ok) err)
                  (set wait-error (failure :TransportError (tostring err))))))))
    (if wait-error (values nil wait-error)
        (and self.finished (= (length self.updates) 0))
        (values nil (failure :ClosedError "Live subscription is closed"))
        (: self :try-next-update))))

(fn Subscription.close [self]
  (if self.closed true
      (do
        (set self.closed true)
        (: self.manager :unsubscribe self.query-id))))

(local Manager {})
(set Manager.__index Manager)

(fn Manager.new [deployment-url client-version options]
  (let [options (or options {})
        ws-url (.. (string.gsub (string.gsub deployment-url "^https://"
                                             "wss://")
                                "^http://" "ws://")
                   :/api/sync)
        self (setmetatable {:websocket-url ws-url
                            : client-version
                            :cq (or options.cq (cqueues.new))
                            :websocket-factory options.websocket-factory
                            :commands []
                            :command-ready (condition.new)
                            :subscriptions {}
                            :remote-results {}
                            :next-query-id 0
                            :query-set-version 0
                            :query-set-ack-pending false
                            :queued-modifications []
                            :remote-version (zero-version)
                            :connection-count 0
                            :last-close-reason :InitialConnect
                            :next-backoff initial-backoff
                            :reconnect-at nil
                            :max-observed-timestamp nil
                            ;; One UUID identifies the logical Live session. It
                            ;; remains stable across every transport reconnect.
                            :session-id (session-id)
                            :socket nil
                            :closed false} Manager)]
    (: self.cq :wrap (fn [] (: self :owner)))
    self))

(fn Manager.respond [self command value err]
  (set command.response.value value)
  (set command.response.error err)
  (set command.response.done true)
  (: command.response.changed :signal 1))

(fn Manager.wait [self response]
  (var owner-error nil)
  (while (and (not response.done) (not owner-error))
    (if (cqueues.running)
        (: response.changed :wait)
        ;; cqueues reports its own transport errors through the owner. A failed
        ;; step here simply lets that owner publish the structured failure.
        ;; A zero-deadline step processes the command without letting a busy
        ;; socket owner monopolise the caller before the acknowledgement lands.
        (let [(ok err) (: self.cq :step 0)]
          (if (and (not response.done) (not ok) err
                   (not (= err errno.ETIMEDOUT)))
              (set owner-error (failure :TransportError (tostring err)))))))
  (if owner-error (values nil owner-error)
      (values response.value response.error)))

(fn Manager.submit [self kind fields]
  (if (and self.closed (not (= kind :close)))
      (values nil (failure :ClosedError "Convex Live manager is closed"))
      (let [command (or fields {})
            response {:changed (condition.new) :done false}]
        (set command.kind kind)
        (set command.response response)
        (table.insert self.commands command)
        (: self.command-ready :signal 1)
        (: self :wait response))))

(fn Manager.subscribe [self path args]
  (: self :submit :subscribe
     {: path :args (copy-json (json.object (or args {})))}))

(fn Manager.unsubscribe [self query-id]
  (if self.closed true (: self :submit :unsubscribe {: query-id})))

(fn Manager.debug-disconnect [self] (: self :submit :debug-disconnect))
(fn Manager.close [self] (if self.closed true (: self :submit :close)))

(fn Manager.add-modification [self query-id state]
  {:type :Add :queryId query-id :udfPath state.path :args [state.args]})

(fn Manager.send [self value timeout]
  (let [(encoded encode-error) (json.encode value)]
    (if (not encoded)
        (values nil (failure :ProtocolError
                             (.. "encode Live message: "
                                 (tostring encode-error))))
        (let [(ok err) (: self.socket :send encoded :text (or timeout 5))]
          (if ok
              true
              (values nil
                      (failure :TransportError
                               (.. "write Live message: " (tostring err)))))))))

(fn Manager.modify [self modifications timeout version-delta]
  (let [next-version (+ self.query-set-version (or version-delta 1))
        message {:type :ModifyQuerySet
                 :baseVersion self.query-set-version
                 :newVersion next-version
                 : modifications}]
    (let [(ok err) (: self :send message timeout)]
      (if ok (do
               (set self.query-set-version next-version)
               (set self.query-set-ack-pending true)
               true)
          (values nil err)))))

(fn Manager.send-or-queue-modification [self modification timeout]
  ;; The server confirms one ModifyQuerySet through the next Transition. Queue
  ;; subsequent Add/Remove commands until that acknowledgement arrives.
  (if self.query-set-ack-pending
      (do (table.insert self.queued-modifications modification) true)
      (: self :modify [modification] timeout)))

(fn Manager.flush-queued-modifications [self]
  (set self.query-set-ack-pending false)
  (if (= (length self.queued-modifications) 0) true
      (let [modifications self.queued-modifications]
        (set self.queued-modifications [])
        (: self :modify modifications nil (length modifications)))))

(fn Manager.recover-query-set-write [self err]
  ;; A failed send is ambiguous. Retire the socket, publish a structured error,
  ;; and replay only subscriptions that are still active on the next socket.
  (: self :clear-generation)
  (: self :disconnect (.. "QuerySetWriteFailed: " err.message) true)
  (: self :publish-error err))

(fn Manager.retire-socket [self reason]
  (if self.socket
      (do
        ;; A forced underlying-socket close is the bounded fallback when a peer
        ;; stalls halfway through RFC6455 close processing.
        (pcall (fn []
                 (: self.socket :close 1001
                    (string.sub (tostring reason) 1 123) 0.25)))
        (if self.socket.socket (pcall (fn [] (: self.socket.socket :shutdown))))
        (if self.socket.socket (pcall (fn [] (: self.socket.socket :close))))
        (set self.socket nil)
        true)
      false))

(fn Manager.disconnect [self reason reconnect]
  (if (: self :retire-socket reason)
      (set self.connection-count (+ self.connection-count 1)))
  (set self.last-close-reason reason)
  (set self.query-set-version 0)
  (set self.query-set-ack-pending false)
  (set self.queued-modifications [])
  (set self.remote-version (zero-version))
  (set self.remote-results {})
  (if (and reconnect (next self.subscriptions))
      (do
        (set self.reconnect-at (+ (cqueues.monotime) self.next-backoff))
        (set self.next-backoff (math.min (* self.next-backoff 2) max-backoff)))))

(fn Manager.publish-error [self err]
  (each [_ state (pairs self.subscriptions)]
    (: state.subscription :deliver {:error err :logs (or err.logs {})})))

(fn Manager.clear-generation [self]
  ;; Once a transport is retired, no value already dequeued from it may appear
  ;; after the structured failure or debugDisconnect acknowledgement.
  (each [_ state (pairs self.subscriptions)]
    (set state.subscription.updates [])
    (set state.subscription.update-bytes 0)))

(fn Manager.connect [self]
  (let [socket (if self.websocket-factory
                   (self.websocket-factory self.websocket-url)
                   (websocket.new_from_uri self.websocket-url))]
    (if (and socket.request socket.request.headers)
        (: socket.request.headers :append :convex-client self.client-version))
    (let [(ok connect-error) (: socket :connect 10)]
      (if (not ok)
          (values nil
                  (failure :TransportError
                           (.. "connect Live WebSocket: "
                               (tostring connect-error))))
          (do
            (set self.socket socket)
            (set self.query-set-version 0)
            (set self.remote-version (zero-version))
            (set self.remote-results {})
            (let [message {:type :Connect
                           :sessionId self.session-id
                           :connectionCount self.connection-count
                           :lastCloseReason self.last-close-reason
                           :clientTs 0}]
              (if self.max-observed-timestamp
                  (set message.maxObservedTimestamp self.max-observed-timestamp))
              (let [(sent send-error) (: self :send message)]
                (if (not sent) (values nil send-error)
                    (let [modifications []]
                      (each [query-id state (pairs self.subscriptions)]
                        (table.insert modifications
                                      (: self :add-modification query-id state)))
                      (table.sort modifications
                                  (fn [a b] (< a.queryId b.queryId)))
                      (if (> (length modifications) 0)
                          (let [(modified modify-error) (: self :modify
                                                           modifications)]
                            (if (not modified) (values nil modify-error))))
                      (set self.next-backoff initial-backoff)
                      (set self.reconnect-at nil)
                      true)))))))))

(fn Manager.transition [self message]
  (if (not (and (valid-version? message.startVersion)
                (valid-version? message.endVersion)))
      (values nil
              (failure :ProtocolError
                       "Transition must include valid startVersion and endVersion objects"))
      (not (versions-equal? message.startVersion self.remote-version))
      (values nil
              (failure :ProtocolError
                       "Transition start version does not match the local version"))
      (not (= message.endVersion.querySet self.query-set-version))
      (values nil
              (failure :ProtocolError
                       "Transition query-set version does not match the locally sent query set"))
      (or (< message.endVersion.querySet message.startVersion.querySet)
          (< message.endVersion.identity message.startVersion.identity)
          (< (compare-timestamps message.endVersion.ts message.startVersion.ts) 0))
      (values nil
              (failure :ProtocolError "Transition end version regresses"))
      (not (json.is-array message.modifications))
      (values nil
              (failure :ProtocolError
                       "Transition modifications must be an array"))
      (let [changed {}
            next-results (copy-json self.remote-results)]
        (var validation-error nil)
        ;; Validate the complete Transition before mutating any version, cached
        ;; result, timestamp, or delivery state.
        (each [_ modification (ipairs message.modifications)]
          (if validation-error nil
              (not (and (= (type modification) :table)
                        (= (type modification.queryId) :number)
                        (= (% modification.queryId 1) 0)))
              (set validation-error
                   (failure :ProtocolError
                            "Transition modification requires an integer queryId"))
              (= modification.type :QueryUpdated)
              (if (= modification.value nil)
                  (set validation-error
                       (failure :ProtocolError "QueryUpdated omitted value")))
              (= modification.type :QueryFailed)
              (if (not (= (type modification.errorMessage) :string))
                  (set validation-error
                       (failure :ProtocolError
                                "QueryFailed omitted errorMessage")))
              (= modification.type :QueryRemoved)
              (if (not (= modification.logLines nil))
                  (set validation-error
                       (failure :ProtocolError
                                "QueryRemoved must not include logLines")))
              (set validation-error
                   (failure :ProtocolError
                            (.. "unknown Transition modification "
                                (tostring modification.type)))))
          (if (and (not validation-error)
                   (or (= modification.type :QueryUpdated)
                       (= modification.type :QueryFailed)))
              (if (not (json.is-array modification.logLines))
                  (set validation-error
                       (failure :ProtocolError
                                "Transition logLines must be an array"))
                  (each [_ line (ipairs modification.logLines)]
                    (if (not (= (type line) :string))
                        (set validation-error
                             (failure :ProtocolError
                                      "Transition logLines entries must be strings")))))))
        (if validation-error
            (values nil validation-error)
            (do
              (each [_ modification (ipairs message.modifications)]
                (if (= modification.type :QueryUpdated)
                    (let [update {:value (copy-json modification.value)
                                  :logs (copy-json modification.logLines)}]
                      (set (. changed modification.queryId) update)
                      (set (. next-results modification.queryId) update))
                    (= modification.type :QueryFailed)
                    (let [err (failure :FunctionError modification.errorMessage
                                       (copy-json modification.errorData)
                                       (copy-json modification.logLines))]
                      (set (. changed modification.queryId)
                           {:error err :logs err.logs})
                      (set (. next-results modification.queryId)
                           (. changed modification.queryId)))
                    (= modification.type :QueryRemoved)
                    (set (. next-results modification.queryId) nil)))
              (set self.remote-results next-results)
              (set self.remote-version (copy-json message.endVersion))
              (set self.max-observed-timestamp
                   (later-timestamp self.max-observed-timestamp
                                    self.remote-version.ts))
              (each [query-id update (pairs changed)]
                (let [state (. self.subscriptions query-id)]
                  (if state
                      (let [duplicate (and (not update.error)
                                           (same-value? state.last-delivered
                                                        update.value))]
                        (if (not duplicate)
                            (do
                              (set state.last-delivered
                                   (if update.error nil
                                       (copy-json update.value)))
                              (: state.subscription :deliver update)))))))
              (: self :flush-queued-modifications))))))

(fn Manager.receive [self]
  (let [(payload kind receive-errno) (: self.socket :receive 0.1)]
    (if (not payload)
        (if (= receive-errno errno.ETIMEDOUT)
            true
            (values nil
                    (failure :TransportError
                             (.. "read Live WebSocket: " (tostring kind)))))
        (> (length payload) max-websocket-message-bytes)
        (values nil
                (failure :TransportError
                         (.. "Live message exceeds " max-websocket-message-bytes
                             " bytes")))
        (not (= kind :text))
        (values nil
                (failure :ProtocolError "Convex Live sent a non-text message"))
        (let [(message decode-error) (json.decode payload)]
          (if (not message)
              (values nil
                      (failure :ProtocolError
                               (.. "decode Live message: "
                                   (tostring decode-error))))
              (= message.type :Transition)
              (let [(ok err) (: self :transition message)]
                (if ok (do
                         (set self.next-backoff initial-backoff)
                         true) (values nil err)))
              (or (= message.type :Ping) (= message.type :MutationResponse)
                  (= message.type :ActionResponse))
              (do
                (set self.next-backoff initial-backoff) true)
              (or (= message.type :FatalError) (= message.type :AuthError))
              (values nil
                      (failure :ProtocolError
                               (.. message.type ": " (tostring message.error))))
              (values nil
                      (failure :ProtocolError
                               (.. "unknown server message "
                                   (tostring message.type)))))))))

;; Command handling is deliberately kept in the owner loop. Subscribe/Remove
;; invalidate state before acknowledgements, and debugDisconnect schedules the
;; replacement connection before returning its acknowledgement.
(fn Manager.process-commands [self]
  (while (> (length self.commands) 0)
    (let [command (table.remove self.commands 1)]
      (if (= command.kind :subscribe)
          (let [query-id self.next-query-id
                subscription (Subscription.new self query-id)
                state {:path command.path
                       :args command.args
                       : subscription
                       :last-delivered nil}]
            (set self.next-query-id (+ query-id 1))
            (set (. self.subscriptions query-id) state)
            (if self.socket
                (let [(ok err) (: self :send-or-queue-modification
                                  (: self :add-modification query-id state))]
                  (if ok (: self :respond command subscription)
                      (do
                        (set (. self.subscriptions query-id) nil)
                        (: subscription :finish)
                        (: self :recover-query-set-write err)
                        (: self :respond command nil err))))
                (do
                  (set self.reconnect-at (cqueues.monotime))
                  (: self :respond command subscription))))
          (= command.kind :unsubscribe)
          (let [state (. self.subscriptions command.query-id)]
            (set (. self.subscriptions command.query-id) nil)
            (set (. self.remote-results command.query-id) nil)
            (if state (: state.subscription :finish))
            (if (and state self.socket)
                (let [(ok err) (: self :send-or-queue-modification
                                  {:type :Remove :queryId command.query-id}
                                  0.25)]
                  (if ok (: self :respond command true)
                      (do
                        (: self :recover-query-set-write err)
                        (: self :respond command nil err))))
                (: self :respond command true)))
          (= command.kind :debug-disconnect)
          (if self.socket
              (do
                (: self :clear-generation)
                (: self :disconnect :DebugDisconnect true)
                (: self :respond command true))
              (: self :respond command nil
                 (failure :TransportError "Live WebSocket is not connected")))
          (= command.kind :close)
          (do
            (set self.closed true)
            (each [_ state (pairs self.subscriptions)]
              (: state.subscription :finish))
            (set self.subscriptions {})
            (: self :retire-socket "client closed")
            (: self :respond command true))))))

(fn Manager.owner [self]
  (while (not self.closed)
    (: self :process-commands)
    (if self.closed nil
        (and (not self.socket) (next self.subscriptions)
             (or (not self.reconnect-at)
                 (>= (cqueues.monotime) self.reconnect-at)))
        (let [(ok err) (: self :connect)]
          (if (not ok)
              (do
                (: self :clear-generation)
                (: self :publish-error err)
                ;; A refused or failed handshake is still a connection attempt,
                ;; and the next successful Connect must report it.
                (if (not self.socket)
                    (set self.connection-count (+ self.connection-count 1)))
                (: self :disconnect err.message true)))) self.socket
        (let [(ok err) (: self :receive)]
          (if (not ok)
              (do
                (: self :clear-generation)
                (: self :publish-error err)
                (: self :disconnect err.message true))))
        (not (next self.subscriptions)) (: self.command-ready :wait 1))))

(set Live.Manager Manager)
(set Live.Subscription Subscription)
(set Live.failure failure)
Live
