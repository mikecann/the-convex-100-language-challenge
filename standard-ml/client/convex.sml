(* The public client.
   Everything a program written against this demonstration touches lives here:
   configuration, the three HTTP call shapes, Live subscriptions, and cleanup.
   HTTP and Live deliberately share one structure so an example or an adapter
   cannot accidentally exercise two different implementations. *)

structure Convex =
struct
  type result = {value: Json.value, logs: string list}

  type update = Live.update
  type subscription = Live.subscription

  datatype client =
    Client of
      {url: Url.t,
       version: string,
       mutex: Thread.Mutex.mutex,
       authToken: string ref,
       closed: bool ref,
       live: Live.manager option ref}

  (* TCP connect and the TLS handshake share this budget. It is deliberately
     short: a peer that accepts a connection and then says nothing must not be
     able to hold a caller for OpenSSL's own default. *)
  val connectSeconds = 2.0
  val requestSeconds = 12.0

  fun reject message = ConvexError.fail ("ProtocolError", message)

  fun validPath path =
    String.size path > 2 andalso Text.contains (path, #":") andalso Text.headerSafe path

  fun make {url, authToken, version} =
    let
      val _ =
        if Text.headerSafe authToken then ()
        else reject "auth token must not contain a newline"
      val _ =
        if version <> "" andalso Text.headerSafe version then ()
        else reject "client version must be a non-empty single-line string"
    in
      Client
        {url = Url.parse url, version = version,
         mutex = Thread.Mutex.mutex (), authToken = ref authToken,
         closed = ref false, live = ref NONE}
    end

  (* A convenience wrapper so callers do not repeat the defaults. *)
  fun client url = make {url = url, authToken = "", version = "standard-ml-0.1.0"}

  fun setAuth (Client {mutex, authToken, closed, ...}, token) =
    (if Text.headerSafe token then () else reject "auth token must not contain a newline";
     Guard.critical
       (mutex,
        fn () =>
          if !closed then ConvexError.fail ("ClosedError", "client is closed")
          else authToken := token))

  fun tokenSnapshot (Client {mutex, authToken, closed, ...}) =
    Guard.critical
      (mutex,
       fn () =>
         if !closed then ConvexError.fail ("ClosedError", "client is closed") else !authToken)

  (* ---- HTTP ---------------------------------------------------------- *)

  fun call (client as Client {url, version, ...}, operation, path, args) : result =
    let
      val _ = if validPath path then () else reject "function path must be module:function"
      val _ = if Json.isObject args then () else reject "arguments must be a named JSON object"
      val token = tokenSnapshot client
      val body =
        Json.encode
          (Json.Object
             [("path", Json.String path), ("args", args), ("format", Json.String "json")])
      val response =
        Http.call
          {url = url, path = "/api/" ^ operation, body = body, token = token,
           version = version, connectDeadline = Clock.deadlineIn connectSeconds,
           deadline = Clock.deadlineIn requestSeconds}
        handle ConvexError.Error failure => raise ConvexError.Error failure
             | failure =>
                 ConvexError.fail
                   ("TransportError",
                    operation ^ " transport failed: " ^ ConvexError.describe failure)
      val payload =
        Json.decode (#body response)
        handle _ =>
          ConvexError.fail
            ("TransportError",
             "HTTP " ^ Int.toString (#status response) ^ " returned non-Convex JSON")
      val logs =
        Json.stringList (Json.getOr (payload, "logLines", Json.Array []))
        handle _ =>
          ConvexError.fail ("ProtocolError", "Convex logLines must be an array of strings")
      val status = Json.asString (Json.getOr (payload, "status", Json.Null))
    in
      case status of
          SOME "success" =>
            if Json.has (payload, "value") then
              {value = Json.getOr (payload, "value", Json.Null), logs = logs}
            else
              ConvexError.fail ("ProtocolError", "Convex success response has no value")
        | SOME "error" =>
            raise ConvexError.Error
              (ConvexError.make
                 {name = "FunctionError",
                  message =
                    (case Json.asString (Json.getOr (payload, "errorMessage", Json.Null)) of
                         SOME text => text
                       | NONE => "Convex function failed"),
                  data = Json.getOr (payload, "errorData", Json.Null),
                  logs = logs,
                  operation = SOME operation})
        | _ =>
            raise ConvexError.Error
              (ConvexError.make
                 {name = "ProtocolError",
                  message =
                    "HTTP " ^ Int.toString (#status response) ^ " response has an unknown status",
                  data = Json.Null, logs = logs, operation = SOME operation})
    end

  fun query (client, path, args) = call (client, "query", path, args)

  fun mutation (client, path, args) = call (client, "mutation", path, args)

  fun action (client, path, args) = call (client, "action", path, args)

  (* ---- Live ---------------------------------------------------------- *)

  fun ensureLive (Client {url, version, mutex, closed, live, ...}) =
    Guard.critical
      (mutex,
       fn () =>
         if !closed then ConvexError.fail ("ClosedError", "client is closed")
         else
           case !live of
               SOME manager => manager
             | NONE =>
                 let
                   val manager = Live.newManager (url, version)
                 in
                   live := SOME manager;
                   manager
                 end)

  fun subscribe (client, path, args) =
    let
      val _ = if validPath path then () else reject "function path must be module:function"
      val _ = if Json.isObject args then () else reject "arguments must be a named JSON object"
    in
      Live.subscribe (ensureLive client, path, args)
    end

  (* Blocks for at most `seconds`; NONE means nothing arrived in time or the
     subscription has ended. *)
  fun next (subscription, seconds) = Live.next (subscription, seconds)

  fun unsubscribe subscription = Live.unsubscribe (subscription, 5.0)

  fun updateValue ({value, ...} : update) = value
  fun updateLogs ({logs, ...} : update) = logs
  fun updateError ({error, ...} : update) = error

  fun close (Client {mutex, closed, live, ...}) =
    let
      val manager =
        Guard.critical
          (mutex,
           fn () =>
             let
               val already = !closed
             in
               closed := true;
               if already then NONE else !live
             end)
    in
      case manager of
          SOME item => Live.close (item, 5.0)
        | NONE => ()
    end

  (* Test-only reach-through.
     debugDisconnect exists so the shared conformance controller can prove five
     real reconnects; it is not part of the client the demonstration teaches,
     which is why it is not in the surface above. *)
  structure Internal =
  struct
    fun debugDisconnect (Client {mutex, closed, live, ...}, seconds) =
      let
        val manager =
          Guard.critical
            (mutex,
             fn () =>
               if !closed then ConvexError.fail ("ClosedError", "client is closed") else !live)
      in
        case manager of
            SOME item => Live.debugDisconnect (item, seconds)
          | NONE => ConvexError.fail ("ProtocolError", "Live WebSocket has not been started")
      end

    (* The owner-published transport generation. The adapter re-checks this
       after dequeuing so a value produced by a retired socket is dropped. *)
    fun liveGeneration (Client {mutex, live, ...}) =
      let
        val manager = Guard.critical (mutex, fn () => !live)
      in
        case manager of SOME item => Live.generationOf item | NONE => 0
      end

    fun updateGeneration ({generation, ...} : update) = generation
  end
end
