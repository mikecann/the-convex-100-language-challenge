open System
open System.Globalization
open System.Text.Json.Nodes
open Convex

let count (value: JsonNode) place =
    match value with
    | :? JsonObject as objectValue when not (isNull objectValue["count"]) ->
        // Convex may encode a whole counter as either 0 or 0.0. Normalize only finite Int32 values.
        let raw = objectValue["count"].ToJsonString()

        match Double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture) with
        | true, number when
            Double.IsFinite number
            && number = Math.Truncate number
            && number >= float Int32.MinValue
            && number <= float Int32.MaxValue
            ->
            int number
        | _ -> invalidOp (place + " did not return a whole Int32 count")
    | _ -> invalidOp (place + " did not return a counter value")

[<EntryPoint>]
let main argv =
    let url = Environment.GetEnvironmentVariable "CONVEX_URL"

    if String.IsNullOrWhiteSpace url then
        invalidOp "CONVEX_URL is required"

    // A unique verifier room prevents other examples from changing this counter.
    let room = if argv.Length > 0 then argv[0] else "fsharp-example"
    let roomArgs = JsonObject()
    roomArgs["room"] <- JsonValue.Create room

    // This public demonstration needs no authentication. Both native clients are disposed on exit.
    use client = new Client(url)
    use live = new LiveClient(url)

    // Read the HTTP query and decode its JSON result into an ordinary F# integer.
    let before =
        client.Query("demo:state", roomArgs).Result.Value
        |> Option.defaultWith (fun () -> invalidOp "query returned null")
        |> fun value -> count value "current query"

    // Start Live before the mutation so this initial value is our observation point.
    use subscription = live.Subscribe("demo:state", roomArgs).Result

    let initial =
        subscription.Next(TimeSpan.FromSeconds 10.)
        |> fun value -> count value "initial Live value"

    if initial <> before then
        invalidOp "Live initial value disagreed"

    // runId makes the mutation idempotent if a transport retry occurs.
    let mutationArgs = JsonObject()
    mutationArgs["room"] <- JsonValue.Create room
    mutationArgs["language"] <- JsonValue.Create "fsharp"
    mutationArgs["runId"] <- JsonValue.Create(Guid.NewGuid().ToString())

    let mutation =
        client.Mutation("demo:increment", mutationArgs).Result.Value
        |> Option.defaultWith (fun () -> invalidOp "mutation returned null")

    let mutationObject = mutation.AsObject()
    let applied = mutationObject["applied"].GetValue<bool>()
    let after = count mutationObject["state"] "mutation"

    if not applied || after <> before + 1 then
        invalidOp "mutation did not produce the next count"

    // Only print after the matching Live update proves the full 0 -> 1 journey.
    let updated =
        subscription.Next(TimeSpan.FromSeconds 10.)
        |> fun value -> count value "updated Live value"

    if updated <> after then
        invalidOp "Live update disagreed"

    printfn "current count: %d" before
    printfn "live initial count: %d" initial
    printfn "mutation applied: true"
    printfn "mutation count: %d" after
    printfn "live updated count: %d" updated
    printfn "verified count: %d -> %d" before updated
    0
