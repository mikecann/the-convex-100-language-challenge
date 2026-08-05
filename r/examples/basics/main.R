#!/usr/local/bin/Rscript
client_path <- Sys.getenv("CONVEX_CLIENT_PATH", "client")
source(file.path(client_path, "convex.R"))
source(file.path(client_path, "live.R"))

# Convex returns numbers from JSON, so reject non-whole counts before printing
# the verifier's stable transcript.
whole_count <- function(value, operation) {
  if (!is.numeric(value) || length(value) != 1L || !is.finite(value) || value != as.integer(value)) stop(operation, " was not a finite whole count")
  as.integer(value)
}

run_example <- function() {
  # The deployment is supplied by the dedicated verification environment.
  client <- convex_client(Sys.getenv("CONVEX_URL"))
  # A unique room keeps concurrent examples isolated; this default is friendly by hand.
  room <- commandArgs(trailingOnly = TRUE)[1] %||% "r-example"
  on.exit(client$close(), add = TRUE)

# Query the current counter over Convex's HTTP endpoint.
current <- client$query("demo:state", list(room = room))$value
current_count <- whole_count(current$count, "current query")
cat("current count:", current_count, "\n")
# Start Live before the mutation, so the reactive value cannot miss the change.
subscription <- client$subscribe("demo:state", list(room = room))
on.exit(subscription$close(), add = TRUE)
initial <- subscription$next_update()$value
if (whole_count(initial$count, "initial Live value") != current_count) stop("Live initial value disagreed with HTTP")
cat("live initial count:", current_count, "\n")
# The idempotency key makes a retry of this logical write safe.
mutation <- client$mutation("demo:increment", list(room = room, language = "r", runId = paste(sample(c(letters, 0:9), 16, TRUE), collapse = "")))$value
if (!isTRUE(mutation$applied)) stop("mutation was not applied")
cat("mutation applied: true\n")
expected <- current_count + 1L
if (whole_count(mutation$state$count, "mutation count") != expected) stop("unexpected mutation count")
cat("mutation count:", expected, "\n")
# This is the changed value delivered by Live, not a second HTTP query.
updated <- subscription$next_update()$value
if (whole_count(updated$count, "updated Live value") != expected) stop("unexpected Live update")
cat("live updated count:", expected, "\n")
  cat("verified count:", current_count, "->", expected, "\n")
}

if (sys.nframe() == 0L) run_example()
