#!/usr/bin/env pike
// A focused regression for the canonical example's own decoding.
//
// It compiles and exercises the exact file the README, the website, and the
// Docker verifier run. There is deliberately no second, test-only copy of the
// example: the helpers asserted below are the ones that decide whether a
// printed transcript is trustworthy.

int checks;
int failures;

void ok(int condition, string description)
{
  checks++;
  if (condition)
    return;
  failures++;
  werror("FAIL %s\n", description);
}

void expect_failure(function body, string description)
{
  checks++;
  if (catch { body(); })
    return;
  failures++;
  werror("FAIL %s (the value was accepted)\n", description);
}

int main()
{
  string here = dirname(__FILE__);
  object convex = compile_file(combine_path(here, "..", "..", "client",
                                            "convex.pike"))();
  object example = compile_file(combine_path(here, "main.pike"))();

  // Convex may spell a whole number in integral decimal form. The example has
  // to accept those and still reject anything that is not a whole number.
  ok(example->room_count(convex, ([ "count": 0 ]), "fixture") == 0,
     "an integer count is accepted");
  ok(example->room_count(convex, ([ "count": 0.0 ]), "fixture") == 0,
     "Convex may spell zero as 0.0");
  ok(example->room_count(convex, ([ "count": 1.0 ]), "fixture") == 1,
     "Convex may spell one as 1.0");

  expect_failure(lambda() {
                   example->room_count(convex, ([ "count": 1.5 ]), "fixture");
                 },
                 "a fractional count is rejected");
  expect_failure(lambda() {
                   example->room_count(convex, ([ "count": "1" ]), "fixture");
                 },
                 "a quoted count is rejected");
  expect_failure(lambda() {
                   example->room_count(convex, ([ "count": Val.null ]),
                                       "fixture");
                 },
                 "a null count is rejected");
  expect_failure(lambda() {
                   example->room_count(convex, ([ "count": 1.0e30 ]),
                                       "fixture");
                 },
                 "an overflowing count is rejected");
  expect_failure(lambda() { example->room_count(convex, ([]), "fixture"); },
                 "a state without a count is rejected");
  expect_failure(lambda() { example->room_count(convex, "0", "fixture"); },
                 "a non-object state is rejected");

  // A Live update carries either a value or a failure. The example must never
  // print a count derived from a failure.
  ok(example->live_count(convex,
                         convex->value_update(([ "count": 1.0 ])),
                         "fixture") == 1,
     "a Live value update yields its whole count");
  expect_failure(lambda() {
                   example->live_count(
                     convex,
                     convex->failure_update(
                       convex->function_error("query rejected", "live")),
                     "fixture");
                 },
                 "a failing Live update never becomes a printed count");

  if (failures) {
    werror("basic example decoding: %d of %d checks failed\n", failures,
           checks);
    return 1;
  }
  write("PASS basic example decoding (%d checks)\n", checks);
  return 0;
}
