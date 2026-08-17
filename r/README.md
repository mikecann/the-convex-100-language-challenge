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

### `%||%` invents a null-coalescing operator on the spot

R lets any name wrapped in percent signs become a new binary operator — the
same trick the `%>%` pipe used for years before base R grew its own. This
client mints `%||%` once and leans on it everywhere a Convex response field
might be absent.

```r
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

# TypeScript: decoded.errorMessage ?? "Convex function failed"
message <- decoded$errorMessage %||% "Convex function failed"
logs <- unlist(decoded$logLines %||% list(), use.names = FALSE)
```

### The client is a closure, not a class

R has no `class` keyword for a small stateful object. The idiom instead
closes over an environment — R's one type that is passed by reference
instead of copied — and hands back a list of functions that share it.
`convex_client()` is just a function that happens to behave like one.

```r
convex_client <- function(url, bearer_token = "") {
  # State lives in an environment so every returned closure sees the same copy.
  state <- new.env(parent = emptyenv())
  state$closed <- FALSE
  state$live <- NULL

  list( # TypeScript: a closure returning { query, mutation, close }
    query = function(path, args = list()) request("query", path, args),
    mutation = function(path, args = list()) request("mutation", path, args),
    close = function() {
      state$closed <- TRUE
      if (!is.null(state$live)) state$live$close()
    }
  )
}
```

### `next_update()` turns Live into a queue you pull from

Rather than firing a callback, this client's Live subscription buffers
updates and makes the caller ask for the next one. `next_update()` blocks
(up to a timeout) until Convex's server pushes a change, so a plain,
top-to-bottom R script can read a subscription the same way it reads a
one-off query.

```r
subscription <- client$subscribe("demo:state", list(room = room))
on.exit(subscription$close(), add = TRUE) # stacks after the client's on.exit

initial <- subscription$next_update()$value # blocks until Live delivers
print(initial$count)

client$mutation("demo:increment", list(room = room, language = "r", runId = run_id))

updated <- subscription$next_update()$value
print(updated$count) # TypeScript: useQuery(api.demo.state, { room }) would rerender here
```

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
