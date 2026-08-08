(* Convex Live over the repository's pinned unversioned /api/sync profile.

   The whole design follows one rule: exactly one thread - the owner - opens,
   reads, writes, retires, and reconnects the WebSocket. Callers never touch the
   socket. They queue a command, the owner acknowledges it, and the
   acknowledgement is the barrier that decides which events are still valid.
   That is what makes unsubscribe, same-identifier replacement, and fault
   injection deterministic rather than racy. *)

structure Timestamp =
struct
  (* Convex spells the sync timestamp as a base64 little-endian unsigned 64-bit
     integer. Both directions are strict so a non-canonical spelling cannot slip
     through as a different version of the same state. *)
  val initial = "AAAAAAAAAAA="

  fun encode (number : IntInf.int) =
    if number < 0 orelse number > 18446744073709551615 then
      ConvexError.fail ("ProtocolError", "Live timestamp is outside unsigned 64 bits")
    else
      Base64.encode
        (CharVector.tabulate
           (8,
            fn index =>
              Char.chr
                (IntInf.toInt (IntInf.mod (IntInf.div (number, IntInf.pow (256, index)), 256)))))

  fun decode text =
    let
      val raw =
        Base64.decode text
        handle _ => ConvexError.fail ("ProtocolError", "Live timestamp is not base64")
      val _ =
        if String.size raw = 8 then ()
        else ConvexError.fail ("ProtocolError", "Live timestamp is not eight bytes")
      fun loop (index, acc) =
        if index < 0 then acc
        else loop (index - 1, acc * 256 + IntInf.fromInt (Bytes.byteAt (raw, index)))
      val number = loop (7, 0 : IntInf.int)
    in
      if encode number = text then number
      else ConvexError.fail ("ProtocolError", "Live timestamp is not canonical")
    end
end

structure Live =
struct
  val initialBackoff = 0.1
  val maximumBackoff = 15.0
  val maxSubscriptions = 64
  val subscriptionByteLimit = 8 * 1024 * 1024
  val deliveryCountLimit = 16
  val deliveryByteLimit = 20 * 1024 * 1024
  val maxUInt32 : IntInf.int = 4294967295

  (* How long the owner blocks waiting for a frame before returning to look at
     its command queue, and how long it will wait once a frame has started. *)
  val idleSlice = 0.05
  val frameBudget = 1.0

  (* One connection attempt. A subscribe may make several of these, but only
     inside the single absolute budget its caller granted. *)
  val connectSeconds = 2.0

  (* How long a caller waits for the owner to acknowledge a subscribe, and the
     shorter budget the owner is given to produce that acknowledgement. Keeping
     the owner's budget strictly inside the caller's is what turns a failed
     first connection into a structured failure rather than a timeout. *)
  val subscribeSeconds = 5.0
  val subscribeBudgetSeconds = 4.0

  type update =
    {value: Json.value,
     logs: string list,
     error: ConvexError.t option,
     (* Stamped by the owner with the transport generation that produced it, so
        a value dequeued before a barrier can still be recognised as stale. *)
     generation: int}

  datatype kind = SubscribeKind | UnsubscribeKind | DisconnectKind | CloseKind

  datatype outcome = Acknowledged | Started of subscription | Generation of int

  and reply =
    Reply of
      {mutex: Thread.Mutex.mutex,
       cond: Thread.ConditionVar.conditionVar,
       settled: bool ref,
       value: outcome ref,
       error: ConvexError.t option ref,
       (* Set by a caller that gave up waiting. The owner reads it under the
          same lock it would settle under, so the decision to publish an
          acknowledgement or to roll its work back is never a race. *)
       cancelled: bool ref}

  and command =
    Command of
      {kind: kind,
       target: subscription option,
       request: (string * Json.value) option,
       (* One absolute budget per command, fixed when the caller queued it, so
          a retrying owner can never restart the caller's clock. *)
       budget: Time.time,
       reply: reply}

  and delivery = Delivery of {target: subscription, update: update, charge: int}

  and subscription =
    Subscription of
      {manager: manager,
       queryId: IntInf.int,
       path: string,
       args: Json.value,
       charge: int,
       active: bool ref,
       (* A fixed-size fingerprint of the last published state. Suppressing an
          unchanged rehydration this way avoids retaining a second copy of the
          value. *)
       fingerprint: word option ref}

  and manager =
    Manager of
      {url: Url.t,
       version: string,
       mutex: Thread.Mutex.mutex,
       signal: Thread.ConditionVar.conditionVar,
       commands: command list ref,
       subscriptions: subscription list ref,
       nextQueryId: IntInf.int ref,
       activeBytes: int ref,
       deliveries: delivery list ref,
       deliveryBytes: int ref,
       closed: bool ref,
       connectionCount: int ref,
       lastCloseReason: string ref,
       maxObservedTimestamp: IntInf.int ref,
       generation: int ref}

  fun managerOf (Subscription {manager, ...}) = manager
  fun queryIdOf (Subscription {queryId, ...}) = queryId
  fun isActive (Subscription {active, ...}) = !active

  (* A subscription carries JSON arguments, which contain reals, so the type
     does not admit structural equality. Identifiers are unique per manager and
     never reused, so they are the identity comparison. *)
  fun sameSubscription (left, right) = queryIdOf left = queryIdOf right

  (* Failures reaching the owner are normalised once. A transport deadline is a
     transport failure, not protocol drift. *)
  fun asFailure exn =
    case exn of
        Transport.Timeout =>
          ConvexError.simple ("TransportError", "Live transport passed its deadline")
      | _ => ConvexError.normalise exn

  fun generationOf (Manager {generation, ...}) = !generation

  (* ---- acknowledgements -------------------------------------------- *)

  fun newReply () =
    Reply
      {mutex = Thread.Mutex.mutex (),
       cond = Thread.ConditionVar.conditionVar (),
       settled = ref false,
       value = ref Acknowledged,
       error = ref NONE,
       cancelled = ref false}

  (* Returns false when nobody is left to receive the result, which is the
     owner's signal to undo whatever it was about to acknowledge. *)
  fun settle (Reply {mutex, cond, settled, value, cancelled, ...}, result) =
    Guard.critical
      (mutex,
       fn () =>
         if !settled orelse !cancelled then false
         else
           (value := result;
            settled := true;
            Thread.ConditionVar.broadcast cond;
            true))

  fun settleError (Reply {mutex, cond, settled, error, ...}, failure) =
    Guard.critical
      (mutex,
       fn () =>
         if !settled then ()
         else (error := SOME failure; settled := true; Thread.ConditionVar.broadcast cond))

  fun awaitReply (Reply {mutex, cond, settled, value, error, cancelled}, seconds, what) =
    let
      val deadline = Clock.deadlineIn seconds
      fun loop () =
        if !settled then
          (case !error of
               SOME failure => raise ConvexError.Error failure
             | NONE => !value)
        else if Clock.expired deadline then
          (* The owner may still be holding this command. Cancelling it here,
             under the lock the owner settles under, is what lets a late
             acknowledgement roll its work back instead of leaving behind a
             subscription no caller holds. *)
          (cancelled := true;
           ConvexError.fail ("TransportError", "timed out waiting for the Live owner to " ^ what))
        else (Thread.ConditionVar.waitUntil (cond, mutex, deadline); loop ())
      val _ = Thread.Mutex.lock mutex
      val result = loop () handle exn => (Thread.Mutex.unlock mutex; raise exn)
    in
      Thread.Mutex.unlock mutex;
      result
    end

  fun enqueueCommand (Manager {mutex, signal, commands, closed, ...}, kind, target, request,
                      budgetSeconds) =
    let
      val reply = newReply ()
      val budget = Clock.deadlineIn budgetSeconds
    in
      Guard.critical
        (mutex,
         fn () =>
           if !closed then ConvexError.fail ("ClosedError", "Live client is closed")
           else
             (commands :=
                !commands
                @ [Command {kind = kind, target = target, request = request, budget = budget,
                            reply = reply}];
              Thread.ConditionVar.broadcast signal));
      reply
    end

  fun takeCommand (Manager {mutex, commands, ...}) =
    Guard.critical
      (mutex,
       fn () =>
         case !commands of
             [] => NONE
           | first :: rest => (commands := rest; SOME first))

  (* ---- accounting --------------------------------------------------- *)

  (* Four times the exact wire length pays for the decoded value, its encoded
     copy, and the queue cell; 4096 bytes covers the records themselves. *)
  fun subscriptionCharge (path, args) =
    4096 + 4 * (String.size path + Json.byteLength args)

  fun updateShape ({value, logs, error, ...} : update) =
    case error of
        SOME {name, message, data, ...} =>
          Json.Object
            [("error",
              Json.Object [("name", Json.String name), ("message", Json.String message),
                           ("data", data)]),
             ("logs", Json.Array (List.map Json.String logs))]
      | NONE =>
          Json.Object
            [("value", value), ("logs", Json.Array (List.map Json.String logs))]

  (* The delivery charge and the suppression fingerprint both come from one walk
     over the update, and that walk retains nothing. Encoding a near-maximum
     value once for its size and again for its fingerprint is itself the memory
     amplification this budget exists to prevent. *)
  fun chargeFor size = 4096 + 4 * size

  (* Insertion order already follows the increasing identifier, but sorting
     explicitly keeps the resent Add list stable if that ever changes. At most
     64 subscriptions exist, so an insertion sort is the right size of tool. *)
  fun sortedSubscriptions (Manager {subscriptions, ...}) =
    let
      fun insert (item, []) = [item]
        | insert (item, first :: rest) =
            if queryIdOf item <= queryIdOf first then item :: first :: rest
            else first :: insert (item, rest)
    in
      List.foldl insert [] (!subscriptions)
    end

  fun findSubscription (Manager {subscriptions, ...}, queryId) =
    List.find (fn item => queryIdOf item = queryId) (!subscriptions)

  fun dropOldestDelivery (Manager {deliveries, deliveryBytes, ...}) =
    case !deliveries of
        [] => ()
      | Delivery {charge, ...} :: rest =>
          (deliveries := rest; deliveryBytes := !deliveryBytes - charge)

  (* Calculate every fallible fingerprint and charge before committing anything.
     One bad member of a transition therefore rejects the whole transition
     instead of publishing a partial state. *)
  fun publishUpdates (manager as Manager {mutex, signal, deliveries, deliveryBytes, ...}, pairs) =
    let
      val prepared =
        List.mapPartial
          (fn (target as Subscription {active, fingerprint, ...}, update) =>
             if not (!active) then NONE
             else
               let
                 val {size, fingerprint = mark} = Json.measure (updateShape update)
               in
                 if !fingerprint = SOME mark then NONE
                 else
                   let
                     val charge = chargeFor size
                   in
                     if charge > deliveryByteLimit then
                       ConvexError.fail
                         ("ProtocolError", "Live update exceeds the global delivery budget")
                     else SOME (target, update, mark, charge)
                   end
               end)
          pairs
    in
      Guard.critical
        (mutex,
         fn () =>
           (List.app
              (fn (target as Subscription {fingerprint, ...}, update, mark, charge) =>
                 let
                   fun trim () =
                     if List.length (!deliveries) >= deliveryCountLimit
                        orelse !deliveryBytes + charge > deliveryByteLimit then
                       (dropOldestDelivery manager; trim ())
                     else ()
                 in
                   trim ();
                   fingerprint := SOME mark;
                   deliveries :=
                     !deliveries @ [Delivery {target = target, update = update, charge = charge}];
                   deliveryBytes := !deliveryBytes + charge
                 end)
              prepared;
            Thread.ConditionVar.broadcast signal))
    end

  fun removeFirstFor (items, target) =
    let
      fun loop (prefix, remaining) =
        case remaining of
            [] => (NONE, List.rev prefix)
          | (item as Delivery {target = owner, ...}) :: rest =>
              if sameSubscription (owner, target) then (SOME item, List.revAppend (prefix, rest))
              else loop (item :: prefix, rest)
    in
      loop ([], items)
    end

  (* Blocks for at most `seconds`. NONE means the subscription ended or nothing
     arrived in time. *)
  fun next (target as Subscription {manager, active, ...}, seconds) =
    let
      val Manager {mutex, signal, deliveries, deliveryBytes, ...} = manager
      val deadline = Clock.deadlineIn seconds
      fun loop () =
        case removeFirstFor (!deliveries, target) of
            (SOME (Delivery {update, charge, ...}), remaining) =>
              (deliveries := remaining;
               deliveryBytes := !deliveryBytes - charge;
               Thread.ConditionVar.broadcast signal;
               SOME update)
          | (NONE, _) =>
              if not (!active) then NONE
              else if Clock.expired deadline then NONE
              else (Thread.ConditionVar.waitUntil (signal, mutex, deadline); loop ())
      val _ = Thread.Mutex.lock mutex
      val result = loop () handle exn => (Thread.Mutex.unlock mutex; raise exn)
    in
      Thread.Mutex.unlock mutex;
      result
    end

  fun purgeFor (Manager {mutex, signal, deliveries, deliveryBytes, ...}, target) =
    Guard.critical
      (mutex,
       fn () =>
         let
           val kept =
             List.filter
               (fn Delivery {target = owner, ...} => not (sameSubscription (owner, target)))
               (!deliveries)
         in
           deliveries := kept;
           deliveryBytes :=
             List.foldl (fn (Delivery {charge, ...}, total) => total + charge) 0 kept;
           Thread.ConditionVar.broadcast signal
         end)

  fun clearDeliveries (Manager {mutex, signal, deliveries, deliveryBytes, ...}) =
    Guard.critical
      (mutex,
       fn () =>
         (deliveries := []; deliveryBytes := 0; Thread.ConditionVar.broadcast signal))

  (* A valid value received just before a transport failure must stay ahead of
     the structured failure event, so queued deliveries are restamped with the
     new generation rather than dropped. Every generation change goes through
     here, not only the ones that publish a failure afterwards: a caller must
     never be told a value it already earned is stale merely because the socket
     that produced it has since been retired for some other reason. *)
  fun rebaseDeliveries (Manager {mutex, signal, deliveries, generation, ...}) =
    Guard.critical
      (mutex,
       fn () =>
         (deliveries :=
            List.map
              (fn Delivery {target, update, charge} =>
                 Delivery
                   {target = target,
                    update =
                      {value = #value update, logs = #logs update, error = #error update,
                       generation = !generation},
                    charge = charge})
              (!deliveries);
          Thread.ConditionVar.broadcast signal))

  (* ---- protocol messages -------------------------------------------- *)

  type version = {querySet: IntInf.int, identity: IntInf.int, ts: string}

  val zeroVersion : version = {querySet = 0, identity = 0, ts = Timestamp.initial}

  fun readVersion value =
    case value of
        Json.Object _ =>
          let
            val querySet =
              Json.asUInt32 (Json.getOr (value, "querySet", Json.Null), "Live querySet")
            val identity =
              Json.asUInt32 (Json.getOr (value, "identity", Json.Null), "Live identity")
            val ts =
              case Json.asString (Json.getOr (value, "ts", Json.Null)) of
                  SOME text => text
                | NONE =>
                    ConvexError.fail
                      ("ProtocolError", "Live state version timestamp must be a string")
          in
            ignore (Timestamp.decode ts);
            {querySet = querySet, identity = identity, ts = ts} : version
          end
      | _ => ConvexError.fail ("ProtocolError", "Live state version must be an object")

  fun sameVersion (left : version, right : version) =
    #querySet left = #querySet right
    andalso #identity left = #identity right
    andalso #ts left = #ts right

  fun addModification target =
    Json.Object
      [("type", Json.String "Add"),
       ("queryId", Json.Int (queryIdOf target)),
       ("udfPath", Json.String (case target of Subscription {path, ...} => path)),
       ("args", Json.Array [case target of Subscription {args, ...} => args])]

  fun removeModification target =
    Json.Object
      [("type", Json.String "Remove"), ("queryId", Json.Int (queryIdOf target))]

  (* The pinned sync profile is deliberately the unversioned endpoint. *)
  val syncPath = "/api/sync"

  (* ---- the owner ----------------------------------------------------- *)

  fun ownerLoop (manager as Manager {url, version, subscriptions, nextQueryId, activeBytes,
                                     closed, connectionCount, lastCloseReason,
                                     maxObservedTimestamp, generation, mutex, signal,
                                     commands, ...}) =
    let
      val socket : WebSocket.t option ref = ref NONE
      (* Subscriptions that are registered and waiting for a first connection.
         They are resolved in the owner's ordinary loop rather than inside the
         subscribe command, so a caller waiting for a connection never blocks
         close or unsubscribe behind it. *)
      val pendingAttach : (subscription * reply * Time.time) list ref = ref []
      val remoteVersion = ref zeroVersion
      val querySetVersion = ref (0 : IntInf.int)
      val nextConnectAt : Time.time option ref = ref NONE
      val backoff = ref initialBackoff
      val fragmentOpen = ref false
      val fragments : string list ref = ref []
      val fragmentSize = ref 0
      val stop = ref false

      fun resetFragments () = (fragmentOpen := false; fragments := []; fragmentSize := 0)

      fun sendJson value =
        case !socket of
            SOME live => WebSocket.sendText (live, Json.encode value, Clock.deadlineIn 1.0)
          | NONE => ConvexError.fail ("TransportError", "Live socket is not connected")

      fun scheduleReconnect delay =
        (nextConnectAt := SOME (Clock.deadlineIn delay);
         backoff := Real.min (maximumBackoff, !backoff * 2.0))

      (* Retiring bumps the generation. That single increment is what every
         later staleness check keys off, so every queued delivery is restamped
         here rather than at the handful of call sites that happen to publish a
         failure afterwards.

         This is also the only place a connection is counted, and it counts one
         that genuinely existed. A handshake that never produced a socket is not
         a connection, so a retried first attempt cannot inflate the count the
         server sees on the attempt that succeeds. *)
      fun disconnectSocket graceful =
        case !socket of
            NONE => ()
          | SOME live =>
              ((if graceful then
                  (WebSocket.sendClose (live, Clock.deadlineIn 0.25) handle _ => ())
                else ());
               (WebSocket.close live handle _ => ());
               socket := NONE;
               generation := !generation + 1;
               connectionCount := !connectionCount + 1;
               rebaseDeliveries manager)

      fun retire (reason, reconnect, graceful) =
        (disconnectSocket graceful;
         lastCloseReason := reason;
         querySetVersion := 0;
         remoteVersion := zeroVersion;
         resetFragments ();
         if reconnect andalso not (List.null (!subscriptions)) then
           scheduleReconnect (!backoff)
         else nextConnectAt := NONE)

      fun publishRecoverable (name, message) =
        publishUpdates
          (manager,
           List.map
             (fn target =>
                (target,
                 {value = Json.Null, logs = [],
                  error = SOME (ConvexError.withOperation (name, message, "query")),
                  generation = !generation}))
             (sortedSubscriptions manager))

      fun retireWith failure =
        let
          val {name, message, ...} = asFailure failure
          val label = if name = "TransportError" then "TransportError" else "ProtocolError"
        in
          (* retire restamps whatever was already queued, so the failure below
             lands behind those values rather than in front of them. *)
          retire (message, true, false);
          publishRecoverable (label, message) handle _ => ()
        end

      fun connectMessage () =
        Json.Object
          ([("type", Json.String "Connect"),
            ("sessionId", Json.String (Rand.hex 16)),
            ("connectionCount", Json.Int (IntInf.fromInt (!connectionCount))),
            ("lastCloseReason", Json.String (!lastCloseReason)),
            ("clientTs", Json.Int 0)]
           @ (if !maxObservedTimestamp > 0 then
                [("maxObservedTimestamp", Json.String (Timestamp.encode (!maxObservedTimestamp)))]
              else []))

      (* Every new connection resends the whole active query set, so a reconnect
         restores exactly the subscriptions the caller still holds. *)
      fun connectNow deadline =
        (let
           val live =
             WebSocket.connect
               {url = url, path = syncPath, version = version, deadline = deadline}
         in
           socket := SOME live;
           sendJson (connectMessage ());
           (case sortedSubscriptions manager of
                [] => ()
              | targets =>
                  (sendJson
                     (Json.Object
                        [("type", Json.String "ModifyQuerySet"),
                         ("baseVersion", Json.Int 0),
                         ("newVersion", Json.Int 1),
                         ("modifications", Json.Array (List.map addModification targets))]);
                   querySetVersion := 1));
           remoteVersion := zeroVersion;
           nextConnectAt := NONE;
           backoff := initialBackoff;
           resetFragments ();
           true
         end)
        handle failure =>
          (* disconnectSocket retires a connection that really existed and does
             nothing when the handshake never produced one, which is exactly the
             distinction connectionCount has to make. *)
          (disconnectSocket false;
           lastCloseReason := #message (asFailure failure);
           scheduleReconnect (!backoff);
           false)

      (* No connection attempt outlives the tightest caller waiting for one.
         Without this the owner could start a fresh two-second attempt with a
         fraction of a second left on a pending subscribe, and that caller would
         be told only that the owner never answered instead of why its
         connection failed. With nothing pending this is the ordinary attempt
         budget, which is what a background reconnect gets. *)
      fun connectBudget () =
        Real.max
          (0.0,
           List.foldl
             (fn ((_, _, budget), least) => Real.min (least, Clock.remainingSeconds budget))
             connectSeconds
             (!pendingAttach))

      fun connectAttempt () = connectNow (Clock.deadlineIn (connectBudget ()))

      (* Backoff is respected by everything that reconnects, including a fresh
         subscribe, so a second caller cannot turn a scheduled retry into an
         immediate one and double the delay for the first. *)
      fun connectDue () =
        case !nextConnectAt of
            NONE => true
          | SOME at => Clock.expired at

      fun sendModification (change, target) =
        (if !querySetVersion >= maxUInt32 then
           ConvexError.fail ("ProtocolError", "Live query-set version exhausted")
         else ();
         sendJson
           (Json.Object
              [("type", Json.String "ModifyQuerySet"),
               ("baseVersion", Json.Int (!querySetVersion)),
               ("newVersion", Json.Int (!querySetVersion + 1)),
               ("modifications", Json.Array [change target])]);
         querySetVersion := !querySetVersion + 1)

      fun deactivate (target as Subscription {active, charge, ...}) =
        (if List.exists (fn item => sameSubscription (item, target)) (!subscriptions) then
           (subscriptions :=
              List.filter (fn item => not (sameSubscription (item, target))) (!subscriptions);
            activeBytes := !activeBytes - charge)
         else ();
         active := false;
         purgeFor (manager, target))

      (* The caller gave up before this acknowledgement could reach it. Remove
         the query from the server if the socket that carried its Add is still
         the current one, then unregister it, so no subscription survives that
         nobody holds and nothing keeps reconnecting for it. *)
      fun rollbackSubscribe target =
        ((case !socket of
              SOME _ =>
                if List.exists (fn item => sameSubscription (item, target)) (!subscriptions) then
                  sendModification (removeModification, target)
                else ()
            | NONE => ())
         handle failure => retire (#message (asFailure failure), true, false);
         deactivate target)

      fun completeAttach (target, reply) =
        if settle (reply, Started target) then () else rollbackSubscribe target

      fun failAttach (target, reply, failure) =
        (deactivate target; settleError (reply, failure))

      fun processSubscribe (path, args, budget, reply) =
        let
          val charge = subscriptionCharge (path, args)
          val _ =
            if List.length (!subscriptions) >= maxSubscriptions
               orelse !activeBytes + charge > subscriptionByteLimit then
              ConvexError.fail ("ProtocolError", "Live subscription capacity exceeded")
            else ()
          val _ =
            if !nextQueryId >= maxUInt32 then
              ConvexError.fail ("ProtocolError", "Live query identifier space exhausted")
            else ()
          val target =
            Subscription
              {manager = manager, queryId = !nextQueryId, path = path, args = args,
               charge = charge, active = ref true, fingerprint = ref NONE}
        in
          nextQueryId := !nextQueryId + 1;
          subscriptions := !subscriptions @ [target];
          activeBytes := !activeBytes + charge;
          attachSubscription (target, budget, reply)
        end
        (* Capacity and identifier exhaustion fail before anything is
           registered, so there is nothing to unwind here. *)
        handle failure => settleError (reply, asFailure failure)

      and attachSubscription (target, budget, reply) =
        case !socket of
            SOME _ =>
              ((sendModification (addModification, target); completeAttach (target, reply))
               handle failure =>
                 (* A partially written Add must not survive the failed
                    acknowledgement. Retiring the socket is the barrier, and the
                    subscription is unregistered so the owner does not keep
                    reconnecting for a query no caller holds. *)
                 (retire (#message (asFailure failure), true, false);
                  failAttach (target, reply, asFailure failure)))
          | NONE =>
              (* A first connection is retried until the caller's own budget
                 runs out rather than abandoned after a single attempt. The
                 target is already registered, so every later attempt resends
                 its Add along with the rest of the query set. *)
              (pendingAttach := !pendingAttach @ [(target, reply, budget)];
               if connectDue () then ignore (connectAttempt ()) else ())

      (* Called once per owner turn. A pending attachment is acknowledged as
         soon as a connection exists, and fails when its own budget runs out. *)
      fun servePending () =
        case !pendingAttach of
            [] => ()
          | waiting =>
              let
                val connected = Option.isSome (!socket)
                fun resolve (target, reply, budget) =
                  if not (isActive target) then
                    (settleError
                       (reply, ConvexError.simple ("ClosedError", "Live client is closed"));
                     NONE)
                  else if connected then (completeAttach (target, reply); NONE)
                  else if Clock.expired budget then
                    (failAttach
                       (target, reply,
                        ConvexError.simple
                          ("TransportError",
                           "Live WebSocket connection failed: " ^ !lastCloseReason));
                     NONE)
                  else SOME (target, reply, budget)
              in
                pendingAttach := List.mapPartial resolve waiting
              end

      (* Shutdown has to answer every pending attachment itself: the owner loop
         stops as soon as close is processed, so nothing else would. *)
      fun failPending failure =
        let
          val waiting = !pendingAttach
        in
          pendingAttach := [];
          List.app
            (fn (target, reply, _) => (deactivate target; settleError (reply, failure)))
            waiting
        end

      fun processUnsubscribe (target, reply) =
        ((case !socket of
              SOME _ =>
                if List.exists (fn item => sameSubscription (item, target)) (!subscriptions) then
                  sendModification (removeModification, target)
                else ()
            | NONE => ());
         deactivate target;
         ignore (settle (reply, Acknowledged)))
        handle failure =>
          (* Retiring is itself a valid Remove barrier: the old generation can no
             longer publish anything even though its final write failed. *)
          (retire (#message (asFailure failure), true, false);
           deactivate target;
           ignore (settle (reply, Acknowledged)))

      fun processDisconnect reply =
        case !socket of
            NONE =>
              settleError
                (reply, ConvexError.simple ("TransportError", "Live WebSocket is not connected"))
          | SOME _ =>
              (* Fault injection is a hard drop. The acknowledgement happens only
                 after the old transport is retired and the reconnect is
                 scheduled, so the caller can trust the barrier. *)
              (disconnectSocket false;
               lastCloseReason := "DebugDisconnect";
               querySetVersion := 0;
               remoteVersion := zeroVersion;
               resetFragments ();
               clearDeliveries manager;
               nextConnectAt := SOME (Clock.deadlineIn initialBackoff);
               backoff := initialBackoff * 2.0;
               ignore (settle (reply, Generation (!generation))))

      fun processClose reply =
        (stop := true;
         (* Answered before lastCloseReason is replaced, so a caller still
            waiting for a first connection learns why that connection never
            arrived rather than being told only that the client closed. *)
         failPending
           (ConvexError.simple
              ("TransportError", "Live WebSocket connection failed: " ^ !lastCloseReason));
         List.app (fn Subscription {active, ...} => active := false) (!subscriptions);
         subscriptions := [];
         activeBytes := 0;
         Guard.critical
           (mutex, fn () => (closed := true; Thread.ConditionVar.broadcast signal));
         clearDeliveries manager;
         retire ("ClientClosed", false, true);
         ignore (settle (reply, Acknowledged)))

      fun processCommand (Command {kind, target, request, budget, reply}) =
        case kind of
            SubscribeKind =>
              (case request of
                   SOME (path, args) => processSubscribe (path, args, budget, reply)
                 | NONE =>
                     settleError
                       (reply,
                        ConvexError.simple
                          ("ProtocolError", "subscribe is missing a query")))
          | UnsubscribeKind =>
              (case target of
                   SOME item => processUnsubscribe (item, reply)
                 | NONE => ignore (settle (reply, Acknowledged)))
          | DisconnectKind => processDisconnect reply
          | CloseKind => processClose reply

      (* ---- server messages ------------------------------------------ *)

      fun parseChange change =
        let
          val kindText =
            case Json.asString (Json.getOr (change, "type", Json.Null)) of
                SOME text => text
              | NONE =>
                  ConvexError.fail
                    ("ProtocolError", "Live modification type must be a string")
          val queryId =
            Json.asUInt32 (Json.getOr (change, "queryId", Json.Null), "Live queryId")
          val target = findSubscription (manager, queryId)
          fun logsOf () = Json.stringList (Json.getOr (change, "logLines", Json.Array []))
        in
          if kindText = "QueryUpdated" then
            (if Json.has (change, "value") then ()
             else ConvexError.fail ("ProtocolError", "QueryUpdated is missing its value");
             (queryId, target,
              Option.map
                (fn _ =>
                   {value = Json.getOr (change, "value", Json.Null),
                    logs = logsOf (), error = NONE, generation = !generation})
                target))
          else if kindText = "QueryFailed" then
            let
              val message =
                case Json.asString (Json.getOr (change, "errorMessage", Json.Null)) of
                    SOME text => text
                  | NONE =>
                      ConvexError.fail
                        ("ProtocolError", "QueryFailed errorMessage must be a string")
              val logs = logsOf ()
            in
              (queryId, target,
               Option.map
                 (fn _ =>
                    {value = Json.Null, logs = logs,
                     error =
                       SOME
                         (ConvexError.make
                            {name = "FunctionError", message = message,
                             data = Json.getOr (change, "errorData", Json.Null),
                             logs = logs, operation = SOME "query"}),
                     generation = !generation})
                 target)
            end
          else if kindText = "QueryRemoved" then (queryId, NONE, NONE)
          else
            ConvexError.fail
              ("ProtocolError", "unsupported Live modification " ^ kindText)
        end

      (* Two changes for the same query inside one transaction publish only the
         final state, so a caller never observes an intermediate value that the
         server considered part of the same transition. *)
      fun coalesce (change, results) =
        let
          val (queryId, _, _) = change
        in
          change :: List.filter (fn (existing, _, _) => existing <> queryId) results
        end

      fun processTransition event =
        let
          val start = readVersion (Json.getOr (event, "startVersion", Json.Null))
          val finish = readVersion (Json.getOr (event, "endVersion", Json.Null))
          val modifications =
            case Json.asList (Json.getOr (event, "modifications", Json.Null)) of
                SOME items => items
              | NONE => ConvexError.fail ("ProtocolError", "Live modifications must be an array")
          val _ =
            if sameVersion (start, !remoteVersion) then ()
            else
              ConvexError.fail
                ("ProtocolError", "Live transition start version did not match local state")
          val endTimestamp = Timestamp.decode (#ts finish)
          val _ =
            if endTimestamp >= Timestamp.decode (#ts start) then ()
            else ConvexError.fail ("ProtocolError", "Live timestamp moved backwards")
          val coalesced =
            List.foldl (fn (change, acc) => coalesce (parseChange change, acc)) [] modifications
        in
          (* Only after every field has validated is the version committed and
             the final per-query state published together. *)
          remoteVersion := finish;
          if endTimestamp > !maxObservedTimestamp then maxObservedTimestamp := endTimestamp else ();
          publishUpdates
            (manager,
             List.mapPartial
               (fn (_, target, update) =>
                  case (target, update) of
                      (SOME item, SOME value) => SOME (item, value)
                    | _ => NONE)
               coalesced);
          backoff := initialBackoff;
          nextConnectAt := NONE
        end

      fun processMessage text =
        let
          val _ =
            if Text.utf8Valid text then ()
            else ConvexError.fail ("ProtocolError", "Live text message is not valid UTF-8")
          val event = Json.decode text
          val kindText =
            case Json.asString (Json.getOr (event, "type", Json.Null)) of
                SOME value => value
              | NONE => ConvexError.fail ("ProtocolError", "Live message type is missing")
        in
          if kindText = "Transition" then processTransition event
          else if kindText = "Ping" orelse kindText = "MutationResponse"
                  orelse kindText = "ActionResponse" then ()
          else
            ConvexError.fail
              ("ProtocolError", "unsupported Live server message " ^ kindText)
        end

      fun appendFragment payload =
        let
          val size = !fragmentSize + String.size payload
        in
          if size > WebSocket.maxMessage then
            ConvexError.fail ("ProtocolError", "fragmented Live message exceeds its byte limit")
          else if List.length (!fragments) >= 4096 then
            ConvexError.fail ("ProtocolError", "fragmented Live message has too many frames")
          else (fragments := payload :: !fragments; fragmentSize := size)
        end

      fun processFrame (frame as {fin, opcode, payload} : WebSocket.frame) =
        case opcode of
            WebSocket.Ping =>
              (case !socket of
                   SOME live => WebSocket.sendPong (live, payload, Clock.deadlineIn 1.0)
                 | NONE => ())
          | WebSocket.Pong => ()
          | WebSocket.CloseFrame =>
              (if WebSocket.closeFrameValid frame then ()
               else ConvexError.fail ("ProtocolError", "invalid WebSocket close payload");
               retire ("ServerClosed", true, true);
               publishRecoverable ("TransportError", "Live server closed the WebSocket"))
          | WebSocket.BinaryFrame =>
              ConvexError.fail ("ProtocolError", "binary Live messages are unsupported")
          | WebSocket.TextFrame =>
              if !fragmentOpen then
                ConvexError.fail ("ProtocolError", "WebSocket fragments arrived out of order")
              else if fin then processMessage payload
              else
                (fragmentOpen := true;
                 fragments := [];
                 fragmentSize := 0;
                 appendFragment payload)
          | WebSocket.Continuation =>
              if not (!fragmentOpen) then
                ConvexError.fail ("ProtocolError", "WebSocket continuation has no start")
              else
                (appendFragment payload;
                 if fin then
                   let
                     val message = String.concat (List.rev (!fragments))
                   in
                     resetFragments ();
                     processMessage message
                   end
                 else ())
          | WebSocket.Reserved _ =>
              ConvexError.fail ("ProtocolError", "unsupported WebSocket frame")

      fun pump () =
        case !socket of
            SOME live =>
              ((case WebSocket.receive
                       (live, Clock.deadlineIn idleSlice, Clock.deadlineIn frameBudget) of
                    NONE => ()
                  | SOME frame => processFrame frame)
               handle failure => retireWith failure)
          | NONE =>
              if not (List.null (!subscriptions)) andalso connectDue () then
                ignore (connectAttempt ())
              else Clock.sleep 0.01

      fun loop () =
        let
          fun drain () =
            case takeCommand manager of
                NONE => ()
              | SOME command => (processCommand command; drain ())
        in
          drain ();
          (* Immediately after the commands, so a subscribe whose connection has
             just come up is acknowledged in the same turn. *)
          servePending ();
          if !stop then ()
          else (pump (); loop ())
        end
    in
      (* An owner that dies still owes an answer to anything waiting for a first
         connection; only this scope can see that list. *)
      loop ()
      handle exn =>
        (failPending (ConvexError.simple ("TransportError", "Live owner stopped unexpectedly"))
         handle _ => ();
         raise exn)
    end

  (* If the owner ever dies, every waiting caller has to learn about it rather
     than block until its own deadline. *)
  fun startOwner manager =
    let
      val Manager {mutex, signal, commands, closed, ...} = manager
      fun body () =
        ownerLoop manager
        handle failure =>
          let
            val {message, ...} = ConvexError.normalise failure
          in
            TextIO.output (TextIO.stdErr, "Convex Live owner stopped: " ^ message ^ "\n");
            TextIO.flushOut TextIO.stdErr;
            Guard.critical
              (mutex,
               fn () =>
                 let
                   val pending = !commands
                 in
                   commands := [];
                   closed := true;
                   List.app
                     (fn Command {reply, ...} =>
                        settleError
                          (reply,
                           ConvexError.simple
                             ("TransportError", "Live owner stopped unexpectedly")))
                     pending;
                   Thread.ConditionVar.broadcast signal
                 end)
          end
    in
      Thread.Thread.fork (body, [])
    end

  fun newManager (url, version) =
    let
      val manager =
        Manager
          {url = url, version = version,
           mutex = Thread.Mutex.mutex (),
           signal = Thread.ConditionVar.conditionVar (),
           commands = ref [], subscriptions = ref [],
           nextQueryId = ref 0, activeBytes = ref 0,
           deliveries = ref [], deliveryBytes = ref 0,
           closed = ref false, connectionCount = ref 0,
           lastCloseReason = ref "InitialConnect",
           maxObservedTimestamp = ref 0, generation = ref 0}
    in
      ignore (startOwner manager);
      manager
    end

  (* ---- caller-facing operations -------------------------------------- *)

  fun subscribe (manager, path, args) =
    case awaitReply
           (enqueueCommand
              (manager, SubscribeKind, NONE, SOME (path, args), subscribeBudgetSeconds),
            subscribeSeconds, "subscribe") of
        Started target => target
      | _ => ConvexError.fail ("ProtocolError", "Live subscribe returned an unexpected result")

  fun unsubscribe (target, seconds) =
    if not (isActive target) then ()
    else
      ignore
        (awaitReply
           (enqueueCommand (managerOf target, UnsubscribeKind, SOME target, NONE, seconds),
            seconds, "unsubscribe"))

  fun debugDisconnect (manager, seconds) =
    case awaitReply
           (enqueueCommand (manager, DisconnectKind, NONE, NONE, seconds), seconds, "disconnect") of
        Generation value => value
      | _ => ConvexError.fail ("ProtocolError", "Live disconnect returned an unexpected result")

  fun close (manager, seconds) =
    ignore
      (awaitReply (enqueueCommand (manager, CloseKind, NONE, NONE, seconds), seconds, "close"))
end
