//
// Regression coverage for the canonical example's own decoding.
//
// This loads the exact file the README and the website show - there is no
// second, test-only copy of the example - and exercises the number rule that
// Convex's JSON actually needs.
//

ConvexExampleTest := Object clone do(
    run := method(
        ConvexTest begin("example/whole-numbers")
        // Convex may spell a whole number either way, and both must be
        // accepted as the same integer.
        ConvexTest equals(ConvexBasics wholeNumber("0", "n"), 0, "an integer literal is accepted")
        ConvexTest equals(ConvexBasics wholeNumber("1", "n"), 1, "one is accepted")
        ConvexTest equals(ConvexBasics wholeNumber("0.0", "n"), 0, "0.0 is the integer zero")
        ConvexTest equals(ConvexBasics wholeNumber("1.000", "n"), 1, "1.000 is the integer one")
        ConvexTest equals(ConvexBasics wholeNumber(" 42 ", "n"), 42, "surrounding space is tolerated")
        ConvexTest equals(ConvexBasics wholeNumber("-3", "n"), -3, "a negative integer is accepted")

        // Everything that is not a finite whole number must fail loudly rather
        // than silently becoming a plausible count.
        ConvexTest ok(try(ConvexBasics wholeNumber("\"1\"", "n")) isNil not, "a quoted digit is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("1.5", "n")) isNil not, "a fraction is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("1e3", "n")) isNil not, "exponent notation is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("nan", "n")) isNil not, "nan is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("null", "n")) isNil not, "null is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("", "n")) isNil not, "an empty token is rejected")
        ConvexTest ok(try(ConvexBasics wholeNumber("-", "n")) isNil not, "a lone sign is rejected")
        ConvexTest ok(
            try(ConvexBasics wholeNumber("90071992547409920", "n")) isNil not,
            "a value beyond Io's exact integer range is rejected"
        )

        ConvexTest begin("example/state-decoding")
        ConvexTest equals(
            ConvexBasics countOf("{\"room\":\"r\",\"count\":0.0,\"lastLanguage\":null}", "state"),
            0,
            "an integral count is read from a realistic state document"
        )
        ConvexTest ok(
            try(ConvexBasics countOf("{\"room\":\"r\"}", "state")) isNil not,
            "a state document without a count is rejected"
        )

        // The verifier runs the entrypoint with one argument, the unique room.
        // Io may place the interpreter, the script, both, or neither ahead of
        // it in System args, so the room must be recognised in every shape
        // rather than read from a guessed index.
        ConvexTest begin("example/room-argument")
        entrypoint := "/usr/local/bin/convex-example"
        unique := "io-example-self-hosted-1770000000-42"
        ConvexTest equals(
            ConvexBasics roomFromArguments(
                list("/usr/local/bin/io", entrypoint, unique), entrypoint
            ),
            unique,
            "the room is found behind the interpreter and the script"
        )
        ConvexTest equals(
            ConvexBasics roomFromArguments(list(entrypoint, unique), entrypoint),
            unique,
            "the room is found behind the script alone"
        )
        ConvexTest equals(
            ConvexBasics roomFromArguments(list(unique), entrypoint),
            unique,
            "the room is found when the VM passes only the caller's arguments"
        )
        ConvexTest equals(
            ConvexBasics roomFromArguments(
                list("/usr/local/bin/io", "client/../examples/basics/main.io", unique),
                "/project/examples/basics/main.io"
            ),
            unique,
            "a source checkout's relative script path is not mistaken for the room"
        )
        ConvexTest equals(
            ConvexBasics roomFromArguments(
                list("/usr/local/bin/io", entrypoint, "-v", unique), entrypoint
            ),
            unique,
            "an interpreter flag ahead of the room is skipped"
        )
        ConvexTest ok(
            ConvexBasics roomFromArguments(list("/usr/local/bin/io", entrypoint), entrypoint) isNil,
            "no argument at all yields no room, so the fallbacks apply"
        )
        ConvexTest ok(ConvexBasics roomFromArguments(nil, nil) isNil, "absent args yield no room")
        ConvexTest
    )
)
