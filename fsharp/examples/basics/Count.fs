module ExampleCount

open System
open System.Globalization
open System.Numerics
open System.Text.Json.Nodes

// Parse the JSON number as decimal digits and an exponent. Using Double here
// would let underflow or precision rounding turn a non-integer into an integer.
let private wholeInt32 (raw: string) =
    let exponentIndex = raw.IndexOfAny([| 'e'; 'E' |])

    let mantissa, exponentText =
        if exponentIndex < 0 then
            raw, None
        else
            raw.Substring(0, exponentIndex), Some(raw.Substring(exponentIndex + 1))

    let negative = mantissa.StartsWith("-", StringComparison.Ordinal)
    let unsignedMantissa = if negative then mantissa.Substring 1 else mantissa
    let decimalIndex = unsignedMantissa.IndexOf '.'

    let digits, fractionalDigits =
        if decimalIndex < 0 then
            unsignedMantissa, 0
        else
            unsignedMantissa.Remove(decimalIndex, 1), unsignedMantissa.Length - decimalIndex - 1

    if digits |> Seq.forall ((=) '0') then
        Some 0
    else
        let exponent =
            match exponentText with
            | None -> Some 0I
            | Some text ->
                match BigInteger.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) with
                | true, value -> Some value
                | _ -> None

        match exponent with
        | None -> None
        | Some value ->
            // JSON permits exponents much larger than Int64. BigInteger keeps
            // the scale calculation exact instead of wrapping at either edge.
            let scale = bigint fractionalDigits - value

            let integerDigits =
                if scale > 0I then
                    if scale > bigint digits.Length then
                        None
                    else
                        let split = digits.Length - int scale
                        let discarded = digits.Substring split

                        if discarded |> Seq.forall ((=) '0') then
                            Some(digits.Substring(0, split))
                        else
                            None
                elif scale < 0I then
                    let zeroes = -scale

                    if zeroes > 10I || bigint digits.Length + zeroes > 11I then
                        None
                    else
                        Some(digits + String('0', int zeroes))
                else
                    Some digits

            match integerDigits with
            | None -> None
            | Some value ->
                let normalized = value.TrimStart '0'
                let normalized = if normalized = "" then "0" else normalized
                let signed = if negative then "-" + normalized else normalized

                match Int32.TryParse(signed, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) with
                | true, result -> Some result
                | _ -> None

let count (value: JsonNode) place =
    match value with
    | :? JsonObject as objectValue when not (isNull objectValue["count"]) ->
        match wholeInt32 (objectValue["count"].ToJsonString()) with
        | Some number -> number
        | None -> invalidOp (place + " did not return a whole Int32 count")
    | _ -> invalidOp (place + " did not return a counter value")
