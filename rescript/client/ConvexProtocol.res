// The pinned realtime profile: convex-rs 0.10.4 (commit
// 6f1df8a8ba1665084ec001e307ca841ca17074d7) speaking unversioned `/api/sync`.
// This module owns URL shapes, the protocol's state versions and opaque
// timestamps, and the encode/decode step for every message the profile uses.
// Keeping it separate from the socket owner makes the wire format testable
// without a network.

let initialTimestamp = "AAAAAAAAAAA="

type stateVersion = {
  querySet: int,
  identity: int,
  ts: string,
}

let zeroVersion = () => {querySet: 0, identity: 0, ts: initialTimestamp}

let stateVersionJson = version =>
  ConvexJson.object_([
    ("querySet", Js.Json.number(Belt.Int.toFloat(version.querySet))),
    ("identity", Js.Json.number(Belt.Int.toFloat(version.identity))),
    ("ts", Js.Json.string(version.ts)),
  ])

let decodeStateVersion = json =>
  switch (
    ConvexJson.intField(json, "querySet"),
    ConvexJson.intField(json, "identity"),
    ConvexJson.stringField(json, "ts"),
  ) {
  | (Some(querySet), Some(identity), Some(ts)) if querySet >= 0 && identity >= 0 =>
    Some({querySet, identity, ts})
  | _ => None
  }

let sameVersion = (left, right) =>
  left.querySet == right.querySet && left.identity == right.identity && left.ts == right.ts

// Protocol timestamps are opaque base64 of a little-endian unsigned 64-bit
// value. Comparing the encoded strings, or the bytes left to right, would order
// them wrongly as soon as the low bytes roll over, so decode and compare from
// the most significant byte down.
let decodeTimestamp = value => {
  let decoded = ConvexNode.bufferFrom(value, "base64")

  // Node's base64 decoder ignores junk instead of failing, so re-encoding is
  // the only reliable way to reject a value that was never a timestamp.
  if ConvexNode.bytesToString(decoded, "base64") != value {
    Error("timestamp is not canonical base64")
  } else if ConvexNode.bytesLength(decoded) != 8 {
    Error(
      "expected an 8 byte timestamp, got " ++ Belt.Int.toString(ConvexNode.bytesLength(decoded)),
    )
  } else {
    Ok(decoded)
  }
}

let compareTimestamps = (left, right) =>
  switch (decodeTimestamp(left), decodeTimestamp(right)) {
  | (Error(message), _) => Error("decode left timestamp: " ++ message)
  | (_, Error(message)) => Error("decode right timestamp: " ++ message)
  | (Ok(leftBytes), Ok(rightBytes)) => {
      let result = ref(0)
      let index = ref(7)
      while result.contents == 0 && index.contents >= 0 {
        let leftByte = ConvexNode.byteAt(leftBytes, index.contents)
        let rightByte = ConvexNode.byteAt(rightBytes, index.contents)
        if leftByte > rightByte {
          result := 1
        } else if leftByte < rightByte {
          result := -1
        }
        index := index.contents - 1
      }
      Ok(result.contents)
    }
  }

// A deployment URL is the one piece of configuration a user supplies, so it is
// validated once, up front, rather than producing a confusing request failure
// later. Credentials, queries, and fragments are rejected instead of being
// quietly forwarded to Convex.
type normalizedUrl = {valid: bool, value: string}

let normalizeDeploymentUrlRaw: string => normalizedUrl = %raw(`function (raw) {
  const value = raw.trim();
  if (/[\u0000-\u001f\u007f]/.test(value)) return {valid: false, value: ""};
  try {
    const url = new URL(value);
    if (url.protocol !== "http:" && url.protocol !== "https:") return {valid: false, value: ""};
    if (!url.hostname || url.username || url.password) return {valid: false, value: ""};
    if ((url.pathname && url.pathname !== "/") || url.search || url.hash) return {valid: false, value: ""};
    return {valid: true, value: url.origin};
  } catch (_) {
    return {valid: false, value: ""};
  }
}`)

let normalizeDeploymentUrl = (raw): result<string, string> => {
  let trimmed = Js.String2.trim(raw)
  let normalized = normalizeDeploymentUrlRaw(trimmed)
  if !normalized.valid {
    Error("Convex deployment URL must be an absolute http or https URL")
  } else {
    Ok(normalized.value)
  }
}

// The pinned profile uses the unversioned sync endpoint. Convex JavaScript
// 1.43.0 uses `/api/<version>/sync` instead; mixing the two would combine
// incompatible session semantics.
let syncUrl = deploymentUrl =>
  if Js.String2.startsWith(deploymentUrl, "https://") {
    "wss://" ++ Js.String2.sliceToEnd(deploymentUrl, ~from=8) ++ "/api/sync"
  } else {
    "ws://" ++ Js.String2.sliceToEnd(deploymentUrl, ~from=7) ++ "/api/sync"
  }

// A fresh Connect message identifies a new client session. The pinned profile
// carries the number of previous connections, why the last one ended, and the
// newest timestamp this client has already observed, so the server can decide
// what the reconnected session still needs.
let connectMessage = (~sessionId, ~connectionCount, ~lastCloseReason, ~maxObservedTimestamp) => {
  let base = [
    ("type", Js.Json.string("Connect")),
    ("sessionId", Js.Json.string(sessionId)),
    ("connectionCount", Js.Json.number(Belt.Int.toFloat(connectionCount))),
    ("lastCloseReason", Js.Json.string(lastCloseReason)),
    ("clientTs", Js.Json.number(0.0)),
  ]
  let entries = switch maxObservedTimestamp {
  | "" => base
  | timestamp => Js.Array2.concat(base, [("maxObservedTimestamp", Js.Json.string(timestamp))])
  }
  ConvexJson.object_(entries)
}

type queryModification =
  | Add({queryId: int, path: string, args: Js.Json.t})
  | Remove({queryId: int})

let modificationJson = modification =>
  switch modification {
  | Add({queryId, path, args}) =>
    ConvexJson.object_([
      ("type", Js.Json.string("Add")),
      ("queryId", Js.Json.number(Belt.Int.toFloat(queryId))),
      ("udfPath", Js.Json.string(path)),
      ("args", Js.Json.array([args])),
    ])
  | Remove({queryId}) =>
    ConvexJson.object_([
      ("type", Js.Json.string("Remove")),
      ("queryId", Js.Json.number(Belt.Int.toFloat(queryId))),
    ])
  }

// The query set is versioned, not merged: every change names the version it
// expects to be applied to. Only the socket owner may build one of these,
// because two concurrent writers would produce a version gap the server
// rejects.
let modifyQuerySetMessage = (~baseVersion, ~newVersion, ~modifications) =>
  ConvexJson.object_([
    ("type", Js.Json.string("ModifyQuerySet")),
    ("baseVersion", Js.Json.number(Belt.Int.toFloat(baseVersion))),
    ("newVersion", Js.Json.number(Belt.Int.toFloat(newVersion))),
    ("modifications", Js.Json.array(Js.Array2.map(modifications, modificationJson))),
  ])

type transitionChange =
  | QueryUpdated({queryId: int, value: Js.Json.t, logs: array<string>})
  | QueryFailed({queryId: int, message: string, data: option<Js.Json.t>, logs: array<string>})
  | QueryRemoved({queryId: int})

type transition = {
  startVersion: stateVersion,
  endVersion: stateVersion,
  changes: array<transitionChange>,
}

let decodeChange = (json): result<transitionChange, string> =>
  switch (ConvexJson.stringField(json, "type"), ConvexJson.intField(json, "queryId")) {
  | (None, _) => Error("Transition modification is missing a type")
  | (_, None) => Error("Transition modification is missing a numeric queryId")
  | (_, Some(queryId)) if queryId < 0 => Error("Transition queryId must be nonnegative")
  | (Some("QueryUpdated"), Some(queryId)) =>
    switch (ConvexJson.field(json, "value"), ConvexJson.strictLogLines(json, "logLines")) {
    | (Some(value), Ok(logs)) => Ok(QueryUpdated({queryId, value, logs}))
    | (_, Error(message)) => Error(message)
    | (None, _) => Error("QueryUpdated is missing its value")
    }
  | (Some("QueryFailed"), Some(queryId)) =>
    switch (
      ConvexJson.stringField(json, "errorMessage"),
      ConvexJson.strictLogLines(json, "logLines"),
    ) {
    | (Some(message), Ok(logs)) =>
      Ok(
        QueryFailed({
          queryId,
          message,
          data: ConvexJson.field(json, "errorData"),
          logs,
        }),
      )
    | (_, Error(message)) => Error(message)
    | _ => Error("QueryFailed is missing a string errorMessage")
    }
  // `{queryId}` (punned) parses as a block returning that int, not as a
  // one-field record, and the resulting type error came out as a
  // confusing "inlined record ... could escape" instead of the real
  // ambiguity; spelling out the field disambiguates it.
  | (Some("QueryRemoved"), Some(queryId)) => Ok(QueryRemoved({queryId: queryId}))
  | (Some(other), _) => Error("unknown Transition modification " ++ other)
  }

let decodeTransition = (json): result<transition, string> =>
  switch (ConvexJson.field(json, "startVersion"), ConvexJson.field(json, "endVersion")) {
  | (Some(startJson), Some(endJson)) =>
    switch (decodeStateVersion(startJson), decodeStateVersion(endJson)) {
    | (Some(startVersion), Some(endVersion)) => {
        let raw = switch ConvexJson.field(json, "modifications") {
        | Some(value) =>
          switch ConvexJson.asArray(value) {
          | Some(items) => Ok(items)
          | None => Error("Transition modifications must be an array")
          }
        | None => Error("Transition is missing modifications")
        }
        switch raw {
        | Error(message) => Error(message)
        | Ok(items) => {
            let failure = ref(None)
            let changes = []
            Js.Array2.forEach(items, item =>
              switch (failure.contents, decodeChange(item)) {
              | (Some(_), _) => ()
              | (None, Error(message)) => failure := Some(message)
              | (None, Ok(change)) => Js.Array2.push(changes, change)->ignore
              }
            )
            switch failure.contents {
            | Some(message) => Error(message)
            | None => Ok({startVersion, endVersion, changes})
            }
          }
        }
      }
    | _ => Error("Transition versions are malformed")
    }
  | _ => Error("Transition is missing startVersion or endVersion")
  }

type serverMessage =
  | Transition(transition)
  | Ignorable(string) // Ping and the mutation/action responses this profile never asks for
  | ServerError(string) // FatalError and AuthError, which end the connection
  | Unsupported(string) // including TransitionChunk, which the pinned profile does not assemble

let decodeServerMessage = (json): result<serverMessage, string> =>
  switch ConvexJson.stringField(json, "type") {
  | None => Error("server message is missing a type")
  | Some("Transition") =>
    switch decodeTransition(json) {
    | Ok(transition) => Ok(Transition(transition))
    | Error(message) => Error(message)
    }
  | Some("Ping") => Ok(Ignorable("Ping"))
  | Some("MutationResponse") => Ok(Ignorable("MutationResponse"))
  | Some("ActionResponse") => Ok(Ignorable("ActionResponse"))
  | Some("FatalError") =>
    switch ConvexJson.stringField(json, "error") {
    | Some(message) => Ok(ServerError("FatalError: " ++ message))
    | None => Error("FatalError is missing a string error")
    }
  | Some("AuthError") =>
    switch ConvexJson.stringField(json, "error") {
    | Some(message) => Ok(ServerError("AuthError: " ++ message))
    | None => Error("AuthError is missing a string error")
    }
  | Some("TransitionChunk") =>
    Ok(Unsupported("TransitionChunk assembly is outside the pinned convex-rs 0.10.4 profile"))
  | Some(other) => Ok(Unsupported("unknown server message " ++ other))
  }
