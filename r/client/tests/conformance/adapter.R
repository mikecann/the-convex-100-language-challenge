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

close_adapter_resources <- function(client, subscriptions) {
  for (subscription_id in ls(subscriptions, all.names = TRUE)) {
    try(get(subscription_id, envir = subscriptions, inherits = FALSE)$close(), silent = TRUE)
    rm(list = subscription_id, envir = subscriptions)
  }
  if (!is.null(client)) try(client$close(), silent = TRUE)
  invisible(NULL)
}

run_adapter <- function(input, output, input_ready, after_input = function(eof) invisible(NULL), client_factory = convex_client) {
  client <- NULL
  subscriptions <- new.env(hash = TRUE, parent = emptyenv())
  running <- TRUE
  cleaned <- FALSE
  input_buffer <- raw()
  cleanup <- function() {
    if (!cleaned) {
      close_adapter_resources(client, subscriptions)
      cleaned <<- TRUE
    }
    invisible(NULL)
  }
  on.exit(cleanup(), add = TRUE)

  ensure_client <- function() {
    if (is.null(client)) {
      deployment_url <- Sys.getenv("CONVEX_URL")
      if (!nzchar(deployment_url)) convex_stop("convex_protocol_error", "CONVEX_URL is required")
      client <<- client_factory(deployment_url)
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
    id <- NULL
    tryCatch(
      {
        if (!is.list(command) || is.null(names(command))) {
          convex_stop("convex_protocol_error", "adapter command must be a JSON object")
        }
        command_id <- command[["id"]]
        if (!is.null(command_id) && (!is.character(command_id) || length(command_id) != 1L || !nzchar(command_id))) {
          convex_stop("convex_protocol_error", "adapter command id must be a nonempty string")
        }
        id <- command_id
        operation <- command[["op"]]
        if (!is.character(operation) || length(operation) != 1L || !nzchar(operation)) {
          convex_stop("convex_protocol_error", "adapter command op must be a nonempty string")
        }
        if (identical(operation, "hello")) {
          if (!identical(command$protocolVersion, 1L)) convex_stop("convex_protocol_error", paste("unsupported adapter protocol version", command$protocolVersion %||% "<missing>"))
          write_event(output, list(
            protocolVersion = 1L,
            id = id,
            type = "ready",
            language = "r",
            implementation = paste0("native-r-", getRversion()),
            runtime = paste0("R-", getRversion())
          ))
        } else if (operation %in% c("query", "mutation", "action")) {
          result <- do.call(ensure_client()[[operation]], list(command$path, command$args %||% list()))
          write_event(output, list(id = id, type = "result", value = result$value, logs = as.list(result$logs)))
        } else if (identical(operation, "setAuth")) {
          ensure_client()$set_auth(command$token %||% "")
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(operation, "subscribe")) {
          subscription_id <- command$subscriptionId
          if (exists(subscription_id, envir = subscriptions, inherits = FALSE)) {
            get(subscription_id, envir = subscriptions, inherits = FALSE)$close()
            rm(list = subscription_id, envir = subscriptions)
          }
          subscription <- ensure_client()$subscribe(command$path, command$args %||% list())
          assign(subscription_id, subscription, envir = subscriptions)
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(operation, "unsubscribe")) {
          subscription_id <- command$subscriptionId
          if (exists(subscription_id, envir = subscriptions, inherits = FALSE)) {
            get(subscription_id, envir = subscriptions, inherits = FALSE)$close()
            rm(list = subscription_id, envir = subscriptions)
          }
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(operation, "debugDisconnect")) {
          ensure_client()$debug_disconnect_for_adapter()
          write_event(output, list(id = id, type = "ack"))
        } else if (identical(operation, "close")) {
          cleanup()
          write_event(output, list(id = id, type = "closed"))
          running <<- FALSE
        } else {
          convex_stop("convex_protocol_error", paste("unknown adapter operation", operation))
        }
      },
      error = function(error) write_event(output, error_event(id, error))
    )
    invisible(NULL)
  }

  handle_frame <- function(frame) {
    if (length(frame) && identical(frame[[length(frame)]], as.raw(0x0d))) {
      frame <- frame[-length(frame)]
    }
    line <- tryCatch(
      iconv(rawToChar(frame), from = "UTF-8", to = "UTF-8", sub = NA_character_),
      error = function(error) NA_character_
    )
    if (length(line) != 1L || is.na(line)) {
      write_event(output, error_event(NULL, convex_error("convex_protocol_error", "decode command: invalid UTF-8")))
    } else {
      parse_succeeded <- TRUE
      command <- tryCatch(
        jsonlite::fromJSON(line, simplifyVector = FALSE),
        error = function(error) {
          parse_succeeded <<- FALSE
          write_event(output, error_event(NULL, convex_error("convex_protocol_error", paste("decode command:", conditionMessage(error)))))
          NULL
        }
      )
      if (parse_succeeded) handle_command(command)
    }
    invisible(NULL)
  }

  while (running) {
    # Run fd and WebSocket callbacks in this process. The adapter remains the
    # only owner of its R connections, avoiding unsafe inherited connections.
    later::run_now(0)
    if (input_ready()) {
      chunk <- tryCatch(
        readBin(input, what = "raw", n = 65536L),
        error = function(error) {
          write_event(output, error_event(NULL, convex_error("convex_transport_error", paste("read command:", conditionMessage(error)))))
          raw()
        }
      )
      eof <- !length(chunk)
      if (!eof) {
        input_buffer <- c(input_buffer, chunk)
        repeat {
          newline <- match(as.raw(0x0a), input_buffer)
          if (is.na(newline)) break
          frame <- if (newline == 1L) raw() else input_buffer[seq_len(newline - 1L)]
          input_buffer <- if (newline == length(input_buffer)) raw() else input_buffer[(newline + 1L):length(input_buffer)]
          handle_frame(frame)
          if (!running) break
        }
      }
      after_input(eof)
      if (eof) {
        if (length(input_buffer)) {
          write_event(output, error_event(NULL, convex_error("convex_protocol_error", "decode command: truncated NDJSON frame at EOF")))
        }
        break
      }
    }
    # Command handling comes first. Unsubscribe and same-ID replacement make
    # the old relay unreachable before their acknowledgement is published.
    if (running) drain_subscriptions()
    Sys.sleep(0.002)
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
  input <- file("stdin", open = "rb", blocking = FALSE)
  on.exit(close(input))
  readiness <- new.env(parent = emptyenv())
  arm_stdin <- function() {
    readiness$ready <- FALSE
    readiness$cancel <- later::later_fd(
      function(...) readiness$ready <- TRUE,
      readfds = 0L
    )
  }
  arm_stdin()
  on.exit(if (!readiness$ready) readiness$cancel(), add = TRUE)
  run_adapter(
    input,
    stdout(),
    input_ready = function() readiness$ready,
    after_input = function(eof) if (!eof) arm_stdin()
  )
} else {
  pieces <- strsplit(address, ":", fixed = TRUE)[[1]]
  listener <- serverSocket(as.integer(pieces[2]))
  socket <- socketAccept(listener, blocking = FALSE, open = "r+b")
  close(listener)
  on.exit(close(socket))
  run_adapter(socket, socket, input_ready = function() socketSelect(list(socket), timeout = 0)[[1L]])
}
