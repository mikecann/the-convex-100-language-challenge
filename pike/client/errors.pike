// Structured failures for the native Pike Convex client.
//
// This fragment is textually included by convex.pike. Keeping the four kinds in
// one place is what makes the adapter truthful: a Convex function that rejects
// a call is never flattened into a network outage, malformed wire data is never
// reported as a successful value, and a closed client never looks like a
// transport failure the controller could retry.
#ifndef CONVEX_ERRORS_PIKE
#define CONVEX_ERRORS_PIKE

// A Convex function ran and returned a failure. The deployment is healthy.
constant FUNCTION_ERROR = "FunctionError";
// The peer spoke something this client refuses to guess about. Fail closed.
constant PROTOCOL_ERROR = "ProtocolError";
// DNS, TCP, TLS, the WebSocket, or a deadline gave up before an answer.
constant TRANSPORT_ERROR = "TransportError";
// The caller kept using a client or subscription it had already closed.
constant CLOSED_ERROR = "ClosedError";

class ConvexError
{
  // Duck-typed marker so `catch` blocks can separate a classified Convex
  // failure from an arbitrary Pike runtime error without a type cast.
  constant is_convex_error = 1;

  string kind;
  string message;
  string operation;

  // Convex's `errorData` is genuinely optional, and the shared adapter schema
  // does not permit an invented null. Presence is tracked separately from the
  // value so an absent payload is omitted rather than serialised as null.
  int carries_data;
  mixed data;
  array(string) logs = ({});

  protected void create(string error_kind, string error_message,
                        void|string error_operation)
  {
    kind = error_kind;
    message = error_message;
    operation = error_operation || "";
  }

  this_program with_data(mixed value)
  {
    data = value;
    carries_data = 1;
    return this;
  }

  this_program with_logs(array(string) lines)
  {
    logs = lines || ({});
    return this;
  }

  string describe()
  {
    if (sizeof(operation))
      return sprintf("%s (%s): %s", kind, operation, message);
    return sprintf("%s: %s", kind, message);
  }
}

ConvexError function_error(string message, void|string operation)
{
  return ConvexError(FUNCTION_ERROR, message, operation);
}

ConvexError protocol_error(string message, void|string operation)
{
  return ConvexError(PROTOCOL_ERROR, message, operation);
}

ConvexError transport_error(string message, void|string operation)
{
  return ConvexError(TRANSPORT_ERROR, message, operation);
}

ConvexError closed_error(string message, void|string operation)
{
  return ConvexError(CLOSED_ERROR, message, operation);
}

// Normalise anything `catch` produced. An unexpected Pike error is a transport
// fault from the controller's point of view, but it keeps its original text so
// the failure is still diagnosable instead of silently reclassified.
ConvexError as_convex_error(mixed thrown, void|string operation)
{
  if (objectp(thrown) && thrown->is_convex_error)
    return [object(ConvexError)]thrown;
  string text = describe_error(thrown);
  // describe_error keeps the trailing newline Pike uses for error text.
  while (sizeof(text) && (text[-1] == '\n' || text[-1] == '\r'))
    text = text[..sizeof(text) - 2];
  return transport_error(text, operation);
}

#endif
