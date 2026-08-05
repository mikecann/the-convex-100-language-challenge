# Convex Live is a small state machine layered on an ordinary WebSocket. Every
# socket callback runs through R's one `later` event loop, so one owner alone
# reads, writes, reconnects, and advances query-set versions.

convex_json <- function(value) {
  jsonlite::toJSON(value, auto_unbox = TRUE, null = "null", digits = NA)
}

convex_json_signature <- function(value) {
  as.character(convex_json(value))
}

convex_session_id <- function() {
  hex <- paste(sample(c(0:9, letters[1:6]), 32L, replace = TRUE), collapse = "")
  paste(substr(hex, 1L, 8L), substr(hex, 9L, 12L), substr(hex, 13L, 16L), substr(hex, 17L, 20L), substr(hex, 21L, 32L), sep = "-")
}

convex_websocket_transport <- function(url, client_version, handlers) {
  socket <- websocket::WebSocket$new(
    url,
    headers = c("Convex-Client" = client_version),
    autoConnect = FALSE,
    errorLogChannels = "none",
    maxMessageSize = 2L * 1024L * 1024L
  )
  socket$onOpen(function(event) handlers$open())
  socket$onMessage(function(event) handlers$message(event$data))
  socket$onClose(function(event) handlers$close(event$reason %||% "ServerClosed"))
  socket$onError(function(event) handlers$error(event$message %||% "WebSocket transport error"))
  list(
    connect = function() socket$connect(),
    send = function(message) socket$send(message),
    close = function(code = 1000L, reason = "client closed") socket$close(code, reason),
    ready_state = function() unclass(socket$readyState())
  )
}

convex_live <- function(deployment_url, client_version, transport_factory = convex_websocket_transport) {
  initial_timestamp <- "AAAAAAAAAAA="
  state <- new.env(parent = emptyenv())
  state$url <- sub("^http", "ws", paste0(sub("/+$", "", deployment_url), "/api/sync"))
  state$client_version <- client_version
  state$transport_factory <- transport_factory
  state$transport <- NULL
  state$generation <- 0L
  state$connecting <- FALSE
  state$connected <- FALSE
  state$closed <- FALSE
  state$subscriptions <- new.env(hash = TRUE, parent = emptyenv())
  state$next_query_id <- 0L
  state$query_set_version <- 0L
  state$remote_version <- list(querySet = 0L, identity = 0L, ts = initial_timestamp)
  state$connection_count <- 0L
  state$last_close_reason <- "InitialConnect"
  state$max_observed_timestamp <- NULL
  state$next_backoff <- 0.1
  state$reconnect_at <- 0
  state$last_server_response <- as.numeric(Sys.time())

  active_entries <- function() {
    ids <- ls(state$subscriptions, all.names = TRUE)
    entries <- lapply(ids, function(id) get(id, envir = state$subscriptions, inherits = FALSE))
    entries[vapply(entries, function(entry) isTRUE(entry$active), logical(1))]
  }

  send_json <- function(value) {
    if (!state$connected || is.null(state$transport)) convex_stop("convex_transport_error", "Live WebSocket is not connected", "live")
    tryCatch(
      {
        state$transport$send(as.character(convex_json(value)))
        TRUE
      },
      error = function(error) {
        typed <- convex_error("convex_transport_error", paste("WebSocket write failed:", conditionMessage(error)), "live")
        publish_error(typed)
        retire_transport(conditionMessage(typed), reconnect = TRUE, close_socket = TRUE)
        FALSE
      }
    )
  }

  add_modification <- function(entry) {
    list(type = "Add", queryId = entry$query_id, udfPath = entry$path, args = list(entry$args))
  }

  modify_query_set <- function(modifications) {
    base_version <- state$query_set_version
    sent <- send_json(list(
      type = "ModifyQuerySet",
      baseVersion = base_version,
      newVersion = base_version + 1L,
      modifications = modifications
    ))
    if (!sent) {
      return(FALSE)
    }
    state$query_set_version <- base_version + 1L
    TRUE
  }

  deliver <- function(entry, update) {
    if (!isTRUE(entry$active)) {
      return(invisible(NULL))
    }
    signature <- convex_json_signature(list(value = update$value, error = if (is.null(update$error)) NULL else list(message = conditionMessage(update$error), data = update$error$data)))
    # A reconnect rehydrates every Add. Do not relay the unchanged current
    # value a second time before the controller can apply its external write.
    if (identical(signature, entry$last_signature)) {
      return(invisible(NULL))
    }
    entry$last_signature <- signature
    entry$updates <- c(entry$updates, list(update))
    if (length(entry$updates) > 16L) entry$updates <- tail(entry$updates, 16L)
    invisible(NULL)
  }

  publish_error <- function(error) {
    for (entry in active_entries()) deliver(entry, list(value = NULL, error = error, logs = error$logs %||% character()))
  }

  schedule_reconnect <- function(immediate = FALSE) {
    if (length(active_entries()) == 0L || state$closed) {
      return(invisible(NULL))
    }
    delay <- if (immediate) 0 else state$next_backoff
    state$reconnect_at <- as.numeric(Sys.time()) + delay
    if (!immediate) state$next_backoff <- min(15, state$next_backoff * 2)
    invisible(NULL)
  }

  retire_transport <- function(reason, reconnect = TRUE, close_socket = FALSE) {
    transport <- state$transport
    had_transport <- !is.null(transport)
    state$generation <- state$generation + 1L
    state$transport <- NULL
    state$connecting <- FALSE
    state$connected <- FALSE
    state$query_set_version <- 0L
    state$remote_version <- list(querySet = 0L, identity = 0L, ts = initial_timestamp)
    if (had_transport) state$connection_count <- state$connection_count + 1L
    state$last_close_reason <- reason
    if (close_socket && had_transport) try(transport$close(1001L, reason), silent = TRUE)
    if (reconnect) schedule_reconnect()
    invisible(NULL)
  }

  handle_transition <- function(message) {
    if (!identical(convex_json_signature(message$startVersion), convex_json_signature(state$remote_version))) {
      convex_stop("convex_protocol_error", "Transition start version does not match the local version", "live")
    }
    if (is.null(message$endVersion)) convex_stop("convex_protocol_error", "Transition omitted endVersion", "live")
    changed <- list()
    for (modification in message$modifications %||% list()) {
      if (is.null(modification$queryId)) convex_stop("convex_protocol_error", "Transition modification omitted queryId", "live")
      query_id <- as.character(modification$queryId)
      if (identical(modification$type, "QueryRemoved")) next
      if (identical(modification$type, "QueryUpdated")) {
        if (!("value" %in% names(modification))) convex_stop("convex_protocol_error", "QueryUpdated omitted value", "live")
        changed[[query_id]] <- list(value = modification$value, error = NULL, logs = unlist(modification$logLines %||% list(), use.names = FALSE))
      } else if (identical(modification$type, "QueryFailed")) {
        error <- convex_error(
          "convex_function_error",
          modification$errorMessage %||% "Live query failed",
          "query",
          modification$errorData,
          unlist(modification$logLines %||% list(), use.names = FALSE)
        )
        changed[[query_id]] <- list(value = NULL, error = error, logs = error$logs)
      } else {
        convex_stop("convex_protocol_error", paste("unknown Transition modification", modification$type %||% "<missing>"), "live")
      }
    }
    # Commit the transition atomically before any consumer can observe it.
    state$remote_version <- message$endVersion
    state$max_observed_timestamp <- message$endVersion$ts %||% state$max_observed_timestamp
    for (query_id in names(changed)) {
      if (exists(query_id, envir = state$subscriptions, inherits = FALSE)) {
        deliver(get(query_id, envir = state$subscriptions, inherits = FALSE), changed[[query_id]])
      }
    }
  }

  handle_message <- function(data, generation) {
    if (generation != state$generation || state$closed) {
      return(invisible(NULL))
    }
    state$last_server_response <- as.numeric(Sys.time())
    state$next_backoff <- 0.1
    tryCatch(
      {
        message <- jsonlite::fromJSON(data, simplifyVector = FALSE)
        if (identical(message$type, "Transition")) {
          handle_transition(message)
        } else if (message$type %in% c("Ping", "MutationResponse", "ActionResponse")) {
          invisible(NULL)
        } else if (message$type %in% c("FatalError", "AuthError")) {
          convex_stop("convex_protocol_error", paste0(message$type, ": ", message$error %||% "unknown server error"), "live")
        } else if (identical(message$type, "TransitionChunk")) {
          convex_stop("convex_protocol_error", "TransitionChunk assembly is not implemented", "live")
        } else {
          convex_stop("convex_protocol_error", paste("unknown server message", message$type %||% "<missing>"), "live")
        }
      },
      error = function(error) {
        typed <- if (inherits(error, "convex_error")) error else convex_error("convex_protocol_error", paste("decode server message:", conditionMessage(error)), "live")
        publish_error(typed)
        retire_transport(conditionMessage(typed), reconnect = TRUE, close_socket = TRUE)
      }
    )
  }

  connect_if_due <- function() {
    if (state$closed || state$connected || state$connecting || length(active_entries()) == 0L) {
      return(invisible(NULL))
    }
    if (as.numeric(Sys.time()) < state$reconnect_at) {
      return(invisible(NULL))
    }
    state$connecting <- TRUE
    state$generation <- state$generation + 1L
    generation <- state$generation
    handlers <- list(
      open = function() {
        if (generation != state$generation || state$closed) {
          return(invisible(NULL))
        }
        state$connecting <- FALSE
        state$connected <- TRUE
        state$query_set_version <- 0L
        state$remote_version <- list(querySet = 0L, identity = 0L, ts = initial_timestamp)
        state$last_server_response <- as.numeric(Sys.time())
        state$next_backoff <- 0.1
        connect_message <- list(
          type = "Connect",
          sessionId = convex_session_id(),
          connectionCount = state$connection_count,
          lastCloseReason = state$last_close_reason,
          clientTs = 0L
        )
        if (!is.null(state$max_observed_timestamp)) connect_message$maxObservedTimestamp <- state$max_observed_timestamp
        if (!send_json(connect_message)) {
          return(invisible(NULL))
        }
        entries <- active_entries()
        if (length(entries)) modify_query_set(lapply(entries, add_modification))
      },
      message = function(data) handle_message(data, generation),
      close = function(reason) {
        if (generation == state$generation && !state$closed) retire_transport(reason, reconnect = TRUE)
      },
      error = function(message) {
        if (generation != state$generation || state$closed) {
          return(invisible(NULL))
        }
        error <- convex_error("convex_transport_error", message, "live")
        publish_error(error)
        retire_transport(message, reconnect = TRUE, close_socket = FALSE)
      }
    )
    tryCatch(
      {
        state$transport <- state$transport_factory(state$url, state$client_version, handlers)
        state$transport$connect()
      },
      error = function(error) {
        state$connecting <- FALSE
        typed <- convex_error("convex_transport_error", conditionMessage(error), "live")
        publish_error(typed)
        retire_transport(conditionMessage(error), reconnect = TRUE, close_socket = TRUE)
      }
    )
    invisible(NULL)
  }

  pump <- function(timeout = 0.01) {
    connect_if_due()
    later::run_now(timeoutSecs = max(0, timeout))
    connect_if_due()
    if (state$connected && as.numeric(Sys.time()) - state$last_server_response > 30) {
      error <- convex_error("convex_transport_error", "InactiveServer", "live")
      publish_error(error)
      retire_transport("InactiveServer", reconnect = TRUE, close_socket = TRUE)
    }
    invisible(NULL)
  }

  unsubscribe <- function(query_id) {
    key <- as.character(query_id)
    if (!exists(key, envir = state$subscriptions, inherits = FALSE)) {
      return(invisible(NULL))
    }
    entry <- get(key, envir = state$subscriptions, inherits = FALSE)
    # Invalidate and clear before Remove is sent. No dequeued or buffered relay
    # can cross the acknowledgement returned by the adapter.
    entry$active <- FALSE
    entry$updates <- list()
    rm(list = key, envir = state$subscriptions)
    if (state$connected) modify_query_set(list(list(type = "Remove", queryId = entry$query_id)))
    invisible(NULL)
  }

  subscribe <- function(path, args) {
    if (state$closed) convex_stop("convex_closed", "Convex Live manager is closed")
    state$next_query_id <- state$next_query_id + 1L
    entry <- new.env(parent = emptyenv())
    entry$query_id <- state$next_query_id - 1L
    entry$path <- path
    entry$args <- jsonlite::fromJSON(
      as.character(convex_json(convex_named_object(args))),
      simplifyVector = FALSE
    )
    entry$updates <- list()
    entry$active <- TRUE
    entry$last_signature <- NULL
    assign(as.character(entry$query_id), entry, envir = state$subscriptions)
    if (state$connected) modify_query_set(list(add_modification(entry))) else state$reconnect_at <- 0
    pump(0)
    list(
      next_update = function(timeout = 10) {
        deadline <- as.numeric(Sys.time()) + timeout
        repeat {
          pump(0.01)
          if (!isTRUE(entry$active)) convex_stop("convex_closed", "Live subscription is closed")
          if (length(entry$updates)) {
            update <- entry$updates[[1L]]
            entry$updates <- entry$updates[-1L]
            return(update)
          }
          if (as.numeric(Sys.time()) >= deadline) convex_stop("convex_transport_error", "timed out waiting for Live update", "live")
        }
      },
      take_update = function() {
        pump(0)
        if (!isTRUE(entry$active) || !length(entry$updates)) {
          return(NULL)
        }
        update <- entry$updates[[1L]]
        entry$updates <- entry$updates[-1L]
        update
      },
      close = function() unsubscribe(entry$query_id),
      active = function() isTRUE(entry$active)
    )
  }

  debug_disconnect <- function() {
    if (!state$connected || is.null(state$transport)) convex_stop("convex_transport_error", "Live WebSocket is not connected", "live")
    # Retire the generation before acknowledging. Any late callback from the
    # old socket is ignored, and reconnect work is already scheduled.
    retire_transport("DebugDisconnect", reconnect = TRUE, close_socket = TRUE)
    state$reconnect_at <- 0
    invisible(NULL)
  }

  close_manager <- function() {
    if (state$closed) {
      return(invisible(NULL))
    }
    state$closed <- TRUE
    for (entry in active_entries()) {
      entry$active <- FALSE
      entry$updates <- list()
    }
    if (!is.null(state$transport)) try(state$transport$close(1000L, "client closed"), silent = TRUE)
    state$generation <- state$generation + 1L
    state$transport <- NULL
    state$connected <- FALSE
    state$connecting <- FALSE
    invisible(NULL)
  }

  list(
    subscribe = subscribe,
    debug_disconnect = debug_disconnect,
    close = close_manager,
    pump = pump,
    metadata = function() {
      list(
        connectionCount = state$connection_count,
        lastCloseReason = state$last_close_reason,
        maxObservedTimestamp = state$max_observed_timestamp
      )
    }
  )
}
