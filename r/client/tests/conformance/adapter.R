#!/usr/local/bin/Rscript
client_path <- Sys.getenv("CONVEX_CLIENT_PATH", "/opt/convex/client")
source(file.path(client_path, "convex.R"))
source(file.path(client_path, "live.R"))

write_event <- function(io, event) {
  writeLines(as.character(convex_json(event)), io)
  flush(io)
}

adapter_error <- function(error) {
  name <- switch(class(error)[1L],
    convex_function_error = "FunctionError",
    convex_protocol_error = "ProtocolError",
    convex_transport_error = "TransportError",
    convex_closed = "ClosedError",
    class(error)[1L] %||% "Error"
  )
  serialized <- list(
    name = name,
    message = conditionMessage(error)
  )
  if (inherits(error, "convex_error") && !is.null(error$data)) serialized$data <- error$data
  serialized
}

error_event <- function(id, error, subscription_id = NULL) {
  event <- list(
    type = if (is.null(subscription_id)) "error" else "subscription",
    error = adapter_error(error)
  )
  if (!is.null(id) && is.null(subscription_id)) event$id <- id
  if (!is.null(subscription_id)) event$subscriptionId <- subscription_id
  if (inherits(error, "convex_error") && length(error$logs)) event$logs <- as.list(error$logs)
  event
}

relay_update <- function(subscription_id, subscription, output, is_current, before_publish = function() invisible(NULL)) {
  update <- subscription$take_update()
  if (is.null(update)) {
    return(FALSE)
  }
  # Recheck after dequeue. This makes a paused relay harmless if unsubscribe or
  # same-ID replacement invalidates it before publication.
  before_publish()
  if (!subscription$active() || !is_current()) {
    return(FALSE)
  }
  if (!is.null(update$error)) {
    write_event(output, error_event(NULL, update$error, subscription_id))
  } else {
    write_event(output, list(
      type = "subscription",
      subscriptionId = subscription_id,
      value = update$value,
      logs = as.list(update$logs)
    ))
  }
  TRUE
}

run_adapter <- function(input, output) {
  client <- NULL
  subscriptions <- new.env(hash = TRUE, parent = emptyenv())
  running <- TRUE

  ensure_client <- function() {
    if (is.null(client)) {
      deployment_url <- Sys.getenv("CONVEX_URL")
      if (!nzchar(deployment_url)) convex_stop("convex_protocol_error", "CONVEX_URL is required")
      client <<- convex_client(deployment_url)
    }
    client
  }

  drain_subscriptions <- function() {
    if (is.null(client)) {
      return(invisible(NULL))
    }
    client$pump_live(0)
    for (subscription_id in ls(subscriptions, all.names = TRUE)) {
      subscription <- get(subscription_id, envir = subscriptions, inherits = FALSE)
      is_current <- function() {
        exists(subscription_id, envir = subscriptions, inherits = FALSE) &&
          identical(get(subscription_id, envir = subscriptions, inherits = FALSE), subscription)
      }
      while (relay_update(subscription_id, subscription, output, is_current)) {
        invisible(NULL)
      }
    }
    invisible(NULL)
  }

  handle_command <- function(command) {
    id <- command$id
    tryCatch(
      {
        if (identical(command$op, "hello")) {
          if (!identical(command$protocolVersion, 1L)) convex_stop("convex_protocol_error", paste("unsupported adapter protocol version", command$protocolVersion %||% "<missing>"))
          write_event(output, list(
            protocolVersion = 1L,
            id = id,
            type = "ready",
            language = "r",
            implementation = paste0("native-r-", getRversion()),
            runtime = paste0("R-", getRversion())
          ))
        } else if (command$op %in% c("query", "mutation", "action")) {
          result <- do.call(ensure_client()[[command$op]], list(command$path, command$args %||% list()))
          write_event(output, list(id = id, type = "result", value = result$value, logs = as.list(result$logs)))
        } else if (identical(command$op, "setAuth")) {
          ensure_client()$set_auth(command$token %||% "")
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(command$op, "subscribe")) {
          subscription_id <- command$subscriptionId
          if (exists(subscription_id, envir = subscriptions, inherits = FALSE)) {
            get(subscription_id, envir = subscriptions, inherits = FALSE)$close()
            rm(list = subscription_id, envir = subscriptions)
          }
          subscription <- ensure_client()$subscribe(command$path, command$args %||% list())
          assign(subscription_id, subscription, envir = subscriptions)
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(command$op, "unsubscribe")) {
          subscription_id <- command$subscriptionId
          if (exists(subscription_id, envir = subscriptions, inherits = FALSE)) {
            get(subscription_id, envir = subscriptions, inherits = FALSE)$close()
            rm(list = subscription_id, envir = subscriptions)
          }
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(command$op, "debugDisconnect")) {
          ensure_client()$debug_disconnect_for_adapter()
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(command$op, "close")) {
          for (subscription_id in ls(subscriptions, all.names = TRUE)) {
            get(subscription_id, envir = subscriptions, inherits = FALSE)$close()
          }
          if (!is.null(client)) client$close()
          write_event(output, list(id = id, type = "closed"))
          running <<- FALSE
        } else {
          convex_stop("convex_protocol_error", paste("unknown adapter operation", command$op %||% "<missing>"))
        }
      },
      error = function(error) write_event(output, error_event(id, error))
    )
    invisible(NULL)
  }

  while (running) {
    line <- tryCatch(readLines(input, n = 1L, warn = FALSE), error = function(error) character())
    if (length(line)) {
      command <- tryCatch(
        jsonlite::fromJSON(line, simplifyVector = FALSE),
        error = function(error) {
          write_event(output, error_event(NULL, convex_error("convex_protocol_error", paste("decode command:", conditionMessage(error)))))
          NULL
        }
      )
      if (!is.null(command)) handle_command(command)
    }
    # Command handling comes first. Unsubscribe and same-ID replacement make
    # the old relay unreachable before their acknowledgement is published.
    if (running) drain_subscriptions()
    if (!length(line)) Sys.sleep(0.002)
  }
  invisible(NULL)
}

address <- Sys.getenv("ADAPTER_LISTEN", "")
if (identical(Sys.getenv("CONVEX_ADAPTER_TESTING"), "1")) {
  invisible(NULL)
} else if (!nzchar(address)) {
  # Rscript initializes stdin() itself, and in the minimal runtime that
  # connection can already be at EOF. Opening this pseudo-file reads the exact
  # controller bytes and permits the Live loop to poll between commands.
  input <- file("stdin", open = "r", blocking = FALSE)
  on.exit(close(input))
  run_adapter(input, stdout())
} else {
  pieces <- strsplit(address, ":", fixed = TRUE)[[1]]
  socket <- socketConnection(
    host = pieces[1],
    port = as.integer(pieces[2]),
    server = TRUE,
    blocking = FALSE,
    open = "r+"
  )
  on.exit(close(socket))
  run_adapter(socket, socket)
}
