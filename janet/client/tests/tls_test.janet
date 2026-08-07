# TLS verification.
#
# A TLS client that connects is not the same as a TLS client that verifies.
# The Docker test stage starts a throwaway certificate authority and a server
# whose certificate names `localhost` only, then runs this file against it.
# Passing means the client accepted the one connection it should and refused
# both connections it should not.

(import ./check :as check)
(import ../http :as http)
(import transport :as transport)

(def port (scan-number (or (os/getenv "TLS_PORT") "0")))
(def test-ca (os/getenv "TLS_CA"))
(def system-ca (or (os/getenv "TLS_SYSTEM_CA") "/etc/ssl/certs/ca-certificates.crt"))

(unless (and (number? port) (> port 0) test-ca)
  (eprint "tls_test needs TLS_PORT and TLS_CA")
  (os/exit 1))

(defn- connect-with [ca host]
  (os/setenv "SSL_CERT_FILE" ca)
  (transport/connect host port true 5000))

# 1. The certificate is signed by the trusted authority and names this host, so
#    the handshake must succeed and carry real traffic.
(def trusted (connect-with test-ca "localhost"))
(check/check (transport/tls? trusted) "the trusted connection is TLS protected")
(http/write-all trusted
                "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                (http/deadline-in 5000))
(def response (http/read-response trusted (buffer/new 512) (http/deadline-in 5000)))
(check/check= (get response :status) 200 "a request completed over the TLS session")
(transport/close trusted)

# 2. The system bundle does not contain the throwaway authority, so the same
#    certificate must now be rejected rather than merely reported.
(check/check-raises "TransportError"
                    (fn [] (connect-with system-ca "localhost"))
                    "a certificate from an untrusted authority is refused")

# 3. The certificate names localhost and nothing else, so connecting by IP
#    address must fail even though the chain itself is trusted.
(check/check-raises "TransportError"
                    (fn [] (connect-with test-ca "127.0.0.1"))
                    "a certificate that does not name the requested host is refused")

(os/setenv "SSL_CERT_FILE" system-ca)
(check/report "janet tls")
