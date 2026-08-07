SuperStrict

' Entry point for the test-only conformance executable.
'
' The adapter itself is a library so the language-local adapter tests can drive
' it in-process. This file exists only to start it and to report the process
' exit status the shared controller checks after a clean close.

Framework BRL.StandardIO

Import "adapter.bmx"

ConvexAdapterExit(ConvexAdapterMain())
