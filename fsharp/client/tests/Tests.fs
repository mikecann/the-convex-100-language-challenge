open System
open System.Buffers.Binary
open System.Diagnostics
open System.IO
open System.Net
open System.Net.Sockets
open System.Net.WebSockets
open System.Security.Cryptography
open System.Text
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Channels
open System.Threading.Tasks
open Convex

type AsyncLineReader() =
    inherit TextReader()
    let lines = Channel.CreateUnbounded<string>()
    member _.Send(line: string) = lines.Writer.WriteAsync(line).AsTask()
    override _.ReadLineAsync() = lines.Reader.ReadAsync().AsTask()

type AsyncLineWriter() =
    inherit TextWriter()
    let lines = Channel.CreateUnbounded<string>()
    override _.Encoding = Encoding.UTF8
    override _.WriteLineAsync(value: string) = lines.Writer.WriteAsync(value).AsTask()

    member _.Read(timeout: TimeSpan) =
        lines.Reader.ReadAsync().AsTask().WaitAsync(timeout)

    member _.TryRead(timeout: TimeSpan) =
        task {
            use cancellation = new CancellationTokenSource(timeout)

            try
                let! value = lines.Reader.ReadAsync(cancellation.Token).AsTask()
                return Some value
            with :? OperationCanceledException ->
                return None
        }

let check condition message =
    if not condition then
        failwith message

let freePort () =
    use listener = new TcpListener(IPAddress.Loopback, 0)
    listener.Start()
    (listener.LocalEndpoint :?> IPEndPoint).Port

let timestamp (value: uint64) =
    let bytes = Array.zeroCreate<byte> 8
    BinaryPrimitives.WriteUInt64LittleEndian(bytes, value)
    Convert.ToBase64String bytes

let version (querySet: int) (timestampValue: uint64) =
    let value = JsonObject()
    value["querySet"] <- JsonValue.Create querySet
    value["identity"] <- JsonValue.Create 0
    value["ts"] <- JsonValue.Create(timestamp timestampValue)
    value

let zero () = version 0 0UL

let transition (startVersion: JsonObject) (endVersion: JsonObject) (modification: JsonNode) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "Transition"
    value["startVersion"] <- startVersion
    value["endVersion"] <- endVersion
    value["modifications"] <- JsonArray([| modification |])
    value.ToJsonString()

let transitionMany (startVersion: JsonObject) (endVersion: JsonNode) (modifications: JsonNode array) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "Transition"
    value["startVersion"] <- startVersion
    value["endVersion"] <- endVersion
    value["modifications"] <- JsonArray modifications
    value.ToJsonString()

let queryUpdatedValue (id: int) (result: JsonNode) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "QueryUpdated"
    value["queryId"] <- JsonValue.Create id
    value["value"] <- if isNull result then null else result.DeepClone()
    value["logLines"] <- JsonArray()
    value :> JsonNode

let queryRemoved (id: int) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "QueryRemoved"
    value["queryId"] <- JsonValue.Create id
    value :> JsonNode

let firstModificationId (message: JsonNode) =
    let modifications = message["modifications"].AsArray()
    let first = modifications[0]
    first["queryId"].GetValue<int>()

let queryUpdated (id: int) (count: int) (text: string) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "QueryUpdated"
    value["queryId"] <- JsonValue.Create id
    let result = JsonObject()
    result["count"] <- JsonValue.Create count
    result["text"] <- JsonValue.Create text
    value["value"] <- result
    value["logLines"] <- JsonArray()
    value :> JsonNode

let queryFailed (id: int) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "QueryFailed"
    value["queryId"] <- JsonValue.Create id
    value["errorMessage"] <- JsonValue.Create "fixture failure"
    value["errorData"] <- JsonValue.Create "detail"
    value["logLines"] <- JsonArray([| JsonValue.Create "fixture log" :> JsonNode |])
    value :> JsonNode

let largeQueryFailed (id: int) marker =
    let payload = String('e', 40000)
    let value = JsonObject()
    value["type"] <- JsonValue.Create "QueryFailed"
    value["queryId"] <- JsonValue.Create id
    value["errorMessage"] <- JsonValue.Create(marker + payload)
    let data = JsonObject()
    data["marker"] <- JsonValue.Create marker
    data["payload"] <- JsonValue.Create payload
    value["errorData"] <- data
    value["logLines"] <- JsonArray([| JsonValue.Create(marker + payload) :> JsonNode |])
    value :> JsonNode

let receiveText (socket: WebSocket) =
    task {
        let buffer = Array.zeroCreate<byte> 4096
        use bytes = new MemoryStream()
        let mutable complete = false

        while not complete do
            let! result = socket.ReceiveAsync(ArraySegment<byte>(buffer), CancellationToken.None)

            if result.MessageType = WebSocketMessageType.Close then
                failwith "fixture client closed unexpectedly"

            bytes.Write(buffer, 0, result.Count)
            complete <- result.EndOfMessage

        return Encoding.UTF8.GetString(bytes.ToArray())
    }

let sendText (socket: WebSocket) (text: string) fragmented =
    task {
        let bytes = Encoding.UTF8.GetBytes text

        if fragmented then
            // Split inside the three-byte UTF-8 snow character. ClientWebSocket must preserve parser state.
            let marker = Encoding.UTF8.GetBytes "雪"
            let mutable split = bytes.Length / 2

            for index in 0 .. bytes.Length - marker.Length do
                if bytes[index] = marker[0] && bytes[index + 1] = marker[1] then
                    split <- index + 1

            do!
                socket.SendAsync(
                    ArraySegment<byte>(bytes, 0, split),
                    WebSocketMessageType.Text,
                    false,
                    CancellationToken.None
                )

            do!
                socket.SendAsync(
                    ArraySegment<byte>(bytes, split, bytes.Length - split),
                    WebSocketMessageType.Text,
                    true,
                    CancellationToken.None
                )
        else
            do! socket.SendAsync(ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None)
    }

let readExact (stream: NetworkStream) count =
    task {
        let bytes = Array.zeroCreate<byte> count
        let mutable offset = 0

        while offset < count do
            let! read = stream.ReadAsync(bytes.AsMemory(offset, count - offset))

            if read = 0 then
                raise (EndOfStreamException "raw WebSocket peer closed")

            offset <- offset + read

        return bytes
    }

let readRawFrame (stream: NetworkStream) =
    task {
        let! header = readExact stream 2
        let mutable length = int (header[1] &&& 0x7Fuy)

        if length = 126 then
            let! extended = readExact stream 2
            length <- (int extended[0] <<< 8) ||| int extended[1]

        let masked = (header[1] &&& 0x80uy) <> 0uy

        let! mask =
            if masked then
                readExact stream 4
            else
                Task.FromResult(Array.empty<byte>)

        let! payload = readExact stream length

        if masked then
            for index in 0 .. payload.Length - 1 do
                payload[index] <- payload[index] ^^^ mask[index % 4]

        return header[0] &&& 0x0Fuy, payload
    }

let sendRawFrame (stream: NetworkStream) opcode (payload: byte array) =
    task {
        let header = ResizeArray<byte>()
        header.Add(0x80uy ||| opcode)

        if payload.Length < 126 then
            header.Add(byte payload.Length)
        else
            header.Add 126uy
            header.Add(byte (payload.Length >>> 8))
            header.Add(byte payload.Length)

        do! stream.WriteAsync(header.ToArray())
        do! stream.WriteAsync payload
    }

let acceptRawWebSocket (listener: TcpListener) =
    task {
        let! connection = listener.AcceptTcpClientAsync()
        let stream = connection.GetStream()
        let request = StringBuilder()
        let mutable complete = false

        while not complete do
            let! next = readExact stream 1
            request.Append(char next[0]) |> ignore
            complete <- request.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)

        let keyLine =
            request.ToString().Split("\r\n", StringSplitOptions.RemoveEmptyEntries)
            |> Array.find (fun line -> line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase))

        let key = keyLine.Substring(keyLine.IndexOf(':') + 1).Trim()

        let accept =
            SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
            |> Convert.ToBase64String

        let response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
            + accept
            + "\r\n\r\n"

        do! stream.WriteAsync(Encoding.ASCII.GetBytes response)
        return connection, stream
    }

let controlFrameFixture () =
    task {
        let port = freePort ()
        use listener = new TcpListener(IPAddress.Loopback, port)
        listener.Start()

        let server =
            task {
                let! connection, stream = acceptRawWebSocket listener
                use connection = connection
                use stream = stream
                let! _, _ = readRawFrame stream
                let! _, addBytes = readRawFrame stream
                let add = JsonNode.Parse(Encoding.UTF8.GetString addBytes)
                let modification = (add["modifications"].AsArray())[0]
                let id = modification["queryId"].GetValue<int>()
                do! sendRawFrame stream 0x9uy (Encoding.UTF8.GetBytes "ping")

                let update = transition (zero ()) (version 1 1UL) (queryUpdated id 0 "control")

                do! sendRawFrame stream 0x1uy (Encoding.UTF8.GetBytes update)
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        let value = subscription.Next(TimeSpan.FromSeconds 5.)
        check (value["count"].GetValue<int>() = 0) "control ping disrupted text delivery"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let liveFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let server =
            task {
                let! firstContext = listener.GetContextAsync()
                let! firstUpgrade = firstContext.AcceptWebSocketAsync(null)
                use first = firstUpgrade.WebSocket
                let! firstConnectText = receiveText first
                let firstConnect = JsonNode.Parse(firstConnectText)
                check (firstConnect["connectionCount"].GetValue<int>() = 0) "initial connection metadata"
                let! firstAddText = receiveText first
                let firstAdd = JsonNode.Parse(firstAddText)
                let firstModification = (firstAdd["modifications"].AsArray())[0]
                let id = firstModification["queryId"].GetValue<int>()
                let v1 = version 1 1UL
                let v2 = version 1 2UL
                let v3 = version 1 3UL
                do! sendText first (transition (zero ()) v1 (queryUpdated id 0 "雪")) true
                do! sendText first (transition (v1.DeepClone().AsObject()) v2 (queryFailed id)) false
                do! sendText first (transition (v2.DeepClone().AsObject()) v3 (queryUpdated id 1 "recovered")) false
                let mutable currentCount = 1
                let mutable currentText = "recovered"
                let mutable expectedTimestamp = timestamp 3UL

                for reconnectNumber in 1..5 do
                    let! nextContext = listener.GetContextAsync()
                    let! nextUpgrade = nextContext.AcceptWebSocketAsync(null)
                    use nextSocket = nextUpgrade.WebSocket
                    let! reconnectText = receiveText nextSocket
                    let reconnect = JsonNode.Parse(reconnectText)
                    check (reconnect["connectionCount"].GetValue<int>() = reconnectNumber) "reconnect count"
                    check (reconnect["lastCloseReason"].GetValue<string>() = "DebugDisconnect") "reconnect close reason"

                    check
                        (reconnect["maxObservedTimestamp"].GetValue<string>() = expectedTimestamp)
                        "max observed timestamp"

                    let! nextAddText = receiveText nextSocket
                    let nextAdd = JsonNode.Parse(nextAddText)
                    let nextModification = (nextAdd["modifications"].AsArray())[0]
                    check (nextModification["type"].GetValue<string>() = "Add") "rehydration did not resend Add"
                    let hydrationTimestamp = uint64 (reconnectNumber * 2 + 2)
                    let updateTimestamp = hydrationTimestamp + 1UL
                    let hydrated = version 1 hydrationTimestamp
                    let updated = version 1 updateTimestamp

                    do!
                        sendText
                            nextSocket
                            (transition (zero ()) hydrated (queryUpdated id currentCount currentText))
                            false

                    currentCount <- currentCount + 1
                    currentText <- "after reconnect"

                    do!
                        sendText
                            nextSocket
                            (transition
                                (hydrated.DeepClone().AsObject())
                                updated
                                (queryUpdated id currentCount currentText))
                            false

                    expectedTimestamp <- timestamp updateTimestamp
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let args = JsonObject()
        args["room"] <- JsonValue.Create "fixture"
        use! subscription = live.Subscribe("demo:state", args)
        let first = subscription.Next(TimeSpan.FromSeconds 5.)

        check
            (first["count"].GetValue<int>() = 0 && first["text"].GetValue<string>() = "雪")
            "fragmented UTF-8 initial value"

        let failed = subscription.NextUpdate(TimeSpan.FromSeconds 5.)

        match failed.Error with
        | Some(FunctionError(_, message, _, logs)) ->
            check (message = "fixture failure" && logs = [ "fixture log" ]) "structured QueryFailed"
        | _ -> failwith "QueryFailed was not structured"

        let recovered = subscription.Next(TimeSpan.FromSeconds 5.)
        check (recovered["count"].GetValue<int>() = 1) "QueryFailed did not recover"

        for reconnectNumber in 1..5 do
            do! live.DebugDisconnect()
            let reconnected = subscription.Next(TimeSpan.FromSeconds 5.)
            check (reconnected["count"].GetValue<int>() = reconnectNumber + 1) "unchanged hydration was not suppressed"

        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let atomicTransitionFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let invalidVersions =
            [| JsonNode.Parse(sprintf "{\"querySet\":1,\"ts\":\"%s\"}" (timestamp 1UL))
               JsonNode.Parse(sprintf "{\"querySet\":1.0,\"identity\":0,\"ts\":\"%s\"}" (timestamp 1UL))
               JsonNode.Parse(sprintf "{\"querySet\":1,\"identity\":4294967296,\"ts\":\"%s\"}" (timestamp 1UL))
               JsonNode.Parse("{\"querySet\":1,\"identity\":0,\"ts\":\"not-base64\"}")
               JsonNode.Parse(sprintf "{\"querySet\":2,\"identity\":0,\"ts\":\"%s\"}" (timestamp 1UL)) |]

        let server =
            task {
                for invalid in invalidVersions do
                    let! context = listener.GetContextAsync()
                    let! upgrade = context.AcceptWebSocketAsync(null)
                    use socket = upgrade.WebSocket
                    let! _ = receiveText socket
                    let! addText = receiveText socket
                    let add = JsonNode.Parse addText
                    let id = firstModificationId add

                    do!
                        sendText
                            socket
                            (transitionMany (zero ()) invalid [| queryUpdated id 999 "must-not-publish" |])
                            false

                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! addText = receiveText socket
                let add = JsonNode.Parse addText
                let id = firstModificationId add
                let one = version 1 1UL
                let two = version 1 2UL

                do!
                    sendText
                        socket
                        (transitionMany (zero ()) one [| queryUpdated id 100 "superseded"; queryRemoved id |])
                        false

                do!
                    sendText
                        socket
                        (transitionMany
                            (one.DeepClone().AsObject())
                            two
                            [| queryUpdated id 1 "intermediate"; queryUpdated id 2 "final" |])
                        false
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())

        for _ in invalidVersions do
            let update = subscription.NextUpdate(TimeSpan.FromSeconds 5.)

            check
                (update.Error
                 |> Option.exists (function
                     | ProtocolError _ -> true
                     | _ -> false))
                "malformed endVersion leaked a partial update"

        let final = subscription.Next(TimeSpan.FromSeconds 5.)
        check (final["count"].GetValue<int>() = 2) "transition changes were not coalesced"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let timestampFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let thirdConnected =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! firstContext = listener.GetContextAsync()
                let! firstUpgrade = firstContext.AcceptWebSocketAsync(null)
                use first = firstUpgrade.WebSocket
                let! _ = receiveText first
                let! addText = receiveText first
                let add = JsonNode.Parse addText
                let id = firstModificationId add
                let twoFiftyFive = version 1 255UL
                let twoFiftySix = version 1 256UL
                do! sendText first (transition (zero ()) twoFiftyFive (queryUpdated id 0 "255")) false

                do!
                    sendText
                        first
                        (transition (twoFiftyFive.DeepClone().AsObject()) twoFiftySix (queryUpdated id 1 "256"))
                        false

                do!
                    sendText
                        first
                        (transition
                            (twoFiftySix.DeepClone().AsObject())
                            (version 1 255UL)
                            (queryUpdated id 999 "backwards"))
                        false

                let! secondContext = listener.GetContextAsync()
                let! secondUpgrade = secondContext.AcceptWebSocketAsync(null)
                use second = secondUpgrade.WebSocket
                let! secondConnectText = receiveText second
                let secondConnect = JsonNode.Parse secondConnectText

                check
                    (secondConnect["maxObservedTimestamp"].GetValue<string>() = timestamp 256UL)
                    "little-endian max timestamp after 255 to 256"

                let! _ = receiveText second
                do! sendText second (transition (zero ()) (version 1 200UL) (queryUpdated id 1 "recovered")) false

                let! thirdContext = listener.GetContextAsync()
                let! thirdUpgrade = thirdContext.AcceptWebSocketAsync(null)
                use third = thirdUpgrade.WebSocket
                let! thirdConnectText = receiveText third
                let thirdConnect = JsonNode.Parse thirdConnectText

                check
                    (thirdConnect["maxObservedTimestamp"].GetValue<string>() = timestamp 256UL)
                    "max timestamp moved backwards across reconnect"

                let! _ = receiveText third
                thirdConnected.TrySetResult() |> ignore
                do! Task.Delay 100
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        check (((subscription.Next(TimeSpan.FromSeconds 5.))["count"]).GetValue<int>() = 0) "timestamp 255"
        check (((subscription.Next(TimeSpan.FromSeconds 5.))["count"]).GetValue<int>() = 1) "timestamp 256"
        let backwards = subscription.NextUpdate(TimeSpan.FromSeconds 5.)

        check
            (backwards.Error
             |> Option.exists (function
                 | ProtocolError _ -> true
                 | _ -> false))
            "backwards timestamp was accepted"

        check
            (((subscription.Next(TimeSpan.FromSeconds 5.))["count"]).GetValue<int>() = 1)
            "same-value recovery after protocol failure was suppressed"

        check (live.MaxObservedTimestamp = Some(timestamp 256UL)) "numeric timestamp maximum"
        do! live.DebugDisconnect()
        do! thirdConnected.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let semanticHydrationFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let objectValue first =
            let value = JsonObject()

            if first then
                value["a"] <- JsonValue.Create 1
                value["b"] <- null
            else
                value["b"] <- null
                value["a"] <- JsonValue.Create 1

            value :> JsonNode

        let server =
            task {
                let! firstContext = listener.GetContextAsync()
                let! firstUpgrade = firstContext.AcceptWebSocketAsync(null)
                use first = firstUpgrade.WebSocket
                let! _ = receiveText first
                let! addText = receiveText first
                let add = JsonNode.Parse addText
                let id = firstModificationId add
                let one = version 1 1UL
                let two = version 1 2UL
                let three = version 1 3UL
                do! sendText first (transition (zero ()) one (queryUpdatedValue id (objectValue true))) false
                do! sendText first (transition (one.DeepClone().AsObject()) two (queryFailed id)) false

                do!
                    sendText
                        first
                        (transition (two.DeepClone().AsObject()) three (queryUpdatedValue id (objectValue false)))
                        false

                let! secondContext = listener.GetContextAsync()
                let! secondUpgrade = secondContext.AcceptWebSocketAsync(null)
                use second = secondUpgrade.WebSocket
                let! _ = receiveText second
                let! _ = receiveText second
                let four = version 1 4UL
                let five = version 1 5UL
                do! sendText second (transition (zero ()) four (queryUpdatedValue id (objectValue true))) false

                do! sendText second (transition (four.DeepClone().AsObject()) five (queryUpdatedValue id null)) false

                let! thirdContext = listener.GetContextAsync()
                let! thirdUpgrade = thirdContext.AcceptWebSocketAsync(null)
                use third = thirdUpgrade.WebSocket
                let! _ = receiveText third
                let! _ = receiveText third
                let six = version 1 6UL
                let seven = version 1 7UL
                do! sendText third (transition (zero ()) six (queryUpdatedValue id null)) false
                let changed = JsonObject()
                changed["a"] <- JsonValue.Create 2

                do! sendText third (transition (six.DeepClone().AsObject()) seven (queryUpdatedValue id changed)) false
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        let initial = subscription.Next(TimeSpan.FromSeconds 5.)
        check (initial["a"].GetValue<int>() = 1) "semantic initial value"
        let failed = subscription.NextUpdate(TimeSpan.FromSeconds 5.)
        check failed.Error.IsSome "QueryFailed missing from semantic fixture"
        let recovered = subscription.Next(TimeSpan.FromSeconds 5.)
        check (recovered["a"].GetValue<int>() = 1) "same semantic value did not recover QueryFailed"
        do! live.DebugDisconnect()
        check (isNull (subscription.Next(TimeSpan.FromSeconds 5.))) "reordered hydration was not suppressed"
        do! live.DebugDisconnect()
        let changed = subscription.Next(TimeSpan.FromSeconds 5.)
        check (changed["a"].GetValue<int>() = 2) "null hydration was not suppressed"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let socketOwnershipFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()
        let operations = ResizeArray<int64 * string>()
        LiveTestHooks.SocketOperation <- fun operation -> lock operations (fun () -> operations.Add operation)

        try
            let server =
                task {
                    let! context = listener.GetContextAsync()
                    let! upgrade = context.AcceptWebSocketAsync(null)
                    use socket = upgrade.WebSocket
                    let! _ = receiveText socket
                    let! addText = receiveText socket
                    let add = JsonNode.Parse addText
                    let id = firstModificationId add
                    do! sendText socket (transition (zero ()) (version 1 1UL) (queryUpdated id 0 "owner")) false
                    let! _ = receiveText socket
                    do! Task.Delay 50
                }

            let live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
            let! subscription = live.Subscribe("demo:state", JsonObject())
            subscription.Next(TimeSpan.FromSeconds 5.) |> ignore
            (subscription :> IDisposable).Dispose()
            (live :> IDisposable).Dispose()
            do! server.WaitAsync(TimeSpan.FromSeconds 5.)

            let observed = lock operations (fun () -> operations |> Seq.toArray)
            check (observed |> Array.map fst |> Array.distinct |> Array.length = 1) "socket had multiple logical owners"

            for operation in [ "Connect"; "Receive"; "Send"; "Abort"; "Dispose" ] do
                check
                    (observed |> Array.exists (fun (_, current) -> current = operation))
                    ("missing owner operation " + operation)
        finally
            LiveTestHooks.SocketOperation <- fun _ -> ()
    }

let globalDeliveryBudgetFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()
        let sent = TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let ids = ResizeArray<int>()

                for _ in 1..8 do
                    let! addText = receiveText socket
                    let add = JsonNode.Parse addText
                    ids.Add(firstModificationId add)

                let mutable current = zero ()
                let payload = String('g', 600000)

                for index in 1..20 do
                    let next = version 1 (uint64 index)
                    let id = ids[(index - 1) % ids.Count]

                    do!
                        sendText
                            socket
                            (transition (current.DeepClone().AsObject()) next (queryUpdated id index payload))
                            false

                    current <- next

                sent.TrySetResult() |> ignore
                do! Task.Delay 1000
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let subscriptions = ResizeArray<Subscription>()

        for index in 1..8 do
            let args = JsonObject()
            args["room"] <- JsonValue.Create index
            let! subscription = live.Subscribe("demo:state", args)
            subscriptions.Add subscription

        do! sent.Task.WaitAsync(TimeSpan.FromSeconds 15.)
        do! Task.Delay 500
        let count, bytes = live.DeliverySnapshot
        check (count <= 16) "global delivery count exceeded 16"
        check (bytes <= 8 * 1024 * 1024) "global encoded delivery bytes exceeded budget"
        check (bytes < 128 * 1024 * 1024) "global delivery memory exceeded container budget"

        let oversizedArgs = JsonObject()
        oversizedArgs["payload"] <- JsonValue.Create(String('a', 300000))

        try
            let! _ = live.Subscribe("demo:state", oversizedArgs)
            failwith "oversized subscription arguments were accepted"
        with :? ArgumentException ->
            ()

        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let subscriptionAndCommandBudgetFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket

                for _ in 1..64 do
                    let! _ = receiveText socket
                    ()

                do! Task.Delay 500
            }

        let live = new LiveClient(sprintf "http://127.0.0.1:%d" port)

        for index in 1..64 do
            let args = JsonObject()
            args["room"] <- JsonValue.Create index
            let! _ = live.Subscribe("demo:state", args)
            ()

        try
            let! _ = live.Subscribe("demo:state", JsonObject())
            failwith "65th Live subscription was accepted"
        with :? InvalidOperationException ->
            ()

        (live :> IDisposable).Dispose()
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)

        use paused = new LiveClient("http://127.0.0.1:1")
        let release = paused.PauseOwnerForTest()

        let oversizedArgs = JsonObject()
        oversizedArgs["payload"] <- JsonValue.Create(String('x', 300000))

        try
            paused.Subscribe("demo:state", oversizedArgs) |> ignore
            failwith "paused owner retained oversized subscription arguments"
        with :? ArgumentException ->
            ()

        let queued = ResizeArray<Task<int * int>>()
        let mutable rejected = 0

        for _ in 1..300 do
            try
                queued.Add(paused.DeliverySnapshotAsyncForTest())
            with :? InvalidOperationException ->
                rejected <- rejected + 1

        check (rejected > 0 && queued.Count <= 256) "Live command ingress was not bounded"
        release.TrySetResult() |> ignore
        let! _ = Task.WhenAll(queued).WaitAsync(TimeSpan.FromSeconds 5.)

        let bytePort = freePort ()
        use byteListener = new HttpListener()
        byteListener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" bytePort)
        byteListener.Start()

        let expectedAdds =
            TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously)

        let byteServer =
            task {
                let! context = byteListener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! expected = expectedAdds.Task

                for _ in 1..expected do
                    let! _ = receiveText socket
                    ()
            }

        let aggregate = new LiveClient(sprintf "http://127.0.0.1:%d" bytePort)
        let aggregateRelease = aggregate.PauseOwnerForTest()
        let subscriptions = ResizeArray<Task<Subscription>>()
        let aggregateArgs = JsonObject()
        aggregateArgs["payload"] <- JsonValue.Create(String('a', 120000))
        let mutable aggregateRejected = 0

        for _ in 1..64 do
            try
                subscriptions.Add(aggregate.Subscribe("demo:state", aggregateArgs))
            with :? InvalidOperationException ->
                aggregateRejected <- aggregateRejected + 1

        let reservedCount, reservedBytes = aggregate.PendingSubscriptionBudgetForTest

        check
            (aggregateRejected > 0
             && reservedCount = subscriptions.Count
             && reservedCount < 64)
            "pending subscription count was not reserved globally"

        check (reservedBytes <= 4 * 1024 * 1024) "pending subscription bytes exceeded global budget"
        expectedAdds.TrySetResult(subscriptions.Count) |> ignore
        aggregateRelease.TrySetResult() |> ignore
        let! _ = Task.WhenAll(subscriptions).WaitAsync(TimeSpan.FromSeconds 15.)
        (aggregate :> IDisposable).Dispose()
        do! byteServer.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let httpBodyBudgetFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let server =
            task {
                let! context = listener.GetContextAsync()

                let body =
                    Encoding.UTF8.GetBytes(
                        "{\"status\":\"success\",\"value\":\"" + String('h', 9 * 1024 * 1024) + "\"}"
                    )

                context.Response.ContentLength64 <- int64 body.Length

                try
                    do! context.Response.OutputStream.WriteAsync body
                with _ ->
                    ()

                context.Response.Close()
            }

        use client = new Client(sprintf "http://127.0.0.1:%d" port)

        try
            let! _ = client.Query("demo:state", JsonObject())
            failwith "oversized HTTP response was accepted"
        with TransportError(_, message) ->
            check (message.Contains "exceeded") "oversized HTTP response error"

        do! server.WaitAsync(TimeSpan.FromSeconds 5.)

        let args = JsonObject()
        args["payload"] <- JsonValue.Create(String('r', 9 * 1024 * 1024))

        try
            let! _ = client.Query("demo:state", args)
            failwith "oversized HTTP request was accepted"
        with :? ArgumentException ->
            ()
    }

let boundedDeliveryFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let smallSent =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let smallDrained =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let largeSent =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let largeDrained =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let errorsSent =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let errorsDrained =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! addText = receiveText socket
                let add = JsonNode.Parse addText
                let addModification = (add["modifications"].AsArray())[0]
                let id = addModification["queryId"].GetValue<int>()
                let mutable current = zero ()
                let initialVersion = version 1 1UL
                do! sendText socket (transition current initialVersion (queryUpdated id 0 "initial")) false
                current <- initialVersion

                for count in 1..20 do
                    let next = version 1 (uint64 (count + 1))

                    do!
                        sendText
                            socket
                            (transition (current.DeepClone().AsObject()) next (queryUpdated id count "small"))
                            false

                    current <- next

                smallSent.TrySetResult() |> ignore
                do! smallDrained.Task
                let payload = String('x', 100000)

                for count in 200..209 do
                    let next = version 1 (uint64 (count - 178))

                    do!
                        sendText
                            socket
                            (transition (current.DeepClone().AsObject()) next (queryUpdated id count payload))
                            false

                    current <- next

                largeSent.TrySetResult() |> ignore
                do! largeDrained.Task

                for index, marker in [ "error-1"; "error-2"; "error-3" ] |> List.indexed do
                    let next = version 1 (uint64 (index + 32))

                    do!
                        sendText
                            socket
                            (transition (current.DeepClone().AsObject()) next (largeQueryFailed id marker))
                            false

                    current <- next

                errorsSent.TrySetResult() |> ignore
                do! errorsDrained.Task
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        let initial = subscription.Next(TimeSpan.FromSeconds 5.)
        check (initial["count"].GetValue<int>() = 0) "bounded fixture initial"
        do! smallSent.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        do! Task.Delay 250
        let small = ResizeArray<int>()
        let mutable draining = true

        while draining do
            try
                let value = subscription.Next(TimeSpan.FromMilliseconds 80.)
                small.Add(value["count"].GetValue<int>())
            with :? TimeoutException ->
                draining <- false

        check (small.Count = 16 && small[0] = 5 && small[15] = 20) "newest-16 count bound"
        smallDrained.TrySetResult() |> ignore
        do! largeSent.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        do! Task.Delay 250
        let large = ResizeArray<int>()
        draining <- true

        while draining do
            try
                let value = subscription.Next(TimeSpan.FromMilliseconds 80.)
                large.Add(value["count"].GetValue<int>())
            with :? TimeoutException ->
                draining <- false

        check (large.Count = 10 && large[0] = 200 && large[9] = 209) "encoded-byte delivery retention"
        largeDrained.TrySetResult() |> ignore
        do! errorsSent.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        do! Task.Delay 250
        let errors = ResizeArray<string>()
        draining <- true

        while draining do
            try
                let update = subscription.NextUpdate(TimeSpan.FromMilliseconds 80.)

                match update.Error with
                | Some(FunctionError(_, message, Some data, logs)) ->
                    let marker = data["marker"].GetValue<string>()

                    check
                        (message.StartsWith marker && logs.Length = 1 && logs[0].StartsWith marker)
                        "large structured error fields"

                    errors.Add marker
                | _ -> failwith "large QueryFailed was not a structured FunctionError"
            with :? TimeoutException ->
                draining <- false

        check (Seq.toList errors = [ "error-1"; "error-2"; "error-3" ]) "structured-error encoded-byte retention"
        errorsDrained.TrySetResult() |> ignore
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let relayBarrierFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let dequeued =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let release =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        ConvexAdapter.relayBeforePublish <-
            Some(fun () ->
                dequeued.TrySetResult() |> ignore
                release.Task)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! addText = receiveText socket
                let add = JsonNode.Parse addText
                let modification = (add["modifications"].AsArray())[0]
                let id = modification["queryId"].GetValue<int>()
                do! sendText socket (transition (zero ()) (version 1 1UL) (queryUpdated id 0 "paused")) false
                let! removeText = receiveText socket
                let remove = JsonNode.Parse removeText
                let removeModification = (remove["modifications"].AsArray())[0]
                check (removeModification["type"].GetValue<string>() = "Remove") "unsubscribe did not send Remove"
            }

        let input = new AsyncLineReader()
        let output = new AsyncLineWriter()

        let adapter =
            ConvexAdapter.runAdapter input output (Some(sprintf "http://127.0.0.1:%d" port))

        do!
            input.Send
                "{\"id\":\"s\",\"op\":\"subscribe\",\"subscriptionId\":\"race\",\"path\":\"demo:state\",\"args\":{}}"

        let! subscribeAck = output.Read(TimeSpan.FromSeconds 5.)
        let subscribeEvent = JsonNode.Parse subscribeAck
        check (subscribeEvent["type"].GetValue<string>() = "ack") "subscribe ack"
        do! dequeued.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        do! input.Send "{\"id\":\"u\",\"op\":\"unsubscribe\",\"subscriptionId\":\"race\"}"
        let! unsubscribeAck = output.Read(TimeSpan.FromSeconds 5.)
        let unsubscribeEvent = JsonNode.Parse unsubscribeAck

        check
            (unsubscribeEvent["type"].GetValue<string>() = "ack"
             && unsubscribeEvent["id"].GetValue<string>() = "u")
            "unsubscribe completion ack"

        release.TrySetResult() |> ignore
        let! stale = output.TryRead(TimeSpan.FromMilliseconds 200.)
        check stale.IsNone "stale relay crossed unsubscribe acknowledgement"
        do! input.Send "{\"id\":\"c\",\"op\":\"close\"}"
        let! _ = output.Read(TimeSpan.FromSeconds 5.)
        do! adapter.WaitAsync(TimeSpan.FromSeconds 5.)
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
        ConvexAdapter.relayBeforePublish <- None
    }

let replacementBarrierFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let dequeued =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let release =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        ConvexAdapter.relayBeforePublish <-
            Some(fun () ->
                dequeued.TrySetResult() |> ignore
                release.Task)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! oldAddText = receiveText socket
                let oldAdd = JsonNode.Parse oldAddText
                let oldModification = (oldAdd["modifications"].AsArray())[0]
                let oldId = oldModification["queryId"].GetValue<int>()
                do! sendText socket (transition (zero ()) (version 1 1UL) (queryUpdated oldId 99 "stale")) false
                let! removeText = receiveText socket
                let remove = JsonNode.Parse removeText
                let removeModification = (remove["modifications"].AsArray())[0]
                check (removeModification["type"].GetValue<string>() = "Remove") "replacement Remove"
                let! newAddText = receiveText socket
                let newAdd = JsonNode.Parse newAddText
                let newModification = (newAdd["modifications"].AsArray())[0]
                let newId = newModification["queryId"].GetValue<int>()

                do! sendText socket (transition (version 1 1UL) (version 3 2UL) (queryUpdated newId 2 "current")) false
            }

        let input = new AsyncLineReader()
        let output = new AsyncLineWriter()

        let adapter =
            ConvexAdapter.runAdapter input output (Some(sprintf "http://127.0.0.1:%d" port))

        do!
            input.Send
                "{\"id\":\"s1\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}"

        let! _ = output.Read(TimeSpan.FromSeconds 5.)
        do! dequeued.Task.WaitAsync(TimeSpan.FromSeconds 5.)

        do!
            input.Send
                "{\"id\":\"s2\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}"

        let! replacementAck = output.Read(TimeSpan.FromSeconds 5.)
        let replacementEvent = JsonNode.Parse replacementAck
        check (replacementEvent["id"].GetValue<string>() = "s2") "replacement completion ack"
        release.TrySetResult() |> ignore
        let! current = output.Read(TimeSpan.FromSeconds 5.)
        let currentEvent = JsonNode.Parse current
        let currentValue = currentEvent["value"]
        check (currentValue["count"].GetValue<int>() = 2) "stale replacement relay"
        do! input.Send "{\"id\":\"c\",\"op\":\"close\"}"
        let! _ = output.Read(TimeSpan.FromSeconds 5.)
        do! adapter.WaitAsync(TimeSpan.FromSeconds 5.)
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
        ConvexAdapter.relayBeforePublish <- None
    }

let serializationFixture () =
    let result =
        ConvexAdapter.resultEvent
            "r"
            { Value = Some(JsonValue.Create 1)
              Logs = [] }

    check (result.ToJsonString() = "{\"type\":\"result\",\"id\":\"r\",\"value\":1}") "serialized success"

    let error =
        ConvexAdapter.failure (Some "e") None (FunctionError("query", "bad", Some(JsonValue.Create "data"), [ "log" ]))

    let errorDetail = error["error"]

    check
        (errorDetail["name"].GetValue<string>() = "FunctionError"
         && isNull (error["subscriptionId"]))
        "serialized HTTP error"

    let subscription = ConvexAdapter.failure None (Some "s") (ProtocolError "bad frame")

    check
        (subscription["type"].GetValue<string>() = "subscription"
         && isNull (subscription["id"]))
        "serialized subscription error"

    let closed = ConvexAdapter.makeEvent "closed" (Some "c")
    check (closed.ToJsonString() = "{\"type\":\"closed\",\"id\":\"c\"}") "serialized close"

let failedReconnectFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let detached =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! firstContext = listener.GetContextAsync()
                let! firstUpgrade = firstContext.AcceptWebSocketAsync(null)
                use first = firstUpgrade.WebSocket
                let! _ = receiveText first
                let! addText = receiveText first
                let add = JsonNode.Parse addText
                let modification = (add["modifications"].AsArray())[0]
                let id = modification["queryId"].GetValue<int>()
                do! sendText first (transition (zero ()) (version 1 1UL) (queryUpdated id 0 "initial")) false
                do! detached.Task
                // 100 + 200 + 400 + 800 + 1600 ms produces five refused reconnects.
                do! Task.Delay 3500
                listener.Start()
                let! nextContext = listener.GetContextAsync()
                let! nextUpgrade = nextContext.AcceptWebSocketAsync(null)
                use next = nextUpgrade.WebSocket
                let! connectText = receiveText next
                let connect = JsonNode.Parse connectText
                check (connect["connectionCount"].GetValue<int>() >= 6) "five failed reconnect attempts"
                let! nextAddText = receiveText next
                let nextAdd = JsonNode.Parse nextAddText
                let nextModification = (nextAdd["modifications"].AsArray())[0]
                let nextId = nextModification["queryId"].GetValue<int>()
                let hydrated = version 1 2UL
                do! sendText next (transition (zero ()) hydrated (queryUpdated nextId 0 "initial")) false

                do!
                    sendText
                        next
                        (transition (hydrated.DeepClone().AsObject()) (version 1 3UL) (queryUpdated nextId 1 "updated"))
                        false
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        let initial = subscription.Next(TimeSpan.FromSeconds 5.)
        check (initial["count"].GetValue<int>() = 0) "failed reconnect initial"
        do! live.DebugDisconnect()
        listener.Stop()
        detached.TrySetResult() |> ignore
        let updated = subscription.Next(TimeSpan.FromSeconds 10.)
        check (updated["count"].GetValue<int>() = 1) "failed reconnect recovery"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let protocolTransportRecoveryFixture () =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let server =
            task {
                let! firstContext = listener.GetContextAsync()
                let! firstUpgrade = firstContext.AcceptWebSocketAsync(null)
                use first = firstUpgrade.WebSocket
                let! _ = receiveText first
                let! _ = receiveText first
                do! sendText first "{" false

                let! secondContext = listener.GetContextAsync()
                let! secondUpgrade = secondContext.AcceptWebSocketAsync(null)
                use second = secondUpgrade.WebSocket
                let! _ = receiveText second
                let! secondAddText = receiveText second
                let secondAdd = JsonNode.Parse secondAddText
                let secondModification = (secondAdd["modifications"].AsArray())[0]
                let secondId = secondModification["queryId"].GetValue<int>()

                do! sendText second (transition (zero ()) (version 1 1UL) (queryUpdated secondId 1 "protocol")) false

                do! Task.Delay 100

                do!
                    second.CloseOutputAsync(
                        WebSocketCloseStatus.InternalServerError,
                        "fixture transport close",
                        CancellationToken.None
                    )

                let! thirdContext = listener.GetContextAsync()
                let! thirdUpgrade = thirdContext.AcceptWebSocketAsync(null)
                use third = thirdUpgrade.WebSocket
                let! _ = receiveText third
                let! thirdAddText = receiveText third
                let thirdAdd = JsonNode.Parse thirdAddText
                let thirdModification = (thirdAdd["modifications"].AsArray())[0]
                let thirdId = thirdModification["queryId"].GetValue<int>()
                let hydrated = version 1 2UL
                do! sendText third (transition (zero ()) hydrated (queryUpdated thirdId 1 "protocol")) false

                do!
                    sendText
                        third
                        (transition
                            (hydrated.DeepClone().AsObject())
                            (version 1 3UL)
                            (queryUpdated thirdId 2 "transport"))
                        false
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        use! subscription = live.Subscribe("demo:state", JsonObject())
        let protocol = subscription.NextUpdate(TimeSpan.FromSeconds 5.)

        check
            (protocol.Error
             |> Option.exists (function
                 | ProtocolError _ -> true
                 | _ -> false))
            "real ProtocolError event"

        let afterProtocol = subscription.Next(TimeSpan.FromSeconds 5.)
        check (afterProtocol["count"].GetValue<int>() = 1) "protocol recovery"
        let transport = subscription.NextUpdate(TimeSpan.FromSeconds 5.)

        check
            (transport.Error
             |> Option.exists (function
                 | TransportError _ -> true
                 | _ -> false))
            "real TransportError event"

        let hydratedAfterTransport = subscription.Next(TimeSpan.FromSeconds 5.)
        check (hydratedAfterTransport["count"].GetValue<int>() = 1) "transport error same-value recovery"
        let afterTransport = subscription.Next(TimeSpan.FromSeconds 5.)
        check (afterTransport["count"].GetValue<int>() = 2) "transport recovery"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let boundedUnsubscribeFixture mode =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let active =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! _ = receiveText socket
                let mutable sending = true

                if mode = 2 then
                    let bytes = Encoding.UTF8.GetBytes "{\"type\":\"Ping\"}"

                    do!
                        socket.SendAsync(
                            ArraySegment<byte>(bytes, 0, 5),
                            WebSocketMessageType.Text,
                            false,
                            CancellationToken.None
                        )

                if mode = 1 then
                    task {
                        let ping = Encoding.UTF8.GetBytes "{\"type\":\"Ping\"}"

                        try
                            while sending do
                                do!
                                    socket.SendAsync(
                                        ArraySegment<byte> ping,
                                        WebSocketMessageType.Text,
                                        true,
                                        CancellationToken.None
                                    )
                        with _ ->
                            ()
                    }
                    |> ignore

                active.TrySetResult() |> ignore
                let! removeText = receiveText socket
                sending <- false
                let remove = JsonNode.Parse removeText
                let removeModification = (remove["modifications"].AsArray())[0]
                check (removeModification["type"].GetValue<string>() = "Remove") "bounded unsubscribe Remove"
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let! subscription = live.Subscribe("demo:state", JsonObject())
        do! active.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        let watch = Stopwatch.StartNew()
        (subscription :> IDisposable).Dispose()
        watch.Stop()
        check (watch.Elapsed < TimeSpan.FromSeconds 1.) "unsubscribe exceeded deadline"
        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let stalledHandshakeFixture () =
    task {
        let port = freePort ()
        use listener = new TcpListener(IPAddress.Loopback, port)
        listener.Start()

        let server =
            task {
                use! connection = listener.AcceptTcpClientAsync()
                do! Task.Delay 4000
            }

        use live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let watch = Stopwatch.StartNew()
        let mutable failed = false

        try
            let! _ = live.Subscribe("demo:state", JsonObject())
            ()
        with _ ->
            failed <- true

        watch.Stop()
        check (failed && watch.Elapsed < TimeSpan.FromSeconds 4.) "stalled WebSocket handshake was not bounded"
        listener.Stop()

        try
            do! server.WaitAsync(TimeSpan.FromSeconds 1.)
        with _ ->
            ()
    }

let boundedCloseFixture continuous =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let active =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! _ = receiveText socket

                if continuous then
                    active.TrySetResult() |> ignore
                    let ping = Encoding.UTF8.GetBytes "{\"type\":\"Ping\"}"

                    try
                        while socket.State = WebSocketState.Open do
                            do!
                                socket.SendAsync(
                                    ArraySegment<byte>(ping),
                                    WebSocketMessageType.Text,
                                    true,
                                    CancellationToken.None
                                )
                    with _ ->
                        ()
                else
                    let partial = Encoding.UTF8.GetBytes "{\"type\":\"Transition\",\"startVersion\":"

                    do!
                        socket.SendAsync(
                            ArraySegment<byte>(partial),
                            WebSocketMessageType.Text,
                            false,
                            CancellationToken.None
                        )

                    active.TrySetResult() |> ignore
                    let buffer = Array.zeroCreate<byte> 1

                    try
                        let! _ = socket.ReceiveAsync(ArraySegment<byte>(buffer), CancellationToken.None)
                        ()
                    with _ ->
                        ()
            }

        let live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let! subscription = live.Subscribe("demo:state", JsonObject())
        do! active.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        let watch = Stopwatch.StartNew()
        (live :> IDisposable).Dispose()
        watch.Stop()

        check
            (watch.Elapsed < TimeSpan.FromSeconds 1.)
            (if continuous then
                 "close blocked on continuous peer"
             else
                 "close blocked on partial frame")

        try
            (subscription :> IDisposable).Dispose()
        with _ ->
            ()

        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let closeUnsubscribeRaceFixture closeFirst =
    task {
        let port = freePort ()
        use listener = new HttpListener()
        listener.Prefixes.Add(sprintf "http://127.0.0.1:%d/" port)
        listener.Start()

        let active =
            TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)

        let server =
            task {
                let! context = listener.GetContextAsync()
                let! upgrade = context.AcceptWebSocketAsync(null)
                use socket = upgrade.WebSocket
                let! _ = receiveText socket
                let! _ = receiveText socket
                active.TrySetResult() |> ignore

                if closeFirst then
                    let buffer = Array.zeroCreate<byte> 1

                    try
                        let! _ = socket.ReceiveAsync(ArraySegment<byte> buffer, CancellationToken.None)
                        ()
                    with _ ->
                        ()
                else
                    let! removeText = receiveText socket
                    let remove = JsonNode.Parse removeText
                    let modification = (remove["modifications"].AsArray())[0]

                    check
                        (modification["type"].GetValue<string>() = "Remove")
                        "unsubscribe was not ordered before close"
            }

        let live = new LiveClient(sprintf "http://127.0.0.1:%d" port)
        let! subscription = live.Subscribe("demo:state", JsonObject())
        do! active.Task.WaitAsync(TimeSpan.FromSeconds 5.)
        let release = live.PauseOwnerForTest()

        if closeFirst then
            let close = Task.Run(fun () -> (live :> IDisposable).Dispose())

            check
                (SpinWait.SpinUntil((fun () -> live.IsDisposedForTest), TimeSpan.FromSeconds 1.))
                "close did not enter the dispose barrier"

            let unsubscribe = Task.Run(fun () -> (subscription :> IDisposable).Dispose())
            do! unsubscribe.WaitAsync(TimeSpan.FromSeconds 1.)
            release.TrySetResult() |> ignore
            do! close.WaitAsync(TimeSpan.FromSeconds 1.)
        else
            let unsubscribe = Task.Run(fun () -> (subscription :> IDisposable).Dispose())

            check
                (SpinWait.SpinUntil((fun () -> live.PendingCommandsForTest = 1), TimeSpan.FromSeconds 1.))
                "unsubscribe did not enter the owner queue barrier"

            let close = Task.Run(fun () -> (live :> IDisposable).Dispose())

            check
                (SpinWait.SpinUntil((fun () -> live.IsDisposedForTest), TimeSpan.FromSeconds 1.))
                "close did not queue behind unsubscribe"

            release.TrySetResult() |> ignore
            do! unsubscribe.WaitAsync(TimeSpan.FromSeconds 4.)
            do! close.WaitAsync(TimeSpan.FromSeconds 4.)

        do! server.WaitAsync(TimeSpan.FromSeconds 5.)
    }

let adapterTcpFixture () =
    task {
        let port = freePort ()
        use adapterProcess = new Process()
        adapterProcess.StartInfo.FileName <- "dotnet"
        adapterProcess.StartInfo.ArgumentList.Add("client/tests/conformance/bin/Release/net8.0/Adapter.dll")
        adapterProcess.StartInfo.Environment["ADAPTER_LISTEN"] <- sprintf "127.0.0.1:%d" port
        adapterProcess.StartInfo.UseShellExecute <- false
        check (adapterProcess.Start()) "adapter process did not start"
        use controller = new TcpClient()
        let mutable connected = false

        for _ in 1..100 do
            if not connected then
                try
                    do! controller.ConnectAsync(IPAddress.Loopback, port)
                    connected <- true
                with _ ->
                    do! Task.Delay 10

        check connected "adapter TCP listener did not start"
        use stream = controller.GetStream()
        use reader = new StreamReader(stream)

        let oversized =
            Encoding.UTF8.GetBytes(String('雪', ConvexAdapter.MaximumNdjsonBytes / 3 + 1) + "\n")

        do! stream.WriteAsync oversized
        let! oversizedError = reader.ReadLineAsync()
        let oversizedEvent = JsonNode.Parse oversizedError

        check
            ((oversizedEvent["error"]["name"]).GetValue<string>() = "ProtocolError")
            "oversized TCP NDJSON was not rejected"

        let hello =
            Encoding.UTF8.GetBytes "{\"protocolVersion\":1,\"id\":\"h\",\"op\":\"hello\"}\n"
        // Partial writes exercise incremental NDJSON framing, not a cooperative whole-line writer.
        do! stream.WriteAsync(hello, 0, 7)
        do! stream.WriteAsync(hello, 7, hello.Length - 7)
        let! ready = reader.ReadLineAsync()
        let readyEvent = JsonNode.Parse ready
        check (readyEvent["type"].GetValue<string>() = "ready") "partial TCP hello"
        let close = Encoding.UTF8.GetBytes "{\"id\":\"c\",\"op\":\"close\"}\n"
        do! stream.WriteAsync(close)
        let! closed = reader.ReadLineAsync()
        let closedEvent = JsonNode.Parse closed
        check (closedEvent["type"].GetValue<string>() = "closed") "TCP close event"
        do! adapterProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds 5.)
        check (adapterProcess.ExitCode = 0) "adapter TCP process failed"
    }

let adapterStdinEofFixture () =
    task {
        use adapterProcess = new Process()
        adapterProcess.StartInfo.FileName <- "dotnet"
        adapterProcess.StartInfo.ArgumentList.Add("client/tests/conformance/bin/Release/net8.0/Adapter.dll")
        adapterProcess.StartInfo.UseShellExecute <- false
        adapterProcess.StartInfo.RedirectStandardInput <- true
        adapterProcess.StartInfo.RedirectStandardOutput <- true
        check (adapterProcess.Start()) "stdin adapter process did not start"
        do! adapterProcess.StandardInput.WriteAsync("{\"protocolVersion\":1,")
        do! adapterProcess.StandardInput.WriteLineAsync("\"id\":\"h\",\"op\":\"hello\"}")
        let! ready = adapterProcess.StandardOutput.ReadLineAsync()
        let readyEvent = JsonNode.Parse ready
        check (readyEvent["type"].GetValue<string>() = "ready") "partial stdin hello"
        adapterProcess.StandardInput.Close()
        do! adapterProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds 5.)
        check (adapterProcess.ExitCode = 0) "stdin EOF did not cleanly stop adapter"
    }

let adapterStdinOversizedEofFixture () =
    task {
        use adapterProcess = new Process()
        adapterProcess.StartInfo.FileName <- "dotnet"
        adapterProcess.StartInfo.ArgumentList.Add("client/tests/conformance/bin/Release/net8.0/Adapter.dll")
        adapterProcess.StartInfo.UseShellExecute <- false
        adapterProcess.StartInfo.RedirectStandardInput <- true
        adapterProcess.StartInfo.RedirectStandardOutput <- true
        check (adapterProcess.Start()) "oversized stdin adapter process did not start"
        let oversized = String('雪', ConvexAdapter.MaximumNdjsonBytes / 3 + 1)
        do! adapterProcess.StandardInput.WriteAsync oversized
        adapterProcess.StandardInput.Close()
        let! errorLine = adapterProcess.StandardOutput.ReadLineAsync()
        let error = JsonNode.Parse errorLine

        check
            ((error["error"]["name"]).GetValue<string>() = "ProtocolError")
            "unterminated oversized stdin NDJSON was not rejected"

        do! adapterProcess.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds 5.)
        check (adapterProcess.ExitCode = 0) "oversized stdin EOF did not cleanly stop adapter"
    }

let stalledControllerWriterFixture () =
    task {
        let stalled (_: byte array) (cancellation: CancellationToken) =
            task { do! Task.Delay(Timeout.Infinite, cancellation) }

        let writer = ConvexAdapter.BoundedWriter stalled
        let watch = Stopwatch.StartNew()
        let blocked = writer.Write(ConvexAdapter.makeEvent "ack" (Some "blocked"))
        let closing = writer.Close(ConvexAdapter.makeEvent "closed" (Some "close"))

        for pending in [ blocked; closing ] do
            try
                do! pending
                failwith "stalled controller write unexpectedly completed"
            with TransportError _ ->
                ()

        watch.Stop()
        check (watch.Elapsed < TimeSpan.FromSeconds 3.) "controller backpressure held close indefinitely"
    }

[<EntryPoint>]
let main _ =
    ExampleCountTests.run ()
    controlFrameFixture().GetAwaiter().GetResult()
    liveFixture().GetAwaiter().GetResult()
    atomicTransitionFixture().GetAwaiter().GetResult()
    timestampFixture().GetAwaiter().GetResult()
    semanticHydrationFixture().GetAwaiter().GetResult()
    socketOwnershipFixture().GetAwaiter().GetResult()
    globalDeliveryBudgetFixture().GetAwaiter().GetResult()
    subscriptionAndCommandBudgetFixture().GetAwaiter().GetResult()
    httpBodyBudgetFixture().GetAwaiter().GetResult()
    boundedDeliveryFixture().GetAwaiter().GetResult()
    relayBarrierFixture().GetAwaiter().GetResult()
    replacementBarrierFixture().GetAwaiter().GetResult()
    serializationFixture ()
    failedReconnectFixture().GetAwaiter().GetResult()
    protocolTransportRecoveryFixture().GetAwaiter().GetResult()
    boundedUnsubscribeFixture 0 |> fun work -> work.GetAwaiter().GetResult()
    boundedUnsubscribeFixture 1 |> fun work -> work.GetAwaiter().GetResult()
    boundedUnsubscribeFixture 2 |> fun work -> work.GetAwaiter().GetResult()
    stalledHandshakeFixture().GetAwaiter().GetResult()
    boundedCloseFixture false |> fun work -> work.GetAwaiter().GetResult()
    boundedCloseFixture true |> fun work -> work.GetAwaiter().GetResult()
    closeUnsubscribeRaceFixture true |> fun work -> work.GetAwaiter().GetResult()
    closeUnsubscribeRaceFixture false |> fun work -> work.GetAwaiter().GetResult()
    adapterStdinEofFixture().GetAwaiter().GetResult()
    adapterStdinOversizedEofFixture().GetAwaiter().GetResult()
    adapterTcpFixture().GetAwaiter().GetResult()
    stalledControllerWriterFixture().GetAwaiter().GetResult()
    printfn "F# client tests passed"
    0
