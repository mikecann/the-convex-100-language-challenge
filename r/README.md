# Convex from R

This is a small R client that queries a Convex counter over HTTP, listens for
the same value over Live, and proves the counter moved from `0` to `1`.

It is educational and unofficial. It is not a production SDK or a package for
publication.

## Start here

[The canonical basics example](examples/basics/main.R) creates the client,
starts Live before the mutation, and checks every observed value.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Awaiting shared conformance |
| Live subscriptions and reconnects | Awaiting shared conformance |

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

## Docker verification

`./run test r` runs R formatting, unit tests, and adapter lifecycle checks in
Docker. `./run build r` builds the minimal linux/amd64 runtime images. The
coordinator runs `verify-example`, `verify`, and `verify-hosted` serially.

## Protocol notes

The client owns Convex HTTP envelopes and the `/api/sync` query-set protocol in
R. `curl`, `jsonlite`, `later`, and `websocket` supply only low-level transport,
JSON, and event-loop primitives. The image pins R 4.5.1, curl 7.1.0, jsonlite
2.0.0, later 1.4.8, and websocket 1.4.4. Each subscription keeps only its newest
16 deliveries. R's base `compiler` namespace remains because the interpreter
loads it for bytecode, but the runtime image removes the `R` command, `R CMD`
tooling, compilers, linkers, package managers, and build frontends.

## Limitations

The implementation intentionally supports the JSON-safe values exercised by
this experiment. Live auth and TransitionChunk assembly are deferred.
