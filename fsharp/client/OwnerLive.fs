namespace Convex

open System
open System.Collections.Generic
open System.Net.WebSockets
open System.Text
open System.Text.Json
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks

type private OwnerCommand =
    | SubscribeOwner of string * JsonObject * TaskCompletionSource<Subscription>
    | UnsubscribeOwner of int * TaskCompletionSource<unit>
    | DebugDisconnectOwner of TaskCompletionSource<unit>
    | SocketTextOwner of int64 * string * TaskCompletionSource<unit>
    | SocketFailureOwner of int64 * string * exn
    | ReconnectOwner of int64
    | MetadataOwner of TaskCompletionSource<int * string * string option>
    | CloseOwner of TaskCompletionSource<unit>

/// Native implementation of the pinned convex-rs 0.10.4 unversioned sync profile.
/// The mailbox alone owns socket writes, generations, query versions, metadata, and reconnect state.
type LiveClient(deployment: string) =
    let endpoint =
        let value = Uri(deployment.TrimEnd('/'))

        UriBuilder(
            value,
            Scheme = (if value.Scheme = "https" then "wss" else "ws"),
            Path = value.AbsolutePath.TrimEnd('/') + "/api/sync"
        )
            .Uri

    let lifetime = new CancellationTokenSource()
    let publicLock = obj ()
    let mutable disposed = false

    let owner =
        MailboxProcessor.Start(fun inbox ->
            async {
                let subscriptions = Dictionary<int, Subscription>()
                let mutable socket: ClientWebSocket option = None
                let mutable socketGeneration = 0L
                let mutable reconnectGeneration = 0L
                let mutable nextId = 0
                let mutable querySet = 0
                let mutable connectionCount = 0
                let mutable lastCloseReason = "InitialConnect"
                let mutable maxObservedTimestamp: string option = None
                let mutable version = Json.zeroVersion ()
                let mutable reconnectDelay = 100
                let mutable intentionalRecovery = false
                let mutable closing = false

                let addMessage (subscription: Subscription) =
                    let message = JsonObject()
                    message["type"] <- JsonValue.Create "Add"
                    message["queryId"] <- JsonValue.Create subscription.QueryId
                    message["udfPath"] <- JsonValue.Create subscription.Path
                    message["args"] <- JsonArray [| subscription.Args.DeepClone() |]
                    message :> JsonNode

                let send (current: ClientWebSocket) (message: JsonObject) =
                    task {
                        use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                        timeout.CancelAfter(TimeSpan.FromSeconds 3.)

                        try
                            let bytes = Encoding.UTF8.GetBytes(message.ToJsonString())

                            do!
                                current.SendAsync(
                                    ArraySegment<byte> bytes,
                                    WebSocketMessageType.Text,
                                    true,
                                    timeout.Token
                                )
                        with error ->
                            return raise (TransportError("live write", error.Message))
                    }

                let modify (current: ClientWebSocket) (modifications: JsonNode array) =
                    task {
                        let message = JsonObject()
                        message["type"] <- JsonValue.Create "ModifyQuerySet"
                        message["baseVersion"] <- JsonValue.Create querySet
                        message["newVersion"] <- JsonValue.Create(querySet + 1)
                        message["modifications"] <- JsonArray modifications
                        do! send current message
                        querySet <- querySet + 1
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
                        socketGeneration <- socketGeneration + 1L
                        current.Abort()
                        current.Dispose()
                        connectionCount <- connectionCount + 1
                    | None -> ()

                    lastCloseReason <- reason
                    querySet <- 0
                    version <- Json.zeroVersion ()

                    if reconnect then
                        scheduleReconnect ()

                // The reader never mutates client state. It reassembles one complete frame,
                // posts it to the owner, and waits for acknowledgement before reading again.
                let startReader generation (current: ClientWebSocket) =
                    task {
                        let buffer = Array.zeroCreate<byte> 4096
                        use frame = new IO.MemoryStream()
                        let strictUtf8 = UTF8Encoding(false, true)
                        let mutable reading = true

                        while reading && not lifetime.IsCancellationRequested do
                            try
                                let! result = current.ReceiveAsync(ArraySegment<byte> buffer, lifetime.Token)

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

                                    inbox.Post(
                                        SocketFailureOwner(
                                            generation,
                                            "WebSocketClose:" + status + ":" + description,
                                            TransportError("live read", "server closed the WebSocket")
                                        )
                                    )

                                    reading <- false
                                elif result.MessageType <> WebSocketMessageType.Text then
                                    inbox.Post(
                                        SocketFailureOwner(
                                            generation,
                                            "ProtocolError:non-text-frame",
                                            ProtocolError "Live server sent a non-text message"
                                        )
                                    )

                                    reading <- false
                                else
                                    frame.Write(buffer, 0, result.Count)

                                    if frame.Length > 1048576L then
                                        inbox.Post(
                                            SocketFailureOwner(
                                                generation,
                                                "ProtocolError:message-too-large",
                                                ProtocolError "Live message exceeded 1048576 bytes"
                                            )
                                        )

                                        reading <- false
                                    elif result.EndOfMessage then
                                        let text = strictUtf8.GetString(frame.ToArray())
                                        frame.SetLength 0

                                        let acknowledged =
                                            TaskCompletionSource<unit>(
                                                TaskCreationOptions.RunContinuationsAsynchronously
                                            )

                                        inbox.Post(SocketTextOwner(generation, text, acknowledged))
                                        do! acknowledged.Task
                            with
                            | :? OperationCanceledException -> reading <- false
                            | :? DecoderFallbackException as error ->
                                inbox.Post(
                                    SocketFailureOwner(
                                        generation,
                                        "ProtocolError:invalid-utf8",
                                        ProtocolError("invalid Live UTF-8: " + error.Message)
                                    )
                                )

                                reading <- false
                            | error ->
                                inbox.Post(
                                    SocketFailureOwner(
                                        generation,
                                        "TransportError:" + error.Message,
                                        TransportError("live read", error.Message)
                                    )
                                )

                                reading <- false
                    }
                    |> ignore

                let connect () =
                    task {
                        let current = new ClientWebSocket()
                        current.Options.SetRequestHeader("Convex-Client", "fsharp-0.1.0")

                        try
                            use timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token)
                            timeout.CancelAfter(TimeSpan.FromSeconds 3.)
                            do! current.ConnectAsync(endpoint, timeout.Token)
                            socket <- Some current
                            socketGeneration <- socketGeneration + 1L
                            let generation = socketGeneration
                            querySet <- 0
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

                            // A completed handshake and query-set write are healthy protocol traffic.
                            reconnectDelay <- 100
                            intentionalRecovery <- false
                            startReader generation current
                        with error ->
                            if socket |> Option.exists (fun active -> Object.ReferenceEquals(active, current)) then
                                socket <- None
                                socketGeneration <- socketGeneration + 1L

                            current.Abort()
                            current.Dispose()
                            connectionCount <- connectionCount + 1
                            lastCloseReason <- "ConnectFailed:" + error.Message
                            querySet <- 0
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
                        | "ActionResponse" -> reconnectDelay <- 100
                        | "Transition" ->
                            if
                                isNull message["startVersion"]
                                || isNull message["endVersion"]
                                || isNull message["modifications"]
                            then
                                raise (ProtocolError "Live transition omitted required fields")

                            if not (JsonNode.DeepEquals(message["startVersion"], version)) then
                                raise (ProtocolError "Live transition version mismatch")

                            let pending = ResizeArray<int * Update>()

                            for node in message["modifications"].AsArray() do
                                if isNull node then
                                    raise (ProtocolError "Live transition contained a null modification")

                                let modification = node.AsObject()

                                if isNull modification["queryId"] || isNull modification["type"] then
                                    raise (ProtocolError "Live modification omitted queryId or type")

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

                            // Commit a fully validated transition in deterministic query-id order.
                            for id, update in pending |> Seq.sortBy fst do
                                match subscriptions.TryGetValue id with
                                | true, subscription -> subscription.Offer update
                                | _ -> ()

                            version <- message["endVersion"].DeepClone().AsObject()

                            if not (isNull version["ts"]) then
                                maxObservedTimestamp <- Some(version["ts"].GetValue<string>())

                            reconnectDelay <- 100
                            intentionalRecovery <- false
                        | other -> raise (ProtocolError("unsupported Live message: " + other))

                        None
                    with
                    | ProtocolError _ as error -> Some error
                    | :? JsonException as error -> Some(ProtocolError("invalid Live JSON: " + error.Message))
                    | :? InvalidOperationException as error ->
                        Some(ProtocolError("invalid Live message shape: " + error.Message))
                    | :? FormatException as error -> Some(ProtocolError("invalid Live field: " + error.Message))

                let mutable running = true

                while running do
                    let! command = inbox.Receive()

                    match command with
                    | SubscribeOwner(path, args, completion) ->
                        if closing then
                            completion.TrySetException(ObjectDisposedException "LiveClient") |> ignore
                        else
                            let unsubscribe id =
                                let result =
                                    TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

                                inbox.Post(UnsubscribeOwner(id, result))
                                result.Task

                            let subscription =
                                new Subscription(nextId, path, args.DeepClone().AsObject(), unsubscribe)

                            nextId <- nextId + 1
                            subscriptions.Add(subscription.QueryId, subscription)

                            try
                                match socket with
                                | None -> do! connect () |> Async.AwaitTask
                                | Some current -> do! modify current [| addMessage subscription |] |> Async.AwaitTask

                                completion.TrySetResult subscription |> ignore
                            with error ->
                                subscriptions.Remove subscription.QueryId |> ignore
                                subscription.Finish()

                                match socket with
                                | Some _ -> retireSocket ("TransportError:" + error.Message) (Some error) true
                                | None -> ()

                                completion.TrySetException error |> ignore
                    | UnsubscribeOwner(id, completion) ->
                        match subscriptions.TryGetValue id with
                        | true, subscription ->
                            subscriptions.Remove id |> ignore
                            subscription.Finish()

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
                    | SocketTextOwner(generation, text, acknowledgement) ->
                        if generation = socketGeneration && socket.IsSome then
                            match handleText text with
                            | Some error -> retireSocket ("ProtocolError:" + error.Message) (Some error) true
                            | None -> ()

                        acknowledgement.TrySetResult() |> ignore
                    | SocketFailureOwner(generation, reason, error) ->
                        if generation = socketGeneration && socket.IsSome then
                            retireSocket reason (Some error) true
                    | ReconnectOwner scheduledGeneration ->
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
                    | MetadataOwner completion ->
                        completion.TrySetResult(connectionCount, lastCloseReason, maxObservedTimestamp)
                        |> ignore
                    | CloseOwner completion ->
                        closing <- true
                        reconnectGeneration <- reconnectGeneration + 1L
                        lifetime.Cancel()

                        match socket with
                        | Some current ->
                            socket <- None
                            socketGeneration <- socketGeneration + 1L
                            current.Abort()
                            current.Dispose()
                        | None -> ()

                        for subscription in subscriptions.Values do
                            subscription.Finish()

                        subscriptions.Clear()
                        completion.TrySetResult() |> ignore
                        running <- false
            })

    let post command =
        lock publicLock (fun () ->
            if disposed then
                raise (ObjectDisposedException "LiveClient")

            owner.Post command)

    member _.Subscribe(path: string, args: JsonObject) =
        if String.IsNullOrWhiteSpace path then
            invalidArg "path" "Convex function path is required"

        let completion =
            TaskCompletionSource<Subscription>(TaskCreationOptions.RunContinuationsAsynchronously)

        post (SubscribeOwner(path, args, completion))
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
