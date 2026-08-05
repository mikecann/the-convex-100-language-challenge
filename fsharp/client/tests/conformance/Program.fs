module ConvexAdapter

open System
open System.Collections.Generic
open System.IO
open System.Net
open System.Net.Sockets
open System.Text
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks
open Convex

[<Literal>]
let MaximumNdjsonBytes = 4 * 1024 * 1024

[<Literal>]
let MaximumControllerLineBytes = 8 * 1024 * 1024

[<Literal>]
let MaximumQueuedControllerBytes = 16 * 1024 * 1024

type ActiveSubscription =
    { Generation: int64
      Subscription: Subscription }

type private ReadOutcome =
    | Line of string
    | Rejected of exn
    | EndOfInput

type private WriteRequest =
    { Bytes: byte array
      Predicate: unit -> bool
      Completion: TaskCompletionSource<unit>
      IsClose: bool }

// Language-local tests pause exactly after dequeue to prove acknowledgement is a relay barrier.
let mutable relayBeforePublish: (unit -> Task) option = None

/// Incremental byte reader for real stdin and TCP mode. It never allocates an
/// arbitrarily large line, and it discards the rest of an oversized record so a
/// later valid NDJSON command still starts at an actual newline boundary.
type private BoundedStreamNdjsonReader(stream: Stream) =
    let readBuffer = Array.zeroCreate<byte> 8192
    let line = new MemoryStream()
    let strictUtf8 = UTF8Encoding(false, true)
    let mutable offset = 0
    let mutable available = 0
    let mutable discarding = false
    let mutable reachedEnd = false

    let decodeLine () =
        let bytes = line.ToArray()
        line.SetLength 0

        let count =
            if bytes.Length > 0 && bytes[bytes.Length - 1] = 13uy then
                bytes.Length - 1
            else
                bytes.Length

        try
            Line(strictUtf8.GetString(bytes, 0, count))
        with :? DecoderFallbackException as error ->
            Rejected(ProtocolError("adapter input was not valid UTF-8: " + error.Message))

    member _.Read() =
        task {
            let mutable result: ReadOutcome option = None

            while result.IsNone do
                if offset = available && not reachedEnd then
                    let! count = stream.ReadAsync(readBuffer.AsMemory())
                    offset <- 0
                    available <- count

                    if count = 0 then
                        reachedEnd <- true

                if offset < available then
                    let value = readBuffer[offset]
                    offset <- offset + 1

                    if value = 10uy then
                        if discarding then
                            discarding <- false

                            result <-
                                Some(
                                    Rejected(
                                        ProtocolError(sprintf "adapter command exceeded %d bytes" MaximumNdjsonBytes)
                                    )
                                )
                        else
                            result <- Some(decodeLine ())
                    elif not discarding then
                        line.WriteByte value

                        if line.Length > int64 MaximumNdjsonBytes then
                            line.SetLength 0
                            discarding <- true
                elif reachedEnd then
                    if discarding then
                        discarding <- false

                        result <-
                            Some(
                                Rejected(ProtocolError(sprintf "adapter command exceeded %d bytes" MaximumNdjsonBytes))
                            )
                    elif line.Length > 0L then
                        result <- Some(decodeLine ())
                    else
                        result <- Some EndOfInput

            return result.Value
        }

/// One bounded pump serializes controller writes. Registry locks are used only
/// by the predicate immediately before a write, never while output backpressure
/// is awaited. Every write has a deadline and the pending queue has count and
/// encoded-byte ceilings.
type BoundedWriter(writeBytes: byte array -> CancellationToken -> Task<unit>) =
    let sync = obj ()
    let signal = new SemaphoreSlim(0)
    let requests = Queue<WriteRequest>()
    let mutable queuedBytes = 0
    let mutable accepting = true
    let mutable terminalError: exn option = None

    let failPending error =
        lock sync (fun () ->
            terminalError <- Some error
            accepting <- false

            while requests.Count > 0 do
                let request = requests.Dequeue()
                queuedBytes <- queuedBytes - request.Bytes.Length
                request.Completion.TrySetException error |> ignore)

    let pump =
        task {
            let mutable running = true

            while running do
                do! signal.WaitAsync()

                let request =
                    lock sync (fun () ->
                        if requests.Count = 0 then
                            None
                        else
                            let value = requests.Dequeue()
                            queuedBytes <- queuedBytes - value.Bytes.Length
                            Some value)

                match request with
                | None -> ()
                | Some current ->
                    try
                        if current.Predicate() then
                            use timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds 1500.)
                            do! writeBytes current.Bytes timeout.Token

                        current.Completion.TrySetResult() |> ignore

                        if current.IsClose then
                            running <- false
                    with error ->
                        let transport = TransportError("adapter write", error.Message)
                        current.Completion.TrySetException transport |> ignore
                        failPending transport
                        running <- false
        }

    do pump |> ignore

    member private _.Queue(predicate: unit -> bool, value: JsonObject, isClose: bool) =
        let bytes = Encoding.UTF8.GetBytes(value.ToJsonString() + "\n")

        let completion =
            TaskCompletionSource<unit>(TaskCreationOptions.RunContinuationsAsynchronously)

        lock sync (fun () ->
            match terminalError with
            | Some error -> completion.TrySetException error |> ignore
            | None when not accepting -> completion.TrySetException(ObjectDisposedException "adapter writer") |> ignore
            | None when bytes.Length > MaximumControllerLineBytes ->
                completion.TrySetException(
                    ProtocolError(sprintf "adapter event exceeded %d bytes" MaximumControllerLineBytes)
                )
                |> ignore
            | None when
                requests.Count >= 32
                || queuedBytes + bytes.Length > MaximumQueuedControllerBytes
                ->
                completion.TrySetException(TransportError("adapter write", "controller output queue is full"))
                |> ignore
            | None ->
                if isClose then
                    accepting <- false

                let request =
                    { Bytes = bytes
                      Predicate = predicate
                      Completion = completion
                      IsClose = isClose }

                requests.Enqueue request
                queuedBytes <- queuedBytes + bytes.Length
                signal.Release() |> ignore)

        completion.Task

    member this.Write(value: JsonObject) =
        this.Queue((fun () -> true), value, false)

    member this.WriteIf(predicate, value: JsonObject) = this.Queue(predicate, value, false)

    member this.Close(value: JsonObject) =
        this.Queue((fun () -> true), value, true)

let makeEvent (kind: string) (id: string option) =
    let value = JsonObject()
    value["type"] <- JsonValue.Create kind

    match id with
    | Some present -> value["id"] <- JsonValue.Create present
    | None -> ()

    value

let addLogs (value: JsonObject) (logs: string list) =
    if not (List.isEmpty logs) then
        value["logs"] <- JsonArray(logs |> List.map (fun line -> JsonValue.Create line :> JsonNode) |> List.toArray)

let failure (id: string option) (subscriptionId: string option) (error: exn) =
    let value = makeEvent (if subscriptionId.IsSome then "subscription" else "error") id

    match subscriptionId with
    | Some present -> value["subscriptionId"] <- JsonValue.Create present
    | None -> ()

    let detail = JsonObject()

    match error with
    | FunctionError(_, message, data, logs) ->
        detail["name"] <- JsonValue.Create "FunctionError"
        detail["message"] <- JsonValue.Create message

        match data with
        | Some present -> detail["data"] <- present.DeepClone()
        | None -> ()

        addLogs value logs
    | TransportError(_, message) ->
        detail["name"] <- JsonValue.Create "TransportError"
        detail["message"] <- JsonValue.Create message
    | ProtocolError message ->
        detail["name"] <- JsonValue.Create "ProtocolError"
        detail["message"] <- JsonValue.Create message
    | _ ->
        detail["name"] <- JsonValue.Create(error.GetType().Name)
        detail["message"] <- JsonValue.Create error.Message

    value["error"] <- detail
    value

let resultEvent (id: string) (result: Result) =
    let value = makeEvent "result" (Some id)

    match result.Value with
    | Some present -> value["value"] <- present.DeepClone()
    | None -> value["value"] <- null

    addLogs value result.Logs
    value

let subscriptionEvent (id: string) (update: Update) =
    let value = makeEvent "subscription" None
    value["subscriptionId"] <- JsonValue.Create id

    match update.Value with
    | Some present -> value["value"] <- present.DeepClone()
    | None -> value["value"] <- null

    addLogs value update.Logs
    value

let private textReader (input: TextReader) () =
    task {
        let! line = input.ReadLineAsync()

        if isNull line then
            return EndOfInput
        elif Encoding.UTF8.GetByteCount line > MaximumNdjsonBytes then
            return Rejected(ProtocolError(sprintf "adapter command exceeded %d bytes" MaximumNdjsonBytes))
        else
            return Line line
    }

let private textWriter (output: TextWriter) (bytes: byte array) (cancellation: CancellationToken) =
    task {
        let text = Encoding.UTF8.GetString(bytes, 0, bytes.Length - 1)
        do! output.WriteLineAsync(text).WaitAsync(cancellation)
    }

let private streamWriter (output: Stream) (bytes: byte array) (cancellation: CancellationToken) =
    task {
        do! output.WriteAsync(bytes.AsMemory(), cancellation)
        do! output.FlushAsync cancellation
    }

let private runAdapterCore (readLine: unit -> Task<ReadOutcome>) (writer: BoundedWriter) (deployment: string option) =
    task {
        let registryLock = obj ()
        let subscriptions = Dictionary<string, ActiveSubscription>()
        let mutable generation = 0L
        let mutable client: Client option = None
        let mutable live: LiveClient option = None

        let requireUrl () =
            match deployment with
            | Some value when not (String.IsNullOrWhiteSpace value) -> value
            | _ -> invalidOp "CONVEX_URL is required"

        let getClient () =
            match client with
            | Some value -> value
            | None ->
                let value = new Client(requireUrl ())
                client <- Some value
                value

        let getLive () =
            match live with
            | Some value -> value
            | None ->
                let value = new LiveClient(requireUrl ())
                live <- Some value
                value

        let isCurrent id active =
            lock registryLock (fun () ->
                match subscriptions.TryGetValue id with
                | true, current ->
                    current.Generation = active.Generation
                    && Object.ReferenceEquals(current.Subscription, active.Subscription)
                | _ -> false)

        let removeOne id =
            lock registryLock (fun () ->
                match subscriptions.TryGetValue id with
                | true, current ->
                    subscriptions.Remove id |> ignore
                    Some current
                | _ -> None)

        let removeAll () =
            lock registryLock (fun () ->
                let values = subscriptions.Values |> Seq.toArray
                subscriptions.Clear()
                values)

        let relay id active =
            task {
                let mutable running = true

                while running && isCurrent id active do
                    try
                        let! update = Task.Run(fun () -> active.Subscription.NextUpdate(TimeSpan.FromDays 1.))

                        match relayBeforePublish with
                        | Some barrier -> do! barrier ()
                        | None -> ()

                        let value =
                            match update.Error with
                            | Some error -> failure None (Some id) error
                            | None -> subscriptionEvent id update

                        do! writer.WriteIf((fun () -> isCurrent id active), value)
                    with
                    | :? ObjectDisposedException -> running <- false
                    | error ->
                        try
                            do! writer.WriteIf((fun () -> isCurrent id active), failure None (Some id) error)
                        with _ ->
                            ()

                        running <- false
            }

        try
            let mutable finished = false

            while not finished do
                match! readLine () with
                | EndOfInput -> finished <- true
                | Rejected error ->
                    try
                        do! writer.Write(failure None None error)
                    with _ ->
                        finished <- true
                | Line line ->
                    let mutable id: string option = None

                    try
                        let command = JsonNode.Parse(line).AsObject()

                        id <-
                            if isNull command["id"] then
                                None
                            else
                                Some(command["id"].GetValue<string>())

                        let operation =
                            if isNull command["op"] then
                                invalidArg "op" "operation is required"
                            else
                                command["op"].GetValue<string>()

                        match operation with
                        | "hello" ->
                            if
                                isNull command["protocolVersion"]
                                || command["protocolVersion"].GetValue<int>() <> 1
                            then
                                invalidArg "protocolVersion" "unsupported adapter protocol version"

                            let value = makeEvent "ready" id
                            value["protocolVersion"] <- JsonValue.Create 1
                            value["language"] <- JsonValue.Create "fsharp"
                            value["implementation"] <- JsonValue.Create "native-fsharp-net8"
                            value["runtime"] <- JsonValue.Create(Environment.Version.ToString())
                            do! writer.Write value
                        | "close" ->
                            let remaining = removeAll ()

                            for entry in remaining do
                                (entry.Subscription :> IDisposable).Dispose()

                            match live with
                            | Some value -> (value :> IDisposable).Dispose()
                            | None -> ()

                            match client with
                            | Some value -> (value :> IDisposable).Dispose()
                            | None -> ()

                            try
                                do! writer.Close(makeEvent "closed" id)
                            finally
                                finished <- true
                        | "setAuth" ->
                            (getClient ())
                                .SetAuth(
                                    if isNull command["token"] then
                                        None
                                    else
                                        Some(command["token"].GetValue<string>())
                                )

                            do! writer.Write(makeEvent "ack" id)
                        | ("query" | "mutation" | "action") as functionType ->
                            let args =
                                if isNull command["args"] then
                                    JsonObject()
                                else
                                    command["args"].AsObject()

                            let path = command["path"].GetValue<string>()

                            let! result =
                                match functionType with
                                | "query" -> (getClient ()).Query(path, args)
                                | "mutation" -> (getClient ()).Mutation(path, args)
                                | _ -> (getClient ()).Action(path, args)

                            do! writer.Write(resultEvent id.Value result)
                        | "subscribe" ->
                            let subscriptionId = command["subscriptionId"].GetValue<string>()

                            match removeOne subscriptionId with
                            | Some old -> (old.Subscription :> IDisposable).Dispose()
                            | None -> ()

                            let! subscription =
                                (getLive ())
                                    .Subscribe(command["path"].GetValue<string>(), command["args"].AsObject())

                            let active =
                                lock registryLock (fun () ->
                                    generation <- generation + 1L

                                    let current =
                                        { Generation = generation
                                          Subscription = subscription }

                                    subscriptions[subscriptionId] <- current
                                    current)

                            do! writer.Write(makeEvent "ack" id)
                            relay subscriptionId active |> ignore
                        | "unsubscribe" ->
                            let subscriptionId = command["subscriptionId"].GetValue<string>()

                            match removeOne subscriptionId with
                            | Some old -> (old.Subscription :> IDisposable).Dispose()
                            | None -> ()

                            do! writer.Write(makeEvent "ack" id)
                        | "debugDisconnect" ->
                            match live with
                            | Some value -> do! value.DebugDisconnect()
                            | None -> invalidOp "Live WebSocket is not connected"

                            do! writer.Write(makeEvent "ack" id)
                        | other -> invalidArg "op" ("unknown operation: " + other)
                    with error ->
                        try
                            do! writer.Write(failure id None error)
                        with _ ->
                            finished <- true
        finally
            let remaining = removeAll ()

            for active in remaining do
                try
                    (active.Subscription :> IDisposable).Dispose()
                with _ ->
                    ()

            match live with
            | Some value ->
                try
                    (value :> IDisposable).Dispose()
                with _ ->
                    ()
            | None -> ()

            match client with
            | Some value -> (value :> IDisposable).Dispose()
            | None -> ()
    }

let runAdapter (input: TextReader) (output: TextWriter) (deployment: string option) =
    let writer = BoundedWriter(textWriter output)
    runAdapterCore (textReader input) writer deployment

let runAdapterStreams (input: Stream) (output: Stream) (deployment: string option) =
    let reader = BoundedStreamNdjsonReader(input)
    let writer = BoundedWriter(streamWriter output)
    runAdapterCore reader.Read writer deployment

[<EntryPoint>]
let main _ =
    let listen = Environment.GetEnvironmentVariable "ADAPTER_LISTEN"
    let deployment = Environment.GetEnvironmentVariable "CONVEX_URL" |> Option.ofObj

    if String.IsNullOrWhiteSpace listen then
        use input = Console.OpenStandardInput()
        use output = Console.OpenStandardOutput()

        runAdapterStreams input output deployment
        |> fun work -> work.GetAwaiter().GetResult()
    else
        let separator = listen.LastIndexOf ':'

        if separator <= 0 then
            invalidArg "ADAPTER_LISTEN" "expected host:port"

        let server =
            new TcpListener(
                IPAddress.Parse(listen.Substring(0, separator)),
                Int32.Parse(listen.Substring(separator + 1))
            )

        server.Start()
        use connection = server.AcceptTcpClient()
        use stream = connection.GetStream()

        runAdapterStreams stream stream deployment
        |> fun work -> work.GetAwaiter().GetResult()

        server.Stop()

    0
