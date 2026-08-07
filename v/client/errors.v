module convex

import x.json2

// Convex failures keep their category all the way from the socket to the
// public API and the conformance adapter. A rejected Convex function must
// never be reported as a transport outage, and malformed protocol data must
// never be flattened into a successful value.
pub const kind_function_error = 'FunctionError'
pub const kind_protocol_error = 'ProtocolError'
pub const kind_transport_error = 'TransportError'
pub const kind_closed_error = 'ClosedError'

// ConvexError is the single error type this client raises. It implements V's
// IError so `or {}` blocks can recover the structured category with
// `err as ConvexError` instead of parsing a message string.
pub struct ConvexError {
pub:
	kind      string
	message   string
	operation string
	data      json2.Any = json2.Any(json2.null)
	logs      []string
}

pub fn (e ConvexError) msg() string {
	if e.operation.len > 0 {
		return 'convex ${e.operation} ${e.kind}: ${e.message}'
	}
	return 'convex ${e.kind}: ${e.message}'
}

// code is required by IError. The category lives in `kind`, so a numeric code
// would be a second, weaker encoding of the same fact.
pub fn (e ConvexError) code() int {
	return 0
}

fn protocol_error(operation string, message string) ConvexError {
	return ConvexError{
		kind:      kind_protocol_error
		operation: operation
		message:   message
	}
}

fn transport_error(operation string, message string) ConvexError {
	return ConvexError{
		kind:      kind_transport_error
		operation: operation
		message:   message
	}
}

fn closed_error(operation string, message string) ConvexError {
	return ConvexError{
		kind:      kind_closed_error
		operation: operation
		message:   message
	}
}

fn function_error(operation string, message string, data json2.Any, logs []string) ConvexError {
	return ConvexError{
		kind:      kind_function_error
		operation: operation
		message:   message
		data:      data
		logs:      logs
	}
}

// wrap_error keeps a foreign V error (a socket failure, a JSON decode fault)
// from silently losing its category. Anything that is already a ConvexError is
// returned untouched so the original kind survives every boundary it crosses.
fn wrap_error(err IError, kind string, operation string, prefix string) ConvexError {
	if err is ConvexError {
		return *err
	}
	return ConvexError{
		kind:      kind
		operation: operation
		message:   '${prefix}: ${err.msg()}'
	}
}
