// Convex failures fall into three kinds that must never collapse into one
// another, because the conformance suite distinguishes them and because an
// application reacts differently to each.
//
//   FunctionError  the Convex function ran and threw. `data` carries the
//                  structured `ConvexError` payload when the function supplied
//                  one, which is how a caller reads an application error code.
//   ProtocolError  a peer said something this client's pinned contract does
//                  not allow. Retrying the same request will not help.
//   TransportError HTTP, TLS, DNS, or WebSocket transport failed. The Live
//                  layer treats this as reconnectable; a one-shot HTTP call
//                  surfaces it to the caller.

primitive NoLogs
  """
  The shared empty log line list, so an error or result without logs does not
  allocate a fresh array at every call site.
  """
  fun apply(): Array[String] val => recover val Array[String] end

primitive FunctionFailure
primitive ProtocolFailure
primitive TransportFailure

type ConvexFailure is (FunctionFailure | ProtocolFailure | TransportFailure)

class val ConvexError
  """
  A single error value carried across actor boundaries.

  `data` is a JSON value and `has_data` distinguishes an absent payload from a
  payload that is literally JSON `null`. The adapter relies on that difference:
  the schema forbids serialising an absent field as `null`.
  """

  let kind: ConvexFailure
  let message: String
  let data: JsonValue
  let has_data: Bool
  let logs: Array[String] val

  new val create(
    kind': ConvexFailure,
    message': String,
    data': JsonValue = None,
    has_data': Bool = false,
    logs': Array[String] val = NoLogs())
  =>
    kind = kind'
    message = message'
    data = data'
    has_data = has_data'
    logs = logs'

  new val function(
    message': String,
    data': JsonValue = None,
    has_data': Bool = false,
    logs': Array[String] val = NoLogs())
  =>
    kind = FunctionFailure
    message = message'
    data = data'
    has_data = has_data'
    logs = logs'

  new val protocol(message': String) =>
    kind = ProtocolFailure
    message = message'
    data = None
    has_data = false
    logs = NoLogs()

  new val transport(message': String) =>
    kind = TransportFailure
    message = message'
    data = None
    has_data = false
    logs = NoLogs()

  fun name(): String =>
    """
    The `error.name` the adapter reports, and the label used in diagnostics.
    """
    match kind
    | FunctionFailure => "FunctionError"
    | ProtocolFailure => "ProtocolError"
    | TransportFailure => "TransportError"
    end

  fun describe(): String =>
    name() + ": " + message

class val ConvexResult
  """
  A successful Convex function result. The value stays as JSON so the caller
  decodes it into whatever shape their application wants without the client
  guessing, and so log lines survive alongside it.
  """

  let value: JsonValue
  let logs: Array[String] val

  new val create(
    value': JsonValue,
    logs': Array[String] val = NoLogs())
  =>
    value = value'
    logs = logs'

interface tag ConvexCallback
  """
  Completion for a one-shot client operation.

  `step` is chosen by the caller and echoed back, so a single actor can drive a
  whole sequence of Convex calls without a separate callback object per call.
  """
  be convex_ok(step: String, result: ConvexResult)
  be convex_failed(step: String, error': ConvexError)

interface tag LiveWatcher
  """
  Receives Live subscription updates.

  A reactive query publishes its current value, so a failure is a value too:
  `live_failed` is followed by `live_value` again once the query recovers, on
  the same subscription.
  """
  be live_value(handle: LiveHandle, result: ConvexResult)
  be live_failed(handle: LiveHandle, error': ConvexError)
