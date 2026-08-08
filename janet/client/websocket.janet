# RFC 6455 client framing, written in Janet over the byte transport.
#
# The transport module knows nothing about WebSockets; everything below — the
# opening handshake, masking, fragmentation, control frames, close codes, and
# the text-payload UTF-8 rule — is implemented and validated here. That matters
# for this project's honesty claim: a client that hands framing to a library is
# not demonstrating that the language can speak the protocol.
#
# Two rules shape the whole design.
#
# 1. A socket is polled, never blocked on. `poll` returns nil when no complete
#    message has arrived yet, so one cooperative owner can interleave reading
#    the socket with serving its controller.
# 2. Once any byte of a message has been consumed, the parser keeps its state
#    across polls and measures an absolute deadline from that first byte. A peer
#    that dribbles one byte before every poll expires cannot hold the connection
#    open forever, and a timeout never resynchronizes at a guessed boundary — it
#    abandons the connection.

(import ./codec :as codec)
(import ./errors :as fail)
(import ./http :as http)
(import transport :as transport)

(def max-message-bytes
  "Largest complete message, across all fragments."
  (* 2 1024 1024))

(def max-frame-deadline-ms
  "How long one message may take once its first byte has been consumed."
  5000)

(def- handshake-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(def- opcode-continuation 0x0)
(def- opcode-text 0x1)
(def- opcode-binary 0x2)
(def- opcode-close 0x8)
(def- opcode-ping 0x9)
(def- opcode-pong 0xA)

(defn- ws-url-parts [url]
  # ws:// and wss:// share http's authority grammar, so reuse that parser
  # rather than writing a second, subtly different one.
  (cond
    (string/has-prefix? "wss://" url)
    (http/parse-url (string "https://" (string/slice url 6)))

    (string/has-prefix? "ws://" url)
    (http/parse-url (string "http://" (string/slice url 5)))

    (fail/protocol "Live URL must use ws or wss")))

(defn- accept-value [key]
  (codec/base64-encode (transport/sha1 (string key handshake-guid))))

(defn- new-socket [conn]
  @{:conn conn
    :inbuf (buffer/new 4096)
    :message (buffer/new 256)
    :message-opcode nil
    # Set when the first byte of an incomplete message is buffered, cleared
    # when the buffer drains. This is the absolute frame deadline.
    :partial-since nil
    :closed false
    :close-code nil
    :close-reason nil})

(defn begin
  "Send the opening upgrade request on an already-open connection.

  The handshake is split in two because the request has to be on the wire
  before the server can compute its answer. A test that owns both ends of a
  connection can therefore drive the real handshake without any concurrency."
  [conn url extra-headers deadline]
  (def parts (ws-url-parts url))
  (def key (codec/base64-encode (transport/random 16)))
  (def target (string (get parts :path) "/api/sync"))
  (def request
    (http/build-request
      "GET" target (get parts :authority)
      (array/concat
        @[["Upgrade" "websocket"]
          ["Connection" "Upgrade"]
          ["Sec-WebSocket-Key" key]
          ["Sec-WebSocket-Version" "13"]]
        extra-headers)
      nil))
  (http/write-all conn request deadline)
  {:conn conn :key key :deadline deadline})

(defn complete
  "Read and validate the server's upgrade response, returning a live socket."
  [pending]
  (def conn (get pending :conn))
  (def key (get pending :key))
  (def deadline (get pending :deadline))
  (def socket (new-socket conn))
  (def [status headers] (http/read-header-block conn (get socket :inbuf) deadline))
  (unless (= status 101) (fail/protocol (string "Live handshake returned HTTP " status)))
  (unless (= "websocket" (string/ascii-lower (or (get headers "upgrade") "")))
    (fail/protocol "Live handshake did not upgrade to websocket"))
  (unless (string/find "upgrade" (string/ascii-lower (or (get headers "connection") "")))
    (fail/protocol "Live handshake did not confirm the upgrade"))
  # The accept value proves the peer read this connection's own key, which is
  # what stops a cached or cross-protocol response from being taken for a
  # WebSocket server.
  (unless (= (accept-value key) (or (get headers "sec-websocket-accept") ""))
    (fail/protocol "Live handshake returned the wrong Sec-WebSocket-Accept"))
  # This client offers no extension or subprotocol, so the server may not
  # select one. Accepting a surprise extension would change the framing.
  (when (get headers "sec-websocket-extensions")
    (fail/protocol "Live handshake selected an unrequested extension"))
  (when (get headers "sec-websocket-protocol")
    (fail/protocol "Live handshake selected an unrequested subprotocol"))
  # Any bytes the server sent after the header block are already frames.
  (when (> (length (get socket :inbuf)) 0)
    (put socket :partial-since (http/now-ms)))
  socket)

(defn connect
  "Open a connection and perform the whole opening handshake.

  `extra-headers` is an array of [name value] pairs added to the upgrade
  request. The deadline covers connecting, sending, and reading the response."
  [url extra-headers timeout-ms]
  (def parts (ws-url-parts url))
  (def deadline (http/deadline-in timeout-ms))
  (def conn (transport/connect (get parts :host)
                               (get parts :port)
                               (get parts :tls)
                               (min 10000 timeout-ms)))
  (try
    (complete (begin conn url extra-headers deadline))
    ([problem]
     (transport/close conn)
     (fail/rethrow problem))))

(defn close-socket!
  "Release the underlying connection without any further protocol exchange."
  [socket]
  (put socket :closed true)
  (transport/close (get socket :conn))
  true)

#
# Writing
#

(defn- encode-frame [opcode payload]
  (def length (length payload))
  (def out (buffer/new (+ length 14)))
  # FIN is always set: this client never fragments what it sends.
  (buffer/push-byte out (+ 0x80 opcode))
  # A client frame is always masked, and the length must use the shortest form.
  (cond
    (< length 126)
    (buffer/push-byte out (+ 0x80 length))

    (< length 65536)
    (do (buffer/push-byte out (+ 0x80 126))
        (buffer/push-byte out (math/floor (/ length 256)))
        (buffer/push-byte out (mod length 256)))

    (do
      (buffer/push-byte out (+ 0x80 127))
      # 64-bit length, big endian. This client never sends above 2 MiB, so the
      # top five bytes are zero by construction.
      (var remaining length)
      (def digits @[])
      (repeat 8
        (array/push digits (mod remaining 256))
        (set remaining (math/floor (/ remaining 256))))
      (var index 7)
      (while (>= index 0)
        (buffer/push-byte out (get digits index))
        (set index (- index 1)))))
  (def mask (transport/random 4))
  (buffer/push-string out mask)
  (var index 0)
  (while (< index length)
    (buffer/push-byte out (bxor (get payload index) (get mask (mod index 4))))
    (set index (+ index 1)))
  out)

(defn send-text!
  "Send one complete text message, bounded by an absolute deadline."
  [socket text timeout-ms]
  (when (get socket :closed) (fail/transport "Live socket is closed"))
  (unless (codec/utf8-valid? text)
    (fail/protocol "cannot send a text frame that is not valid UTF-8"))
  (when (> (length text) max-message-bytes)
    (fail/protocol "Live message exceeds the 2 MiB limit"))
  (http/write-all (get socket :conn)
                  (encode-frame opcode-text text)
                  (http/deadline-in timeout-ms))
  true)

(defn send-close!
  "Send a close frame. Never waits for the peer's reply, so this is bounded
  even against a peer that is idle, flooding, or stalled mid-frame."
  [socket code timeout-ms]
  (if (get socket :closed)
    false
    (do
      (def payload (buffer/new 2))
      (buffer/push-byte payload (math/floor (/ code 256)))
      (buffer/push-byte payload (mod code 256))
      # A failure here is not interesting: the caller closes the socket next.
      (try
        (http/write-all (get socket :conn)
                        (encode-frame opcode-close payload)
                        (http/deadline-in timeout-ms))
        ([_] nil))
      true)))

(defn- send-pong! [socket payload]
  # A pong is a courtesy reply; a slow peer must not stall the owner, so this
  # uses a short deadline of its own and gives up rather than blocking.
  (try
    (http/write-all (get socket :conn)
                    (encode-frame opcode-pong payload)
                    (http/deadline-in 250))
    ([_] nil)))

#
# Reading
#

# Pull whatever bytes are available. Returns :data, :idle, or :eof.
(defn- read-more! [socket timeout-ms]
  (def buffer (get socket :inbuf))
  (def before (length buffer))
  (def got (transport/read (get socket :conn) buffer 65536 timeout-ms))
  (cond
    (nil? got) :eof
    (> (length buffer) before) :data
    :idle))

(defn- enforce-frame-deadline! [socket]
  (def since (get socket :partial-since))
  (when (and since (> (- (http/now-ms) since) max-frame-deadline-ms))
    # State is deliberately not reset. The caller retires this connection; a
    # parser that resumed here would be guessing at a frame boundary.
    (fail/transport "Live message exceeded its absolute frame deadline")))

# Decode the extended payload length. Returns [length extra-header-bytes], or
# nil when the buffer does not yet hold the whole length field.
(defn- payload-length [buffer offset short-length]
  (cond
    (< short-length 126) [short-length 0]

    (= short-length 126)
    (when (>= (length buffer) (+ offset 2))
      (def value (+ (* 256 (get buffer offset)) (get buffer (+ offset 1))))
      # The 16-bit form must not encode a length the 7-bit form could carry.
      (when (< value 126) (fail/protocol "Live frame uses a non-minimal length"))
      [value 2])

    (when (>= (length buffer) (+ offset 8))
      (var value 0)
      (var index 0)
      # The high bit of a 64-bit length must be zero.
      (when (>= (get buffer offset) 0x80)
        (fail/protocol "Live frame declares a negative 64-bit length"))
      (while (< index 8)
        (set value (+ (* value 256) (get buffer (+ offset index))))
        (set index (+ index 1)))
      (when (< value 65536) (fail/protocol "Live frame uses a non-minimal length"))
      [value 8])))

# Parse one complete frame out of the buffer, or return nil when more bytes are
# needed. Returns {:fin bool :opcode n :payload bytes}.
(defn- take-frame! [socket]
  (def buffer (get socket :inbuf))
  (when (>= (length buffer) 2)
    (def first-byte (get buffer 0))
    (def second-byte (get buffer 1))
    (def fin (>= first-byte 0x80))
    (def reserved (mod (math/floor (/ first-byte 16)) 8))
    (def opcode (mod first-byte 16))
    (def masked (>= second-byte 0x80))
    (def short-length (mod second-byte 128))
    # No extension was negotiated, so any reserved bit is a protocol violation.
    (when (not= reserved 0) (fail/protocol "Live frame set a reserved bit"))
    # RFC 6455 forbids a server from masking frames it sends to a client.
    (when masked (fail/protocol "Live server frame was masked"))
    (unless (or (= opcode opcode-continuation) (= opcode opcode-text)
                (= opcode opcode-binary) (= opcode opcode-close)
                (= opcode opcode-ping) (= opcode opcode-pong))
      (fail/protocol "Live frame used an unknown opcode"))
    (def control? (>= opcode 0x8))
    (when (and control? (not fin))
      (fail/protocol "Live control frame was fragmented"))
    (when (and control? (> short-length 125))
      (fail/protocol "Live control frame carried an oversized payload"))
    (def decoded (payload-length buffer 2 short-length))
    (when decoded
      (def [size extra] decoded)
      (when (> size max-message-bytes)
        (fail/protocol "Live frame exceeds the 2 MiB limit"))
      (def header (+ 2 extra))
      (when (>= (length buffer) (+ header size))
        (def payload (string (buffer/slice buffer header (+ header size))))
        (def rest (buffer/slice buffer (+ header size)))
        (buffer/clear buffer)
        (buffer/push-string buffer rest)
        {:fin fin :opcode opcode :payload payload}))))

(defn- validate-close-payload [payload]
  (def size (length payload))
  (cond
    (= size 0) [nil ""]
    (= size 1) (fail/protocol "Live close frame carried a one-byte payload")
    (do
      (def code (+ (* 256 (get payload 0)) (get payload 1)))
      (def reason (string (string/slice payload 2)))
      (unless (codec/utf8-valid? reason)
        (fail/protocol "Live close reason is not valid UTF-8"))
      # The reserved and unassigned ranges must not appear on the wire.
      (unless (or (and (>= code 1000) (<= code 1003))
                  (and (>= code 1007) (<= code 1011))
                  (and (>= code 3000) (<= code 4999)))
        (fail/protocol "Live close frame used a reserved status code"))
      [code reason])))

(defn poll!
  "Advance the reader by at most `timeout-ms` and return one event or nil.

  Events are [:text payload], [:close code reason], or nil when nothing is
  complete yet. Ping frames are answered and pong frames ignored internally."
  [socket timeout-ms]
  (when (get socket :closed) (fail/transport "Live socket is closed"))
  (enforce-frame-deadline! socket)
  (def status (read-more! socket timeout-ms))
  (when (and (> (length (get socket :inbuf)) 0) (nil? (get socket :partial-since)))
    (put socket :partial-since (http/now-ms)))

  (var event nil)
  (var again true)
  (while (and again (nil? event))
    (set again false)
    (def frame (take-frame! socket))
    (when frame
      (def opcode (get frame :opcode))
      (def payload (get frame :payload))
      (cond
        (= opcode opcode-ping)
        (do (send-pong! socket payload) (set again true))

        (= opcode opcode-pong)
        (set again true)

        (= opcode opcode-close)
        (do
          (def [code reason] (validate-close-payload payload))
          (put socket :close-code code)
          (put socket :close-reason reason)
          (set event [:close code reason]))

        (= opcode opcode-continuation)
        (do
          (unless (get socket :message-opcode)
            (fail/protocol "Live continuation frame had no message to continue"))
          (when (> (+ (length (get socket :message)) (length payload)) max-message-bytes)
            (fail/protocol "Live message exceeds the 2 MiB limit"))
          (buffer/push-string (get socket :message) payload)
          (if (get frame :fin)
            (set event :complete)
            (set again true)))

        (do
          (when (get socket :message-opcode)
            (fail/protocol "Live data frame interrupted an unfinished message"))
          (when (> (length payload) max-message-bytes)
            (fail/protocol "Live message exceeds the 2 MiB limit"))
          (put socket :message-opcode opcode)
          (buffer/clear (get socket :message))
          (buffer/push-string (get socket :message) payload)
          (if (get frame :fin)
            (set event :complete)
            (set again true))))))

  (when (= event :complete)
    (def opcode (get socket :message-opcode))
    (def payload (string (get socket :message)))
    (put socket :message-opcode nil)
    (buffer/clear (get socket :message))
    (if (= opcode opcode-text)
      (do
        # A text message must be valid UTF-8 as a whole, which is exactly why
        # this check waits for reassembly instead of running per fragment.
        (unless (codec/utf8-valid? payload)
          (fail/protocol "Live text message was not valid UTF-8"))
        (set event [:text payload]))
      (fail/protocol "Live server sent a binary message")))

  # The deadline clock only runs while bytes are held back. Draining the buffer
  # and having no partial message means the next byte starts a fresh deadline.
  (when (and (= 0 (length (get socket :inbuf)))
             (nil? (get socket :message-opcode)))
    (put socket :partial-since nil))
  # End of stream is reported only after everything already received has been
  # handed over, so a peer that sends a final message and closes immediately
  # does not lose that message. The connection stays at end of stream, so the
  # next poll reports it.
  (when (and (nil? event) (= status :eof))
    (fail/transport "Live peer closed the connection"))
  event)
