namespace Convex

open System
open System.Collections.Generic
open System.Buffers.Binary
open System.Globalization
open System.Net.Http
open System.Net.WebSockets
open System.Text
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks

exception FunctionError of operation: string * message: string * data: JsonNode option * logs: string list
exception TransportError of operation: string * message: string
exception ProtocolError of message: string

type Result =
    { Value: JsonNode option
      Logs: string list }

module private Json =
    [<Literal>]
    let MaximumHttpBytes = 8 * 1024 * 1024

    type StateVersion =
        { QuerySet: uint32
          Identity: uint32
          Timestamp: string
          TimestampValue: uint64 }

    let strings (node: JsonNode) =
        match node with
        | :? JsonArray as values ->
            [ for value in values do
                  if isNull value then
                      raise (ProtocolError "Live logLines contained null")

                  try
                      yield value.GetValue<string>()
                  with _ ->
                      raise (ProtocolError "Live logLines must contain only strings") ]
        | _ -> raise (ProtocolError "Live logLines must be an array")

    let private versionCounter (version: JsonObject) field label =
        if not (version.ContainsKey field) || isNull version[field] then
            raise (ProtocolError(sprintf "%s omitted integer %s" label field))

        let encoded = version[field].ToJsonString()

        match UInt32.TryParse(encoded, NumberStyles.None, CultureInfo.InvariantCulture) with
        | true, value -> value
        | _ -> raise (ProtocolError(sprintf "%s has invalid %s" label field))

    let private timestamp (value: JsonNode) label =
        if isNull value then
            raise (ProtocolError(sprintf "%s omitted string ts" label))

        let encoded =
            try
                value.GetValue<string>()
            with _ ->
                raise (ProtocolError(sprintf "%s omitted string ts" label))

        let decoded =
            try
                Convert.FromBase64String encoded
            with :? FormatException ->
                raise (ProtocolError(sprintf "%s ts is not valid base64" label))

        if decoded.Length <> 8 then
            raise (ProtocolError(sprintf "%s ts must encode exactly eight bytes" label))

        if Convert.ToBase64String(decoded) <> encoded then
            raise (ProtocolError(sprintf "%s ts is not canonical base64" label))

        encoded, BinaryPrimitives.ReadUInt64LittleEndian decoded

    let stateVersion (node: JsonNode) label =
        let version =
            match node with
            | :? JsonObject as value -> value
            | _ -> raise (ProtocolError(sprintf "%s must be an object" label))

        let encodedTimestamp, timestampValue = timestamp version["ts"] label

        { QuerySet = versionCounter version "querySet" label
          Identity = versionCounter version "identity" label
          Timestamp = encodedTimestamp
          TimestampValue = timestampValue }

    let zeroVersion () =
        { QuerySet = 0u
          Identity = 0u
          Timestamp = "AAAAAAAAAAA="
          TimestampValue = 0UL }

    let rec semanticallyEqual (left: JsonNode) (right: JsonNode) =
        if isNull left || isNull right then
            isNull left && isNull right
        else
            match left, right with
            | (:? JsonObject as leftObject), (:? JsonObject as rightObject) ->
                leftObject.Count = rightObject.Count
                && (leftObject
                    |> Seq.forall (fun pair ->
                        rightObject.ContainsKey pair.Key
                        && semanticallyEqual pair.Value rightObject[pair.Key]))
            | (:? JsonArray as leftArray), (:? JsonArray as rightArray) ->
                leftArray.Count = rightArray.Count
                && Seq.forall2 semanticallyEqual leftArray rightArray
            | _ -> JsonNode.DeepEquals(left, right)

    let successfulValuesEqual (left: JsonNode option) (right: JsonNode option) =
        match left, right with
        | None, None -> true
        | Some leftValue, Some rightValue -> semanticallyEqual leftValue rightValue
        | _ -> false

    let readBoundedUtf8 operation (stream: IO.Stream) =
        task {
            let buffer = Array.zeroCreate<byte> 8192
            use collected = new IO.MemoryStream()
            let mutable finished = false

            while not finished do
                let! count = stream.ReadAsync(buffer.AsMemory())

                if count = 0 then
                    finished <- true
                elif collected.Length + int64 count > int64 MaximumHttpBytes then
                    raise (TransportError(operation, sprintf "HTTP response exceeded %d bytes" MaximumHttpBytes))
                else
                    collected.Write(buffer, 0, count)

            try
                return UTF8Encoding(false, true).GetString(collected.ToArray())
            with :? DecoderFallbackException as error ->
                return raise (TransportError(operation, "HTTP response was not valid UTF-8: " + error.Message))
        }

/// Native F# implementation of Convex's JSON HTTP function endpoint.
type Client(deployment: string) =
    let baseUri =
        let value = Uri(deployment.TrimEnd('/'))

        if
            (value.Scheme <> "http" && value.Scheme <> "https")
            || not (String.IsNullOrEmpty value.UserInfo)
        then
            invalidArg "deployment" "Convex URL must be http(s) without user info"

        value

    let http = new HttpClient(Timeout = TimeSpan.FromSeconds 30.)
    let mutable token = ""
    let mutable closed = false

    member _.SetAuth(value: string option) =
        if closed then
            raise (ObjectDisposedException "Client")

        token <- defaultArg value ""

    member private _.Call(operation: string, path: string, args: JsonObject) =
        task {
            if closed then
                raise (ObjectDisposedException "Client")

            if String.IsNullOrWhiteSpace path then
                invalidArg "path" "Convex function path is required"

            let payload = JsonObject()
            payload["path"] <- JsonValue.Create path
            payload["args"] <- args.DeepClone()
            payload["format"] <- JsonValue.Create "json"

            use request =
                new HttpRequestMessage(HttpMethod.Post, Uri(baseUri, "/api/" + operation))

            let encodedPayload = payload.ToJsonString()

            if Encoding.UTF8.GetByteCount encodedPayload > Json.MaximumHttpBytes then
                invalidArg "args" (sprintf "Convex request exceeded %d bytes" Json.MaximumHttpBytes)

            request.Content <- new StringContent(encodedPayload, Encoding.UTF8, "application/json")

            request.Headers.TryAddWithoutValidation("Convex-Client", "fsharp-0.1.0")
            |> ignore

            if token <> "" then
                request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token)
                |> ignore

            let! response =
                task {
                    try
                        return! http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead)
                    with error ->
                        return raise (TransportError(operation, error.Message))
                }

            use! responseStream = response.Content.ReadAsStreamAsync()
            let! body = Json.readBoundedUtf8 operation responseStream

            let decoded =
                try
                    JsonNode.Parse(body).AsObject()
                with error ->
                    raise (TransportError(operation, "non-Convex HTTP response: " + error.Message))

            let logs =
                if isNull decoded["logLines"] then
                    []
                else
                    Json.strings decoded["logLines"]

            if isNull decoded["status"] then
                return raise (ProtocolError "HTTP response omitted status")
            elif decoded["status"].GetValue<string>() = "success" then
                if not (decoded.ContainsKey "value") then
                    raise (ProtocolError "success response omitted value")

                let value =
                    if isNull decoded["value"] then
                        None
                    else
                        Some(decoded["value"].DeepClone())

                return { Value = value; Logs = logs }
            elif decoded["status"].GetValue<string>() = "error" then
                let message =
                    if isNull decoded["errorMessage"] then
                        "Convex function failed"
                    else
                        decoded["errorMessage"].GetValue<string>()

                let data =
                    if isNull decoded["errorData"] then
                        None
                    else
                        Some(decoded["errorData"].DeepClone())

                return raise (FunctionError(operation, message, data, logs))
            else
                return raise (ProtocolError "HTTP response has unknown status")
        }

    member this.Query(path, args) = this.Call("query", path, args)
    member this.Mutation(path, args) = this.Call("mutation", path, args)
    member this.Action(path, args) = this.Call("action", path, args)

    interface IDisposable with
        member _.Dispose() =
            closed <- true
            http.Dispose()

type Update =
    { Value: JsonNode option
      Error: exn option
      Logs: string list }

type internal DeliveryEntry(update: Update, size: int, local: LinkedList<DeliveryEntry>) =
    member _.Update = update
    member _.Size = size
    member _.Local = local
    member val GlobalNode: LinkedListNode<DeliveryEntry> = null with get, set
    member val LocalNode: LinkedListNode<DeliveryEntry> = null with get, set

/// All subscriptions on one Live client share this budget. A slow collection of
/// subscriptions therefore cannot multiply the memory ceiling per query.
type internal DeliveryBudget(maximumCount: int, maximumBytes: int) =
    let sync = obj ()
    let entries = LinkedList<DeliveryEntry>()
    let mutable encodedBytes = 0

    let remove (entry: DeliveryEntry) =
        if not (isNull entry.GlobalNode) then
            entries.Remove entry.GlobalNode
            entry.Local.Remove entry.LocalNode
            encodedBytes <- encodedBytes - entry.Size
            entry.GlobalNode <- null
            entry.LocalNode <- null

    member _.Sync = sync

    member _.Add(local: LinkedList<DeliveryEntry>, update: Update, size: int) =
        while entries.Count > 0
              && (entries.Count >= maximumCount || encodedBytes + size > maximumBytes) do
            remove entries.First.Value

        if size > maximumBytes then
            raise (ProtocolError(sprintf "Live delivery exceeded the global %d-byte budget" maximumBytes))

        let entry = DeliveryEntry(update, size, local)
        entry.GlobalNode <- entries.AddLast entry
        entry.LocalNode <- local.AddLast entry
        encodedBytes <- encodedBytes + size

    member _.Remove(entry: DeliveryEntry) = remove entry

    member _.Clear(local: LinkedList<DeliveryEntry>) =
        while local.Count > 0 do
            remove local.First.Value

    member _.Snapshot = entries.Count, encodedBytes

/// A subscription reads from the one global count-and-byte bounded newest buffer.
type Subscription
    internal (queryId: int, path: string, args: JsonObject, budget: DeliveryBudget, unsubscribe: int -> Task<unit>) =
    let updates = LinkedList<DeliveryEntry>()
    let mutable closed = false
    let mutable suppressEqual: JsonNode option option = None
    let mutable lastValue: JsonNode option option = None
    let mutable lastDeliveryWasError = false

    let encodedSize (update: Update) =
        // Size the complete delivery shape. Function errors can carry large JSON data and
        // logs, so charging every value-less update a token constant would not bound memory.
        let encoded = JsonObject()

        match update.Error with
        | Some error ->
            let detail = JsonObject()

            match error with
            | FunctionError(_, message, data, logs) ->
                detail["name"] <- JsonValue.Create "FunctionError"
                detail["message"] <- JsonValue.Create message

                match data with
                | Some present -> detail["data"] <- present.DeepClone()
                | None -> ()

                encoded["logs"] <-
                    JsonArray(logs |> List.map (fun line -> JsonValue.Create line :> JsonNode) |> List.toArray)
            | TransportError(_, message) ->
                detail["name"] <- JsonValue.Create "TransportError"
                detail["message"] <- JsonValue.Create message
            | ProtocolError message ->
                detail["name"] <- JsonValue.Create "ProtocolError"
                detail["message"] <- JsonValue.Create message
            | _ ->
                detail["name"] <- JsonValue.Create(error.GetType().Name)
                detail["message"] <- JsonValue.Create error.Message

            encoded["error"] <- detail
        | None ->
            match update.Value with
            | Some value -> encoded["value"] <- value.DeepClone()
            | None -> encoded["value"] <- null

            encoded["logs"] <-
                JsonArray(
                    update.Logs
                    |> List.map (fun line -> JsonValue.Create line :> JsonNode)
                    |> List.toArray
                )

        Encoding.UTF8.GetByteCount(encoded.ToJsonString())

    member _.QueryId = queryId
    member _.Path = path
    member _.Args = args

    member internal _.PrepareHydrationDedup() =
        lock budget.Sync (fun () ->
            suppressEqual <-
                if lastDeliveryWasError then
                    None
                else
                    lastValue |> Option.map (Option.map _.DeepClone()))

    member internal _.Offer(update: Update) =
        lock budget.Sync (fun () ->
            if not closed then
                let successfulValue = update.Value |> Option.map _.DeepClone()

                let duplicateHydration =
                    match suppressEqual with
                    | Some previous when update.Error.IsNone -> Json.successfulValuesEqual previous successfulValue
                    | _ -> false

                suppressEqual <- None

                if not duplicateHydration then
                    let size = encodedSize update

                    budget.Add(updates, update, size)

                    if update.Error.IsNone then
                        lastValue <- Some successfulValue
                        lastDeliveryWasError <- false
                    else
                        // An unchanged value after QueryFailed is recovery, not duplicate hydration.
                        lastDeliveryWasError <- true

                    Monitor.PulseAll budget.Sync)

    member internal _.Finish() =
        lock budget.Sync (fun () ->
            closed <- true
            budget.Clear updates
            Monitor.PulseAll budget.Sync)

    member _.NextUpdate(timeout: TimeSpan) =
        lock budget.Sync (fun () ->
            let deadline = DateTime.UtcNow + timeout

            while updates.Count = 0 && not closed do
                let remaining = deadline - DateTime.UtcNow

                if remaining <= TimeSpan.Zero || not (Monitor.Wait(budget.Sync, remaining)) then
                    raise (TimeoutException "timed out waiting for Live update")

            if updates.Count = 0 then
                raise (ObjectDisposedException "Subscription")

            let entry = updates.First.Value
            budget.Remove entry
            entry.Update)

    member this.Next(timeout: TimeSpan) =
        let update = this.NextUpdate timeout

        match update.Error, update.Value with
        | Some error, _ -> raise error
        | None, Some value -> value
        | _ -> null

    interface IDisposable with
        member _.Dispose() =
            let shouldUnsubscribe =
                lock budget.Sync (fun () ->
                    if closed then
                        false
                    else
                        // Invalidate delivery before asking the owner to remove the query.
                        // This is the unsubscribe acknowledgement's local generation barrier.
                        closed <- true
                        budget.Clear updates
                        Monitor.PulseAll budget.Sync
                        true)

            if shouldUnsubscribe then
                unsubscribe queryId |> fun work -> work.GetAwaiter().GetResult()

#if LEGACY_LIVE
// Historical semaphore-coordinated attempt retained as evidence. The compiled owner loop is in OwnerLive.fs.
/// Native implementation of the pinned convex-rs 0.10.4 unversioned sync profile.
/// One serialized gate owns socket replacement, writes, query-set versions, and reconnect decisions.
type private LegacyLiveClient(deployment: string) =
    let endpoint =
        let value = Uri(deployment.TrimEnd('/'))

        UriBuilder(
            value,
            Scheme = (if value.Scheme = "https" then "wss" else "ws"),
            Path = value.AbsolutePath.TrimEnd('/') + "/api/sync"
        )
            .Uri

    let gate = new SemaphoreSlim(1, 1)
    let lifetime = new CancellationTokenSource()
    let subscriptions = Dictionary<int, Subscription>()
    let mutable socket: ClientWebSocket option = None
    let mutable receiveTask: Task option = None
    let mutable nextId = 0
    let mutable querySet = 0
    let mutable connectionCount = 0
    let mutable lastCloseReason = "InitialConnect"
    let mutable maxObservedTimestamp: string option = None
    let mutable version = Json.zeroVersion ()
    let mutable closed = false
    let mutable reconnecting = false
    let mutable reconnectDelay = 100
    let mutable intentionalRecovery = false

    let sendLocked (message: JsonObject) =
        task {
            match socket with
            | None -> return raise (TransportError("live", "socket is not connected"))
            | Some current ->
                use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                timeout.CancelAfter(TimeSpan.FromSeconds 3.)

                try
                    do!
                        current.SendAsync(
                            ArraySegment<byte>(Encoding.UTF8.GetBytes(message.ToJsonString())),
                            WebSocketMessageType.Text,
                            true,
                            timeout.Token
                        )
                with error ->
                    return raise (TransportError("live", error.Message))
        }

    let addMessage (subscription: Subscription) =
        let message = JsonObject()
        message["type"] <- JsonValue.Create "Add"
        message["queryId"] <- JsonValue.Create subscription.QueryId
        message["udfPath"] <- JsonValue.Create subscription.Path
        message["args"] <- JsonArray([| subscription.Args.DeepClone() |])
        message :> JsonNode

    let modifyLocked (modifications: JsonNode array) =
        task {
            let message = JsonObject()
            message["type"] <- JsonValue.Create "ModifyQuerySet"
            message["baseVersion"] <- JsonValue.Create querySet
            message["newVersion"] <- JsonValue.Create(querySet + 1)
            message["modifications"] <- JsonArray(modifications)
            do! sendLocked message
            querySet <- querySet + 1
        }

    let deliverFailure error =
        for subscription in subscriptions.Values do
            subscription.Offer
                { Value = None
                  Error = Some error
                  Logs = [] }

    let rec disconnect (expected: ClientWebSocket option) reason reconnect failure =
        task {
            do! gate.WaitAsync()

            try
                let matches =
                    match expected, socket with
                    | Some wanted, Some current -> Object.ReferenceEquals(wanted, current)
                    | Some _, None -> false
                    | None, _ -> true

                if matches then
                    match failure with
                    | Some error when not intentionalRecovery -> deliverFailure error
                    | _ -> ()

                    match socket with
                    | Some current ->
                        current.Abort()
                        current.Dispose()
                        socket <- None
                        connectionCount <- connectionCount + 1
                    | None -> ()

                    lastCloseReason <- reason
                    querySet <- 0
                    version <- Json.zeroVersion ()

                    if reconnect && subscriptions.Count > 0 && not closed && not reconnecting then
                        reconnecting <- true
                        reconnectLoop () |> ignore
            finally
                gate.Release() |> ignore
        }

    and receiveLoop (owned: ClientWebSocket) =
        task {
            let buffer = Array.zeroCreate<byte> 4096
            use frame = new IO.MemoryStream()
            let mutable running = true
            let mutable failure: exn option = None

            while running && not closed do
                try
                    let! result = owned.ReceiveAsync(ArraySegment<byte>(buffer), lifetime.Token)

                    if result.MessageType = WebSocketMessageType.Close then
                        running <- false
                        failure <- Some(TransportError("live", "Live WebSocket closed unexpectedly"))
                    elif result.MessageType <> WebSocketMessageType.Text then
                        running <- false
                        failure <- Some(ProtocolError "Live server sent a non-text message")
                    else
                        frame.Write(buffer, 0, result.Count)

                        if result.EndOfMessage then
                            let utf8 = UTF8Encoding(false, true)
                            let message = JsonNode.Parse(utf8.GetString(frame.ToArray())).AsObject()
                            frame.SetLength 0
                            do! handleMessage owned message
                with
                | :? OperationCanceledException when closed -> running <- false
                | error ->
                    running <- false
                    failure <- Some error

            if not closed then
                let reason =
                    match failure with
                    | Some(:? ProtocolError) -> "ProtocolError"
                    | _ -> "TransportError"

                do! disconnect (Some owned) reason true failure
        }

    and handleMessage (owned: ClientWebSocket) (message: JsonObject) =
        task {
            if isNull message["type"] then
                return raise (ProtocolError "Live message omitted type")

            match message["type"].GetValue<string>() with
            | "Ping"
            | "MutationResponse"
            | "ActionResponse" -> ()
            | "Transition" ->
                if
                    isNull message["startVersion"]
                    || isNull message["endVersion"]
                    || isNull message["modifications"]
                then
                    return raise (ProtocolError "Live transition omitted required fields")

                let pending = ResizeArray<int * Update>()

                for node in message["modifications"].AsArray() do
                    let modification = node.AsObject()
                    let id = modification["queryId"].GetValue<int>()

                    let logs =
                        if isNull modification["logLines"] then
                            []
                        else
                            Json.strings modification["logLines"]

                    match modification["type"].GetValue<string>() with
                    | "QueryRemoved" -> ()
                    | "QueryUpdated" ->
                        if not (modification.ContainsKey "value") then
                            raise (ProtocolError "QueryUpdated omitted value")

                        let value =
                            if isNull modification["value"] then
                                None
                            else
                                Some(modification["value"].DeepClone())

                        pending.Add(
                            id,
                            { Value = value
                              Error = None
                              Logs = logs }
                        )
                    | "QueryFailed" ->
                        let messageText =
                            if isNull modification["errorMessage"] then
                                "query failed"
                            else
                                modification["errorMessage"].GetValue<string>()

                        let data =
                            if isNull modification["errorData"] then
                                None
                            else
                                Some(modification["errorData"].DeepClone())

                        pending.Add(
                            id,
                            { Value = None
                              Error = Some(FunctionError("query", messageText, data, logs))
                              Logs = logs }
                        )
                    | other -> raise (ProtocolError("unsupported Live modification: " + other))

                do! gate.WaitAsync()

                try
                    match socket with
                    | Some current when Object.ReferenceEquals(current, owned) ->
                        if not (JsonNode.DeepEquals(message["startVersion"], version)) then
                            raise (ProtocolError "Live transition version mismatch")

                        for id, update in pending do
                            match subscriptions.TryGetValue id with
                            | true, subscription -> subscription.Offer update
                            | _ -> ()

                        version <- message["endVersion"].DeepClone().AsObject()

                        maxObservedTimestamp <-
                            if isNull version["ts"] then
                                maxObservedTimestamp
                            else
                                Some(version["ts"].GetValue<string>())

                        reconnectDelay <- 100 // Only valid protocol traffic resets transport backoff.
                        intentionalRecovery <- false
                    | _ -> () // A detached generation can never publish or advance version state.
                finally
                    gate.Release() |> ignore
            | other -> return raise (ProtocolError("unsupported Live message: " + other))
        }

    and connectLocked () =
        task {
            if closed then
                raise (ObjectDisposedException "LiveClient")

            let current = new ClientWebSocket()
            current.Options.SetRequestHeader("Convex-Client", "fsharp-0.1.0")
            use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
            timeout.CancelAfter(TimeSpan.FromSeconds 3.)
            do! current.ConnectAsync(endpoint, timeout.Token)
            socket <- Some current
            querySet <- 0
            version <- Json.zeroVersion ()

            if connectionCount > 0 then
                for subscription in subscriptions.Values do
                    subscription.PrepareHydrationDedup()

            let connect = JsonObject()
            connect["type"] <- JsonValue.Create "Connect"
            connect["sessionId"] <- JsonValue.Create(Guid.NewGuid().ToString())
            connect["connectionCount"] <- JsonValue.Create connectionCount
            connect["lastCloseReason"] <- JsonValue.Create lastCloseReason
            connect["clientTs"] <- JsonValue.Create 0

            match maxObservedTimestamp with
            | Some timestamp -> connect["maxObservedTimestamp"] <- JsonValue.Create timestamp
            | None -> ()

            do! sendLocked connect

            if subscriptions.Count > 0 then
                do! modifyLocked (subscriptions.Values |> Seq.map addMessage |> Seq.toArray)

            let pump = receiveLoop current
            receiveTask <- Some pump
        }

    and reconnectLoop () =
        task {
            let mutable doneConnecting = false

            while not doneConnecting && not closed do
                try
                    do! Task.Delay(reconnectDelay, lifetime.Token)
                    do! gate.WaitAsync(lifetime.Token)

                    try
                        if socket.IsNone && subscriptions.Count > 0 then
                            do! connectLocked ()

                        reconnecting <- false
                        doneConnecting <- true
                    finally
                        gate.Release() |> ignore
                with
                | :? OperationCanceledException -> doneConnecting <- true
                | _ -> reconnectDelay <- min 15000 (reconnectDelay * 2)
        }

    let unsubscribe id =
        task {
            do! gate.WaitAsync()

            try
                match subscriptions.TryGetValue id with
                | true, subscription ->
                    subscriptions.Remove id |> ignore
                    subscription.Finish() // This is the completion barrier observed before adapter acknowledgement.

                    if socket.IsSome then
                        let remove = JsonObject()
                        remove["type"] <- JsonValue.Create "Remove"
                        remove["queryId"] <- JsonValue.Create id
                        do! modifyLocked [| remove :> JsonNode |]
                | _ -> ()
            finally
                gate.Release() |> ignore
        }

    member _.Subscribe(path: string, args: JsonObject) =
        task {
            if String.IsNullOrWhiteSpace path then
                invalidArg "path" "Convex function path is required"

            do! gate.WaitAsync()

            try
                if closed then
                    raise (ObjectDisposedException "LiveClient")

                let subscription =
                    new Subscription(nextId, path, args.DeepClone().AsObject(), unsubscribe)

                nextId <- nextId + 1
                subscriptions.Add(subscription.QueryId, subscription)

                try
                    if socket.IsNone then
                        do! connectLocked ()
                    else
                        do! modifyLocked [| addMessage subscription |]

                    return subscription
                with error ->
                    subscriptions.Remove subscription.QueryId |> ignore
                    subscription.Finish()
                    return raise error
            finally
                gate.Release() |> ignore
        }

    member _.DebugDisconnect() =
        task {
            let mutable stopped: Task option = None
            do! gate.WaitAsync()

            try
                if closed then
                    raise (ObjectDisposedException "LiveClient")

                match socket with
                | None -> invalidOp "Live WebSocket is not connected"
                | Some previous ->
                    socket <- None
                    stopped <- receiveTask
                    receiveTask <- None
                    previous.Abort()
                    previous.Dispose()
                    connectionCount <- connectionCount + 1
                    lastCloseReason <- "DebugDisconnect"
                    querySet <- 0
                    version <- Json.zeroVersion ()
                    intentionalRecovery <- true
            finally
                gate.Release() |> ignore

            match stopped with
            | Some pump ->
                try
                    do! pump.WaitAsync(TimeSpan.FromSeconds 3.)
                with _ ->
                    ()
            | None -> ()

            do! gate.WaitAsync()

            try
                if not closed && subscriptions.Count > 0 && socket.IsNone && not reconnecting then
                    reconnecting <- true
                    reconnectLoop () |> ignore
            finally
                gate.Release() |> ignore
        }

    member _.ConnectionCount = connectionCount
    member _.LastCloseReason = lastCloseReason
    member _.MaxObservedTimestamp = maxObservedTimestamp

    interface IDisposable with
        member _.Dispose() =
            if not closed then
                closed <- true
                lifetime.Cancel()

                match socket with
                | Some current ->
                    current.Abort()
                    current.Dispose()
                | None -> ()

                socket <- None

                for subscription in subscriptions.Values do
                    subscription.Finish()

                subscriptions.Clear()
                gate.Dispose()
                lifetime.Dispose()
#endif
