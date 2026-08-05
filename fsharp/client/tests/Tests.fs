open System
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

let version (querySet: int) (timestamp: string) =
    let value = JsonObject()
    value["querySet"] <- JsonValue.Create querySet
    value["identity"] <- JsonValue.Create 0
    value["ts"] <- JsonValue.Create timestamp
    value

let zero () = version 0 "AAAAAAAAAAA="

let transition (startVersion: JsonObject) (endVersion: JsonObject) (modification: JsonNode) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create "Transition"
    value["startVersion"] <- startVersion
    value["endVersion"] <- endVersion
    value["modifications"] <- JsonArray([| modification |])
    value.ToJsonString()

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

                let update =
                    transition (zero ()) (version 1 "control") (queryUpdated id 0 "control")

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
                let v1 = version 1 "AAAAAAAAAAE="
                let v2 = version 1 "AAAAAAAAAAI="
                let v3 = version 1 "AAAAAAAAAAM="
                do! sendText first (transition (zero ()) v1 (queryUpdated id 0 "雪")) true
                do! sendText first (transition (v1.DeepClone().AsObject()) v2 (queryFailed id)) false
                do! sendText first (transition (v2.DeepClone().AsObject()) v3 (queryUpdated id 1 "recovered")) false
                let mutable currentCount = 1
                let mutable currentText = "recovered"
                let mutable expectedTimestamp = "AAAAAAAAAAM="

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
                    let hydrationTimestamp = sprintf "hydration-%d" reconnectNumber
                    let updateTimestamp = sprintf "update-%d" reconnectNumber
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

                    expectedTimestamp <- updateTimestamp
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
                let initialVersion = version 1 "bounded-initial"
                do! sendText socket (transition current initialVersion (queryUpdated id 0 "initial")) false
                current <- initialVersion

                for count in 1..20 do
                    let next = version 1 (sprintf "small-%d" count)

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
                    let next = version 1 (sprintf "large-%d" count)

                    do!
                        sendText
                            socket
                            (transition (current.DeepClone().AsObject()) next (queryUpdated id count payload))
                            false

                    current <- next

                largeSent.TrySetResult() |> ignore
                do! largeDrained.Task

                for marker in [ "error-1"; "error-2"; "error-3" ] do
                    let next = version 1 marker

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

        check (large.Count = 2 && large[0] = 208 && large[1] = 209) "encoded-byte delivery bound"
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

        check (Seq.toList errors = [ "error-2"; "error-3" ]) "structured-error encoded-byte bound"
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
                do! sendText socket (transition (zero ()) (version 1 "relay") (queryUpdated id 0 "paused")) false
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
                do! sendText socket (transition (zero ()) (version 1 "old") (queryUpdated oldId 99 "stale")) false
                let! removeText = receiveText socket
                let remove = JsonNode.Parse removeText
                let removeModification = (remove["modifications"].AsArray())[0]
                check (removeModification["type"].GetValue<string>() = "Remove") "replacement Remove"
                let! newAddText = receiveText socket
                let newAdd = JsonNode.Parse newAddText
                let newModification = (newAdd["modifications"].AsArray())[0]
                let newId = newModification["queryId"].GetValue<int>()

                do!
                    sendText
                        socket
                        (transition (version 1 "old") (version 3 "new") (queryUpdated newId 2 "current"))
                        false
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
                do! sendText first (transition (zero ()) (version 1 "initial") (queryUpdated id 0 "initial")) false
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
                let hydrated = version 1 "hydrated"
                do! sendText next (transition (zero ()) hydrated (queryUpdated nextId 0 "initial")) false

                do!
                    sendText
                        next
                        (transition
                            (hydrated.DeepClone().AsObject())
                            (version 1 "updated")
                            (queryUpdated nextId 1 "updated"))
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

                do!
                    sendText
                        second
                        (transition (zero ()) (version 1 "recovered-protocol") (queryUpdated secondId 1 "protocol"))
                        false

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
                let hydrated = version 1 "hydrated-transport"
                do! sendText third (transition (zero ()) hydrated (queryUpdated thirdId 1 "protocol")) false

                do!
                    sendText
                        third
                        (transition
                            (hydrated.DeepClone().AsObject())
                            (version 1 "recovered-transport")
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

[<EntryPoint>]
let main _ =
    controlFrameFixture().GetAwaiter().GetResult()
    liveFixture().GetAwaiter().GetResult()
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
    adapterStdinEofFixture().GetAwaiter().GetResult()
    adapterTcpFixture().GetAwaiter().GetResult()
    printfn "F# client tests passed"
    0
