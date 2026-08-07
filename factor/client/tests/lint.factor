! Source formatting check for the checked-in Factor sources.
!
! Factor ships no standalone formatter, so this stands in for one. The README
! and the website display these files verbatim, which makes tabs, trailing
! whitespace, over-long lines, and missing final newlines a presentation
! problem rather than a matter of taste. Every path is passed explicitly by
! the Docker stage so the check never depends on a directory walk.

USING: command-line io.encodings.utf8 io.files kernel locals math
math.parser namespaces sequences splitting strings
convex.tests.support ;
IN: convex.tests.lint

CONSTANT: max-columns 80

:: check-file ( path -- )
    path utf8 file-contents :> text
    text empty? [
        path " is empty" append assertion-failed
    ] when
    text last CHAR: \n = [
        path " does not end with a newline" append assertion-failed
    ] unless
    CHAR: \r text member? [
        path " contains a carriage return" append assertion-failed
    ] when
    CHAR: \t text member? [
        path " contains a tab" append assertion-failed
    ] when
    text "\n" split but-last [| line index |
        line length max-columns > [
            path ":" append index 1 + number>string append
            " exceeds " append max-columns number>string append
            " columns" append assertion-failed
        ] when
        line empty? [ f ] [ line last CHAR: \s = ] if [
            path ":" append index 1 + number>string append
            " has trailing whitespace" append assertion-failed
        ] when
    ] each-index ;

: run-lint ( -- )
    command-line get dup empty? [
        "lint requires at least one source path" assertion-failed
    ] when
    [ dup [ check-file ] curry run-test ] each
    finish-tests ;

MAIN: run-lint
