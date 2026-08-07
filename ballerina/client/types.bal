// Shared result and error types for the native Ballerina Convex demonstration.
//
// Convex distinguishes three failure shapes on the wire: a function itself
// returning an application error, a violation of the sync/HTTP protocol, and
// a transport-level failure (socket, TLS, timeout). Modelling them as three
// distinct error types - rather than one error with a string "kind" field -
// lets every call site narrow with `is` and the compiler check every branch
// is handled.

# Detail carried by a `FunctionError`: the Convex operation that failed
# (`query`, `mutation`, or `action`), any structured `errorData` the function
# attached, and the log lines produced before the failure.
public type FunctionErrorDetail record {|
    string operation;
    json data = ();
    string[] logs = [];
|};

# Detail carried by `ProtocolError` and `TransportError`: only log context,
# kept symmetrical with `FunctionErrorDetail` so callers can pattern match
# without special-casing.
public type PlainErrorDetail record {|
    string[] logs = [];
|};

# The real Convex function ran and reported failure. This is not a bug in the
# client; it is a normal, expected outcome of calling a function.
public type FunctionError distinct error<FunctionErrorDetail>;

# The server (or a fixture standing in for it) sent something that does not
# conform to the pinned sync/HTTP profile.
public type ProtocolError distinct error<PlainErrorDetail>;

# A socket, TLS, or timeout failure below the protocol layer.
public type TransportError distinct error<PlainErrorDetail>;

# The client (or the specific subscription) was already closed when the call
# was made.
public type ClosedError distinct error<PlainErrorDetail>;

# Every error a Convex call can produce.
public type ConvexError FunctionError|ProtocolError|TransportError|ClosedError;

# The successful result of `query`, `mutation`, or `action`.
public type CallResult record {|
    json value;
    string[] logs = [];
|};

# One delivery to a Live subscription: either a fresh value or a structured
# failure, never both. `logs` accompanies whichever one is present.
public type Update record {|
    json value = ();
    ConvexError? err = ();
    string[] logs = [];
|};

# Narrows a general Ballerina `error` down to the four-way `ConvexError`
# union. Every error this client raises is already one of the four; this
# only guards the rare case where a lower layer (or `bal` itself) hands back
# a plain `error` that was never wrapped, so it still surfaces as a
# TransportError instead of failing an unrelated `is ConvexError` check.
public isolated function asConvexError(error e) returns ConvexError {
    if e is FunctionError {
        return e;
    }
    if e is ProtocolError {
        return e;
    }
    if e is TransportError {
        return e;
    }
    if e is ClosedError {
        return e;
    }
    return error TransportError(e.message(), logs = []);
}
