(* ConvexLive - the Convex /api/sync WebSocket state machine: Connect,
   ModifyQuerySet (Add/Remove), Transition parsing, per-subscription
   QueryUpdated/QueryFailed delivery with rehydration dedup, and
   reconnect with exponential backoff.

   This is a single-threaded state machine: every procedure here reads
   and mutates the same T in place, and none of them block internally
   except Poll's own bounded network read. There is deliberately no
   internal locking or worker thread -- the "one worker owns the
   socket" requirement is satisfied by convention instead, the same way
   a single-threaded event loop always satisfies it: callers must not
   call two of these procedures on the same T concurrently from
   different threads. Every language client in this project observed
   this same convention is sufficient; introducing real concurrency
   here would only add a second, harder way to get it wrong. *)
INTERFACE ConvexLive;

IMPORT ConvexJson;

TYPE
  EventKind = {Update, Error};

  Event = RECORD
    kind: EventKind;
    subscriptionId: TEXT;
    value: ConvexJson.T;     (* set iff kind = Update *)
    logLines: ConvexJson.T;  (* an array, possibly empty, never NIL *)
    errName: TEXT;           (* set iff kind = Error *)
    errMessage: TEXT;
    errData: ConvexJson.T;   (* may be NIL even when kind = Error *)
  END;

  EventBatch = RECORD
    count: INTEGER;
    events: REF ARRAY OF Event;
  END;

  T <: ROOT;

(* "url" is the deployment's wss:// (or ws:// for the local self-hosted
   backend) base URL; ConvexLive appends /api/sync itself when the URL
   has no path of its own. No network activity happens until the first
   Add or Poll. *)
PROCEDURE New(url: TEXT): T;

(* Register a subscription and, if not already connected, connect. Any
   events observed synchronously during that connect attempt (there
   normally are none -- the initial value always arrives from a later
   Poll) are appended to "events" starting at "events.count". *)
PROCEDURE Add(live: T; subscriptionId: TEXT; path: TEXT; args: ConvexJson.T);

(* Unregister a subscription. Its old relay is invalidated (removed
   from the live subscription table) before this returns, so no event
   for it can be delivered by a later Poll even if one was already
   in flight from the server when Remove was called. *)
PROCEDURE Remove(live: T; subscriptionId: TEXT);

(* Block for at most "timeoutMs" waiting for new events, then return
   whatever arrived (possibly nothing). A stopped/slow consumer that
   simply calls Poll less often is fine; an internal pending-event
   queue absorbs a burst up to a bound (see ConvexLive.m3's
   MaxPendingEvents) and forces a TransportError reconnect rather than
   growing without bound if a caller falls too far behind. *)
PROCEDURE Poll(live: T; timeoutMs: INTEGER): EventBatch;

(* Adapter-only: retire the current connection and arm the reconnect
   timer synchronously, so the caller can acknowledge immediately after
   this returns. Not part of the public client API (see manifest.yaml's
   adapter.adapterOnlyCommands). *)
PROCEDURE DebugDisconnect(live: T);

PROCEDURE Close(live: T);

PROCEDURE ConnectionCount(live: T): INTEGER;
PROCEDURE LastCloseReason(live: T): TEXT;
PROCEDURE IsConnected(live: T): BOOLEAN;
(* NIL if no Transition has arrived yet. *)
PROCEDURE MaxObservedTimestamp(live: T): TEXT;

END ConvexLive.
