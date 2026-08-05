(import scheme
        (chicken base)
        (chicken condition)
        (chicken io)
        (chicken port)
        (chicken process-context)
        (chicken string)
        (chicken tcp)
        (chicken time)
        srfi-1
        srfi-18
        srfi-69
        convex)

(define +adapter-line-limit+ (* 2 1024 1024))
(define +output-count-limit+ 16)
(define +output-byte-limit+ (* 6 1024 1024))

(define (condition-text condition)
  (cond
    ((convex-error? condition) (convex-error-message condition))
    ((and (condition? condition)
          ((condition-predicate 'exn) condition))
     (let ((message (get-condition-property condition 'exn 'message #f)))
       (let ((location (get-condition-property condition 'exn 'location #f))
             (arguments (get-condition-property condition 'exn 'arguments '())))
         (with-output-to-string
          (lambda ()
            (if message (display message) (display "Scheme exception"))
            (when location
              (display " at ")
              (display location))
            (when (pair? arguments)
              (display ": ")
              (write arguments)))))))
    (else (with-output-to-string (lambda () (write condition))))))

(define (event . pairs) (apply json-object pairs))

(define (error-event condition #!key (id #f) (subscription-id #f))
  (let* ((convex? (convex-error? condition))
         (name (if convex? (convex-error-name condition) "ProtocolError"))
         (message (condition-text condition))
         (data (if convex? (convex-error-data condition) json-null))
         (logs (if convex? (convex-error-logs condition) '()))
         (pairs
           (append
            (list "type" (if subscription-id "subscription" "error"))
            (if id (list "id" id) '())
            (if subscription-id (list "subscriptionId" subscription-id) '())
            (list "error" (event "name" name "message" message "data" data))
            (if (pair? logs) (list "logs" logs) '()))))
    (apply event pairs)))

;; Every encoded event is charged before it enters the writer. The charge is
;; retained while a TCP write is in flight, so a stopped controller cannot hide
;; memory in the kernel-blocked writer stack.
(define-record-type <output-item>
  (make-output-item text size droppable?)
  output-item?
  (text output-item-text)
  (size output-item-size)
  (droppable? output-item-droppable?))

(define-record-type <output-sink>
  (%make-output-sink port lock condition encoder-lock queue queued-bytes
                     in-flight-bytes closed? failed writer tcp?)
  output-sink?
  (port output-sink-port)
  (lock output-sink-lock)
  (condition output-sink-condition)
  (encoder-lock output-sink-encoder-lock)
  (queue output-sink-queue output-sink-queue-set!)
  (queued-bytes output-sink-queued-bytes output-sink-queued-bytes-set!)
  (in-flight-bytes output-sink-in-flight-bytes
                   output-sink-in-flight-bytes-set!)
  (closed? output-sink-closed? output-sink-closed-set!)
  (failed output-sink-failed output-sink-failed-set!)
  (writer output-sink-writer output-sink-writer-set!)
  (tcp? output-sink-tcp?))

(define (sink-count sink)
  (+ (length (output-sink-queue sink))
     (if (> (output-sink-in-flight-bytes sink) 0) 1 0)))

(define (sink-total-bytes sink)
  (+ (output-sink-queued-bytes sink)
     (output-sink-in-flight-bytes sink)))

(define (remove-first-droppable! sink)
  (let loop ((remaining (output-sink-queue sink)) (prefix '()))
    (cond
      ((null? remaining) #f)
      ((output-item-droppable? (car remaining))
       (let ((item (car remaining)))
         (output-sink-queue-set!
          sink (append (reverse prefix) (cdr remaining)))
         (output-sink-queued-bytes-set!
          sink (- (output-sink-queued-bytes sink) (output-item-size item)))
         #t))
      (else (loop (cdr remaining) (cons (car remaining) prefix))))))

(define (output-writer-loop sink)
  (handle-exceptions condition
    (begin
      (display "adapter output failed: " (current-error-port))
      (display (condition-text condition) (current-error-port))
      (newline (current-error-port))
      (flush-output (current-error-port))
      (mutex-lock! (output-sink-lock sink))
      (output-sink-in-flight-bytes-set! sink 0)
      (output-sink-failed-set! sink condition)
      (output-sink-closed-set! sink #t)
      (condition-variable-broadcast! (output-sink-condition sink))
      (mutex-unlock! (output-sink-lock sink)))
    (let loop ()
      (mutex-lock! (output-sink-lock sink))
      (let wait ()
        (when (and (null? (output-sink-queue sink))
                   (not (output-sink-closed? sink)))
          (mutex-unlock! (output-sink-lock sink)
                         (output-sink-condition sink))
          (mutex-lock! (output-sink-lock sink))
          (wait)))
      (if (and (null? (output-sink-queue sink))
               (output-sink-closed? sink))
          (mutex-unlock! (output-sink-lock sink))
          (let* ((item (car (output-sink-queue sink)))
                 (remaining (cdr (output-sink-queue sink))))
            (output-sink-queue-set! sink remaining)
            (output-sink-queued-bytes-set!
             sink (- (output-sink-queued-bytes sink) (output-item-size item)))
            (output-sink-in-flight-bytes-set! sink (output-item-size item))
            (mutex-unlock! (output-sink-lock sink))
            (if (output-sink-tcp? sink)
                (parameterize ((tcp-write-timeout 500))
                  (display (output-item-text item) (output-sink-port sink))
                  (flush-output (output-sink-port sink)))
                (begin
                  (display (output-item-text item) (output-sink-port sink))
                  (flush-output (output-sink-port sink))))
            (mutex-lock! (output-sink-lock sink))
            (output-sink-in-flight-bytes-set! sink 0)
            (condition-variable-broadcast! (output-sink-condition sink))
            (mutex-unlock! (output-sink-lock sink))
            (loop))))))

(define (make-output-sink port tcp?)
  (let ((sink
          (%make-output-sink port (make-mutex 'adapter-output)
                             (make-condition-variable 'adapter-output)
                             (make-mutex 'adapter-encoder)
                             '() 0 0 #f #f #f tcp?)))
    (output-sink-writer-set!
     sink
     (thread-start!
      (make-thread (lambda () (output-writer-loop sink))
                   'adapter-bounded-writer)))
    sink))

(define (output-publish! sink object #!key (droppable? #f) (timeout 5.0))
  ;; Serialising through one lock also bounds the otherwise uncharged encoder
  ;; work to one event, even if many Live relay threads publish concurrently.
  (mutex-lock! (output-sink-encoder-lock sink))
  (let ((text
          (handle-exceptions condition
            (begin
              (mutex-unlock! (output-sink-encoder-lock sink))
              (raise condition))
            (string-append (json-encode object) "\n"))))
    (mutex-unlock! (output-sink-encoder-lock sink))
    (let ((size (string-length text))
          (deadline (+ (current-seconds) timeout)))
      (when (> size +output-byte-limit+)
        (error 'output-publish! "adapter event exceeds encoded output budget"))
      (mutex-lock! (output-sink-lock sink))
      (let fit ()
        (when (or (>= (sink-count sink) +output-count-limit+)
                  (> (+ (sink-total-bytes sink) size) +output-byte-limit+))
          (cond
            ((remove-first-droppable! sink) (fit))
            (droppable?
             (mutex-unlock! (output-sink-lock sink))
             (set! size #f))
            (else
             (let ((remaining (- deadline (current-seconds))))
               (if (<= remaining 0)
                   (begin
                     (mutex-unlock! (output-sink-lock sink))
                     (error 'output-publish!
                            "adapter output remained backpressured"))
                   (begin
                     (mutex-unlock! (output-sink-lock sink)
                                    (output-sink-condition sink)
                                    remaining)
                     (mutex-lock! (output-sink-lock sink))
                     (fit))))))))
      (if (not size)
          #f
          (begin
            (when (or (output-sink-closed? sink) (output-sink-failed sink))
              (mutex-unlock! (output-sink-lock sink))
              (if droppable?
                  (set! size #f)
                  (error 'output-publish! "adapter output is closed")))
            (if (not size)
                #f
                (begin
                  (output-sink-queue-set!
                   sink
                   (append (output-sink-queue sink)
                           (list (make-output-item text size droppable?))))
                  (output-sink-queued-bytes-set!
                   sink (+ (output-sink-queued-bytes sink) size))
                  (condition-variable-broadcast! (output-sink-condition sink))
                  (mutex-unlock! (output-sink-lock sink))
                  #t)))))))

(define (close-output-sink! sink #!optional (drain? #t))
  (mutex-lock! (output-sink-lock sink))
  (unless drain?
    (output-sink-queue-set! sink '())
    (output-sink-queued-bytes-set! sink 0))
  (output-sink-closed-set! sink #t)
  (condition-variable-broadcast! (output-sink-condition sink))
  (mutex-unlock! (output-sink-lock sink))
  (let ((writer (output-sink-writer sink)))
    (when writer
      (unless (thread-join! writer 1.0 #f)
        (thread-terminate! writer)))))

(define-record-type <relay-record>
  (make-relay-record subscription generation active? thread)
  relay-record?
  (subscription relay-subscription)
  (generation relay-generation)
  (active? relay-active? relay-active-set!)
  (thread relay-thread relay-thread-set!))

(define-record-type <adapter-state>
  (%make-adapter-state client client-lock publication-lock relays generations
                       minimum-live-generation output closed? hello?)
  adapter-state?
  (client adapter-client adapter-client-set!)
  (client-lock adapter-client-lock)
  (publication-lock adapter-publication-lock)
  (relays adapter-relays)
  (generations adapter-generations)
  (minimum-live-generation adapter-minimum-live-generation
                           adapter-minimum-live-generation-set!)
  (output adapter-output)
  (closed? adapter-closed? adapter-closed-set!)
  (hello? adapter-hello? adapter-hello-set!))

(define (make-adapter-state output)
  (%make-adapter-state #f (make-mutex 'adapter-client)
                       (make-mutex 'adapter-publication)
                       (make-hash-table string=? string-hash)
                       (make-hash-table string=? string-hash)
                       0 output #f #f))

(define (ensure-adapter-client state)
  (mutex-lock! (adapter-client-lock state))
  (let ((existing (adapter-client state)))
    (if existing
        (begin (mutex-unlock! (adapter-client-lock state)) existing)
        (let ((url (get-environment-variable "CONVEX_URL"))
              (token (or (get-environment-variable "CONVEX_AUTH_TOKEN") "")))
          (handle-exceptions condition
            (begin
              (mutex-unlock! (adapter-client-lock state))
              (raise condition))
            (unless (and url (> (string-length url) 0))
              (error 'adapter "CONVEX_URL is required"))
            (let ((client (make-client url auth-token: token
                                      client-version: "scheme-0.1.0")))
              (adapter-client-set! state client)
              (mutex-unlock! (adapter-client-lock state))
              client))))))

(define (next-generation! state subscription-id)
  (let ((next (+ 1 (hash-table-ref/default
                    (adapter-generations state) subscription-id 0))))
    (hash-table-set! (adapter-generations state) subscription-id next)
    next))

(define (call-with-publication-lock state procedure)
  (let ((lock (adapter-publication-lock state)))
    (mutex-lock! lock)
    (handle-exceptions condition
      (begin (mutex-unlock! lock) (raise condition))
      (let ((result (procedure)))
        (mutex-unlock! lock)
        result))))

(define (invalidate-relay! state subscription-id)
  (call-with-publication-lock
   state
   (lambda ()
     (next-generation! state subscription-id)
     (let ((record (hash-table-ref/default
                    (adapter-relays state) subscription-id #f)))
       (when record (relay-active-set! record #f))
       (hash-table-delete! (adapter-relays state) subscription-id)
       record))))

(define (stop-relay! record #!optional (close-subscription? #t))
  (when record
    (relay-active-set! record #f)
    (when close-subscription?
      ;; The owner acknowledgement is the transport barrier. A partial Remove
      ;; write retires the socket inside the client before this returns.
      (subscription-close! (relay-subscription record) 6.0))
    (let ((thread (relay-thread record)))
      (when thread (thread-join! thread 0.5 #f)))))

(define (relay-event subscription-id update)
  (let ((error (update-error update)) (logs (update-logs update)))
    (if error
        (error-event error subscription-id: subscription-id)
        (apply event
               (append
                (list "type" "subscription"
                      "subscriptionId" subscription-id
                      "value" (update-value update))
                (if (pair? logs) (list "logs" logs) '()))))))

(define (relay-loop state subscription-id record)
  (let loop ()
    (when (and (relay-active? record) (not (adapter-closed? state)))
      (let ((update (subscription-next (relay-subscription record) 0.25)))
        (when update
          ;; The owner stamps this update before queueing it. Rechecking both
          ;; generations under the publication lock closes replacement,
          ;; unsubscribe, and debug-disconnect races after dequeue.
          (call-with-publication-lock
           state
           (lambda ()
             (when (and (relay-active? record)
                        (= (relay-generation record)
                           (hash-table-ref/default
                            (adapter-generations state) subscription-id -1))
                        (>= (update-generation update)
                            (adapter-minimum-live-generation state)))
               (output-publish! (adapter-output state)
                                (relay-event subscription-id update)
                                droppable?: #t))))))
      (loop))))

(define (start-relay! state subscription-id record)
  (relay-thread-set!
   record
   (thread-start!
    (make-thread (lambda () (relay-loop state subscription-id record))
                 (string->symbol
                  (string-append "adapter-relay-" subscription-id))))))

(define (publish-response! state object)
  (call-with-publication-lock
   state (lambda () (output-publish! (adapter-output state) object))))

(define (valid-short-string value)
  (and (string? value) (<= 1 (string-length value) 128)))

(define (command-id command)
  (let ((id (json-get command "id" #f)))
    (and (valid-short-string id) id)))

(define (command-subscription-id command)
  (let ((id (json-get command "subscriptionId" #f)))
    (unless (valid-short-string id)
      (error 'adapter "subscriptionId must contain 1 to 128 characters"))
    id))

(define (run-call state command id operation)
  (let* ((client (ensure-adapter-client state))
         (path (json-get command "path" #f))
         (args (json-get command "args" (json-object)))
         (result
           (cond
             ((string=? operation "query") (client-query client path args))
             ((string=? operation "mutation") (client-mutation client path args))
             (else (client-action client path args)))))
    (publish-response!
     state
     (apply event
            (append (list "id" id "type" "result"
                          "value" (result-value result))
                    (if (pair? (result-logs result))
                        (list "logs" (result-logs result)) '()))))))

(define (handle-adapter-command! state command)
  (unless (json-object? command)
    (error 'adapter "adapter command must be an object"))
  (let ((id (command-id command))
        (operation (json-get command "op" #f)))
    (unless id (error 'adapter "adapter command requires a non-empty id"))
    (unless (string? operation) (error 'adapter "adapter command requires op"))
    (unless (or (adapter-hello? state) (string=? operation "hello"))
      (error 'adapter "hello must be the first adapter command"))
    (handle-exceptions condition
      (publish-response! state (error-event condition id: id))
      (cond
        ((string=? operation "hello")
         (when (adapter-hello? state)
           (error 'adapter "hello may only be sent once"))
         (unless (equal? (json-get command "protocolVersion" -1) 1)
           (error 'adapter "unsupported adapter protocol version"))
         (adapter-hello-set! state #t)
         (publish-response!
          state
          (event "protocolVersion" 1 "id" id "type" "ready"
                 "language" "scheme"
                 "implementation" "native-chicken-scheme-5.3.0"
                 "runtime" "CHICKEN 5.3.0")))
        ((member operation '("query" "mutation" "action") string=?)
         (run-call state command id operation))
        ((string=? operation "setAuth")
         (let ((token (json-get command "token" "")))
           (unless (string? token) (error 'adapter "token must be a string"))
           (client-set-auth! (ensure-adapter-client state) token)
           (publish-response! state (event "id" id "type" "ack"))))
        ((string=? operation "subscribe")
         (let* ((subscription-id (command-subscription-id command))
                (old (invalidate-relay! state subscription-id)))
           (stop-relay! old #t)
           (let* ((subscription
                    (client-subscribe
                     (ensure-adapter-client state)
                     (json-get command "path" #f)
                     (json-get command "args" (json-object))))
                  (record #f))
             ;; Registration and ACK are one publication transaction. Starting
             ;; the relay afterward prevents an already-hydrated value from
             ;; overtaking the replacement acknowledgement.
             (call-with-publication-lock
              state
              (lambda ()
                (let ((generation (next-generation! state subscription-id)))
                  (set! record
                        (make-relay-record subscription generation #t #f))
                  (hash-table-set! (adapter-relays state)
                                   subscription-id record)
                  (output-publish! (adapter-output state)
                                   (event "id" id "type" "ack")))))
             (start-relay! state subscription-id record))))
        ((string=? operation "unsubscribe")
         (let* ((subscription-id (command-subscription-id command))
                (record (invalidate-relay! state subscription-id)))
           (stop-relay! record #t)
           (publish-response! state (event "id" id "type" "ack"))))
        ((string=? operation "debugDisconnect")
         ;; Hold the publication lock across the owner barrier. A relay that
         ;; dequeued an old update can only resume after the new minimum
         ;; generation and ACK have been published, at which point it drops it.
         (call-with-publication-lock
          state
          (lambda ()
            (let ((generation
                    (client-debug-disconnect!
                     (ensure-adapter-client state) 6.0)))
              (adapter-minimum-live-generation-set! state generation)
              (output-publish! (adapter-output state)
                               (event "id" id "type" "ack"))))))
        ((string=? operation "close")
         (adapter-closed-set! state #t)
         (publish-response! state (event "id" id "type" "closed")))
        (else (error 'adapter "unknown adapter operation"))))))

(define (cleanup-adapter! state)
  (let ((records '()))
    (call-with-publication-lock
     state
     (lambda ()
       (adapter-closed-set! state #t)
       (hash-table-walk
        (adapter-relays state)
        (lambda (subscription-id record)
          (next-generation! state subscription-id)
          (relay-active-set! record #f)
          (set! records (cons record records))))
       (hash-table-clear! (adapter-relays state))))
    ;; Closing the one client retires the one Live owner and all subscriptions
    ;; in one bounded operation instead of serialising many Remove commands.
    (let ((client (adapter-client state)))
      (when client
        (handle-exceptions condition #f (client-close! client 2.0))))
    (for-each
     (lambda (record)
       (let ((thread (relay-thread record)))
         (when thread (thread-join! thread 0.5 #f))))
     records)))

(define (publish-protocol-error! state message)
  (handle-exceptions condition #f
    (publish-response! state (error-event (make-property-condition
                                           'exn 'message message)))))

(define (process-line! state line)
  (handle-exceptions condition
    (publish-response! state (error-event condition))
    (when (and (> (string-length line) 0)
               (char=? (string-ref line (- (string-length line) 1)) #\return))
      (set! line (substring line 0 (- (string-length line) 1))))
    (when (= (string-length line) 0)
      (error 'adapter "adapter command line must not be empty"))
    (unless (utf8-valid? line)
      (error 'adapter "adapter command is not valid UTF-8"))
    (handle-adapter-command! state (json-decode line))))

(define (adapter-loop input output tcp?)
  (let* ((sink (make-output-sink output tcp?))
         (state (make-adapter-state sink)))
    (handle-exceptions condition
      (begin
        (display "adapter failed: " (current-error-port))
        (display (condition-text condition) (current-error-port))
        (newline (current-error-port))
        (flush-output (current-error-port)))
      (let line-loop ((buffer (open-output-string)) (count 0) (discarding? #f))
        (unless (adapter-closed? state)
          (let ((character (read-char input)))
            (cond
              ((eof-object? character)
               (when (and (not discarding?) (> count 0))
                 (publish-protocol-error!
                  state "adapter command must end with a newline")))
              ((char=? character #\newline)
               (unless discarding?
                 (process-line! state (get-output-string buffer)))
               (line-loop (open-output-string) 0 #f))
              (discarding? (line-loop buffer count #t))
              ((>= count +adapter-line-limit+)
               (publish-protocol-error!
                state "adapter command exceeds 2 MiB")
               (line-loop (open-output-string) 0 #t))
              (else
               (write-char character buffer)
               (line-loop buffer (+ count 1) #f)))))))
    (cleanup-adapter! state)
    (close-output-sink! sink #t)))

(define (last-index-of text character)
  (let loop ((index (- (string-length text) 1)))
    (cond ((< index 0) #f)
          ((char=? (string-ref text index) character) index)
          (else (loop (- index 1))))))

(define (parse-listen-address text)
  (let ((colon (last-index-of text #\:)))
    (unless colon (error 'adapter "ADAPTER_LISTEN must be host:port"))
    (let ((host (substring text 0 colon))
          (port (string->number (substring text (+ colon 1)))))
      (unless (and (> (string-length host) 0) (integer? port)
                   (<= 1 port 65535))
        (error 'adapter "ADAPTER_LISTEN must contain a valid host and port"))
      (values host port))))

(define (adapter-flood-test-main)
  ;; Runtime audit hook: the real bounded writer is exercised while the Docker
  ;; controller deliberately never reads stdout.
  (let ((sink (make-output-sink (current-output-port) #f))
        (large (make-string 350000 #\x)))
    (let loop ((index 0))
      (when (< index 40)
        (output-publish!
         sink
         (event "type" "subscription" "subscriptionId" "memory"
                "value" (event "index" index "text" large))
         droppable?: #t)
        (loop (+ index 1))))
    (display "adapter flood queue ready\n" (current-error-port))
    (flush-output (current-error-port))
    (thread-sleep! 3.0)
    (close-output-sink! sink #f)))

(define (adapter-main)
  (handle-exceptions condition
    (begin
      (display "adapter failed: " (current-error-port))
      (display (condition-text condition) (current-error-port))
      (newline (current-error-port))
      (flush-output (current-error-port))
      (exit 1))
    (if (get-environment-variable "ADAPTER_FLOOD_TEST")
        (adapter-flood-test-main)
        (let ((listen (get-environment-variable "ADAPTER_LISTEN")))
          (if (or (not listen) (= (string-length listen) 0))
              (adapter-loop (current-input-port) (current-output-port) #f)
              (call-with-values
                (lambda () (parse-listen-address listen))
                (lambda (host port)
                  (parameterize ((tcp-read-timeout #f)
                                 (tcp-write-timeout 500))
                    (let ((listener (tcp-listen port 1 host)))
                      (display "adapter listening on " (current-error-port))
                      (display listen (current-error-port))
                      (newline (current-error-port))
                      (flush-output (current-error-port))
                      (call-with-values
                        (lambda () (tcp-accept listener))
                        (lambda (input output)
                          (tcp-close listener)
                          (adapter-loop input output #t)
                          ;; Do not flush a controller that has already gone
                          ;; away. The bounded writer has drained before this
                          ;; hard socket retirement.
                          (tcp-abandon-port output)))))))))))
  (exit 0))

(unless (get-environment-variable "ADAPTER_LIBRARY_ONLY")
  (adapter-main))
