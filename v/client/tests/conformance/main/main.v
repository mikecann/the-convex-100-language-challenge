module main

import conformance

// The conformance executable is a two-line entry point on purpose. Keeping the
// adapter itself in an importable module is what lets the deterministic
// fixtures next to it exercise the real command validation, the real bounded
// output writer, and the real invalidation rules.
fn main() {
	conformance.run_adapter()
}
