# Convex's protocol glue lives in R. The imported packages only provide normal
# HTTP/TLS, JSON, and WebSocket primitives; they do not know Convex.

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

convex_error <- function(class, message, operation = NULL, data = NULL, logs = character()) {
  structure(
    list(
      message = message,
      call = NULL,
      operation = operation,
      data = data,
      logs = logs
    ),
    class = c(class, "convex_error", "error", "condition")
  )
}

convex_stop <- function(class, message, operation = NULL, data = NULL, logs = character()) {
  stop(convex_error(class, message, operation, data, logs))
}

convex_result <- function(value, logs = character()) {
  structure(list(value = value, logs = logs), class = "convex_result")
}

convex_named_object <- function(value) {
  if (!length(value)) names(value) <- character()
  value
}

convex_validate_args <- function(path, args) {
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) {
    convex_stop("convex_protocol_error", "Convex function path is required")
  }
  if (!is.list(args) || (length(args) && (is.null(names(args)) || any(!nzchar(names(args)))))) {
    convex_stop("convex_protocol_error", "Convex arguments must be a named JSON object")
  }
  tryCatch(
    jsonlite::toJSON(args, auto_unbox = TRUE, null = "null"),
    error = function(error) convex_stop("convex_protocol_error", paste("encode Convex arguments:", conditionMessage(error)))
  )
  invisible(NULL)
}

convex_client <- function(url, bearer_token = "", client_version = "r-0.1.0") {
  if (!is.character(url) || length(url) != 1L || !grepl("^https?://[^/]+", url)) {
    convex_stop("convex_protocol_error", "Convex deployment URL must use http or https")
  }
  state <- new.env(parent = emptyenv())
  state$url <- sub("/+$", "", url)
  state$token <- bearer_token
  state$version <- client_version
  state$closed <- FALSE
  state$live <- NULL

  request <- function(operation, path, args = list()) {
    if (state$closed) convex_stop("convex_closed", "Convex client is closed")
    if (!(operation %in% c("query", "mutation", "action"))) convex_stop("convex_protocol_error", paste("unknown Convex operation", operation))
    convex_validate_args(path, args)

    endpoint <- paste0(state$url, "/api/", operation)
    headers <- c(
      "Content-Type" = "application/json",
      "Accept" = "application/json",
      "Convex-Client" = state$version
    )
    if (nzchar(state$token)) headers <- c(headers, "Authorization" = paste("Bearer", state$token))
    body <- jsonlite::toJSON(
      list(path = path, args = convex_named_object(args), format = "json"),
      auto_unbox = TRUE,
      null = "null",
      digits = NA
    )
    handle <- curl::new_handle(
      postfields = body,
      connecttimeout = 10,
      timeout = 30
    )
    curl::handle_setheaders(handle, .list = headers)
    response <- tryCatch(
      curl::curl_fetch_memory(endpoint, handle = handle),
      error = function(error) convex_stop("convex_transport_error", conditionMessage(error), operation)
    )
    if (length(response$content) > 8L * 1024L * 1024L) {
      convex_stop("convex_transport_error", "response exceeds 8 MiB", operation)
    }
    decoded <- tryCatch(
      jsonlite::fromJSON(rawToChar(response$content), simplifyVector = FALSE),
      error = function(error) convex_stop("convex_transport_error", paste("invalid Convex JSON:", conditionMessage(error)), operation)
    )
    if (identical(decoded$status, "success") && "value" %in% names(decoded)) {
      return(convex_result(decoded$value, unlist(decoded$logLines %||% list(), use.names = FALSE)))
    }
    if (identical(decoded$status, "error")) {
      convex_stop(
        "convex_function_error",
        decoded$errorMessage %||% "Convex function failed",
        operation,
        decoded$errorData,
        unlist(decoded$logLines %||% list(), use.names = FALSE)
      )
    }
    convex_stop(
      "convex_protocol_error",
      sprintf("HTTP %s response has unexpected Convex status %s", response$status_code, decoded$status %||% "<missing>"),
      operation
    )
  }

  list(
    query = function(path, args = list()) request("query", path, args),
    mutation = function(path, args = list()) request("mutation", path, args),
    action = function(path, args = list()) request("action", path, args),
    set_auth = function(token) {
      state$token <- token
      invisible(NULL)
    },
    subscribe = function(path, args = list()) {
      convex_validate_args(path, args)
      if (state$closed) convex_stop("convex_closed", "Convex client is closed")
      if (is.null(state$live)) state$live <- convex_live(state$url, state$version)
      state$live$subscribe(path, args)
    },
    pump_live = function(timeout = 0) {
      if (!is.null(state$live)) state$live$pump(timeout)
      invisible(NULL)
    },
    debug_disconnect_for_adapter = function() {
      if (is.null(state$live)) convex_stop("convex_transport_error", "Live WebSocket is not connected", "live")
      state$live$debug_disconnect()
    },
    close = function() {
      if (state$closed) {
        return(invisible(NULL))
      }
      state$closed <- TRUE
      if (!is.null(state$live)) state$live$close()
      invisible(NULL)
    }
  )
}
