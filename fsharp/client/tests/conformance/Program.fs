module ConvexAdapter

open System
open System.Collections.Generic
open System.IO
open System.Net
open System.Net.Sockets
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks
open Convex

type ActiveSubscription =
    { Generation: int64
      Subscription: Subscription }

// Language-local tests pause exactly after dequeue to prove acknowledgement is a relay barrier.
let mutable relayBeforePublish: (unit -> Task) option = None

type LockedWriter(target: TextWriter) =
    let gate = new SemaphoreSlim(1, 1)
    let mutable closed = false

    member _.Write(value: JsonObject) =
        task {
            do! gate.WaitAsync()

            try
                if not closed then
                    do! target.WriteLineAsync(value.ToJsonString())
            finally
                gate.Release() |> ignore
        }

    member _.WriteIf(predicate: unit -> bool, value: JsonObject) =
        task {
            do! gate.WaitAsync()

            try
                if not closed && predicate () then
                    do! target.WriteLineAsync(value.ToJsonString())
            finally
                gate.Release() |> ignore
        }

    member _.Close(value: JsonObject) =
        task {
            do! gate.WaitAsync()

            try
                if not closed then
                    closed <- true
                    do! target.WriteLineAsync(value.ToJsonString())
            finally
                gate.Release() |> ignore
        }

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

let runAdapter (input: TextReader) (output: TextWriter) (deployment: string option) =
    task {
        let writer = LockedWriter(output)
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
                        do! writer.WriteIf((fun () -> isCurrent id active), failure None (Some id) error)
                        running <- false
            }

        try
            let mutable finished = false

            while not finished do
                let! line = input.ReadLineAsync()

                if isNull line then
                    finished <- true
                else
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
                            lock registryLock (fun () ->
                                for entry in subscriptions.Values do
                                    (entry.Subscription :> IDisposable).Dispose()

                                subscriptions.Clear())

                            match live with
                            | Some value -> (value :> IDisposable).Dispose()
                            | None -> ()

                            match client with
                            | Some value -> (value :> IDisposable).Dispose()
                            | None -> ()

                            do! writer.Close(makeEvent "closed" id)
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

                            let previous =
                                lock registryLock (fun () ->
                                    match subscriptions.TryGetValue subscriptionId with
                                    | true, current ->
                                        subscriptions.Remove subscriptionId |> ignore
                                        Some current
                                    | _ -> None)
                            // Dispose completes the old relay generation before the replacement acknowledgement.
                            match previous with
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

                            let previous =
                                lock registryLock (fun () ->
                                    match subscriptions.TryGetValue subscriptionId with
                                    | true, current ->
                                        subscriptions.Remove subscriptionId |> ignore
                                        Some current
                                    | _ -> None)

                            match previous with
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
                        do! writer.Write(failure id None error)
        finally
            let remaining =
                lock registryLock (fun () ->
                    let values = subscriptions.Values |> Seq.toArray
                    subscriptions.Clear()
                    values)

            for active in remaining do
                (active.Subscription :> IDisposable).Dispose()

            match live with
            | Some value -> (value :> IDisposable).Dispose()
            | None -> ()

            match client with
            | Some value -> (value :> IDisposable).Dispose()
            | None -> ()
    }

[<EntryPoint>]
let main _ =
    let listen = Environment.GetEnvironmentVariable "ADAPTER_LISTEN"
    let deployment = Environment.GetEnvironmentVariable "CONVEX_URL" |> Option.ofObj

    if String.IsNullOrWhiteSpace listen then
        runAdapter Console.In Console.Out deployment
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
        use input = new StreamReader(stream)
        use output = new StreamWriter(stream, AutoFlush = true)
        runAdapter input output deployment |> fun work -> work.GetAwaiter().GetResult()
        server.Stop()

    0
