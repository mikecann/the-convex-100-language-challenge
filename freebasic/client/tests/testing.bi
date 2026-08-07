' A tiny assertion helper shared by the language-local test binaries. Each
' test links its own copy, so there is no shared mutable state between suites.

#pragma once

#include once "core.bi"

dim shared as long TestChecks
dim shared as long TestFailures

sub Check(byval condition as boolean, byref label as string)
  TestChecks += 1
  if not condition then
    TestFailures += 1
    print "FAIL " & label
  end if
end sub

sub CheckEqual(byref actual as string, byref expected as string, byref label as string)
  TestChecks += 1
  if actual <> expected then
    TestFailures += 1
    print "FAIL " & label
    print "  expected: " & expected
    print "  actual:   " & actual
  end if
end sub

function TestSummary(byref suite as string) as long
  if TestFailures > 0 then
    print "FAIL " & suite & ": " & FormatInteger(TestFailures) & " of " & _
      FormatInteger(TestChecks) & " checks failed"
    return 1
  end if
  print "PASS " & suite & " (" & FormatInteger(TestChecks) & " checks)"
  return 0
end function
