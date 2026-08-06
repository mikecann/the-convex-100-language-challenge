(* Test-only conformance executable.

   This is infrastructure for the shared black-box controller, not client code.
   It speaks NDJSON adapter protocol v1: stdout carries protocol events and
   nothing else, diagnostics go to stderr, and every operation calls the real
   Standard ML client. It also supports the TCP mode the shared harness uses.

   Two properties are load-bearing:

   * Output is bounded. A controller that stops reading must not be able to grow
     this process past the shared 128 MiB limit, so encoded events are charged
     to a queue that includes a write already in flight.
   * Publication is ordered. Acknowledgements and subscription events share one
     publication lock and a per-identifier generation, so a value dequeued
     before a replacement, unsubscribe, or reconnect barrier is dropped rather
     than delivered late. *)

structure Adapter =
struct
  val protocolVersion = 1
  val languageId = "standard-ml"
  (* Both strings are derived from the compiler actually in use, so the hello
     response can never disagree with the toolchain that built this binary.
     Poly/ML reports a value like "5.7.1 Release". *)
  val runtimeVersion = "Poly/ML " ^ PolyML.Compiler.compilerVersion
  val implementation =
    "native-poly-ml-"
    ^ (case String.tokens Char.isSpace PolyML.Compiler.compilerVersion of
           first :: _ => first
         | [] => "unknown")

  val lineLimit = 2 * 1024 * 1024
  val outputCountLimit = 16
  val outputByteLimit = 6 * 1024 * 1024

  fun adapterFail message = ConvexError.fail ("ProtocolError", message)

  fun describe exn =
    case exn of
        ConvexError.Error {message, ...} => message
      | _ => ConvexError.describe exn

  fun failureOf exn =
    case exn of
        ConvexError.Error record => record
      | Transport.Timeout =>
          ConvexError.simple ("TransportError", "adapter transport passed its deadline")
      | _ => ConvexError.simple ("ProtocolError", describe exn)

  fun note text =
    (TextIO.output (TextIO.stdErr, text ^ "\n"); TextIO.flushOut TextIO.stdErr)

  (* ---- events -------------------------------------------------------- *)

  fun optional (key, value) =
    case value of SOME text => [(key, Json.String text)] | NONE => []

  fun logsField logs =
    if List.null logs then [] else [("logs", Json.Array (List.map Json.String logs))]

  (* An absent identifier or absent logs are omitted, never serialised as null:
     the shared schema validates every emitted event strictly. *)
  fun errorEvent (failure : ConvexError.t, id, subscriptionId) =
    Json.Object
      ([("type", Json.String (if Option.isSome subscriptionId then "subscription" else "error"))]
       @ optional ("id", id)
       @ optional ("subscriptionId", subscriptionId)
       @ [("error",
           Json.Object
             [("name", Json.String (#name failure)),
              ("message", Json.String (#message failure)),
              ("data", #data failure)])]
       @ logsField (#logs failure))

  fun relayEvent (subscriptionId, update) =
    case Convex.updateError update of
        SOME failure => errorEvent (failure, NONE, SOME subscriptionId)
      | NONE =>
          Json.Object
            ([("type", Json.String "subscription"),
              ("subscriptionId", Json.String subscriptionId),
              ("value", Convex.updateValue update)]
             @ logsField (Convex.updateLogs update))

  (* ---- bounded output ------------------------------------------------ *)

  datatype item = Item of {text: string, size: int, droppable: bool}

  datatype sink =
    Sink of
      {emit: string -> unit,
       mutex: Thread.Mutex.mutex,
       cond: Thread.ConditionVar.conditionVar,
       (* Serialising encoding through one lock also bounds the otherwise
          uncharged encoder work to a single event, however many relays publish
          at once. *)
       encoder: Thread.Mutex.mutex,
       queue: item list ref,
       queuedBytes: int ref,
       inFlight: int ref,
       closed: bool ref,
       failed: bool ref,
       finished: Latch.t}

  fun sinkCount (Sink {queue, inFlight, ...}) =
    List.length (!queue) + (if !inFlight > 0 then 1 else 0)

  fun sinkBytes (Sink {queuedBytes, inFlight, ...}) = !queuedBytes + !inFlight

  fun dropFirstDroppable (Sink {queue, queuedBytes, ...}) =
    let
      fun loop (prefix, remaining) =
        case remaining of
            [] => false
          | (item as Item {size, droppable, ...}) :: rest =>
              if droppable then
                (queue := List.revAppend (prefix, rest);
                 queuedBytes := !queuedBytes - size;
                 true)
              else loop (item :: prefix, rest)
    in
      loop ([], !queue)
    end

  fun writerLoop (Sink {emit, mutex, cond, queue, queuedBytes, inFlight, closed,
                        failed, finished, ...}) =
    let
      fun loop () =
        let
          val _ = Thread.Mutex.lock mutex
          fun wait () =
            if List.null (!queue) andalso not (!closed) then
              (Thread.ConditionVar.wait (cond, mutex); wait ())
            else ()
          val _ = wait ()
        in
          case !queue of
              [] => (Thread.Mutex.unlock mutex; ())
            | Item {text, size, ...} :: rest =>
                (queue := rest;
                 queuedBytes := !queuedBytes - size;
                 (* The charge stays with the event while the write is in
                    flight, so a kernel-blocked writer cannot hide memory. *)
                 inFlight := size;
                 Thread.Mutex.unlock mutex;
                 emit text;
                 Guard.critical
                   (mutex,
                    fn () => (inFlight := 0; Thread.ConditionVar.broadcast cond));
                 loop ())
        end
    in
      (loop ()
       handle exn =>
         (note ("adapter output failed: " ^ describe exn);
          Guard.critical
            (mutex,
             fn () =>
               (inFlight := 0; failed := true; closed := true;
                Thread.ConditionVar.broadcast cond))));
      Latch.release finished
    end

  fun newSink emit =
    let
      val sink =
        Sink
          {emit = emit, mutex = Thread.Mutex.mutex (),
           cond = Thread.ConditionVar.conditionVar (),
           encoder = Thread.Mutex.mutex (),
           queue = ref [], queuedBytes = ref 0, inFlight = ref 0,
           closed = ref false, failed = ref false, finished = Latch.new ()}
    in
      ignore (Thread.Thread.fork (fn () => writerLoop sink, []));
      sink
    end

  (* A sink with no writer thread. The deterministic budget test drives the real
     queue without anything draining it. *)
  fun newStoppedSink () =
    Sink
      {emit = fn _ => (), mutex = Thread.Mutex.mutex (),
       cond = Thread.ConditionVar.conditionVar (),
       encoder = Thread.Mutex.mutex (),
       queue = ref [], queuedBytes = ref 0, inFlight = ref 0,
       closed = ref false, failed = ref false, finished = Latch.new ()}

  (* Returns false when a droppable event was coalesced away under pressure. *)
  fun publish (sink as Sink {mutex, cond, encoder, queue, queuedBytes, closed, failed, ...},
               value, droppable, seconds) =
    let
      val text =
        Guard.critical (encoder, fn () => Json.encode value ^ "\n")
      val size = String.size text
      val deadline = Clock.deadlineIn seconds
      val _ =
        if size > outputByteLimit then
          adapterFail "adapter event exceeds the encoded output budget"
        else ()
      fun fit () =
        if sinkCount sink >= outputCountLimit orelse sinkBytes sink + size > outputByteLimit then
          (if dropFirstDroppable sink then fit ()
           else if droppable then false
           else if Clock.expired deadline then
             adapterFail "adapter output remained backpressured"
           else (Thread.ConditionVar.waitUntil (cond, mutex, deadline); fit ()))
        else true
      val _ = Thread.Mutex.lock mutex
      val accepted =
        (if not (fit ()) then false
         else if !closed orelse !failed then
           (if droppable then false else adapterFail "adapter output is closed")
         else
           (queue := !queue @ [Item {text = text, size = size, droppable = droppable}];
            queuedBytes := !queuedBytes + size;
            Thread.ConditionVar.broadcast cond;
            true))
        handle exn => (Thread.Mutex.unlock mutex; raise exn)
    in
      Thread.Mutex.unlock mutex;
      accepted
    end

  fun closeSink (Sink {mutex, cond, queue, queuedBytes, closed, finished, ...}, drain) =
    (Guard.critical
       (mutex,
        fn () =>
          (if drain then () else (queue := []; queuedBytes := 0);
           closed := true;
           Thread.ConditionVar.broadcast cond));
     ignore (Latch.awaitSeconds (finished, 1.0)))

  (* ---- adapter state -------------------------------------------------- *)

  datatype relay =
    Relay of
      {subscription: Convex.subscription,
       generation: int,
       active: bool ref,
       finished: Latch.t}

  datatype state =
    State of
      {client: Convex.client option ref,
       clientMutex: Thread.Mutex.mutex,
       publication: Thread.Mutex.mutex,
       (* Only one relay may hold a dequeued value before it has been charged to
          the encoded output queue. Without this, many relays could each retain
          a near-maximum update that nothing has accounted for. *)
       dequeue: Thread.Mutex.mutex,
       relays: (string * relay) list ref,
       generations: (string * int) list ref,
       minimumGeneration: int ref,
       sink: sink,
       closed: bool ref,
       hello: bool ref}

  (* Replaced by the deterministic relay test to stop a relay in the exact
     window after dequeue and before the publication lock. The production
     entrypoint never assigns it. *)
  val afterDequeueHook : (string * relay * Convex.update -> unit) ref = ref (fn _ => ())

  fun newState sink =
    State
      {client = ref NONE, clientMutex = Thread.Mutex.mutex (),
       publication = Thread.Mutex.mutex (), dequeue = Thread.Mutex.mutex (),
       relays = ref [], generations = ref [], minimumGeneration = ref 0,
       sink = sink, closed = ref false, hello = ref false}

  fun ensureClient (State {client, clientMutex, ...}) =
    Guard.critical
      (clientMutex,
       fn () =>
         case !client of
             SOME existing => existing
           | NONE =>
               let
                 val url =
                   case OS.Process.getEnv "CONVEX_URL" of
                       SOME text => if text = "" then adapterFail "CONVEX_URL is required" else text
                     | NONE => adapterFail "CONVEX_URL is required"
                 val token =
                   case OS.Process.getEnv "CONVEX_AUTH_TOKEN" of SOME text => text | NONE => ""
                 val fresh =
                   Convex.make
                     {url = url, authToken = token, version = "standard-ml-0.1.0"}
               in
                 client := SOME fresh;
                 fresh
               end)

  fun currentGeneration (State {generations, ...}, subscriptionId) =
    case List.find (fn (key, _) => key = subscriptionId) (!generations) of
        SOME (_, value) => value
      | NONE => ~1

  fun bumpGeneration (State {generations, ...}, subscriptionId) =
    let
      val next =
        case List.find (fn (key, _) => key = subscriptionId) (!generations) of
            SOME (_, value) => value + 1
          | NONE => 1
    in
      generations :=
        (subscriptionId, next)
        :: List.filter (fn (key, _) => key <> subscriptionId) (!generations);
      next
    end

  fun withPublication (State {publication, ...}, body) = Guard.critical (publication, body)

  fun takeRelay (state as State {relays, ...}, subscriptionId) =
    withPublication
      (state,
       fn () =>
         let
           val found =
             Option.map #2 (List.find (fn (key, _) => key = subscriptionId) (!relays))
         in
           ignore (bumpGeneration (state, subscriptionId));
           (case found of SOME (Relay {active, ...}) => active := false | NONE => ());
           relays := List.filter (fn (key, _) => key <> subscriptionId) (!relays);
           found
         end)

  (* Never called while the publication lock is held: the relay itself needs
     that lock to finish its current iteration. *)
  fun stopRelay (relay, closeSubscription) =
    case relay of
        NONE => ()
      | SOME (Relay {subscription, active, finished, ...}) =>
          (active := false;
           (* The owner acknowledgement inside the client is the transport
              barrier; a partial Remove write retires the socket before this
              returns. *)
           if closeSubscription then
             (Live.unsubscribe (subscription, 6.0) handle _ => ())
           else ();
           ignore (Latch.awaitSeconds (finished, 1.0)))

  fun relayLoop (state as State {sink, dequeue, closed, minimumGeneration, client, ...},
                 subscriptionId, relay as Relay {subscription, generation, active, finished}) =
    let
      fun step () =
        Guard.critical
          (dequeue,
           fn () =>
             case Convex.next (subscription, 0.05) of
                 NONE => ()
               | SOME update =>
                   ((!afterDequeueHook) (subscriptionId, relay, update);
                    (* Re-check both the adapter generation and the client's own
                       transport generation under the publication lock. That
                       closes the replacement, unsubscribe, and reconnect races
                       that open after a value has been dequeued. *)
                    withPublication
                      (state,
                       fn () =>
                         let
                           val live =
                             case !client of
                                 SOME item => Convex.Internal.liveGeneration item
                               | NONE => 0
                         in
                           if !active
                              andalso currentGeneration (state, subscriptionId) = generation
                              andalso Convex.Internal.updateGeneration update
                                       >= Int.max (!minimumGeneration, live) then
                             ignore
                               (publish (sink, relayEvent (subscriptionId, update), true, 5.0))
                           else ()
                         end)))
      fun loop () =
        if not (!active) orelse !closed then ()
        else (step (); loop ())
    in
      (loop () handle exn => note ("adapter relay stopped: " ^ describe exn));
      Latch.release finished
    end

  fun startRelay (state, subscriptionId, relay) =
    ignore (Thread.Thread.fork (fn () => relayLoop (state, subscriptionId, relay), []))

  fun respond (state as State {sink, ...}, value) =
    withPublication (state, fn () => ignore (publish (sink, value, false, 5.0)))

  (* ---- command validation --------------------------------------------- *)

  fun shortString value =
    case Json.asString value of
        SOME text =>
          if String.size text >= 1 andalso String.size text <= 128 then SOME text else NONE
      | NONE => NONE

  fun commandId command = shortString (Json.getOr (command, "id", Json.Null))

  fun subscriptionIdOf command =
    case shortString (Json.getOr (command, "subscriptionId", Json.Null)) of
        SOME text => text
      | NONE => adapterFail "subscriptionId must contain 1 to 128 characters"

  (* The shared schema rejects unknown and duplicate fields, so the adapter
     rejects them too rather than discovering the mismatch in black-box
     conformance. *)
  fun validateShape (command, operation) =
    let
      val (allowed, required) =
        if operation = "hello" then
          (["protocolVersion", "id", "op"], ["protocolVersion", "id", "op"])
        else if operation = "query" orelse operation = "mutation" orelse operation = "action" then
          (["id", "op", "path", "args"], ["id", "op", "path", "args"])
        else if operation = "subscribe" orelse operation = "unsubscribe" then
          (["id", "op", "subscriptionId", "path", "args"], ["id", "op", "subscriptionId"])
        else if operation = "setAuth" then (["id", "op", "token"], ["id", "op", "token"])
        else if operation = "close" orelse operation = "debugDisconnect" then
          (["id", "op"], ["id", "op"])
        else adapterFail "unknown adapter operation"
      val entries =
        case Json.asEntries command of
            SOME items => items
          | NONE => adapterFail "adapter command must be an object"
      fun check (seen, []) = ()
        | check (seen, (key, _) :: rest) =
            (if List.exists (fn name => name = key) allowed then ()
             else adapterFail ("adapter command contains an unknown field " ^ key);
             if List.exists (fn name => name = key) seen then
               adapterFail ("adapter command contains a duplicate field " ^ key)
             else ();
             check (key :: seen, rest))
      val _ = check ([], entries)
      val _ =
        List.app
          (fn key =>
             if Json.has (command, key) then ()
             else adapterFail ("adapter command is missing the required field " ^ key))
          required
      val _ =
        if Json.has (command, "args")
           andalso not (Json.isObject (Json.getOr (command, "args", Json.Null))) then
          adapterFail "args must be a JSON object"
        else ()
      val pathText = Option.mapPartial Json.asString (Json.get (command, "path"))
      val _ =
        if Json.has (command, "path") andalso not (Option.isSome pathText) then
          adapterFail "path must be a string"
        else ()
    in
      if (operation = "query" orelse operation = "mutation" orelse operation = "action")
         andalso String.size (Option.getOpt (pathText, "")) < 3 then
        adapterFail "path must contain at least three characters"
      else ()
    end

  (* ---- commands -------------------------------------------------------- *)

  fun runCall (state, command, id, operation) =
    let
      val client = ensureClient state
      val path = Option.getOpt (Option.mapPartial Json.asString (Json.get (command, "path")), "")
      val args = Json.getOr (command, "args", Json.Object [])
      val {value, logs} =
        if operation = "query" then Convex.query (client, path, args)
        else if operation = "mutation" then Convex.mutation (client, path, args)
        else Convex.action (client, path, args)
    in
      respond
        (state,
         Json.Object
           ([("id", Json.String id), ("type", Json.String "result"), ("value", value)]
            @ logsField logs))
    end

  fun handleCommand (state as State {sink, relays, minimumGeneration, closed, hello, client, ...},
                     command) =
    let
      val _ =
        if Json.isObject command then () else adapterFail "adapter command must be an object"
      val id =
        case commandId command of
            SOME text => text
          | NONE => adapterFail "adapter command requires a non-empty id"
      val operation =
        case Json.asString (Json.getOr (command, "op", Json.Null)) of
            SOME text => text
          | NONE => adapterFail "adapter command requires op"
      val _ =
        if !hello orelse operation = "hello" then ()
        else adapterFail "hello must be the first adapter command"
    in
      (validateShape (command, operation);
       if operation = "hello" then
         (if !hello then adapterFail "hello may only be sent once" else ();
          if Json.asInt (Json.getOr (command, "protocolVersion", Json.Null))
             = SOME (IntInf.fromInt protocolVersion) then ()
          else adapterFail "unsupported adapter protocol version";
          hello := true;
          respond
            (state,
             Json.Object
               [("protocolVersion", Json.Int (IntInf.fromInt protocolVersion)),
                ("id", Json.String id),
                ("type", Json.String "ready"),
                ("language", Json.String languageId),
                ("implementation", Json.String implementation),
                ("runtime", Json.String runtimeVersion)]))
       else if operation = "query" orelse operation = "mutation" orelse operation = "action" then
         runCall (state, command, id, operation)
       else if operation = "setAuth" then
         (case Json.asString (Json.getOr (command, "token", Json.Null)) of
              SOME token =>
                (Convex.setAuth (ensureClient state, token);
                 respond (state, Json.Object [("id", Json.String id), ("type", Json.String "ack")]))
            | NONE => adapterFail "token must be a string")
       else if operation = "subscribe" then
         let
           val subscriptionId = subscriptionIdOf command
           val old = takeRelay (state, subscriptionId)
           val _ = stopRelay (old, true)
           val subscription =
             Convex.subscribe
               (ensureClient state,
                Option.getOpt (Option.mapPartial Json.asString (Json.get (command, "path")), ""),
                Json.getOr (command, "args", Json.Object []))
           (* Registration and the acknowledgement are one publication
              transaction, and the relay only starts afterwards, so an
              already-hydrated value cannot overtake the acknowledgement. *)
           val relay =
             withPublication
               (state,
                fn () =>
                  let
                    val generation = bumpGeneration (state, subscriptionId)
                    val relay =
                      Relay
                        {subscription = subscription, generation = generation,
                         active = ref true, finished = Latch.new ()}
                  in
                    relays := (subscriptionId, relay) :: !relays;
                    ignore
                      (publish
                         (sink,
                          Json.Object [("id", Json.String id), ("type", Json.String "ack")],
                          false, 5.0));
                    relay
                  end)
         in
           startRelay (state, subscriptionId, relay)
         end
       else if operation = "unsubscribe" then
         let
           val subscriptionId = subscriptionIdOf command
         in
           stopRelay (takeRelay (state, subscriptionId), true);
           respond (state, Json.Object [("id", Json.String id), ("type", Json.String "ack")])
         end
       else if operation = "debugDisconnect" then
         (* The publication lock is held across the owner barrier. A relay that
            already dequeued an old value can only resume after the new minimum
            generation and the acknowledgement are published, at which point it
            drops that value. *)
         withPublication
           (state,
            fn () =>
              let
                val generation = Convex.Internal.debugDisconnect (ensureClient state, 6.0)
              in
                minimumGeneration := generation;
                ignore
                  (publish
                     (sink, Json.Object [("id", Json.String id), ("type", Json.String "ack")],
                      false, 5.0))
              end)
       else if operation = "close" then
         (closed := true;
          respond (state, Json.Object [("id", Json.String id), ("type", Json.String "closed")]))
       else adapterFail "unknown adapter operation")
      handle exn => respond (state, errorEvent (failureOf exn, SOME id, NONE))
    end

  fun cleanup (state as State {relays, client, closed, clientMutex, ...}) =
    let
      val stopped =
        withPublication
          (state,
           fn () =>
             let
               val current = !relays
             in
               closed := true;
               List.app
                 (fn (subscriptionId, Relay {active, ...}) =>
                    (ignore (bumpGeneration (state, subscriptionId)); active := false))
                 current;
               relays := [];
               current
             end)
    in
      (* Closing the one client retires the one Live owner and every
         subscription in a single bounded operation. *)
      (case Guard.critical (clientMutex, fn () => !client) of
           SOME item => (Convex.close item handle _ => ())
         | NONE => ());
      List.app
        (fn (_, Relay {finished, ...}) => ignore (Latch.awaitSeconds (finished, 1.0)))
        stopped
    end

  (* ---- line handling ---------------------------------------------------- *)

  fun processLine (state, rawLine) =
    let
      val line =
        if String.size rawLine > 0
           andalso String.sub (rawLine, String.size rawLine - 1) = #"\r" then
          String.substring (rawLine, 0, String.size rawLine - 1)
        else rawLine
      val _ = if line = "" then adapterFail "adapter command line must not be empty" else ()
      val _ =
        if Text.utf8Valid line then () else adapterFail "adapter command is not valid UTF-8"
    in
      handleCommand (state, Json.decode line)
    end
    handle exn => respond (state, errorEvent (failureOf exn, NONE, NONE))

  (* Reads NDJSON one byte at a time so an overlong line can be drained exactly
     once instead of buffered. *)
  fun runLoop (readByte, emit) =
    let
      val sink = newSink emit
      val state = newState sink
      val State {closed, ...} = state
      fun loop (buffer, count, discarding) =
        if !closed then ()
        else
          case readByte () of
              NONE =>
                if not discarding andalso count > 0 then
                  respond
                    (state,
                     errorEvent
                       (ConvexError.simple
                          ("ProtocolError", "adapter command must end with a newline"),
                        NONE, NONE))
                else ()
            | SOME #"\n" =>
                (if discarding then () else processLine (state, Buffer.contents buffer);
                 loop (Buffer.new (), 0, false))
            | SOME character =>
                if discarding then loop (buffer, count, true)
                else if count >= lineLimit then
                  (respond
                     (state,
                      errorEvent
                        (ConvexError.simple ("ProtocolError", "adapter command exceeds 2 MiB"),
                         NONE, NONE));
                   loop (Buffer.new (), 0, true))
                else (Buffer.addChar (buffer, character); loop (buffer, count + 1, false))
    in
      (loop (Buffer.new (), 0, false)
       handle exn => note ("adapter failed: " ^ describe exn));
      cleanup state;
      closeSink (sink, true)
    end

  (* ---- entry points ------------------------------------------------------ *)

  fun standardStreams () =
    (fn () => TextIO.input1 TextIO.stdIn,
     fn text => (TextIO.output (TextIO.stdOut, text); TextIO.flushOut TextIO.stdOut))

  fun parseListen text =
    case Text.lastIndex (text, #":") of
        NONE => adapterFail "ADAPTER_LISTEN must be host:port"
      | SOME index =>
          let
            val host = String.substring (text, 0, index)
            val port = Int.fromString (String.extract (text, index + 1, NONE))
          in
            case port of
                SOME value =>
                  if host <> "" andalso value >= 1 andalso value <= 65535 then (host, value)
                  else adapterFail "ADAPTER_LISTEN must contain a valid host and port"
              | NONE => adapterFail "ADAPTER_LISTEN must contain a valid host and port"
          end

  fun serveTcp listen =
    let
      val (host, port) = parseListen listen
      val listener = INetSock.TCP.socket ()
      val _ = Socket.Ctl.setREUSEADDR (listener, true)
      val _ = Socket.bind (listener, INetSock.toAddr (Transport.resolve host, port))
      val _ = Socket.listen (listener, 1)
      val _ = note ("adapter listening on " ^ listen)
      val (accepted, _) = Socket.accept listener
      val _ = Socket.close listener
      val channel = Transport.ofSocket accepted
      val reader = Reader.new channel
      (* The shared controller owns the pace of this connection, so reads wait
         indefinitely while writes stay bounded. *)
      fun readByte () = Reader.byte (reader, Clock.deadlineIn 3600.0)
      fun emit text = Transport.writeAll (channel, text, Clock.deadlineIn 0.5)
    in
      runLoop (readByte, emit);
      (* Do not linger on a controller that has already gone away. *)
      Transport.close channel
    end

  (* Runtime audit hook: the real bounded writer is exercised while the caller
     deliberately never reads stdout. *)
  fun floodTest () =
    let
      val sink = newSink (fn text => (TextIO.output (TextIO.stdOut, text);
                                      TextIO.flushOut TextIO.stdOut))
      val large = CharVector.tabulate (350000, fn _ => #"x")
      fun loop index =
        if index >= 40 then ()
        else
          (ignore
             (publish
                (sink,
                 Json.Object
                   [("type", Json.String "subscription"),
                    ("subscriptionId", Json.String "memory"),
                    ("value",
                     Json.Object
                       [("index", Json.Int (IntInf.fromInt index)), ("text", Json.String large)])],
                 true, 5.0));
           loop (index + 1))
    in
      loop 0;
      note "adapter flood queue ready";
      Clock.sleep 3.0;
      closeSink (sink, false)
    end

  fun main () =
    (case OS.Process.getEnv "ADAPTER_FLOOD_TEST" of
         SOME _ => floodTest ()
       | NONE =>
           (case OS.Process.getEnv "ADAPTER_LISTEN" of
                SOME listen => if listen = "" then runLoop (standardStreams ()) else serveTcp listen
              | NONE => runLoop (standardStreams ())))
    handle exn =>
      (note ("adapter failed: " ^ describe exn); OS.Process.exit OS.Process.failure)
end
