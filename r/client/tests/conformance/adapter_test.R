Sys.setenv(CONVEX_ADAPTER_TESTING = "1", CONVEX_CLIENT_PATH = normalizePath("client"))
source("client/tests/conformance/adapter.R")

assert <- function(value, message) {
  if (!isTRUE(value)) stop(message, call. = FALSE)
}

serialize <- function(event) {
  output <- textConnection("lines", open = "w", local = TRUE)
  on.exit(close(output))
  write_event(output, event)
  jsonlite::fromJSON(lines, simplifyVector = FALSE)
}

result <- serialize(list(id = "call", type = "result", value = list(ok = TRUE), logs = list("log")))
assert(result$id == "call" && isTRUE(result$value$ok), "result serialization lost fields")

failure <- convex_error("convex_function_error", "expected failure", "query", list(code = "EXPECTED"), "before failure")
error <- serialize(error_event("call", failure))
assert(error$type == "error" && error$error$data$code == "EXPECTED", "structured HTTP error serialization lost data")

subscription_error <- serialize(error_event(NULL, failure, "subscription"))
assert(subscription_error$type == "subscription", "subscription error used the wrong event type")
assert(subscription_error$subscriptionId == "subscription", "subscription error lost its ID")

closed <- serialize(list(id = "close", type = "closed"))
assert(closed$id == "close" && closed$type == "closed", "close serialization was invalid")

plain_error <- serialize(error_event("protocol", convex_error("convex_protocol_error", "bad frame")))
assert(!("data" %in% names(plain_error$error)), "absent structured error data was serialized as null")

# Pause after dequeue, then model unsubscribe and same-ID replacement. Neither
# stale relay may publish after the corresponding acknowledgement.
stale_relay <- function(replace) {
  active <- TRUE
  current <- TRUE
  queued <- list(value = list(count = 1L), error = NULL, logs = character())
  subscription <- list(
    take_update = function() {
      value <- queued
      queued <<- NULL
      value
    },
    active = function() active
  )
  output <- textConnection("lines", open = "w", local = TRUE)
  published <- relay_update(
    "race",
    subscription,
    output,
    function() current,
    before_publish = function() {
      if (replace) current <<- FALSE else active <<- FALSE
    }
  )
  close(output)
  !published && !length(lines)
}
assert(stale_relay(FALSE), "a dequeued relay crossed unsubscribe acknowledgement")
assert(stale_relay(TRUE), "a dequeued relay crossed same-ID replacement acknowledgement")
cat("PASS R adapter protocol serialization fixtures\n")
