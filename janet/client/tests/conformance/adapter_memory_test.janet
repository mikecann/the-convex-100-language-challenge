# The stopped-reader memory proof.
#
# An event-count limit is not a memory limit. Sixteen retained events is a
# small number until one of them is nearly the size of a whole WebSocket frame,
# at which point a "bounded" adapter is holding tens of megabytes. This test
# drives the real adapter, over real sockets, with values close to the frame
# limit, while the controller never reads a single byte — and then measures
# what the process is actually holding.
#
# The shared policy runs these images under a 128 MiB memory limit.

(os/setenv "ADAPTER_LIBRARY_ONLY" "1")
(os/setenv "CONVEX_URL" "http://fixture.test:1234")

(import ../check :as check)
(import ../fixture :as fixture)
(import ../../codec :as codec)
(import ./adapter :as adapter)
(import ../../convex :as convex)
(import ../../http :as http)
(import ../../json :as json)
(import transport :as transport)
(import ../../websocket :as ws)

# Comfortably below the shared 128 MiB container limit, and well above what
# this workload should ever need.
(def resident-limit (* 96 1024 1024))

# Close to the 2 MiB frame ceiling without exceeding it once the surrounding
# Transition envelope is added.
(def value-bytes 1900000)

(def peer-state @{:peer nil})

(defn- attach-peer! [client]
  (def [client-conn server-conn] (fixture/pair))
  (def peer (fixture/ws-peer server-conn))
  (def pending (ws/begin client-conn (convex/live-url client) @[] (http/deadline-in 2000)))
  (fixture/ws-handshake! peer)
  (def socket (ws/complete pending))
  (put peer-state :peer peer)
  socket)

(def [control controller] (fixture/pair))
(def state (adapter/adapter-new control))

(defn- await-message! [timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (var raw nil)
  (while (and (nil? raw) (> (http/remaining-ms deadline) 0))
    (adapter/adapter-step! state)
    (when (get peer-state :peer)
      (fixture/ws-step! (get peer-state :peer) 2)
      (set raw (fixture/ws-next-message! (get peer-state :peer)))))
  (when raw (json/decode raw)))

(def cursor @{:tick 0 :remote {"querySet" 0 "identity" 0 "ts" "AAAAAAAAAAA="}})

(defn- timestamp-for [n]
  (def raw (buffer/new 8))
  (var value n)
  (repeat 8
    (buffer/push-byte raw (mod value 256))
    (set value (math/floor (/ value 256))))
  (codec/base64-encode raw))

(var peak-resident 0)

(defn- note-resident! []
  (def resident (transport/resident-bytes))
  (when (and resident (> resident peak-resident)) (set peak-resident resident)))

(defn- deliver-large! [query-id index filler]
  "Write one near-maximum Transition, stepping the real adapter as it goes."
  (put cursor :tick (+ 1 (get cursor :tick)))
  (def finish {"querySet" 1 "identity" 0 "ts" (timestamp-for (get cursor :tick))})
  (def frame
    (fixture/server-frame
      0x1
      (json/encode {"type" "Transition"
                    "startVersion" (get cursor :remote)
                    "endVersion" finish
                    "modifications" [{"type" "QueryUpdated"
                                      "queryId" query-id
                                      "value" {"count" index "filler" filler}}]})))
  (put cursor :remote finish)
  (var offset 0)
  (def deadline (http/deadline-in 20000))
  (while (and (< offset (length frame)) (> (http/remaining-ms deadline) 0))
    (set offset (+ offset (transport/write (get (get peer-state :peer) :conn)
                                           frame offset 5)))
    (adapter/adapter-step! state)
    (note-resident!))
  # Give the adapter room to finish decoding and relaying what was written.
  (def settle (http/deadline-in 500))
  (while (> (http/remaining-ms settle) 0)
    (adapter/adapter-step! state)
    (note-resident!)))

(with-dyns [convex/live-socket-dynamic attach-peer!]
  (adapter/process-line!
    state
    (json/encode @{"id" "s1" "op" "subscribe" "subscriptionId" "big"
                   "path" "demo:state" "args" @{"room" "memory"}}))
  (check/check= (get (await-message! 5000) "type") "Connect"
                "the memory proof opened a Live session")
  (def add (await-message! 5000))
  (def query-id (get-in add ["modifications" 0 "queryId"]))
  (check/check (number? query-id) "the subscription was added")

  (def filler (string/repeat "x" value-bytes))
  (var index 0)
  (while (< index 4)
    (deliver-large! query-id index filler)
    (set index (+ index 1)))

  (check/check (<= (get state :out-bytes) adapter/max-output-bytes)
               (string "the adapter output budget held at " (get state :out-bytes)
                       " of " adapter/max-output-bytes " bytes"))
  (check/check (<= (length (get state :outbuf)) adapter/max-output-events)
               "the adapter event count budget held")
  (check/check (<= (get (convex/live-status (get state :client)) :queued-bytes)
                   convex/max-update-bytes)
               (string "the client delivery budget held at "
                       (get (convex/live-status (get state :client)) :queued-bytes)
                       " bytes"))
  (check/check (> (get state :dropped) 0)
               "values were coalesced under pressure rather than accumulating")
  (check/check (get state :running)
               "coalescing a subscription value did not fail the connection")
  (check/check (nil? (get state :failure))
               "no mandatory event was lost while the controller was stopped")

  (note-resident!)
  (check/check (> peak-resident 0)
               "the resident set size was actually measured")
  (check/check (< peak-resident resident-limit)
               (string "peak resident set stayed at "
                       (math/floor (/ peak-resident 1048576)) " MiB, under "
                       (math/floor (/ resident-limit 1048576)) " MiB"))
  (convex/close! (get state :client)))

(transport/close controller)
(transport/close control)
(check/report "janet adapter memory")
