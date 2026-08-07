SuperStrict

' Minimal assertions for the language-local test executables.
'
' BlitzMax's unit-test module is built around reflection and a runner; these
' tests need to interleave a client and a hostile peer inside one thread, so
' they are plain programs that assert and report a process exit status.

Import BRL.StandardIO

Import "../transport.bmx"

Extern
	Function convex_test_exit(code:Int) = "exit"
End Extern

Rem
bbdoc: Ends a test executable with @code.
about: BlitzMax's End always reports success, and every test gate in the
Dockerfile depends on a non-zero status when a check fails.
End Rem
Function ConvexTestExit(code:Int)
	convex_test_exit(code)
End Function

Global ConvexTestFailures:Int
Global ConvexTestChecks:Int

Function ConvexCheck(condition:Int, description:String)
	ConvexTestChecks :+ 1
	If condition Then
		Return
	End If
	ConvexTestFailures :+ 1
	ErrPrint("FAIL " + description)
End Function

Function ConvexCheckEqual(actual:String, expected:String, description:String)
	ConvexCheck(actual = expected, description + " (expected " + expected + ", got " + actual + ")")
End Function

Function ConvexCheckEqualInt(actual:Long, expected:Long, description:String)
	ConvexCheck(actual = expected, description + " (expected " + expected + ", got " + actual + ")")
End Function

Rem
bbdoc: Asserts that @body raises a client error whose message contains @fragment.
End Rem
Function ConvexCheckRaises(body:Int(), fragment:String, description:String)
	Local raised:String = ""
	Try
		body()
	Catch problem:TConvexError
		raised = problem.message
	Catch other:Object
		raised = other.ToString()
	End Try
	If raised.length = 0 Then
		ConvexCheck(False, description + " (expected a failure mentioning " + fragment + ", but none was raised)")
		Return
	End If
	ConvexCheck(raised.Find(fragment) >= 0, description + " (expected a failure mentioning " + fragment + ", got " + raised + ")")
End Function

Rem
bbdoc: Prints the summary line and returns the process exit code.
End Rem
Function ConvexTestSummary:Int(suite:String)
	If ConvexTestFailures > 0 Then
		ErrPrint(suite + ": " + ConvexTestFailures + " of " + ConvexTestChecks + " checks failed")
		Return 1
	End If
	Print suite + ": " + ConvexTestChecks + " checks passed"
	Return 0
End Function
