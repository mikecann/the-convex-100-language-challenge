# Bounded HTTP/1.1 over the byte transport.
#
# Janet has no HTTP client, so this file writes and reads the messages itself.
# It only implements what a Convex call needs: one request, one response, and
# an absolute deadline that no combination of slow bytes can extend. Persistent
# connections are deliberately absent — each call opens a connection, sends
# `Connection: close`, and reads until the server finishes.
#
# The header reader is shared with the WebSocket handshake, because RFC 6455
# opens with an ordinary HTTP request and the same limits should apply to both.

(import ./errors :as fail)
(import ./codec :as codec)
(import transport :as transport)

(def max-body-bytes
  "Largest response body this client will accept."
  (* 2 1024 1024))

(def max-header-bytes
  "Largest status line plus header block this client will accept."
  16384)

(def max-headers
  "Largest number of response header fields."
  64)

(def- read-chunk 16384)

(defn now-ms
  "Monotonic milliseconds, the only clock any deadline in this client uses."
  []
  (transport/monotonic-ms))

(defn deadline-in
  "An absolute deadline `milliseconds` from now."
  [milliseconds]
  (+ (now-ms) milliseconds))

(defn remaining-ms
  "Milliseconds left before `deadline`, never negative."
  [deadline]
  (def left (- deadline (now-ms)))
  (if (< left 0) 0 left))

(defn parse-url
  "Split a deployment URL into its parts.

  Rejects credentials, control characters, and anything that is not http(s),
  because those are the shapes that turn a URL into a request-smuggling bug."
  [url]
  (unless (and (string? url) (codec/utf8-valid? url))
    (fail/protocol "deployment URL must be UTF-8 text"))
  (when (or (string/find "\r" url) (string/find "\n" url) (string/find "\0" url)
            (string/find " " url))
    (fail/protocol "deployment URL contains a control character"))
  (def tls? (string/has-prefix? "https://" url))
  (def plain? (string/has-prefix? "http://" url))
  (unless (or tls? plain?) (fail/protocol "deployment URL must use http or https"))
  (def rest (string/slice url (if tls? 8 7)))
  (def slash (string/find "/" rest))
  (def authority (if slash (string/slice rest 0 slash) rest))
  (def path (if slash (string/slice rest slash) ""))
  (when (string/find "@" authority)
    (fail/protocol "deployment URL must not carry credentials"))
  (when (= 0 (length authority)) (fail/protocol "deployment URL has no host"))
  # An IPv6 literal is bracketed, so only look for a port after the bracket.
  (def close-bracket (string/find "]" authority))
  (def colon (if close-bracket
               (string/find ":" authority (+ 1 close-bracket))
               (string/find ":" authority)))
  (def host (if colon (string/slice authority 0 colon) authority))
  (def port-text (if colon (string/slice authority (+ 1 colon)) nil))
  (def port (cond
              (nil? port-text) (if tls? 443 80)
              (let [scanned (scan-number port-text)]
                (unless (and (number? scanned)
                             (= scanned (math/floor scanned))
                             (>= scanned 1)
                             (<= scanned 65535))
                  (fail/protocol "deployment URL has an invalid port"))
                scanned)))
  # Strip the brackets that only exist to delimit an IPv6 literal in a URL.
  (def bare-host (if (string/has-prefix? "[" host)
                   (string/slice host 1 (- (length host) 1))
                   host))
  (when (= 0 (length bare-host)) (fail/protocol "deployment URL has no host"))
  {:tls tls?
   :host bare-host
   :authority authority
   :port port
   # A trailing slash on the base URL would double up in the request target.
   :path (string/trimr path "/")})

(defn valid-header-value?
  "Header values must be single-line printable text.

  This is the check that stops an auth token or a room name from injecting a
  second header, so it runs before any byte reaches the socket."
  [value]
  (and (string? value)
       (codec/utf8-valid? value)
       (nil? (string/find "\r" value))
       (nil? (string/find "\n" value))
       (nil? (string/find "\0" value))))

(defn write-all
  "Write every byte of `data`, or raise once the absolute deadline passes."
  [conn data deadline]
  (var offset 0)
  (while (< offset (length data))
    (when (<= (remaining-ms deadline) 0)
      (fail/transport "timed out while sending a request"))
    (def written (transport/write conn data offset (min 1000 (remaining-ms deadline))))
    (set offset (+ offset written)))
  offset)

# Read one chunk into `buffer`. Returns :data, :idle, or :eof, and raises once
# the absolute deadline has passed so a dribbling peer cannot extend it.
(defn- fill [conn buffer deadline]
  (when (<= (remaining-ms deadline) 0) (fail/transport "timed out while reading"))
  (def got (transport/read conn buffer read-chunk (min 1000 (remaining-ms deadline))))
  (cond
    (nil? got) :eof
    (= got 0) :idle
    :data))

(defn- find-header-end [buffer]
  # Only a bare CRLFCRLF terminates a header block. Accepting LFLF here is how
  # a parser ends up disagreeing with the server about where the body starts.
  (string/find "\r\n\r\n" buffer))

(defn read-header-block
  "Read the status line and header block, leaving any extra bytes in `buffer`.

  Returns [status headers] where `headers` is a table of lowercased field names."
  [conn buffer deadline]
  (var end (find-header-end buffer))
  (while (nil? end)
    (when (> (length buffer) max-header-bytes)
      (fail/protocol "response headers exceed the 16 KiB limit"))
    (case (fill conn buffer deadline)
      :eof (fail/transport "connection closed before the response headers arrived")
      nil)
    (set end (find-header-end buffer)))
  (when (> (+ end 4) max-header-bytes)
    (fail/protocol "response headers exceed the 16 KiB limit"))
  (def block (string (buffer/slice buffer 0 end)))
  # Consume exactly the header block; whatever follows is body or frame bytes.
  (def leftover (buffer/slice buffer (+ end 4)))
  (buffer/clear buffer)
  (buffer/push-string buffer leftover)

  (def lines (string/split "\r\n" block))
  (def status-line (get lines 0))
  (unless (and (string? status-line)
               (>= (length status-line) 12)
               (string/has-prefix? "HTTP/1." status-line)
               (= 0x20 (get status-line 8)))
    (fail/protocol "response is not HTTP/1.x"))
  (def status-text (string/slice status-line 9 12))
  (def status (scan-number status-text))
  (unless (and (number? status) (>= status 100) (<= status 599)
               (= status (math/floor status)))
    (fail/protocol "response has no HTTP status code"))

  (def headers @{})
  (var index 1)
  (while (< index (length lines))
    (def line (get lines index))
    (when (> index max-headers) (fail/protocol "response has too many headers"))
    # Obsolete line folding is ambiguous, so it is refused rather than joined.
    (when (or (string/has-prefix? " " line) (string/has-prefix? "\t" line))
      (fail/protocol "response uses obsolete header line folding"))
    (def colon (string/find ":" line))
    (unless colon (fail/protocol "response header has no colon"))
    (def name (string/ascii-lower (string/slice line 0 colon)))
    (def value (string/trim (string/slice line (+ 1 colon))))
    (when (= 0 (length name)) (fail/protocol "response header has an empty name"))
    (if (has-key? headers name)
      # Repeating a framing header is how responses get smuggled, so only
      # genuinely list-valued fields may repeat.
      (if (or (= name "content-length") (= name "transfer-encoding"))
        (fail/protocol "response repeats a framing header")
        (put headers name (string (get headers name) ", " value)))
      (put headers name value))
    (set index (+ index 1)))
  [status headers])

(defn- read-fixed-body [conn buffer expected deadline]
  (when (> expected max-body-bytes)
    (fail/protocol "response body exceeds the 2 MiB limit"))
  (while (< (length buffer) expected)
    (case (fill conn buffer deadline)
      :eof (fail/transport "connection closed before the response body arrived")
      nil))
  (string (buffer/slice buffer 0 expected)))

(defn- read-chunked-body [conn buffer deadline]
  (def body (buffer/new 256))
  (var done false)
  (while (not done)
    (var newline (string/find "\r\n" buffer))
    (while (nil? newline)
      (when (> (length buffer) max-header-bytes)
        (fail/protocol "chunk header exceeds the 16 KiB limit"))
      (case (fill conn buffer deadline)
        :eof (fail/transport "connection closed inside a chunked body")
        nil)
      (set newline (string/find "\r\n" buffer)))
    (def header (string (buffer/slice buffer 0 newline)))
    # A chunk extension after the size is legal and carries no meaning here.
    (def semicolon (string/find ";" header))
    (def size-text (string/ascii-lower
                     (string/trim (if semicolon (string/slice header 0 semicolon) header))))
    (def size (scan-number (string "16r" size-text)))
    (unless (and (number? size) (>= size 0) (= size (math/floor size))
                 (<= size max-body-bytes))
      (fail/protocol "chunked body has an invalid chunk size"))
    (def consumed (+ newline 2))
    (def leftover (buffer/slice buffer consumed))
    (buffer/clear buffer)
    (buffer/push-string buffer leftover)
    (if (= size 0)
      # The terminating chunk ends the body. Any trailer section after it is
      # discarded along with the connection, which this client always closes.
      (set done true)
      (do
        (when (> (+ (length body) size) max-body-bytes)
          (fail/protocol "response body exceeds the 2 MiB limit"))
        (while (< (length buffer) (+ size 2))
          (case (fill conn buffer deadline)
            :eof (fail/transport "connection closed inside a chunk")
            nil))
        (buffer/push-string body (buffer/slice buffer 0 size))
        (unless (= "\r\n" (string (buffer/slice buffer size (+ size 2))))
          (fail/protocol "chunk is not terminated by CRLF"))
        (def rest (buffer/slice buffer (+ size 2)))
        (buffer/clear buffer)
        (buffer/push-string buffer rest))))
  (string body))

(defn- read-until-eof [conn buffer deadline]
  (var done false)
  (while (not done)
    (when (> (length buffer) max-body-bytes)
      (fail/protocol "response body exceeds the 2 MiB limit"))
    (case (fill conn buffer deadline)
      :eof (set done true)
      nil))
  (when (> (length buffer) max-body-bytes)
    (fail/protocol "response body exceeds the 2 MiB limit"))
  (string buffer))

(defn read-response
  "Read one complete HTTP response, honouring the framing the server chose."
  [conn buffer deadline]
  (def [status headers] (read-header-block conn buffer deadline))
  (def encoding (string/ascii-lower (or (get headers "transfer-encoding") "")))
  (def length-text (get headers "content-length"))
  (cond
    (= encoding "chunked")
    {:status status :headers headers :body (read-chunked-body conn buffer deadline)}

    (not= encoding "")
    (fail/protocol "response uses an unsupported transfer encoding")

    length-text
    (do
      (def expected (scan-number length-text))
      (unless (and (number? expected) (>= expected 0) (= expected (math/floor expected)))
        (fail/protocol "response has an invalid Content-Length"))
      {:status status
       :headers headers
       :body (read-fixed-body conn buffer expected deadline)})

    {:status status :headers headers :body (read-until-eof conn buffer deadline)}))

(defn build-request
  "Serialize a request. `headers` is an array of [name value] pairs."
  [method target host-header headers body]
  (each pair headers
    (unless (and (valid-header-value? (get pair 0)) (valid-header-value? (get pair 1)))
      (fail/protocol "request header contains a control character")))
  (def out (buffer/new 256))
  (buffer/push-string out method)
  (buffer/push-string out " ")
  (buffer/push-string out target)
  (buffer/push-string out " HTTP/1.1\r\nHost: ")
  (buffer/push-string out host-header)
  (buffer/push-string out "\r\n")
  (each pair headers
    (buffer/push-string out (get pair 0))
    (buffer/push-string out ": ")
    (buffer/push-string out (get pair 1))
    (buffer/push-string out "\r\n"))
  (when body
    (buffer/push-string out "Content-Length: ")
    (buffer/push-string out (string (length body)))
    (buffer/push-string out "\r\n"))
  (buffer/push-string out "\r\n")
  (when body (buffer/push-string out body))
  (string out))

(defn exchange
  "Send one request on an open connection and read one response back.

  Kept separate from `post-json` so a test can drive the real writer and reader
  over a connection it controls, rather than only through a live deployment."
  [conn url-parts path headers body deadline]
  (def target (string (get url-parts :path) path))
  (def request (build-request "POST" target (get url-parts :authority)
                              (array/concat @[["Connection" "close"]] headers)
                              body))
  (write-all conn request deadline)
  (def buffer (buffer/new 1024))
  (def response (read-response conn buffer deadline))
  {:status (get response :status) :body (get response :body)})

(defn post-json
  "Connect, send one JSON request body, and read one JSON-shaped response.

  Returns {:status n :body text}. The caller decides what the status and body
  mean together, because Convex reports function failures with both."
  [url-parts path headers body timeout-ms]
  (def deadline (deadline-in timeout-ms))
  (def conn (transport/connect (get url-parts :host)
                               (get url-parts :port)
                               (get url-parts :tls)
                               (min 10000 timeout-ms)))
  (defer (transport/close conn)
    (exchange conn url-parts path headers body deadline)))
