# Build the final client without deterministic test pause points. Gleam 1.9 has
# no conditional compilation, so the checked source keeps test-only regions
# explicit and this tiny projection removes them before the production build.

/^[[:space:]]*\/\/ TEST_ONLY_BEGIN[[:space:]]*$/ {
  test_only = 1
  next
}

/^[[:space:]]*\/\/ TEST_ONLY_END[[:space:]]*$/ {
  test_only = 0
  next
}

test_only {
  next
}

/^[[:space:]]*\/\/ PROD / {
  sub(/\/\/ PROD /, "")
  print
  next
}

{
  print
}
