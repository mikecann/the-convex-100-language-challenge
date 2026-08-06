//// Minimal assertions shared by the language-local tests.
////
//// The tests run as ordinary Gleam programs inside the Docker test stage
//// rather than through a test framework, so they add no dependency that would
//// then have to be justified in the runtime images.

import convex_sys
import gleam/int
import gleam/io

/// Counts checks as they pass so a run that silently skips work is visible.
pub fn ok(name: String, condition: Bool) -> Nil {
  case condition {
    True -> Nil
    False -> {
      convex_sys.stderr_write("FAIL " <> name)
      panic as "assertion failed"
    }
  }
}

pub fn equal_int(name: String, actual: Int, expected: Int) -> Nil {
  case actual == expected {
    True -> Nil
    False -> {
      convex_sys.stderr_write(
        "FAIL "
        <> name
        <> ": expected "
        <> int.to_string(expected)
        <> " but got "
        <> int.to_string(actual),
      )
      panic as "assertion failed"
    }
  }
}

pub fn equal_string(name: String, actual: String, expected: String) -> Nil {
  case actual == expected {
    True -> Nil
    False -> {
      convex_sys.stderr_write(
        "FAIL " <> name <> ": expected " <> expected <> " but got " <> actual,
      )
      panic as "assertion failed"
    }
  }
}

/// Announce a finished suite. Test output is deliberately on stdout here
/// because these programs are not the adapter and have no protocol surface.
pub fn done(suite: String) -> Nil {
  io.println("PASS " <> suite)
}
