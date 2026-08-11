# LOLCODE

[LOLCODE](http://lolcode.org/) is the intentionally playful language built from
early internet cat-meme grammar. It began as a joke, but its functions, loops,
objects, and conditionals are real enough to make a Convex client an unusually
good stress test.

## Getting Started

The canonical example is [`examples/basics/main.lol`](examples/basics/main.lol).
From the repository root, run `./run verify-example lolcode` once verification
is complete.

## Interesting Parts

The implementation is still in progress.

## Status

| Capability | Status |
| --- | --- |
| HTTP | Pending verification |
| Live | Pending verification |

## Example

```lolcode
HAI 1.3
KTHXBYE
```

## Implementation Notes

The pinned `lci` interpreter is built for `linux/amd64`. A compiled extension
supplies ordinary transport primitives, while Convex behavior stays in LOLCODE.

## Known Issues

1. The client and canonical example are not complete yet.
