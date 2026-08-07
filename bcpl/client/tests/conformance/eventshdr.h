// eventshdr.h -- global numbering for the shared adapter event builders.
//
// Test infrastructure, not public client code. The builders in events.b are
// included by both the conformance adapter and the language-local byte tests,
// so they need globals of their own. They start at 800, well above the client's
// range, which ends below 700, and above the 700 to 799 band the adapter and
// the test programs use for their own state.

GLOBAL {
evPut: 800
evLogs
evError
evReady
evAck
evResult
evSubscription
evClosed
evProtocolError
evFromError
}
