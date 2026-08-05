(defpackage #:convex
  (:use #:cl)
  (:export
   #:+json-null+
   #:+json-false+
   #:json-decode
   #:json-encode
   #:json-object
   #:json-get
   #:json-has-key-p
   #:make-client
   #:client-query
   #:client-mutation
   #:client-action
   #:client-set-auth
   #:client-subscribe
   #:client-close
   #:subscription-next
   #:subscription-close
   #:client-debug-disconnect
   #:client-live-metadata
   #:result-value
   #:result-logs
   #:update-value
   #:update-logs
   #:update-error
   #:convex-error
   #:function-error
   #:protocol-error
   #:transport-error
   #:error-name
   #:error-message
   #:error-data
   #:error-logs
   #:random-hex-id
   #:canonical-timestamp-p
   #:timestamp-greater-p))

(in-package #:convex)
