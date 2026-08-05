(ns raw-websocket-fixture
  "Small deterministic RFC 6455 fixture. It validates masked client frames and can
  split UTF-8 text around control frames without hiding behavior in a library."
  (:require [clojure.data.json :as json]
            [clojure.string :as string])
  (:import [java.io ByteArrayOutputStream DataInputStream InputStream OutputStream]
           [java.net InetAddress ServerSocket Socket SocketException]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]
           [java.time Duration]
           [java.util Base64]
           [java.util.concurrent Executors TimeUnit]
           [java.util.concurrent.atomic AtomicBoolean AtomicInteger]))

(def ^:private websocket-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(declare send-frame!)

(defn- read-http-headers [^InputStream input]
  (let [buffer (ByteArrayOutputStream.)]
    (loop [tail ""]
      (let [byte (.read input)]
        (when (= -1 byte) (throw (java.io.EOFException. "EOF during WebSocket handshake")))
        (.write buffer byte)
        (let [next-tail (str tail (char byte))
              next-tail (subs next-tail (max 0 (- (count next-tail) 4)))]
          (if (= "\r\n\r\n" next-tail)
            (.toString buffer StandardCharsets/US_ASCII)
            (recur next-tail)))))))

(defn- header [headers name]
  (some (fn [line]
          (let [[key value] (string/split line #":" 2)]
            (when (= (string/lower-case key) (string/lower-case name))
              (string/trim value))))
        (string/split-lines headers)))

(defn- accept-value [key]
  (.encodeToString (Base64/getEncoder)
                   (.digest (MessageDigest/getInstance "SHA-1")
                            (.getBytes (str key websocket-guid) StandardCharsets/US_ASCII))))

(defn- handshake! [^Socket socket]
  (let [headers (read-http-headers (.getInputStream socket))
        key (header headers "Sec-WebSocket-Key")]
    (when-not key (throw (AssertionError. "client omitted Sec-WebSocket-Key")))
    (let [response (str "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Accept: " (accept-value key) "\r\n\r\n")]
      (.write (.getOutputStream socket) (.getBytes response StandardCharsets/US_ASCII))
      (.flush (.getOutputStream socket)))))

(defn- read-byte! [^DataInputStream input]
  (let [value (.read input)]
    (when (= -1 value) (throw (java.io.EOFException. "WebSocket peer closed")))
    value))

(defn read-frame! [connection]
  (let [input ^DataInputStream (:input connection)
        first (read-byte! input)
        second (read-byte! input)
        opcode (bit-and first 0x0f)
        final? (pos? (bit-and first 0x80))
        masked? (pos? (bit-and second 0x80))
        short-length (bit-and second 0x7f)
        length (case short-length
                 126 (.readUnsignedShort input)
                 127 (.readLong input)
                 short-length)]
    (when-not masked? (throw (AssertionError. "client WebSocket frame was not masked")))
    (when (> length (* 2 1024 1024)) (throw (AssertionError. "fixture frame too large")))
    (let [mask (byte-array 4)
          payload (byte-array (int length))]
      (.readFully input mask)
      (.readFully input payload)
      (dotimes [index (alength payload)]
        (aset-byte payload index
                   (byte (bit-xor (bit-and 0xff (aget payload index))
                                  (bit-and 0xff (aget mask (mod index 4)))))))
      {:opcode opcode :final? final? :payload payload})))

(defn read-message! [connection]
  (let [parts (ByteArrayOutputStream.)]
    (loop [first? true]
      (let [{:keys [opcode final? payload]} (read-frame! connection)]
        (cond
          (= opcode 8) (throw (java.io.EOFException. "client closed WebSocket"))
          (= opcode 9) (do (send-frame! connection 10 true payload) (recur first?))
          (= opcode 10) (recur first?)
          (and first? (not= opcode 1)) (throw (AssertionError. (str "expected text frame, got opcode " opcode)))
          (and (not first?) (not= opcode 0)) (throw (AssertionError. "expected continuation frame"))
          :else (do (.write parts payload)
                    (if final?
                      (json/read-str (.toString parts StandardCharsets/UTF_8))
                      (recur false))))))))

(defn send-frame! [connection opcode final? payload]
  (let [bytes (if (string? payload) (.getBytes ^String payload StandardCharsets/UTF_8) payload)
        output ^OutputStream (:output connection)
        first (bit-or opcode (if final? 0x80 0))]
    (.write output first)
    (cond
      (< (alength ^bytes bytes) 126) (.write output (alength ^bytes bytes))
      (<= (alength ^bytes bytes) 65535) (do (.write output 126)
                                            (.write output (bit-and 0xff (bit-shift-right (alength ^bytes bytes) 8)))
                                            (.write output (bit-and 0xff (alength ^bytes bytes))))
      :else (do
              (.write output 127)
              (doseq [shift (range 56 -1 -8)]
                (.write output (bit-and 0xff (bit-shift-right (long (alength ^bytes bytes)) shift))))))
    (.write output ^bytes bytes)
    (.flush output)))

(defn send-text! [connection value]
  (send-frame! connection 1 true (if (string? value) value (json/write-str value))))

(defn send-fragmented-text! [connection value split-at]
  (let [bytes (.getBytes ^String (if (string? value) value (json/write-str value)) StandardCharsets/UTF_8)
        first (java.util.Arrays/copyOfRange bytes 0 split-at)
        second (java.util.Arrays/copyOfRange bytes split-at (alength bytes))]
    (send-frame! connection 1 false first)
    ;; A control frame between fragments proves parser state survives it.
    (send-frame! connection 9 true (.getBytes "ping" StandardCharsets/UTF_8))
    (send-frame! connection 0 true second)))

(defn close-transport! [connection] (.close ^Socket (:socket connection)))

(defrecord Fixture [^ServerSocket server executor stopped connections failure handler]
  java.lang.AutoCloseable
  (close [_]
    (.set ^AtomicBoolean stopped true)
    (.close server)
    (.shutdownNow executor)
    (.awaitTermination executor 2 TimeUnit/SECONDS)
    (when-let [error @failure] (throw error))))

(defn fixture [handler]
  (let [server (ServerSocket. 0 20 (InetAddress/getLoopbackAddress))
        executor (Executors/newCachedThreadPool)
        stopped (AtomicBoolean. false)
        connections (AtomicInteger. 0)
        failure (atom nil)
        result (->Fixture server executor stopped connections failure handler)]
    (.execute executor
              (reify Runnable
                (run [_]
                  (while (not (.get stopped))
                    (try
                      (let [socket (.accept server)
                            index (.getAndIncrement connections)]
                        (.setSoTimeout socket 10000)
                        (.execute executor
                                  (reify Runnable
                                    (run [_]
                                      (with-open [owned socket]
                                        (try
                                          (handshake! socket)
                                          (handler {:socket socket
                                                    :input (DataInputStream. (.getInputStream socket))
                                                    :output (.getOutputStream socket)} index)
                                          (catch SocketException _ nil)
                                          (catch java.io.EOFException _ nil)
                                          (catch InterruptedException _
                                            (.interrupt (Thread/currentThread)))
                                          (catch Throwable error
                                            (compare-and-set! failure nil error))))))))
                      (catch SocketException _ nil))))))
    result))

(defn url [fixture] (str "http://127.0.0.1:" (.getLocalPort ^ServerSocket (:server fixture))))

(defn version [query-set timestamp]
  {"querySet" query-set "identity" 0
   "ts" (if (zero? timestamp) "AAAAAAAAAAA=" (str "fixture-ts-" timestamp))})

(defn updated [query-id value & [logs]]
  (cond-> {"type" "QueryUpdated" "queryId" query-id "value" value}
    (seq logs) (assoc "logLines" logs)))

(defn failed [query-id]
  {"type" "QueryFailed" "queryId" query-id "errorMessage" "fixture failure"
   "errorData" {"code" "FIXTURE"}})

(defn transition [start end & modifications]
  {"type" "Transition" "startVersion" start "endVersion" end
   "modifications" (vec modifications)})
