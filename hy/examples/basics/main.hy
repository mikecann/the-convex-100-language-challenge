(import math os secrets sys)
(sys.path.insert 0 (os.environ.get "CONVEX_CLIENT_PATH" "/work/client"))
(import convex [Client])

(defn whole [value operation]
  ;; Convex may spell a whole number as 1.0. Accept it, but refuse fractions.
  (if (or (isinstance value bool) (not (isinstance value #(int float))) (and (isinstance value float) (or (not (math.isfinite value)) (not (.is_integer value)))))
    (raise (RuntimeError (+ operation " count was not a finite whole number"))) None)
  (int value))

(defn main []
  ;; Read the dedicated deployment and unique room supplied by the verifier.
  (setv deployment-url (.get os.environ "CONVEX_URL")
        room (if (> (len sys.argv) 1) (get sys.argv 1) "hy-example"))
  ;; Create this unofficial Hy client. This example does not use authentication.
  (setv client (Client deployment-url))
  (try
    ;; Query over HTTP and decode Convex's JSON number as a whole count.
    (setv current (whole (get (. (.query client "demo:state" {"room" room}) value) "count") "current query"))
    (print (+ "current count: " (str current)))
    ;; Start Live before mutating so the subscription cannot miss the change.
    (setv subscription (.subscribe client "demo:state" {"room" room}))
    (try
      ;; The first Live value is the current result and must agree with HTTP.
      (setv initial (.next-update subscription 10))
      (if initial.error (raise initial.error) None)
      (if (!= (whole (get initial.value "count") "initial Live value") current) (raise (RuntimeError "initial Live value disagreed with HTTP")) None)
      (print (+ "live initial count: " (str current)))
      ;; runId makes the logical increment safe if this example is retried.
      (setv mutation (. (.mutation client "demo:increment" {"room" room "language" "hy" "runId" (secrets.token_hex 8)}) value))
      (if (is-not (get mutation "applied") True) (raise (RuntimeError "mutation was not applied")) None)
      (print "mutation applied: true")
      (setv expected (+ current 1))
      (if (!= (whole (get (get mutation "state") "count") "mutation") expected) (raise (RuntimeError "mutation count disagreed")) None)
      (print (+ "mutation count: " (str expected)))
      (setv changed (.next-update subscription 10))
      (if changed.error (raise changed.error) None)
      (if (!= (whole (get changed.value "count") "updated Live value") expected) (raise (RuntimeError "updated Live count disagreed")) None)
      (print (+ "live updated count: " (str expected)))
      (print (+ "verified count: " (str current) " -> " (str expected)))
      ;; Unsubscribe even if decoding or verification raises an exception.
      (finally (.close subscription)))
    ;; Closing the client retires the WebSocket owner and HTTP state.
    (finally (.close client))))

(if (and (= __name__ "__main__") (.get os.environ "CONVEX_URL")) (main) None)
