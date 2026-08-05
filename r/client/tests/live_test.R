source("client/convex.R")
source("client/live.R")

assert <- function(value, message) {
  if (!isTRUE(value)) stop(message, call. = FALSE)
}

fixture <- new.env(parent = emptyenv())
fixture$connections <- list()
fixture$factory <- function(url, client_version, handlers) {
  connection <- new.env(parent = emptyenv())
  connection$url <- url
  connection$client_version <- client_version
  connection$handlers <- handlers
  connection$sent <- list()
  connection$closed <- FALSE
  transport <- list(
    connect = function() handlers$open(),
    send = function(message) connection$sent <- c(connection$sent, list(jsonlite::fromJSON(message, simplifyVector = FALSE))),
    close = function(code = 1000L, reason = "") connection$closed <- TRUE,
    ready_state = function() if (connection$closed) 3L else 1L
  )
  connection$transport <- transport
  fixture$connections[[length(fixture$connections) + 1L]] <- connection
  transport
}

version <- function(query_set, timestamp) {
  list(querySet = query_set, identity = 0L, ts = timestamp)
}

transition <- function(start, end, modifications) {
  convex_json(list(type = "Transition", startVersion = start, endVersion = end, modifications = modifications))
}

emit <- function(connection, message) {
  connection$handlers$message(as.character(message))
}

manager <- convex_live("http://127.0.0.1:9999", "r-test", fixture$factory)
subscription <- manager$subscribe("demo:state", list(room = "fixture"))
connection <- fixture$connections[[1L]]
assert(connection$sent[[1L]]$type == "Connect", "Live did not send Connect first")
assert(connection$sent[[1L]]$connectionCount == 0L, "first Connect had the wrong connection count")
add <- connection$sent[[2L]]
assert(add$type == "ModifyQuerySet" && add$baseVersion == 0L && add$newVersion == 1L, "Add used the wrong query-set version")
assert(add$modifications[[1L]]$type == "Add", "first query-set modification was not Add")
assert(add$modifications[[1L]]$args[[1L]]$room == "fixture", "Add did not encode args as a one-element array")
assert(
  as.character(convex_json(list(args = list(convex_named_object(list()))))) == '{"args":[{}]}',
  "empty Live args were encoded as an array"
)

v0 <- version(0L, "AAAAAAAAAAA=")
v1 <- version(1L, "AQAAAAAAAAA=")
emit(connection, transition(v0, v1, list(list(type = "QueryUpdated", queryId = 0L, value = list(count = 0L), logLines = list()))))
assert(subscription$next_update(0.1)$value$count == 0L, "initial QueryUpdated was not delivered")

v2 <- version(1L, "AgAAAAAAAAA=")
emit(connection, transition(v1, v2, list(list(type = "QueryFailed", queryId = 0L, errorMessage = "room empty", errorData = list(code = "ROOM_EMPTY"), logLines = list("before failure")))))
failed <- subscription$next_update(0.1)
assert(inherits(failed$error, "convex_function_error"), "QueryFailed was not structured")
assert(failed$error$data$code == "ROOM_EMPTY", "QueryFailed lost its data")

v3 <- version(1L, "AwAAAAAAAAA=")
emit(connection, transition(v2, v3, list(list(type = "QueryUpdated", queryId = 0L, value = list(count = 1L), logLines = list()))))
assert(subscription$next_update(0.1)$value$count == 1L, "subscription did not recover after QueryFailed")

# A slow consumer retains exactly the newest sixteen updates.
previous <- v3
for (count in 2:18) {
  next_version <- version(1L, paste0("timestamp-", count))
  emit(connection, transition(previous, next_version, list(list(type = "QueryUpdated", queryId = 0L, value = list(count = count), logLines = list()))))
  previous <- next_version
}
observed <- integer()
repeat {
  update <- subscription$take_update()
  if (is.null(update)) break
  observed <- c(observed, update$value$count)
}
assert(identical(observed, 3:18), "Live did not retain the newest sixteen updates")

# Unsubscribe invalidates and clears a relay before Remove is acknowledged.
emit(connection, transition(previous, version(1L, "stale"), list(list(type = "QueryUpdated", queryId = 0L, value = list(count = 19L), logLines = list()))))
subscription$close()
assert(is.null(subscription$take_update()), "a stale update crossed unsubscribe")
remove <- tail(connection$sent, 1L)[[1L]]
assert(remove$modifications[[1L]]$type == "Remove", "unsubscribe did not send Remove")

# Reconnect five times, resend every Add, retain connection metadata, and
# suppress unchanged hydration before delivering the real changed value.
subscription <- manager$subscribe("demo:state", list(room = "reconnect"))
connection <- fixture$connections[[1L]]
start <- version(1L, "stale")
initial <- version(2L, "initial-reconnect")
emit(connection, transition(start, initial, list(list(type = "QueryUpdated", queryId = 1L, value = list(count = 0L), logLines = list()))))
assert(subscription$next_update(0.1)$value$count == 0L, "reconnect fixture initial value failed")
last_version <- initial
for (attempt in 1:5) {
  manager$debug_disconnect()
  manager$pump(0)
  connection <- fixture$connections[[attempt + 1L]]
  assert(connection$sent[[1L]]$connectionCount == attempt, "Connect lost connectionCount")
  assert(connection$sent[[1L]]$lastCloseReason == "DebugDisconnect", "Connect lost lastCloseReason")
  assert(connection$sent[[1L]]$maxObservedTimestamp == last_version$ts, "Connect lost maxObservedTimestamp")
  assert(connection$sent[[2L]]$modifications[[1L]]$type == "Add", "reconnect did not resend Add")
  hydrated <- version(1L, paste0("hydrate-", attempt))
  emit(connection, transition(v0, hydrated, list(list(type = "QueryUpdated", queryId = 1L, value = list(count = attempt - 1L), logLines = list()))))
  if (attempt == 1L) assert(is.null(subscription$take_update()), "unchanged hydration was relayed")
  changed <- version(1L, paste0("changed-", attempt))
  emit(connection, transition(hydrated, changed, list(list(type = "QueryUpdated", queryId = 1L, value = list(count = attempt), logLines = list()))))
  assert(subscription$next_update(0.1)$value$count == attempt, "reconnect did not deliver the changed value")
  last_version <- changed
}
metadata <- manager$metadata()
assert(metadata$connectionCount == 5L, "metadata lost connectionCount")
assert(metadata$lastCloseReason == "DebugDisconnect", "metadata lost lastCloseReason")
assert(metadata$maxObservedTimestamp == last_version$ts, "metadata lost maxObservedTimestamp")

# Protocol and transport failures are typed, reconnect, and do not strand the
# otherwise valid subscription.
connection$handlers$message("not-json")
protocol_failure <- subscription$next_update(0.1)
assert(inherits(protocol_failure$error, "convex_protocol_error"), "invalid JSON did not produce ProtocolError")
Sys.sleep(0.11)
manager$pump(0)
connection <- tail(fixture$connections, 1L)[[1L]]
connection$handlers$error("fixture transport failure")
transport_failure <- subscription$next_update(0.1)
assert(inherits(transport_failure$error, "convex_transport_error"), "transport failure was not structured")
Sys.sleep(0.11)
manager$pump(0)
connection <- tail(fixture$connections, 1L)[[1L]]
recovered <- version(1L, "recovered")
emit(connection, transition(v0, recovered, list(list(type = "QueryUpdated", queryId = 1L, value = list(count = 99L), logLines = list()))))
assert(subscription$next_update(0.1)$value$count == 99L, "subscription stayed stranded after reconnect")

started <- proc.time()[["elapsed"]]
manager$close()
assert(proc.time()[["elapsed"]] - started < 0.5, "close was not bounded")

# Same-ID adapter replacement closes the old client subscription before the
# acknowledgement. A late old query update is ignored while the replacement
# continues normally on its new query ID.
fixture$connections <- list()
manager <- convex_live("http://127.0.0.1:9999", "r-test", fixture$factory)
old <- manager$subscribe("demo:state", list(room = "replacement-old"))
connection <- fixture$connections[[1L]]
old_initial <- version(1L, "replacement-old")
emit(connection, transition(v0, old_initial, list(list(type = "QueryUpdated", queryId = 0L, value = list(count = 0L), logLines = list()))))
invisible(old$next_update(0.1))
old$close()
replacement <- manager$subscribe("demo:state", list(room = "replacement-new"))
replacement_version <- version(2L, "replacement-new")
emit(connection, transition(old_initial, replacement_version, list(
  list(type = "QueryUpdated", queryId = 0L, value = list(count = 99L), logLines = list()),
  list(type = "QueryUpdated", queryId = 1L, value = list(count = 1L), logLines = list())
)))
assert(is.null(old$take_update()), "a stale event crossed same-ID replacement")
assert(replacement$next_update(0.1)$value$count == 1L, "replacement subscription was stranded")
manager$close()

# A healthy handshake resets exponential backoff. The second failure must be
# eligible after the initial 100 ms delay, not inherit the previous maximum.
fixture$connections <- list()
manager <- convex_live("http://127.0.0.1:9999", "r-test", fixture$factory)
subscription <- manager$subscribe("demo:state", list(room = "backoff"))
fixture$connections[[1L]]$handlers$error("first failure")
Sys.sleep(0.11)
manager$pump(0)
assert(length(fixture$connections) == 2L, "first reconnect was not scheduled")
fixture$connections[[2L]]$handlers$error("second failure")
Sys.sleep(0.11)
manager$pump(0)
assert(length(fixture$connections) == 3L, "healthy handshake did not reset backoff")
manager$close()
cat("PASS R Live state-machine fixtures\n")
