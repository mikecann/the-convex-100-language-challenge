<img src="logo.png" alt="R logo" width="180">
<!-- Logo source: https://www.r-project.org/logo/Rlogo.svg -->

# R

[R](https://www.r-project.org/) is a language and environment for statistical
computing and graphics. Ross Ihaka and Robert Gentleman began it in the early
1990s as a free implementation inspired by Bell Labs' S language. R remains a
specialist mainstay for statistics, data science, research, and
publication-quality graphics, with a large ecosystem of extension packages.

This repository uses R for an educational Convex client demonstration. It is
unofficial, is not a production SDK, and is not a package intended for
publication.

## Getting Started

[The canonical basics example](examples/basics/main.R) queries a counter,
subscribes to it before changing it, and checks the complete `0` to `1`
journey. From the repository root, run:

```sh
./run verify-example r
```

That command builds and runs the exact example in Docker against an isolated
room. You do not need R installed on your computer.

## Interesting Parts

### Named lists become Convex argument objects

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function CounterValue() {
  const state = useQuery(api.demo.state, { room: "readme-r-query" });
  if (state === undefined) return <span>Loading...</span>;
  return <span>{state.count}</span>; // state and count are type-safe here.
}
```

**R**

```r
source("client/convex.R")

read_counter <- function() {
  # CONVEX_URL selects the deployment; the named list becomes { room: ... }.
  client <- convex_client(Sys.getenv("CONVEX_URL"))
  on.exit(client$close()) # Dispose of HTTP and Live resources on every exit.

  args <- list(room = "readme-r-query")
  state <- client$query("demo:state", args)$value
  print(state$count) # JSON objects decode to named lists, accessed with `$`.
}

read_counter()
```

R's named lists are a natural fit for JSON objects, so the call stays compact.
Unlike the generated TypeScript API, field names and result shapes are checked
at runtime. This R call is also a one-off HTTP query, not a reactive hook.

### This client makes the Live lifecycle explicit

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  const room = "readme-r-live";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(), // Retries with this key apply only once.
    });
    console.log(result.applied);
    // useQuery owns the subscription and rerenders when the count changes.
  }

  return (
    <button disabled={state === undefined} onClick={addOne}>
      Count: {state?.count ?? "loading"}
    </button>
  );
}
```

**R**

```r
source("client/convex.R")
source("client/live.R")

watch_one_change <- function() {
  client <- convex_client(Sys.getenv("CONVEX_URL"))
  on.exit(client$close(), add = TRUE) # Always dispose of the client.
  room <- "readme-r-live"

  # Subscribe before mutating, then read the initial server value explicitly.
  subscription <- client$subscribe("demo:state", list(room = room))
  on.exit(subscription$close(), add = TRUE) # Stop Live when this function ends.
  initial <- subscription$next_update()$value
  print(initial$count)

  # Convex treats runId as an idempotency key. Time and PID distinguish this run.
  run_id <- paste0("readme-r-", as.integer(Sys.time()), "-", Sys.getpid())
  result <- client$mutation(
    "demo:increment",
    list(
      room = room,
      language = "r",
      runId = run_id
    )
  )$value
  print(result$applied) # The mutation result is another decoded named list.

  updated <- subscription$next_update()$value
  print(updated$count) # This value arrived through Live, not another query.
}

watch_one_change()
```

React creates, updates, and disposes the subscription with the component. This
command-line client instead returns a subscription that the caller reads and
closes directly. The blocking `next_update()` API is a deliberate client design
for a small executable, not a limitation of R itself.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Live subscriptions and reconnects | Verified by shared local and hosted conformance |

The manifest records this as a native R implementation with both `http` and
`live` capabilities earned.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.R -->
```r
#!/usr/local/bin/Rscript
client_path <- Sys.getenv("CONVEX_CLIENT_PATH", "client")
source(file.path(client_path, "convex.R"))
source(file.path(client_path, "live.R"))

# Convex returns numbers from JSON, so reject non-whole counts before printing
# the verifier's stable transcript.
whole_count <- function(value, operation) {
  if (
    !is.numeric(value) ||
      length(value) != 1L ||
      !is.finite(value) ||
      value != as.integer(value)
  ) {
    stop(operation, " was not a finite whole count")
  }
  as.integer(value)
}

example_room <- function(arguments = commandArgs(trailingOnly = TRUE)) {
  if (length(arguments)) arguments[[1L]] else "r-example"
}

# writeLines adds only the requested newline. Unlike cat's default separator,
# it cannot insert a trailing space that breaks the universal transcript.
example_line <- function(value) {
  writeLines(value, stdout())
}

run_example <- function() {
  # The deployment is supplied by the dedicated verification environment.
  client <- convex_client(Sys.getenv("CONVEX_URL"))
  # A unique room keeps concurrent examples isolated. The default is friendly by hand.
  room <- example_room()
  # Always close the client and its Live socket, including when a check fails.
  on.exit(client$close(), add = TRUE)

  # Query the current counter over Convex's HTTP endpoint.
  current <- client$query("demo:state", list(room = room))$value
  current_count <- whole_count(current$count, "current query")
  example_line(sprintf("current count: %d", current_count))

  # Start Live before the mutation, so the reactive value cannot miss the change.
  subscription <- client$subscribe("demo:state", list(room = room))
  # Unsubscribe during cleanup so the server does not retain this query.
  on.exit(subscription$close(), add = TRUE)

  # Live first sends its current value. Decode it into a normal R list and
  # confirm that it agrees with the HTTP query before changing anything.
  initial <- subscription$next_update()$value
  if (whole_count(initial$count, "initial Live value") != current_count) {
    stop("Live initial value disagreed with HTTP")
  }
  example_line(sprintf("live initial count: %d", current_count))

  # The runId is an idempotency key, so a retry of this logical write is safe.
  mutation <- client$mutation(
    "demo:increment",
    list(
      room = room,
      language = "r",
      runId = paste(sample(c(letters, 0:9), 16, TRUE), collapse = "")
    )
  )$value
  if (!isTRUE(mutation$applied)) stop("mutation was not applied")
  example_line("mutation applied: true")

  expected <- current_count + 1L
  if (whole_count(mutation$state$count, "mutation count") != expected) {
    stop("unexpected mutation count")
  }
  example_line(sprintf("mutation count: %d", expected))

  # Decode the changed value delivered by Live, without a second HTTP query.
  updated <- subscription$next_update()$value
  if (whole_count(updated$count, "updated Live value") != expected) {
    stop("unexpected Live update")
  }
  example_line(sprintf("live updated count: %d", expected))

  # Reaching this line proves HTTP and Live agreed on the complete journey.
  example_line(sprintf("verified count: %d -> %d", current_count, expected))
}

if (sys.nframe() == 0L) run_example()
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The client builds Convex's HTTP request envelopes and Live query state in R.
The `curl`, `jsonlite`, `later`, and `websocket` packages provide ordinary
HTTP/TLS, JSON, event-loop, and WebSocket machinery; they do not delegate to
another Convex client. The image pins R 4.5.1, curl 7.1.0, jsonlite 2.0.0, later
1.4.8, and websocket 1.4.4.

Live socket callbacks run through one `later` event loop, which keeps socket
ownership and reconnect state in one place. Every subscription exposes
`next_update()` for a bounded wait and `take_update()` for a non-blocking read.
Its queue retains only the newest 16 deliveries.

All build and verification work happens in Docker. `./run test r` checks R
formatting and language-local tests, while `./run build r` creates the minimal
`linux/amd64` runtime images. The final image keeps R's base `compiler`
namespace because `Rscript` needs bytecode support, but removes the interactive
`R` command, `R CMD` tools, compilers, linkers, and package managers.

## Known Issues

1. The client supports the JSON-safe Convex values exercised here, not the full
   set of Convex-specific value types.
2. Live authentication, optimistic updates, and `TransitionChunk` assembly are
   deferred.
3. A slow Live consumer can lose intermediate deliveries because each
   subscription intentionally keeps only its newest 16 events.
