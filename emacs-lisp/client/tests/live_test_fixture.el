;;; live_test_fixture.el --- the scripted peer for live_test.el.
;;
;; Blocking I/O means a fixture and its client cannot cooperatively share
;; one process here any more than in most of this project's other clients:
;; while this client's convex-query blocks inside url-retrieve-synchronously
;; waiting for a response, nothing else in that same process runs to send
;; one. This therefore runs as a second, real OS process - started by the
;; Dockerfile before live_test.el - a real TCP peer speaking the real wire
;; protocol (HTTP framing and RFC 6455 framing by hand, via
;; live_fixture.el), not a mocked transport. It carries no assertions of
;; its own; it only speaks the exact sequence live_test.el expects.

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "live_fixture.el" here) nil t))

(defconst fx--port 18500)

(fixture-listen fx--port)

;; --- connection 1: HTTP query ---
(fixture-read-http-request)
(fixture-respond-http
 "200 OK"
 "{\"status\":\"success\",\"value\":{\"room\":\"x\",\"count\":0},\"logLines\":[\"from-fixture\"]}")
(fixture-close)

;; --- connection 2: HTTP mutation -> FunctionError ---
(fixture-listen fx--port)
(fixture-read-http-request)
(fixture-respond-http
 "200 OK"
 "{\"status\":\"error\",\"errorMessage\":\"boom\",\"errorData\":{\"code\":\"ROOM_EMPTY\"}}")
(fixture-close)

;; --- connection 3: Live subscribe demo:state, initial value + external
;; update. The client forces this connection closed via debugDisconnect
;; right after, so it is not reused for anything further. ---
(fixture-listen fx--port)
(let ((request (fixture-read-http-request)))
  (fixture-ws-accept-upgrade (nth 2 request)))
(fixture-ws-read) ;; Connect
(fixture-ws-read) ;; ModifyQuerySet (Add)
(fixture-send-transition
 (fixture-version-json 0 0 0) (fixture-version-json 1 0 1)
 "[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":0},\"logLines\":[]}]")
(fixture-send-transition
 (fixture-version-json 1 0 1) (fixture-version-json 1 0 2)
 "[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":1},\"logLines\":[\"ext\"]}]")

;; --- connections 4-8: five reconnects, each resubscribing the same
;; query. Every resubscribed value is offset by 100 so none of them ever
;; collides with the count:1 the external update above already delivered
;; (or with each other): a client that correctly suppresses an unchanged
;; rehydration would otherwise see the first reconnect's own resubscribe as
;; a no-op duplicate and never deliver a value for it at all - a fixture
;; data bug, not a client bug. The fifth of these stays open afterwards:
;; the client's own unsubscribe (Remove) for that query arrives on it
;; before the client resets the connection for the next, unrelated
;; subscription. ---
(dotimes (i 5)
  (let ((n (1+ i)))
    (fixture-reaccept fx--port)
    (let ((request (fixture-read-http-request)))
      (fixture-ws-accept-upgrade (nth 2 request)))
    (fixture-ws-read) ;; Connect
    (fixture-ws-read) ;; ModifyQuerySet (Add), resent after every reconnect
    (fixture-send-transition
     (fixture-version-json 0 0 0) (fixture-version-json 1 0 n)
     (format "[{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":%d},\"logLines\":[]}]"
             (+ 100 n)))))
(fixture-ws-read) ;; the client's Remove for qid 0
(fixture-close)

;; --- connection 9: a fresh subscription that immediately fails. Query IDs
;; are never reused (the client's own next-qid keeps counting up even
;; across unsubscribe), so this second subscription is queryId 1, not 0: a
;; modification naming a query the client is not tracking is silently
;; ignored rather than delivered. ---
(fixture-listen fx--port)
(let ((request (fixture-read-http-request)))
  (fixture-ws-accept-upgrade (nth 2 request)))
(fixture-ws-read) ;; Connect
(fixture-ws-read) ;; ModifyQuerySet (Add)
(fixture-send-transition
 (fixture-version-json 0 0 0) (fixture-version-json 0 0 1)
 "[{\"type\":\"QueryFailed\",\"queryId\":1,\"errorMessage\":\"empty\",\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[]}]")
(fixture-close)

(kill-emacs 0)
