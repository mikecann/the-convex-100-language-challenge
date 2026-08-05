module ExampleCountTests

open System
open System.Text.Json.Nodes
open ExampleCount

let private parsed raw =
    JsonNode.Parse("{\"count\":" + raw + "}")

let private accepted raw expected =
    if count (parsed raw) "test" <> expected then
        failwith ("count parser rejected exact value " + raw)

let private rejected raw =
    try
        count (parsed raw) "test" |> ignore
        failwith ("count parser accepted inexact value " + raw)
    with :? InvalidOperationException ->
        ()

let run () =
    accepted "0" 0
    accepted "0.0" 0
    accepted "100e-2" 1
    accepted "2147483647.000" Int32.MaxValue
    accepted "-2147483648.0" Int32.MinValue
    rejected "1e-400"
    rejected "1e-9223372036854775808"
    rejected "1e-9223372036854775809"
    rejected "1.0000000000000000000000000001"
    rejected "2147483648"
    rejected "-2147483649"
    rejected "1e100000"
    rejected "1e9223372036854775808"
