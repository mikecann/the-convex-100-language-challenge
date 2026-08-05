source("client/convex.R")
Sys.setenv(CONVEX_CLIENT_PATH = normalizePath("client"))
example <- new.env()
source("examples/basics/main.R", chdir = TRUE, local = example)
stopifnot(example$whole_count(1, "test") == 1L)
bad <- tryCatch(
  {
    example$whole_count(1.5, "test")
    NULL
  },
  error = identity
)
stopifnot(inherits(bad, "error"))
stopifnot(identical(example$example_room(character()), "r-example"))
stopifnot(identical(example$example_room("provided-room"), "provided-room"))

rooms <- character()
updates <- list(list(value = list(count = 0L)), list(value = list(count = 1L)))
subscription <- list(
  next_update = function() {
    update <- updates[[1L]]
    updates <<- updates[-1L]
    update
  },
  close = function() invisible(NULL)
)
fake_client <- list(
  query = function(path, args) {
    rooms <<- c(rooms, args$room)
    list(value = list(count = 0L))
  },
  subscribe = function(path, args) {
    rooms <<- c(rooms, args$room)
    subscription
  },
  mutation = function(path, args) {
    rooms <<- c(rooms, args$room)
    list(value = list(applied = TRUE, state = list(count = 1L)))
  },
  close = function() invisible(NULL)
)
example$convex_client <- function(url) fake_client
example$commandArgs <- function(trailingOnly) character()

# Capture bytes, not parsed lines, so trailing spaces and the final newline are
# both part of this regression for the universal example transcript.
transcript_path <- tempfile("r-example-transcript-")
sink(transcript_path)
example$run_example()
sink()
transcript <- readBin(transcript_path, what = "raw", n = file.info(transcript_path)$size)
unlink(transcript_path)
transcript_text <- rawToChar(transcript)
transcript_lines <- strsplit(transcript_text, "\n", fixed = TRUE)[[1L]]
stopifnot(length(transcript_lines) == 6L)
stopifnot(endsWith(transcript_text, "\n"))
stopifnot(!grepl("\r", transcript_text, fixed = TRUE))
stopifnot(!any(!nzchar(transcript_lines)))
stopifnot(!any(endsWith(transcript_lines, " ")))
stopifnot(identical(rooms, rep("r-example", 3L)))
cat("PASS R example unit tests\n")
