# The Convex 100 Language Challenge

[![I made 100 programming languages talk to Convex](https://img.youtube.com/vi/l61cLu8e2tg/maxresdefault.jpg)](https://youtu.be/l61cLu8e2tg)

Hi, I'm Mike. I work at [Convex](https://www.convex.dev/), and I had a slightly
ridiculous idea: what would happen if I pointed a large group of coding agents
at Convex and asked them to make it work in 100 different programming
languages?

So that is what I did.

I had the agents attempt to make Convex, a realtime database and compute
platform, work everywhere from JavaScript and Python to Fortran, COBOL,
LOLCODE, x86-64 assembly and even Verilog. Some of those languages existed
before the internet. One of them is meant for designing hardware. Somehow,
they are all here talking to the same cloud backend.

This repository is the complete result: the clients, runnable examples,
Docker builds, shared tests, failed attempts and all the evidence produced
along the way. If you would rather hear the story first, the video above covers
the journey and some of the stranger things that happened.

## What does "working with Convex" mean?

[Convex](https://www.convex.dev/) is a backend platform with a realtime
database and server-side functions. An application can call queries,
mutations and actions, then subscribe to a query and receive a new result when
the underlying data changes.

For a language to make the final roster, it had to demonstrate the same useful
slice of that experience:

- Call Convex queries, mutations and actions over HTTP.
- Send and receive normal Convex values, errors and authentication tokens.
- Subscribe to live query updates over a WebSocket.
- Build and run from a clean Docker container rather than relying on whatever
  happened to be installed on my machine.

The goal was not to produce 100 folders that merely compiled. I wanted one set
of rules that could be applied to every language, including the deeply weird
ones, without quietly lowering the bar when things got difficult.

## A few of my favourite parts

- **Fortran** first appeared in 1957. It now has a Convex client receiving live
  query updates from a cloud database.
- **COBOL** predates the Beatles, and its client is nearly ten thousand lines
  including tests because COBOL likes to make absolutely everything explicit.
- **LOLCODE** begins with `HAI 1.3` and `CAN HAS TRANSPORT?`. The agents got it
  over the line by patching the interpreter itself, which feels very on-brand.
- **Verilog** is normally used to describe circuits that become hardware. It
  was never meant for this, but it works anyway :P

Not every language made it. Some needed proprietary tools, some could not open
a network connection, and a few fought the container limits until the bitter
end. I kept those stories in [INFEASIBLE.md](INFEASIBLE.md) rather than quietly
deleting them.

## Where should I start?

- [Watch the video](https://youtu.be/l61cLu8e2tg) for the full story.
- [Browse all 100 languages](https://the-convex-100-language-challenge.mikecann.app/)
  and open any card to see its example and evidence.
- Read [STATS.md](STATS.md) for the numbers, [LESSONS.md](LESSONS.md) for the
  things the agents and I learned, or [BUILD-FLEET.md](BUILD-FLEET.md) for the
  small army of rented servers behind the final push.
- Pick a language directory if you just want to see what a Convex client looks
  like in your favourite language.

If you have Docker, you can run the same basic counter example used throughout
the project:

```sh
git clone https://github.com/mikecann/the-convex-100-language-challenge
cd the-convex-100-language-challenge
./run verify-example fortran
```

Swap `fortran` for another language ID to try a different one.

## A quick caveat

These are educational experiments, not official Convex SDKs. They are not
published packages and I would not quietly slip one into a production app. The
interesting part is the source, the common challenge and what each language
needed to make the same small client experience work.

## Project status

The final roster contains 100 language implementations. Each one completed the
shared HTTP and Live suites against both the pinned local backend and a hosted
compatibility deployment. Every language manifest on `main` records both
capabilities. See [STATS.md](STATS.md) for the measured completion summary.

The final trusted-main website index is still outstanding. The language runs
were completed on the remote build fleet and recorded in their merged pull
requests, but the repository's GitHub Actions evidence publisher was never
expanded beyond the Go pilot. Until that index is produced, `./run site` will
withhold trusted website badges rather than treating manifest claims as signed
CI evidence.

## What the badges mean

| Status | Meaning |
| --- | --- |
| Yellow: HTTP | Queries, mutations, actions, JSON-safe values, bearer-token forwarding, and errors work over the documented HTTP API. |
| Green: Live | The client additionally supports live query subscriptions over WebSockets. |
| Red: Failed | A clean Docker build, execution, or claimed capability test fails. |

Live includes HTTP. Implementation provenance is a separate label:

| Provenance | Meaning |
| --- | --- |
| Native | The target language owns the Convex-specific state machine. Normal HTTP, TLS, JSON, and WebSocket libraries are allowed. |
| Binding | The language exposes an idiomatic API over a shared Convex core through FFI, JVM, CLR, WASM, or similar. |
| Generated | An HTTP client produced from an API description such as OpenAPI. |
| Transpiled | The implementation is written in the named source language and compiled to a different host language. |
| Bridge | The code shells out to another Convex client, runtime, CLI, or sidecar. Bridges are shown but do not count as native clients. |

## The rules I gave the agents

- One source language, one audited entry in the roster.
- Every build and test runs in Docker. Language toolchains are never installed on the host.
- HTTP is the minimum useful target. Realtime and resilience are separate earned capabilities.
- Every runnable example is a commented guided tour of the verified client API, and that same source is shown in its README and on the website.
- Checked-in layouts favour readable educational source. Docker may rearrange files into temporary toolchain-specific paths during a build.
- Package publishing, registry metadata, and release automation are outside the project's scope.
- A native implementation may use ordinary transport libraries, but Convex-specific behavior must be written in the target language.
- Shared-core and transpiled clients are labelled rather than hidden.
- Results are attached to a source commit, container digest, runtime version, protocol revision, and conformance-suite version.
- Experimental clients stay in this monorepo. Passing a test does not make a package officially supported by Convex.

## Repository shape

```text
<language-id>/             one top-level directory per roster language
  manifest.yaml            declared intent, toolchain, and provenance
  Dockerfile               pinned build and runtime image
  client/                  client, build metadata, unit tests, and conformance entrypoint
  examples/basics/         the shared counter-room example and its own tests
  README.md                usage, evidence, and limitations
  logo.png                 optional language logo displayed by the README
_shared/                   trusted backend, harness, schemas, site, and results
run                         Docker-only orchestration entrypoint
roster/                    sourced language selection and feasibility audit
```

The repository root is intentionally visual: the accepted roster appears as 100
peer language directories. Popularity rank lives in metadata, so a ranking
change never renames a directory. Shared infrastructure is kept under
`_shared/` and is protected separately from language implementation changes.

Build status and verified platforms are recorded as evidence. They are not
capability badges. A successful build alone does not mean a client can talk to
Convex.

## Run it yourself

The root script is the supported entrypoint. It invokes Docker for every build,
test, package operation, and generated artifact.

```sh
./run doctor
./run validate
./run verify-example go
./run verify go
./run verify-hosted go
./run verify-all go
./run site-preview
./run site-serve
```

`verify-example` compiles and runs the canonical basic example inside Docker,
then requires its complete stdout to match the universal ordered happy-path
transcript in `_shared/examples/basics.expected.txt`. The last two commands
generate a clearly labelled local evidence preview and serve it at
`http://127.0.0.1:4173`. `./run site` is
stricter: it ignores local results and renders only the trusted-main result
index.

See the [roster methodology](roster/methodology.md), [exact proposed roster](roster/languages.yaml), [conformance contract](docs/conformance.md), and [implementation architecture](docs/architecture.md).
