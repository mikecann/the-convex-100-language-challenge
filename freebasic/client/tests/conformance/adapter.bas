' Entry point for the test-only conformance executable.
'
' The adapter speaks NDJSON adapter protocol v1 over stdin/stdout, or over one
' accepted TCP connection when ADAPTER_LISTEN is set. All of its behaviour
' lives in adapter_core so the same code can be exercised by unit tests.

#include once "adapter_core.bi"

end AdapterMain()
