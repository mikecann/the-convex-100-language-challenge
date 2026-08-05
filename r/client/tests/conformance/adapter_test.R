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
assert(error$error$name == "FunctionError", "function error used a noncanonical name")
assert(is.list(error$logs) && identical(error$logs, list("before failure")), "one error log was not serialized as an array")

subscription_error <- serialize(error_event(NULL, failure, "subscription"))
assert(subscription_error$type == "subscription", "subscription error used the wrong event type")
assert(subscription_error$subscriptionId == "subscription", "subscription error lost its ID")

closed <- serialize(list(id = "close", type = "closed"))
assert(closed$id == "close" && closed$type == "closed", "close serialization was invalid")

plain_error <- serialize(error_event("protocol", convex_error("convex_protocol_error", "bad frame")))
assert(!("data" %in% names(plain_error$error)), "absent structured error data was serialized as null")
assert(plain_error$error$name == "ProtocolError", "protocol error used a noncanonical name")
transport_error <- serialize(error_event("transport", convex_error("convex_transport_error", "socket closed")))
assert(transport_error$error$name == "TransportError", "transport error used a noncanonical name")

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

closed_count <- 0L
fake_subscriptions <- new.env(hash = TRUE, parent = emptyenv())
assign("one", list(close = function() closed_count <<- closed_count + 1L), envir = fake_subscriptions)
assign("two", list(close = function() closed_count <<- closed_count + 1L), envir = fake_subscriptions)
fake_client <- list(close = function() closed_count <<- closed_count + 1L)
close_adapter_resources(fake_client, fake_subscriptions)
assert(closed_count == 3L && !length(ls(fake_subscriptions)), "EOF cleanup did not close every relay and client")

# Fragment two commands across TCP writes, then close without an explicit close
# command. EOF must close the client and relay as well as terminate the adapter.
port <- 44000L + (Sys.getpid() %% 10000L)
server <- serverSocket(port)
resource_closes <- 0L
fake_subscription <- list(
  close = function() resource_closes <<- resource_closes + 1L,
  take_update = function() NULL,
  active = function() TRUE
)
fake_client <- list(
  subscribe = function(path, args) fake_subscription,
  pump_live = function(timeout) invisible(NULL),
  close = function() resource_closes <<- resource_closes + 1L
)
writer <- parallel::mcparallel(
  {
    socket <- socketConnection("127.0.0.1", port, blocking = TRUE, open = "wb")
    on.exit(close(socket))
    bytes <- charToRaw(paste0(
      '{"protocolVersion":1,"id":"hello","op":"hello"}\n',
      '{"id":"watch","op":"subscribe","subscriptionId":"sub","path":"counter:get","args":{}}\n'
    ))
    writeBin(bytes[1:17], socket)
    flush(socket)
    Sys.sleep(0.02)
    writeBin(bytes[18:63], socket)
    flush(socket)
    Sys.sleep(0.02)
    writeBin(bytes[64:length(bytes)], socket)
    flush(socket)
    writeBin(charToRaw('{"id":"partial"'), socket)
    flush(socket)
    close(socket)
    invisible(NULL)
  },
  silent = TRUE
)
input <- socketAccept(server, blocking = FALSE, open = "rb")
output <- textConnection("events", open = "w", local = TRUE)
started <- proc.time()[["elapsed"]]
Sys.setenv(CONVEX_URL = "https://fixture.invalid")
run_adapter(
  input,
  output,
  input_ready = function() socketSelect(list(input), timeout = 0)[[1L]],
  client_factory = function(url) fake_client
)
elapsed <- proc.time()[["elapsed"]] - started
close(output)
close(input)
close(server)
invisible(parallel::mccollect(writer, wait = TRUE))
assert(elapsed < 0.5, "fragmented TCP EOF did not terminate within the deadline")
assert(length(events) == 3L && grepl('"type":"ready"', events[[1L]], fixed = TRUE), "fragmented TCP command was not assembled before EOF")
assert(grepl('"id":"watch","type":"ack"', events[[2L]], fixed = TRUE), "fragmented subscription was not acknowledged")
assert(grepl('"name":"ProtocolError"', events[[3L]], fixed = TRUE), "partial TCP frame did not report a structured EOF error")
assert(resource_closes == 2L, "TCP EOF did not close the subscription and client")

# Valid JSON is not necessarily a command object. Scalars, null, and arrays
# must stay inside the protocol error boundary instead of crashing on `$`.
malformed_input <- rawConnection(charToRaw('"scalar"\n1\nnull\n[]\n'), open = "rb")
malformed_output <- textConnection("malformed_events", open = "w", local = TRUE)
run_adapter(malformed_input, malformed_output, input_ready = function() TRUE)
close(malformed_output)
close(malformed_input)
assert(length(malformed_events) == 4L, "non-object JSON did not produce one error per command")
for (event in malformed_events) {
  decoded <- jsonlite::fromJSON(event, simplifyVector = FALSE)
  assert(decoded$type == "error" && decoded$error$name == "ProtocolError", "non-object JSON escaped the structured protocol error boundary")
}
cat("PASS R adapter protocol serialization fixtures\n")
