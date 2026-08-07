# Deterministic loopback peers for the language-local tests.
#
# These tests do not mock the client. They open a real socket pair inside the
# process, speak real HTTP and real RFC 6455 at the far end of it, and let the
# client's own reader and writer do all the work. That is what makes a failure
# here mean something: the bytes are the bytes the client would put on a wire.
#
# Everything is synchronous. A request always fits inside the kernel's socket
# buffer, so one side can write and the other side can then read without any
# threads, fibers, or scheduling. The client's `step!` is non-blocking by
# design, so a test can interleave client and server progress by hand.

(import ../codec :as codec)
(import ../errors :as fail)
(import ../http :as http)
(import transport :as transport)

(def- handshake-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(defn pair
  "Open a connected pair of loopback connections inside this process."
  []
  (def listener (transport/listen "127.0.0.1" 0))
  (def port (transport/listen-port listener))
  # The kernel completes a loopback connection from the listen backlog, so the
  # client end is usable before anything calls accept.
  (def client (transport/connect "127.0.0.1" port false 2000))
  (def server (transport/accept listener 2000))
  (transport/close listener)
  (unless server (fail/transport "fixture could not accept its own connection"))
  [client server])

(defn write-all!
  "Write every byte to a fixture connection with a short, bounded deadline."
  [conn data]
  (http/write-all conn data (http/deadline-in 2000)))

(defn read-available!
  "Append whatever bytes are ready. Returns :data, :idle, or :eof."
  [conn buffer &opt timeout-ms]
  (def before (length buffer))
  (def got (transport/read conn buffer 16384 (or timeout-ms 5)))
  (cond
    (nil? got) :eof
    (> (length buffer) before) :data
    :idle))

#
# HTTP responses
#

(defn http-response
  "Build a raw HTTP response with a Content-Length body."
  [status body &opt extra]
  (string "HTTP/1.1 " status " Test\r\n"
          "Content-Type: application/json\r\n"
          (or extra "")
          "Content-Length: " (length body) "\r\n"
          "Connection: close\r\n\r\n"
          body))

(defn chunked-response
  "Build a raw chunked HTTP response from a list of chunk strings."
  [status chunks]
  (def out (buffer/new 256))
  (buffer/push-string out (string "HTTP/1.1 " status " Test\r\n"
                                  "Content-Type: application/json\r\n"
                                  "Transfer-Encoding: chunked\r\n"
                                  "Connection: close\r\n\r\n"))
  (each chunk chunks
    (buffer/push-string out (string/format "%x\r\n" (length chunk)))
    (buffer/push-string out chunk)
    (buffer/push-string out "\r\n"))
  (buffer/push-string out "0\r\n\r\n")
  (string out))

#
# A server-side RFC 6455 peer
#

(defn ws-peer
  "Wrap a fixture connection as a server-side WebSocket peer."
  [conn]
  @{:conn conn
    :inbuf (buffer/new 4096)
    :messages @[]
    :message (buffer/new 256)
    :pings 0
    :pongs 0
    :closed false})

(defn ws-handshake!
  "Read the client's upgrade request and answer it correctly.

  Also returns the parsed request headers so a test can assert on what the
  client actually sent, such as its Convex-Client version."
  [peer]
  (def conn (get peer :conn))
  (def buffer (get peer :inbuf))
  (def deadline (http/deadline-in 2000))
  (var end (string/find "\r\n\r\n" buffer))
  (while (nil? end)
    (when (= :eof (read-available! conn buffer 50))
      (fail/transport "fixture peer saw no upgrade request"))
    (set end (string/find "\r\n\r\n" buffer)))
  (def block (string (buffer/slice buffer 0 end)))
  (def rest (buffer/slice buffer (+ end 4)))
  (buffer/clear buffer)
  (buffer/push-string buffer rest)

  (def headers @{})
  (def lines (string/split "\r\n" block))
  (var index 1)
  (while (< index (length lines))
    (def line (get lines index))
    (def colon (string/find ":" line))
    (when colon
      (put headers
           (string/ascii-lower (string/slice line 0 colon))
           (string/trim (string/slice line (+ 1 colon)))))
    (set index (+ index 1)))
  (def key (get headers "sec-websocket-key"))
  (unless key (fail/protocol "fixture peer saw no Sec-WebSocket-Key"))
  (write-all! conn
              (string "HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\n"
                      "Connection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: "
                      (codec/base64-encode (transport/sha1 (string key handshake-guid)))
                      "\r\n\r\n"))
  {:headers headers :request-line (get lines 0)})

(defn ws-reject!
  "Answer an upgrade request with a plain HTTP response instead of an upgrade."
  [peer status body]
  (def conn (get peer :conn))
  (def buffer (get peer :inbuf))
  (var end (string/find "\r\n\r\n" buffer))
  (while (nil? end)
    (when (= :eof (read-available! conn buffer 50))
      (fail/transport "fixture peer saw no upgrade request"))
    (set end (string/find "\r\n\r\n" buffer)))
  (write-all! conn (http-response status body)))

(defn ws-bad-accept!
  "Answer an upgrade with a syntactically valid but wrong accept value."
  [peer]
  (def conn (get peer :conn))
  (def buffer (get peer :inbuf))
  (var end (string/find "\r\n\r\n" buffer))
  (while (nil? end)
    (when (= :eof (read-available! conn buffer 50))
      (fail/transport "fixture peer saw no upgrade request"))
    (set end (string/find "\r\n\r\n" buffer)))
  (write-all! conn
              (string "HTTP/1.1 101 Switching Protocols\r\n"
                      "Upgrade: websocket\r\n"
                      "Connection: Upgrade\r\n"
                      "Sec-WebSocket-Accept: "
                      (codec/base64-encode (transport/sha1 "not-the-client-key"))
                      "\r\n\r\n")))

(defn server-frame
  "Encode one unmasked server frame, which is what RFC 6455 requires."
  [opcode payload &opt fin]
  (def final (if (nil? fin) true fin))
  (def out (buffer/new (+ (length payload) 10)))
  (buffer/push-byte out (+ (if final 0x80 0) opcode))
  (def size (length payload))
  (cond
    (< size 126) (buffer/push-byte out size)
    (< size 65536)
    (do (buffer/push-byte out 126)
        (buffer/push-byte out (math/floor (/ size 256)))
        (buffer/push-byte out (mod size 256)))
    (do
      (buffer/push-byte out 127)
      (var remaining size)
      (def digits @[])
      (repeat 8
        (array/push digits (mod remaining 256))
        (set remaining (math/floor (/ remaining 256))))
      (var index 7)
      (while (>= index 0)
        (buffer/push-byte out (get digits index))
        (set index (- index 1)))))
  (buffer/push-string out payload)
  (string out))

(defn ws-send-text! [peer text] (write-all! (get peer :conn) (server-frame 0x1 text)))
(defn ws-send-raw! [peer bytes] (write-all! (get peer :conn) bytes))
(defn ws-send-ping! [peer payload] (write-all! (get peer :conn) (server-frame 0x9 payload)))

(defn ws-send-close!
  [peer code]
  (def payload (buffer/new 2))
  (buffer/push-byte payload (math/floor (/ code 256)))
  (buffer/push-byte payload (mod code 256))
  (write-all! (get peer :conn) (server-frame 0x8 payload)))

(defn- take-client-frame! [peer]
  (def buffer (get peer :inbuf))
  (when (>= (length buffer) 2)
    (def first-byte (get buffer 0))
    (def second-byte (get buffer 1))
    (def fin (>= first-byte 0x80))
    (def opcode (mod first-byte 16))
    (def masked (>= second-byte 0x80))
    (def short-length (mod second-byte 128))
    # RFC 6455 requires every client frame to be masked. Asserting it here is
    # how the fixture proves the client's own writer got that right.
    (unless masked (fail/protocol "fixture peer received an unmasked client frame"))
    (def sized
      (cond
        (< short-length 126) [short-length 2]
        (= short-length 126)
        (when (>= (length buffer) 4)
          [(+ (* 256 (get buffer 2)) (get buffer 3)) 4])
        (when (>= (length buffer) 10)
          (do
            (var value 0)
            (var index 2)
            (while (< index 10)
              (set value (+ (* value 256) (get buffer index)))
              (set index (+ index 1)))
            [value 10]))))
    (when sized
      (def [size header] sized)
      (when (>= (length buffer) (+ header 4 size))
        (def mask (buffer/slice buffer header (+ header 4)))
        (def body (buffer/new size))
        (var index 0)
        (while (< index size)
          (buffer/push-byte body (bxor (get buffer (+ header 4 index))
                                       (get mask (mod index 4))))
          (set index (+ index 1)))
        (def rest (buffer/slice buffer (+ header 4 size)))
        (buffer/clear buffer)
        (buffer/push-string buffer rest)
        {:fin fin :opcode opcode :payload (string body)}))))

(defn ws-step!
  "Read whatever the client sent and collect complete text messages."
  [peer &opt timeout-ms]
  (def status (read-available! (get peer :conn) (get peer :inbuf) (or timeout-ms 5)))
  (when (= status :eof) (put peer :closed true))
  (var frame (take-client-frame! peer))
  (while frame
    (def opcode (get frame :opcode))
    (cond
      (= opcode 0x9) (put peer :pings (+ 1 (get peer :pings)))
      (= opcode 0xA) (put peer :pongs (+ 1 (get peer :pongs)))
      (= opcode 0x8) (put peer :closed true)
      (do
        (buffer/push-string (get peer :message) (get frame :payload))
        (when (get frame :fin)
          (array/push (get peer :messages) (string (get peer :message)))
          (buffer/clear (get peer :message)))))
    (set frame (take-client-frame! peer)))
  peer)

(defn ws-next-message!
  "Pop the oldest complete client message, or nil."
  [peer]
  (when (> (length (get peer :messages)) 0)
    (def message (get (get peer :messages) 0))
    (array/remove (get peer :messages) 0)
    message))

(defn ws-close! [peer]
  (put peer :closed true)
  (transport/close (get peer :conn)))
