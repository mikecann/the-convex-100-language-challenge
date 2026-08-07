// Convex's documented public HTTP API: POST /api/query, /api/mutation, and
// /api/action with `format: "json"`. This is the whole yellow-badge surface,
// and it is deliberately independent of the sync socket.

type operation =
  | Query
  | Mutation
  | Action

let operationPath = operation =>
  switch operation {
  | Query => "/api/query"
  | Mutation => "/api/mutation"
  | Action => "/api/action"
  }

let operationName = operation =>
  switch operation {
  | Query => "query"
  | Mutation => "mutation"
  | Action => "action"
  }

type callResult = {
  value: Js.Json.t,
  logs: array<string>,
}

// A Convex answer is small. Reading an unbounded body into memory would let a
// wrong URL or a hostile proxy exhaust the 128 MiB the verifier allows the
// container, so the client stops well before that.
let maximumResponseBytes = 2 * 1024 * 1024
let maximumRequestBytes = 2 * 1024 * 1024
let requestDeadlineMs = 10000

let requestBody = (~path, ~args) =>
  ConvexJson.stringify(
    ConvexJson.object_([
      ("path", Js.Json.string(path)),
      ("args", args),
      // The documented public format. Convex JavaScript's HTTP client currently
      // sends the undocumented `convex_encoded_json` instead; using that would
      // claim Int64 and bytes fidelity this client does not have.
      ("format", Js.Json.string("json")),
    ]),
  )

let requestHeaders = (~clientVersion, ~authToken) => {
  let headers = Js.Dict.empty()
  Js.Dict.set(headers, "content-type", "application/json")
  Js.Dict.set(headers, "accept", "application/json")
  Js.Dict.set(headers, "convex-client", clientVersion)

  // An empty token means "no identity". The token is forwarded exactly as
  // configured: this client never parses, trims, or re-encodes it.
  if authToken != "" {
    Js.Dict.set(headers, "authorization", "Bearer " ++ authToken)
  }
  headers
}

let decodeResponse = (~status, ~text): callResult => {
  let json = switch ConvexJson.parse(text) {
  | Ok(json) => json
  | Error(message) =>
    ConvexError.raiseError(
      ConvexError.protocol(
        "HTTP " ++ Belt.Int.toString(status) ++ " response was not Convex JSON: " ++ message,
      ),
    )
  }

  let logs = switch ConvexJson.strictLogLines(json, "logLines") {
  | Ok(logs) => logs
  | Error(message) => ConvexError.raiseError(ConvexError.protocol(message))
  }

  switch ConvexJson.stringField(json, "status") {
  | Some("success") =>
    switch ConvexJson.field(json, "value") {
    | Some(value) => {value, logs}
    | None =>
      ConvexError.raiseError(ConvexError.protocol("successful Convex response has no value"))
    }
  | Some("error") =>
    // An application failure is a real answer, not a transport problem. Its
    // message, structured ConvexError payload, and logs all survive.
    switch ConvexJson.stringField(json, "errorMessage") {
    | Some(message) =>
      ConvexError.raiseError(
        ConvexError.functionFailure(message, ConvexJson.field(json, "errorData"), logs),
      )
    | None =>
      ConvexError.raiseError(ConvexError.protocol("error response has no string errorMessage"))
    }
  | Some(other) =>
    ConvexError.raiseError(
      ConvexError.protocol(
        "HTTP " ++ Belt.Int.toString(status) ++ " response has unknown status " ++ other,
      ),
    )
  | None =>
    ConvexError.raiseError(
      ConvexError.protocol(
        "HTTP " ++ Belt.Int.toString(status) ++ " response has no Convex status field",
      ),
    )
  }
}

let call = async (~deploymentUrl, ~clientVersion, ~authToken, ~operation, ~path, ~args) => {
  if path == "" {
    ConvexError.raiseError(ConvexError.usage("Convex function path is required"))
  } else if ConvexNode.utf8ByteLength(path) > 1024 {
    ConvexError.raiseError(ConvexError.usage("Convex function path is too long"))
  }
  // Convex functions take named arguments. Rejecting anything else here keeps
  // the failure next to the mistake instead of inside a server error.
  switch ConvexJson.asObject(args) {
  | Some(_) => ()
  | None =>
    ConvexError.raiseError(ConvexError.usage("Convex arguments must be a named JSON object"))
  }

  let url = deploymentUrl ++ operationPath(operation)
  let body = requestBody(~path, ~args)
  if ConvexNode.utf8ByteLength(body) > maximumRequestBytes {
    ConvexError.raiseError(ConvexError.usage("Convex request exceeds the byte limit"))
  }
  let request: ConvexNode.fetchRequest = {
    method: "POST",
    headers: requestHeaders(~clientVersion, ~authToken),
    body,
  }

  let response = try {
    await ConvexNode.boundedFetch(url, request, maximumResponseBytes, requestDeadlineMs)
  } catch {
  | error =>
    ConvexError.raiseError(
      ConvexError.transport(
        operationName(operation) ++
        " transport failed: " ++
        ConvexError.fromException(error).message,
      ),
    )
  }

  let status = response.status
  let text = response.text

  // A proxy error body is not a Convex result even when it happens to contain
  // a success-shaped JSON object. Status takes precedence over the envelope.
  if status < 200 || status >= 300 {
    ConvexError.raiseError(
      ConvexError.transport(
        operationName(operation) ++ " returned HTTP " ++ Belt.Int.toString(status),
      ),
    )
  }

  decodeResponse(~status, ~text)
}
