#!/usr/local/bin/io
//
// Io has no standard formatter, so this stands in for one: it parses every
// checked-in Io source file with the VM's own reader and enforces the layout
// rules the README and the website depend on.
//
// A parse failure here is a compile failure for an interpreted language, which
// is why the Docker test stage runs this before anything else.
//

ConvexStyle := Object clone do(
    failures := 0
    maximumLineLength := 110

    base := method(
        script := System launchScript
        if(script isNil, ".", script pathComponent)
    )

    // A best-effort diagnostic write, retried a bounded number of times
    // rather than propagated as a fatal exception on the first failure. This
    // script runs standalone, before convex.io is known to parse cleanly, so
    // it cannot depend on Convex writeDiagnostic there; see that method's
    // comment for why a bare File write is not enough on its own - a write to
    // this process's own stderr through a pipe (the shape every Docker log
    // capture uses) can occasionally raise "error writing to file" for a
    // transient reason unrelated to this script's own correctness, and an
    // immediate retry was enough to clear it in every observed case.
    writeStderr := method(text,
        attempts := 0
        written := false
        while(written not and attempts < 8,
            problem := try(File standardError write(text))
            if(problem isNil, written = true, attempts = attempts + 1)
        )
        written
    )

    sources := method(
        list(
            "../convex.io",
            "harness.io",
            "unit_test.io",
            "http_peer_test.io",
            "live_peer_test.io",
            "style.io",
            "run.io",
            "conformance/adapter.io",
            "conformance/tcp_smoke.io",
            "conformance/adapter_test.io",
            "../../examples/basics/main.io",
            "../../examples/basics/main_test.io"
        )
    )

    complain := method(path, detail,
        ConvexStyle failures = ConvexStyle failures + 1
        ConvexStyle writeStderr("STYLE " .. path .. ": " .. detail .. "\n")
        false
    )

    check := method(relative,
        path := ConvexStyle base .. "/" .. relative
        file := File with(path)
        if(file exists not, return ConvexStyle complain(relative, "missing source file"))
        contents := file contents

        // A carriage return would change the bytes the website renders.
        if(contents containsSeq("\r"), ConvexStyle complain(relative, "contains a carriage return"))
        if(contents containsSeq("\t"), ConvexStyle complain(relative, "contains a tab"))
        if(contents size > 0 and contents at(contents size - 1) != 10,
            ConvexStyle complain(relative, "does not end with a newline")
        )

        number := 0
        contents split("\n") foreach(line,
            number = number + 1
            if(line size > 0 and (line at(line size - 1) == 32 or line at(line size - 1) == 9),
                ConvexStyle complain(relative, "line " .. number asString .. " has trailing whitespace")
            )
            if(line size > ConvexStyle maximumLineLength,
                ConvexStyle complain(
                    relative,
                    "line " .. number asString .. " is " .. line size asString .. " bytes long"
                )
            )
        )

        // The reader is the authority on whether this file is valid Io.
        problem := try(contents asMessage)
        if(problem,
            ConvexStyle complain(relative, "does not parse: " .. problem error)
        )
        true
    )

    run := method(
        ConvexStyle sources foreach(relative, ConvexStyle check(relative))
        if(ConvexStyle failures == 0,
            ConvexStyle writeStderr(
                "style: " .. ConvexStyle sources size asString .. " Io sources are clean\n"
            )
        )
        ConvexStyle failures
    )
)

System exit(if(ConvexStyle run > 0, 1, 0))
