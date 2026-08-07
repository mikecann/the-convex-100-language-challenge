#!/bin/sh
set -eu

source_file=examples/basics/main.zig
readme=README.md
begin='<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.zig -->'
end='<!-- END GENERATED EXAMPLE -->'

extract() {
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside = 1; next }
        $0 == end { exit }
        inside && $0 == "```zig" { code = 1; next }
        inside && code && $0 == "```" { code = 0; next }
        inside && code { print }
    ' "$readme"
}

if [ "${1:-}" = "--check" ]; then
    extracted=$(mktemp)
    trap 'rm -f "$extracted"' EXIT
    extract >"$extracted"
    cmp -s "$source_file" "$extracted" || {
        echo "README canonical Zig block differs from $source_file" >&2
        exit 1
    }
    exit 0
fi

if [ "${1:-}" != "--update" ]; then
    echo "usage: $0 --check|--update" >&2
    exit 2
fi

updated=$(mktemp)
trap 'rm -f "$updated"' EXIT
awk -v begin="$begin" -v end="$end" -v source="$source_file" '
    $0 == begin {
        print
        print "```zig"
        while ((getline line < source) > 0) print line
        close(source)
        print "```"
        skipping = 1
        next
    }
    skipping && $0 == end {
        skipping = 0
        print
        next
    }
    !skipping { print }
' "$readme" >"$updated"
mv "$updated" "$readme"
trap - EXIT
