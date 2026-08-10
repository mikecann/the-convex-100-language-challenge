;; One writer owns adapter output. Count and byte limits bound retained events
;; even when the controller stops reading near-maximum protocol frames.
(local condition (require :cqueues.condition))
(local socket (require :socket))
(local json (require :json))

(local Output {})
(set Output.__index Output)
(set Output.MAX_PENDING 64)
(set Output.MAX_PENDING_BYTES (* 8 1024 1024))
(set Output.ENTRY_OVERHEAD 256)

(fn Output.new [stream options]
  (let [options (or options {})
        max-pending (or options.max-pending Output.MAX_PENDING)
        max-pending-bytes (or options.max-pending-bytes
                              Output.MAX_PENDING_BYTES)]
    (assert (and (= (type max-pending) :number) (>= max-pending 1)
                 (= (% max-pending 1) 0)))
    (assert (and (= (type max-pending-bytes) :number) (>= max-pending-bytes 1)
                 (= (% max-pending-bytes 1) 0)))
    (setmetatable {: stream
                   :queue []
                   :changed (condition.new)
                   :finished false
                   :failed nil
                   : max-pending
                   : max-pending-bytes
                   :pending-bytes 0
                   :tcp-offset 1
                   :now (or options.now socket.gettime)
                   :wait-writable (or options.wait-writable
                                      (fn [peer timeout]
                                        (let [(_ writable wait-error) (socket.select nil
                                                                                     [peer]
                                                                                     timeout)]
                                          (if (= (length writable) 0)
                                              (values nil
                                                      (or wait-error :timeout))
                                              true))))}
                  Output)))

(fn Output.overflow [self limit attempted-bytes]
  (set self.failed {:name :TransportError
                    :message (.. "adapter output queue exceeded its " limit)
                    :data {:maxPendingEvents self.max-pending
                           :maxPendingBytes self.max-pending-bytes
                           :pendingEvents (length self.queue)
                           :pendingBytes self.pending-bytes
                           :attemptedBytes attempted-bytes}})
  (set self.finished true)
  (if self.stream.close (pcall (fn [] (: self.stream :close))))
  (: self.changed :signal 1)
  (error self.failed 0))

(fn Output.enqueue [self event subscriptions subscription-id entry]
  (if (and entry (not (= (. subscriptions subscription-id) entry)))
      false
      (do
        (if (>= (length self.queue) self.max-pending)
            (: self :overflow "event limit"))
        (let [(encoded encode-error) (json.encode event)]
          (assert encoded encode-error)
          (let [accounted-bytes (+ (length encoded) 1 Output.ENTRY_OVERHEAD)]
            (if (> (+ self.pending-bytes accounted-bytes)
                   self.max-pending-bytes)
                (: self :overflow "byte limit" accounted-bytes))
            (table.insert self.queue
                          {:line (.. encoded "\n") :bytes accounted-bytes})
            (set self.pending-bytes (+ self.pending-bytes accounted-bytes))
            (: self.changed :signal 1)
            true)))))

(fn Output.remove-first [self]
  (let [queued (table.remove self.queue 1)]
    (set self.pending-bytes (- self.pending-bytes queued.bytes))
    queued))

(fn Output.finish [self]
  (set self.finished true)
  (: self.changed :signal 1))

(fn Output.run-stdio [self]
  (while (or (not self.finished) (> (length self.queue) 0))
    (if (= (length self.queue) 0)
        (: self.changed :wait)
        (let [queued (. self.queue 1)
              (ok write-error) (: self.stream :write queued.line)]
          (assert ok write-error)
          (if self.stream.flush (assert (: self.stream :flush)))
          (: self :remove-first)))))

(fn Output.flush-tcp [self timeout]
  (let [deadline (+ (self.now) (or timeout 5))]
    (var complete false)
    (var failure nil)
    (while (and (not complete) (not failure))
      (if (= (length self.queue) 0)
          (set complete true)
          (let [queued (. self.queue 1)
                (sent send-error last-byte) (: self.stream :send queued.line
                                               self.tcp-offset)]
            (if sent
                (do
                  (: self :remove-first)
                  (set self.tcp-offset 1))
                (not (= send-error :timeout))
                (set failure (.. "write adapter event: " (tostring send-error)))
                (do
                  (set self.tcp-offset
                       (+ (or last-byte (- self.tcp-offset 1)) 1))
                  (let [remaining (- deadline (self.now))]
                    (if (<= remaining 0)
                        (set failure "timed out writing adapter event")
                        (let [(writable wait-error) (self.wait-writable self.stream
                                                                        remaining)]
                          (if (not writable)
                              (set failure
                                   (.. "timed out writing adapter event: "
                                       (tostring wait-error))))))))))))
    (if failure (values nil failure) true)))

Output
