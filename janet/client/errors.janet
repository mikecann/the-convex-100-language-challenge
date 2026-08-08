# Structured failures for the Convex client.
#
# Convex asks a client to keep three failure classes apart, and flattening them
# into strings is the mistake that makes a client look like it works:
#
#   FunctionError  the Convex function ran and returned an error the caller
#                  should see, including its structured `data` payload
#   ProtocolError  the peer spoke something that is not the pinned Convex or
#                  RFC 6455 protocol, so the local state is no longer trustworthy
#   TransportError the bytes never made it, or a deadline expired
#
# Each is raised as a Janet table so `try` receives a value that can be
# inspected, re-raised, and serialized without ever being reparsed from text.

(defn make
  "Build a structured error value without raising it."
  [name message &opt data logs]
  (def value @{:name name :message message})
  # `data` is genuinely optional and may legitimately be JSON null, so record
  # its presence separately instead of testing the value for nil.
  (when (not (nil? data)) (put value :data data))
  (when (not (nil? logs)) (put value :logs logs))
  value)

(defn client-error?
  "Is this a structured error raised by the Convex client?"
  [value]
  (and (dictionary? value)
       (string? (get value :name))
       (string? (get value :message))))

(defn name-of
  "The error class, defaulting to a transport failure for foreign values."
  [value]
  (if (client-error? value) (get value :name) "TransportError"))

(defn message-of
  "A printable message for any raised value, including Janet's own errors."
  [value]
  (cond
    (client-error? value) (get value :message)
    (string? value) value
    (buffer? value) (string value)
    (describe value)))

(defn function
  "The Convex function ran and failed. `data` is the application's own payload."
  [message &opt data logs]
  (error (make "FunctionError" message data logs)))

(defn protocol
  "The peer is not speaking the pinned protocol."
  [message]
  (error (make "ProtocolError" message)))

(defn transport
  "Bytes were lost, refused, or a deadline expired."
  [message]
  (error (make "TransportError" message)))

(defn rethrow
  "Re-raise a caught value, normalizing foreign values into a transport error."
  [value]
  (if (client-error? value)
    (error value)
    (error (make "TransportError" (message-of value)))))
