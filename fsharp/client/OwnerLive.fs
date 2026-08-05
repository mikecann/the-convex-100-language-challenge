namespace Convex

open System
open System.Collections.Generic
open System.Globalization
open System.IO
open System.Net.WebSockets
open System.Text
open System.Text.Json
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks

module internal LiveTestHooks =
    // Tests replace this briefly to prove every explicit socket operation comes
    // through one logical owner. Production leaves it as a no-op.
    let mutable SocketOperation: (int64 * string -> unit) = fun _ -> ()

type private OwnedSocket(ownerId: int64) =
    let socket = new ClientWebSocket()

    let observe operation =
        LiveTestHooks.SocketOperation(ownerId, operation)

    member _.Options = socket.Options

    member _.Connect(endpoint: Uri, cancellation: CancellationToken) =
        observe "Connect"
        socket.ConnectAsync(endpoint, cancellation)

    member _.Send(bytes: byte array, cancellation: CancellationToken) =
        observe "Send"
        socket.SendAsync(ArraySegment<byte> bytes, WebSocketMessageType.Text, true, cancellation)

    member _.Receive(buffer: byte array, cancellation: CancellationToken) =
        observe "Receive"
        socket.ReceiveAsync(ArraySegment<byte> buffer, cancellation)

    member _.AbortAndDispose() =
        observe "Abort"

        try
            socket.Abort()
        with _ ->
            ()

        observe "Dispose"
        socket.Dispose()

type private PendingChange =
    | Publish of Update
    | Removed

type private OwnerCommand =
    | SubscribeOwner of string * JsonObject * int * TaskCompletionSource<Subscription>
    | UnsubscribeOwner of int * TaskCompletionSource<unit>
    | DebugDisconnectOwner of TaskCompletionSource<unit>
    | ReconnectOwner of int64
    | MetadataOwner of TaskCompletionSource<int * string * string option>
    | BufferOwner of TaskCompletionSource<int * int>
    | PauseOwnerForTest of TaskCompletionSource<unit> * Task<unit>
    | CloseOwner of TaskCompletionSource<unit>

/// Native implementation of the pinned convex-rs 0.10.4 unversioned sync profile.
/// This mailbox is the sole caller of Connect, Receive, Send, Abort, and Dispose.
type LiveClient(deployment: string) =
    [<Literal>]
    let MaximumSubscriptions = 64

    [<Literal>]
    let MaximumSubscriptionBytes = 4 * 1024 * 1024

    [<Literal>]
    let MaximumSubscriptionArgumentBytes = 256 * 1024

    [<Literal>]
    let MaximumPendingCommands = 256

    [<Literal>]
    let MaximumOrdinaryPendingCommands = 192

    [<Literal>]
    let MaximumLiveMessageBytes = 2 * 1024 * 1024

    let endpoint =
        let value = Uri(deployment.TrimEnd('/'))

        if
            (value.Scheme <> "http" && value.Scheme <> "https")
            || not (String.IsNullOrEmpty value.UserInfo)
        then
            invalidArg "deployment" "Convex URL must be http(s) without user info"

        UriBuilder(
            value,
            Scheme = (if value.Scheme = "https" then "wss" else "ws"),
            Path = value.AbsolutePath.TrimEnd('/') + "/api/sync"
        )
            .Uri

    let lifetime = new CancellationTokenSource()
    let publicLock = obj ()
    let mutable disposed = false
    let mutable pendingCommands = 0
    let mutable reservedSubscriptionCount = 0
    let mutable reservedSubscriptionBytes = 0
    let mutable nextOwnerId = 0L

    let releaseSubscriptionReservation cost =
        lock publicLock (fun () ->
            reservedSubscriptionCount <- max 0 (reservedSubscriptionCount - 1)
            reservedSubscriptionBytes <- max 0 (reservedSubscriptionBytes - cost))

    let owner =
        MailboxProcessor.Start(fun inbox ->
            async {
                let ownerId = Interlocked.Increment(&nextOwnerId)
                let subscriptions = Dictionary<int, Subscription>()
                let subscriptionCosts = Dictionary<int, int>()
                let deliveryBudget = DeliveryBudget(16, 8 * 1024 * 1024)
                let receiveBuffer = Array.zeroCreate<byte> 8192
                use frame = new MemoryStream()
                let strictUtf8 = UTF8Encoding(false, true)
                let mutable socket: OwnedSocket option = None
                let mutable receive: Task<WebSocketReceiveResult> option = None
                let mutable reconnectGeneration = 0L
                let mutable nextId = 0
                let mutable querySet = 0u
                let mutable connectionCount = 0
                let mutable lastCloseReason = "InitialConnect"
                let mutable maxObservedTimestamp: string option = None
                let mutable maxObservedTimestampValue: uint64 option = None
                let mutable version = Json.zeroVersion ()
                let mutable reconnectDelay = 100
                let mutable intentionalRecovery = false
                let mutable subscriptionBytes = 0
                let mutable closing = false

                let exactUInt32 (node: JsonNode) label =
                    if isNull node then
                        raise (ProtocolError(label + " was omitted"))

                    let encoded = node.ToJsonString()

                    match UInt32.TryParse(encoded, NumberStyles.None, CultureInfo.InvariantCulture) with
                    | true, value -> value
                    | _ -> raise (ProtocolError(label + " must be an exact uint32 integer"))

                let logs (change: JsonObject) =
                    if change.ContainsKey "logLines" then
                        Json.strings change["logLines"]
                    else
                        []

                let addMessage (subscription: Subscription) =
                    let message = JsonObject()
                    message["type"] <- JsonValue.Create "Add"
                    message["queryId"] <- JsonValue.Create subscription.QueryId
                    message["udfPath"] <- JsonValue.Create subscription.Path
                    message["args"] <- JsonArray [| subscription.Args.DeepClone() |]
                    message :> JsonNode

                let send (current: OwnedSocket) (message: JsonObject) =
                    task {
                        use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                        timeout.CancelAfter(TimeSpan.FromSeconds 3.)

                        try
                            let bytes = Encoding.UTF8.GetBytes(message.ToJsonString())
                            do! current.Send(bytes, timeout.Token)
                        with error ->
                            return raise (TransportError("live write", error.Message))
                    }

                let modify (current: OwnedSocket) (modifications: JsonNode array) =
                    task {
                        if querySet = UInt32.MaxValue then
                            raise (ProtocolError "Live query-set version overflowed uint32")

                        let message = JsonObject()
                        message["type"] <- JsonValue.Create "ModifyQuerySet"
                        message["baseVersion"] <- JsonValue.Create querySet
                        message["newVersion"] <- JsonValue.Create(querySet + 1u)
                        message["modifications"] <- JsonArray modifications
                        do! send current message
                        querySet <- querySet + 1u
                    }

                let deliverFailure error =
                    for subscription in subscriptions.Values do
                        subscription.Offer
                            { Value = None
                              Error = Some error
                              Logs = [] }

                let scheduleReconnect () =
                    if not closing && socket.IsNone && subscriptions.Count > 0 then
                        reconnectGeneration <- reconnectGeneration + 1L
                        let scheduledGeneration = reconnectGeneration
                        let delay = reconnectDelay
                        reconnectDelay <- min 15000 (reconnectDelay * 2)

                        task {
                            try
                                do! Task.Delay(delay, lifetime.Token)
                                inbox.Post(ReconnectOwner scheduledGeneration)
                            with :? OperationCanceledException ->
                                ()
                        }
                        |> ignore

                let retireSocket reason failure reconnect =
                    match failure with
                    | Some error when not intentionalRecovery -> deliverFailure error
                    | _ -> ()

                    match socket with
                    | Some current ->
                        socket <- None
                        receive <- None
                        frame.SetLength 0
                        current.AbortAndDispose()

                        if connectionCount < Int32.MaxValue then
                            connectionCount <- connectionCount + 1
                    | None -> ()

                    lastCloseReason <- reason
                    querySet <- 0u
                    version <- Json.zeroVersion ()

                    if reconnect then
                        scheduleReconnect ()

                let connect () =
                    task {
                        let current = OwnedSocket(ownerId)
                        current.Options.SetRequestHeader("Convex-Client", "fsharp-0.1.0")

                        try
                            use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                            timeout.CancelAfter(TimeSpan.FromSeconds 3.)
                            do! current.Connect(endpoint, timeout.Token)
                            socket <- Some current
                            receive <- None
                            frame.SetLength 0
                            querySet <- 0u
                            version <- Json.zeroVersion ()

                            if connectionCount > 0 then
                                for subscription in subscriptions.Values do
                                    subscription.PrepareHydrationDedup()

                            let connectMessage = JsonObject()
                            connectMessage["type"] <- JsonValue.Create "Connect"
                            connectMessage["sessionId"] <- JsonValue.Create(Guid.NewGuid().ToString())
                            connectMessage["connectionCount"] <- JsonValue.Create connectionCount
                            connectMessage["lastCloseReason"] <- JsonValue.Create lastCloseReason
                            connectMessage["clientTs"] <- JsonValue.Create 0

                            match maxObservedTimestamp with
                            | Some timestamp -> connectMessage["maxObservedTimestamp"] <- JsonValue.Create timestamp
                            | None -> ()

                            do! send current connectMessage

                            if subscriptions.Count > 0 then
                                let additions =
                                    subscriptions.Values
                                    |> Seq.sortBy _.QueryId
                                    |> Seq.map addMessage
                                    |> Seq.toArray

                                do! modify current additions

                            // The WebSocket handshake plus valid client protocol writes are healthy traffic.
                            reconnectDelay <- 100
                            intentionalRecovery <- false
                        with error ->
                            if socket |> Option.exists (fun active -> Object.ReferenceEquals(active, current)) then
                                socket <- None

                            receive <- None
                            frame.SetLength 0
                            current.AbortAndDispose()

                            if connectionCount < Int32.MaxValue then
                                connectionCount <- connectionCount + 1

                            lastCloseReason <- "ConnectFailed:" + error.Message
                            querySet <- 0u
                            version <- Json.zeroVersion ()

                            match error with
                            | TransportError _ -> return raise error
                            | _ -> return raise (TransportError("live connect", error.Message))
                    }

                let handleText (text: string) =
                    try
                        let message = JsonNode.Parse(text).AsObject()

                        if isNull message["type"] then
                            raise (ProtocolError "Live message omitted type")

                        match message["type"].GetValue<string>() with
                        | "Ping"
                        | "MutationResponse"
                        | "ActionResponse" ->
                            reconnectDelay <- 100
                            intentionalRecovery <- false
                        | "Transition" ->
                            if
                                not (message.ContainsKey "startVersion")
                                || not (message.ContainsKey "endVersion")
                                || not (message.ContainsKey "modifications")
                            then
                                raise (ProtocolError "Live transition omitted required fields")

                            // Parse both complete versions before looking at any deliverable change.
                            let startVersion = Json.stateVersion message["startVersion"] "startVersion"
                            let endVersion = Json.stateVersion message["endVersion"] "endVersion"

                            if startVersion <> version then
                                raise (ProtocolError "Live transition version mismatch")

                            if
                                endVersion.QuerySet < startVersion.QuerySet
                                || endVersion.Identity < startVersion.Identity
                                || endVersion.TimestampValue < startVersion.TimestampValue
                            then
                                raise (ProtocolError "Live transition version moved backwards")

                            if endVersion.QuerySet > querySet then
                                raise (ProtocolError "Live transition exceeded the client query-set version")

                            let modifications =
                                match message["modifications"] with
                                | :? JsonArray as value -> value
                                | _ -> raise (ProtocolError "Live transition modifications must be an array")

                            // A transition is a replacement set. Keep only the final state for each query,
                            // while still validating every earlier modification in the message.
                            let pending = Dictionary<int, PendingChange>()

                            for node in modifications do
                                let modification =
                                    match node with
                                    | :? JsonObject as value -> value
                                    | _ -> raise (ProtocolError "Live transition modification must be an object")

                                if isNull modification["type"] then
                                    raise (ProtocolError "Live modification omitted type")

                                let wireId = exactUInt32 modification["queryId"] "Live queryId"

                                if wireId > uint32 Int32.MaxValue then
                                    raise (ProtocolError "Live queryId exceeded Int32 range")

                                let id = int wireId

                                match modification["type"].GetValue<string>() with
                                | "QueryRemoved" -> pending[id] <- Removed
                                | "QueryUpdated" ->
                                    if not (modification.ContainsKey "value") then
                                        raise (ProtocolError "QueryUpdated omitted value")

                                    let value =
                                        if isNull modification["value"] then
                                            None
                                        else
                                            Some(modification["value"].DeepClone())

                                    pending[id] <-
                                        Publish
                                            { Value = value
                                              Error = None
                                              Logs = logs modification }
                                | "QueryFailed" ->
                                    if isNull modification["errorMessage"] then
                                        raise (ProtocolError "QueryFailed omitted errorMessage")

                                    let messageText =
                                        try
                                            modification["errorMessage"].GetValue<string>()
                                        with _ ->
                                            raise (ProtocolError "QueryFailed errorMessage must be a string")

                                    let data =
                                        if
                                            not (modification.ContainsKey "errorData")
                                            || isNull modification["errorData"]
                                        then
                                            None
                                        else
                                            Some(modification["errorData"].DeepClone())

                                    let logLines = logs modification

                                    pending[id] <-
                                        Publish
                                            { Value = None
                                              Error = Some(FunctionError("query", messageText, data, logLines))
                                              Logs = logLines }
                                | other -> raise (ProtocolError("unsupported Live modification: " + other))

                            // Commit all owner state before publishing the first subscription delivery.
                            version <- endVersion

                            if
                                maxObservedTimestampValue.IsNone
                                || endVersion.TimestampValue > maxObservedTimestampValue.Value
                            then
                                maxObservedTimestamp <- Some endVersion.Timestamp
                                maxObservedTimestampValue <- Some endVersion.TimestampValue

                            reconnectDelay <- 100
                            intentionalRecovery <- false

                            for pair in pending |> Seq.sortBy _.Key do
                                match pair.Value, subscriptions.TryGetValue pair.Key with
                                | Publish update, (true, subscription) -> subscription.Offer update
                                | _ -> ()
                        | other -> raise (ProtocolError("unsupported Live message: " + other))

                        None
                    with
                    | ProtocolError _ as error -> Some error
                    | :? JsonException as error -> Some(ProtocolError("invalid Live JSON: " + error.Message))
                    | :? InvalidOperationException as error ->
                        Some(ProtocolError("invalid Live message shape: " + error.Message))
                    | :? FormatException as error -> Some(ProtocolError("invalid Live field: " + error.Message))

                let processReceive (completed: Task<WebSocketReceiveResult>) =
                    try
                        let result = completed.GetAwaiter().GetResult()

                        if result.MessageType = WebSocketMessageType.Close then
                            let status =
                                if result.CloseStatus.HasValue then
                                    string result.CloseStatus.Value
                                else
                                    "NoStatus"

                            let description =
                                if isNull result.CloseStatusDescription then
                                    ""
                                else
                                    result.CloseStatusDescription

                            retireSocket
                                ("WebSocketClose:" + status + ":" + description)
                                (Some(TransportError("live read", "server closed the WebSocket")))
                                true
                        elif result.MessageType <> WebSocketMessageType.Text then
                            retireSocket
                                "ProtocolError:non-text-frame"
                                (Some(ProtocolError "Live server sent a non-text message"))
                                true
                        else
                            frame.Write(receiveBuffer, 0, result.Count)

                            if frame.Length > int64 MaximumLiveMessageBytes then
                                retireSocket
                                    "ProtocolError:message-too-large"
                                    (Some(
                                        ProtocolError(sprintf "Live message exceeded %d bytes" MaximumLiveMessageBytes)
                                    ))
                                    true
                            elif result.EndOfMessage then
                                let text = strictUtf8.GetString(frame.ToArray())
                                frame.SetLength 0

                                match handleText text with
                                | Some error -> retireSocket ("ProtocolError:" + error.Message) (Some error) true
                                | None -> ()
                    with
                    | :? OperationCanceledException when closing -> ()
                    | :? DecoderFallbackException as error ->
                        retireSocket
                            "ProtocolError:invalid-utf8"
                            (Some(ProtocolError("invalid Live UTF-8: " + error.Message)))
                            true
                    | error ->
                        retireSocket
                            ("TransportError:" + error.Message)
                            (Some(TransportError("live read", error.Message)))
                            true

                let finishSubscription id (subscription: Subscription) =
                    subscriptions.Remove id |> ignore

                    match subscriptionCosts.TryGetValue id with
                    | true, cost ->
                        subscriptionCosts.Remove id |> ignore
                        subscriptionBytes <- subscriptionBytes - cost
                        releaseSubscriptionReservation cost
                    | _ -> ()

                    subscription.Finish()

                let mutable running = true

                while running do
                    let! command = inbox.TryReceive 1

                    match command with
                    | Some(ReconnectOwner scheduledGeneration) ->
                        if
                            scheduledGeneration = reconnectGeneration
                            && socket.IsNone
                            && subscriptions.Count > 0
                            && not closing
                        then
                            try
                                do! connect () |> Async.AwaitTask
                            with _ ->
                                scheduleReconnect ()
                    | Some(CloseOwner completion) ->
                        closing <- true
                        reconnectGeneration <- reconnectGeneration + 1L
                        lifetime.Cancel()

                        match socket with
                        | Some current ->
                            socket <- None
                            receive <- None
                            current.AbortAndDispose()
                        | None -> ()

                        for subscription in subscriptions.Values do
                            subscription.Finish()

                        subscriptions.Clear()
                        subscriptionCosts.Clear()
                        subscriptionBytes <- 0

                        lock publicLock (fun () ->
                            reservedSubscriptionCount <- 0
                            reservedSubscriptionBytes <- 0)

                        completion.TrySetResult() |> ignore
                        running <- false
                    | Some command ->
                        Interlocked.Decrement(&pendingCommands) |> ignore

                        match command with
                        | SubscribeOwner(path, args, cost, completion) ->
                            if closing then
                                releaseSubscriptionReservation cost
                                completion.TrySetException(ObjectDisposedException "LiveClient") |> ignore
                            elif subscriptions.Count >= MaximumSubscriptions then
                                releaseSubscriptionReservation cost

                                completion.TrySetException(
                                    InvalidOperationException(
                                        sprintf "Live client supports at most %d subscriptions" MaximumSubscriptions
                                    )
                                )
                                |> ignore
                            elif cost > MaximumSubscriptionArgumentBytes then
                                releaseSubscriptionReservation cost

                                completion.TrySetException(
                                    ArgumentException(
                                        sprintf
                                            "Live subscription arguments exceeded %d bytes"
                                            MaximumSubscriptionArgumentBytes,
                                        "args"
                                    )
                                )
                                |> ignore
                            elif subscriptionBytes + cost > MaximumSubscriptionBytes then
                                releaseSubscriptionReservation cost

                                completion.TrySetException(
                                    InvalidOperationException(
                                        sprintf
                                            "Live subscription arguments exceeded the global %d-byte budget"
                                            MaximumSubscriptionBytes
                                    )
                                )
                                |> ignore
                            else
                                let unsubscribe id =
                                    let result =
                                        TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

                                    lock publicLock (fun () ->
                                        if disposed then
                                            result.TrySetResult() |> ignore
                                        else
                                            // Ordinary commands reserve 64 of the global 256
                                            // owner slots for the at-most-64 live subscriptions.
                                            // Posting while holding publicLock orders this cleanup
                                            // before any concurrent CloseOwner acknowledgement.
                                            let queued = Interlocked.Increment(&pendingCommands)

                                            if queued > MaximumPendingCommands then
                                                Interlocked.Decrement(&pendingCommands) |> ignore

                                                result.TrySetException(
                                                    InvalidOperationException "Live command queue invariant failed"
                                                )
                                                |> ignore
                                            else
                                                inbox.Post(UnsubscribeOwner(id, result)))

                                    result.Task

                                let subscription = new Subscription(nextId, path, args, deliveryBudget, unsubscribe)
                                nextId <- nextId + 1
                                subscriptions.Add(subscription.QueryId, subscription)
                                subscriptionCosts.Add(subscription.QueryId, cost)
                                subscriptionBytes <- subscriptionBytes + cost

                                try
                                    match socket with
                                    | None -> do! connect () |> Async.AwaitTask
                                    | Some current ->
                                        do! modify current [| addMessage subscription |] |> Async.AwaitTask

                                    completion.TrySetResult subscription |> ignore
                                with error ->
                                    finishSubscription subscription.QueryId subscription

                                    match socket with
                                    | Some _ -> retireSocket ("TransportError:" + error.Message) (Some error) true
                                    | None -> ()

                                    completion.TrySetException error |> ignore
                        | UnsubscribeOwner(id, completion) ->
                            match subscriptions.TryGetValue id with
                            | true, subscription ->
                                finishSubscription id subscription

                                match socket with
                                | Some current ->
                                    try
                                        let remove = JsonObject()
                                        remove["type"] <- JsonValue.Create "Remove"
                                        remove["queryId"] <- JsonValue.Create id
                                        do! modify current [| remove :> JsonNode |] |> Async.AwaitTask
                                    with error ->
                                        retireSocket ("TransportError:" + error.Message) (Some error) true
                                | None -> ()
                            | _ -> ()

                            completion.TrySetResult() |> ignore
                        | DebugDisconnectOwner completion ->
                            match socket with
                            | None ->
                                completion.TrySetException(InvalidOperationException "Live WebSocket is not connected")
                                |> ignore
                            | Some _ ->
                                intentionalRecovery <- true
                                retireSocket "DebugDisconnect" None true
                                completion.TrySetResult() |> ignore
                        | MetadataOwner completion ->
                            completion.TrySetResult(connectionCount, lastCloseReason, maxObservedTimestamp)
                            |> ignore
                        | BufferOwner completion -> completion.TrySetResult deliveryBudget.Snapshot |> ignore
                        | PauseOwnerForTest(entered, release) ->
                            entered.TrySetResult() |> ignore
                            do! release |> Async.AwaitTask
                        | _ -> ()
                    | None -> ()

                    if running then
                        match socket, receive with
                        | Some current, None -> receive <- Some(current.Receive(receiveBuffer, lifetime.Token))
                        | Some _, Some completed when completed.IsCompleted ->
                            receive <- None
                            processReceive completed
                        | _ -> ()
            })

    let post command =
        lock publicLock (fun () ->
            if disposed then
                raise (ObjectDisposedException "LiveClient")

            let queued = Interlocked.Increment(&pendingCommands)

            if queued > MaximumOrdinaryPendingCommands then
                Interlocked.Decrement(&pendingCommands) |> ignore
                raise (InvalidOperationException "Live command queue is full")

            owner.Post command)

    member _.Subscribe(path: string, args: JsonObject) =
        if String.IsNullOrWhiteSpace path then
            invalidArg "path" "Convex function path is required"

        let copied = args.DeepClone().AsObject()

        let cost =
            Encoding.UTF8.GetByteCount(path)
            + Encoding.UTF8.GetByteCount(copied.ToJsonString())

        let completion =
            TaskCompletionSource<Subscription>(TaskCreationOptions.RunContinuationsAsynchronously)

        lock publicLock (fun () ->
            if disposed then
                raise (ObjectDisposedException "LiveClient")

            if cost > MaximumSubscriptionArgumentBytes then
                raise (
                    ArgumentException(
                        sprintf "Live subscription arguments exceeded %d bytes" MaximumSubscriptionArgumentBytes,
                        "args"
                    )
                )

            if reservedSubscriptionCount >= MaximumSubscriptions then
                raise (
                    InvalidOperationException(
                        sprintf "Live client supports at most %d active or pending subscriptions" MaximumSubscriptions
                    )
                )

            if reservedSubscriptionBytes + cost > MaximumSubscriptionBytes then
                raise (
                    InvalidOperationException(
                        sprintf
                            "Active and pending Live subscription arguments exceeded the global %d-byte budget"
                            MaximumSubscriptionBytes
                    )
                )

            let queued = Interlocked.Increment(&pendingCommands)

            if queued > MaximumOrdinaryPendingCommands then
                Interlocked.Decrement(&pendingCommands) |> ignore
                raise (InvalidOperationException "Live command queue is full")

            reservedSubscriptionCount <- reservedSubscriptionCount + 1
            reservedSubscriptionBytes <- reservedSubscriptionBytes + cost
            owner.Post(SubscribeOwner(path, copied, cost, completion)))

        completion.Task

    member _.DebugDisconnect() =
        let completion =
            TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (DebugDisconnectOwner completion)
        completion.Task

    member private _.Metadata() =
        let completion =
            TaskCompletionSource<int * string * string option>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (MetadataOwner completion)
        completion.Task.GetAwaiter().GetResult()

    member this.ConnectionCount =
        let count, _, _ = this.Metadata()
        count

    member this.LastCloseReason =
        let _, reason, _ = this.Metadata()
        reason

    member this.MaxObservedTimestamp =
        let _, _, timestamp = this.Metadata()
        timestamp

    member internal _.DeliverySnapshot =
        let completion =
            TaskCompletionSource<int * int>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (BufferOwner completion)
        completion.Task.GetAwaiter().GetResult()

    member internal _.DeliverySnapshotAsyncForTest() =
        let completion =
            TaskCompletionSource<int * int>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (BufferOwner completion)
        completion.Task

    member internal _.PauseOwnerForTest() =
        let entered =
            TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

        let release =
            TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (PauseOwnerForTest(entered, release.Task))
        entered.Task.GetAwaiter().GetResult()
        release

    member internal _.IsDisposedForTest = lock publicLock (fun () -> disposed)

    member internal _.PendingCommandsForTest = Volatile.Read(&pendingCommands)

    member internal _.PendingSubscriptionBudgetForTest =
        lock publicLock (fun () -> reservedSubscriptionCount, reservedSubscriptionBytes)

    interface IDisposable with
        member _.Dispose() =
            let shouldClose =
                lock publicLock (fun () ->
                    if disposed then
                        false
                    else
                        disposed <- true
                        true)

            if shouldClose then
                let completion =
                    TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

                owner.Post(CloseOwner completion)

                if not (completion.Task.Wait(TimeSpan.FromSeconds 4.)) then
                    lifetime.Cancel()
                    raise (TimeoutException "timed out closing Live client")

                lifetime.Dispose()
