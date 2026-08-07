// Small decoding helpers shared by the HTTP client, the sync protocol, the
// conformance adapter, and the canonical example. They exist so every surface
// makes the same decision about what a Convex JSON value is allowed to be.

let object_ = entries => Js.Json.object_(Js.Dict.fromArray(entries))

let emptyObject = () => Js.Json.object_(Js.Dict.empty())

let field = (json, key) =>
  switch Js.Json.classify(json) {
  | JSONObject(dict) => Js.Dict.get(dict, key)
  | _ => None
  }

let asObject = json =>
  switch Js.Json.classify(json) {
  | JSONObject(dict) => Some(dict)
  | _ => None
  }

let asArray = json =>
  switch Js.Json.classify(json) {
  | JSONArray(values) => Some(values)
  | _ => None
  }

let asString = json =>
  switch Js.Json.classify(json) {
  | JSONString(value) => Some(value)
  | _ => None
  }

let asBool = json =>
  switch Js.Json.classify(json) {
  | JSONTrue => Some(true)
  | JSONFalse => Some(false)
  | _ => None
  }

let isNull = json =>
  switch Js.Json.classify(json) {
  | JSONNull => true
  | _ => false
  }

let stringField = (json, key) =>
  switch field(json, key) {
  | Some(value) => asString(value)
  | None => None
  }

let stringFieldOr = (json, key, fallback) =>
  switch stringField(json, key) {
  | Some(value) => value
  | None => fallback
  }

let objectField = (json, key) =>
  switch field(json, key) {
  | Some(value) => asObject(value)
  | None => None
  }

// Log lines are optional everywhere in the Convex wire format. An absent list
// and an empty list mean the same thing to a caller, so both decode to [].
let logLines = (json, key) =>
  switch field(json, key) {
  | Some(value) =>
    switch Js.Json.classify(value) {
    | JSONArray(items) =>
      Js.Array2.reduce(
        items,
        (accumulator, item) =>
          switch asString(item) {
          | Some(line) => Js.Array2.concat(accumulator, [line])
          | None => accumulator
          },
        [],
      )
    | _ => []
    }
  | None => []
  }

// Wire decoders use the strict form. Optional means absent, not malformed:
// once present, every log entry must be a string or the whole envelope is a
// protocol error.
let strictLogLines = (json, key): result<array<string>, string> =>
  switch field(json, key) {
  | None => Ok([])
  | Some(value) =>
    switch asArray(value) {
    | None => Error(key ++ " must be an array of strings")
    | Some(items) => {
        let logs = []
        let invalid = ref(false)
        Js.Array2.forEach(items, item =>
          switch asString(item) {
          | Some(line) => Js.Array2.push(logs, line)->ignore
          | None => invalid := true
          }
        )
        invalid.contents ? Error(key ++ " must contain only strings") : Ok(logs)
      }
    }
  }

let maximumInt = 2147483647.0
let minimumInt = -2147483648.0

// Convex numbers are JSON doubles, so a counter can arrive as `0`, `0.0`, or
// `1e0`. Accept any mathematically integral value that still fits an idiomatic
// ReScript int, and reject quoted, fractional, non-finite, or overflowing
// values instead of silently truncating them into a plausible-looking answer.
let asInt = json =>
  switch Js.Json.classify(json) {
  | JSONNumber(value) =>
    if !Js.Float.isFinite(value) {
      None
    } else if Js.Math.floor_float(value) != value {
      None
    } else if value > maximumInt || value < minimumInt {
      None
    } else {
      Some(Belt.Float.toInt(value))
    }
  | _ => None
  }

let intField = (json, key) =>
  switch field(json, key) {
  | Some(value) => asInt(value)
  | None => None
  }

let parse = (text): result<Js.Json.t, string> =>
  try Ok(Js.Json.parseExn(text)) catch {
  | Js.Exn.Error(error) =>
    switch Js.Exn.message(error) {
    | Some(message) => Error(message)
    | None => Error("invalid JSON")
    }
  | _ => Error("invalid JSON")
  }

let stringify = json => Js.Json.stringify(json)

// Structural comparison of two decoded values. Both sides always come from the
// same server serialising the same query result, so comparing the re-encoded
// text is enough to recognise an unchanged value after a reconnect. It is
// deliberately conservative: a false "changed" only costs one extra update,
// while a false "unchanged" would hide a real result.
let equal = (left, right) => stringify(left) == stringify(right)
