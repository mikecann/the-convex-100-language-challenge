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
        File standardError write("STYLE " .. path .. ": " .. detail .. "\n")
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
            File standardError write(
                "style: " .. ConvexStyle sources size asString .. " Io sources are clean\n"
            )
        )
        ConvexStyle failures
    )
)

System exit(if(ConvexStyle run > 0, 1, 0))
