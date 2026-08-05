# A single R event-loop owner polls the socket and applies every query-set
# transition. Subscriptions only enqueue state changes, so they never write to
# or read from the WebSocket concurrently.
convex_live <- function(deployment_url, client_version) {
  state <- new.env(parent = emptyenv())
  state$url <- sub("^http", "ws", paste0(sub("/+$", "", deployment_url), "/api/sync"))
  state$version <- client_version; state$socket <- NULL; state$subscriptions <- list(); state$next_id <- 0L
  state$connection_count <- 0L; state$last_close_reason <- "InitialConnect"; state$max_observed_timestamp <- NULL; state$closed <- FALSE
  state$backoff <- 0.1; state$next_connect <- Sys.time(); state$remote <- list(); state$version_number <- 0L
  connect <- function() {
    if (state$closed || !is.null(state$socket) || Sys.time() < state$next_connect) return()
    state$socket <- websocket::WebSocket$new(state$url, headers = c("Convex-Client" = state$version))
    state$socket$onOpen(function(event) {
      state$connection_count <- state$connection_count + 1L
      state$backoff <- 0.1
      for (entry in state$subscriptions) {
        state$socket$send(jsonlite::toJSON(list(type = "ModifyQuerySet", version = state$version_number, modifications = list(list(type = "Add", queryId = entry$query_id, udfPath = entry$path, args = entry$args))), auto_unbox = TRUE, null = "null"))
      }
    })
    state$socket$onMessage(function(event) apply_message(event$data))
    state$socket$onClose(function(event) { state$last_close_reason <- event$reason %||% "TransportClosed"; state$socket <- NULL; state$next_connect <- Sys.time() + state$backoff; state$backoff <- min(15, state$backoff * 2) })
  }
  enqueue <- function(entry, update) { if (!entry$active) return(); entry$updates <- c(entry$updates, list(update)); if (length(entry$updates) > 16L) entry$updates <- tail(entry$updates, 16L); state$subscriptions[[entry$query_id]] <<- entry }
  apply_message <- function(data) {
    message <- tryCatch(jsonlite::fromJSON(data, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(message)) return()
    state$max_observed_timestamp <- message$ts %||% state$max_observed_timestamp
    # Convex Sync transitions contain QueryUpdated or QueryFailed entries.
    for (transition in message$modifications %||% list()) {
      id <- transition$queryId %||% ""; entry <- state$subscriptions[[id]]
      if (is.null(entry)) next
      if (identical(transition$type, "QueryUpdated")) enqueue(entry, list(value = transition$value, error = NULL, logs = transition$logLines %||% character()))
      if (identical(transition$type, "QueryFailed")) enqueue(entry, list(value = NULL, error = convex_error("convex_function_error", transition$errorMessage %||% "Live query failed", "live"), logs = character()))
    }
  }
  pump <- function(seconds = 0.02) { connect(); if (!is.null(state$socket)) try(state$socket$poll(timeout = seconds), silent = TRUE); invisible(NULL) }
  subscribe <- function(path, args) {
    state$next_id <- state$next_id + 1L
    id <- as.character(state$next_id)
    entry <- list(query_id = id, path = path, args = args, updates = list(), active = TRUE)
    state$subscriptions[[id]] <- entry
    connect()
    if (!is.null(state$socket) && state$socket$readyState == 1L) state$socket$send(jsonlite::toJSON(list(type = "ModifyQuerySet", version = state$version_number, modifications = list(list(type = "Add", queryId = id, udfPath = path, args = args))), auto_unbox = TRUE, null = "null"))
    list(next_update = function(timeout = 10) { deadline <- Sys.time() + timeout; repeat { pump(); entry <- state$subscriptions[[id]]; if (is.null(entry) || !entry$active) convex_stop("convex_closed", "Live subscription is closed"); if (length(entry$updates)) { update <- entry$updates[[1]]; entry$updates <- entry$updates[-1]; state$subscriptions[[id]] <- entry; return(update) }; if (Sys.time() >= deadline) convex_stop("convex_transport_error", "timed out waiting for Live update", "live") } }, close = function() { entry <- state$subscriptions[[id]]; if (is.null(entry)) return(invisible(NULL)); entry$active <- FALSE; state$subscriptions[[id]] <- entry; if (!is.null(state$socket) && state$socket$readyState == 1L) try(state$socket$send(jsonlite::toJSON(list(type = "ModifyQuerySet", version = state$version_number, modifications = list(list(type = "Remove", queryId = id))), auto_unbox = TRUE)), silent = TRUE); state$subscriptions[[id]] <- NULL; invisible(NULL) })
  }
  list(subscribe = subscribe, debug_disconnect = function() { if (!is.null(state$socket)) state$socket$close(); pump(); invisible(NULL) }, close = function() { state$closed <- TRUE; if (!is.null(state$socket)) state$socket$close(); state$subscriptions <- list(); invisible(NULL) }, metadata = function() list(connectionCount = state$connection_count, lastCloseReason = state$last_close_reason, maxObservedTimestamp = state$max_observed_timestamp))
}
