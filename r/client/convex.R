# Convex's protocol glue lives in R. The imported packages only provide normal
# HTTP/TLS, JSON, and WebSocket primitives; they do not know Convex.
convex_error <- function(class, message, operation = NULL, data = NULL, logs = character()) {
  structure(list(message = message, operation = operation, data = data, logs = logs), class = c(class, "convex_error", "error", "condition"))
}

convex_stop <- function(class, message, operation = NULL, data = NULL, logs = character()) stop(convex_error(class, message, operation, data, logs))

convex_result <- function(value, logs = character()) structure(list(value = value, logs = logs), class = "convex_result")

convex_client <- function(url, bearer_token = "", client_version = "r-0.1.0") {
  stopifnot(is.character(url), length(url) == 1L, nzchar(url))
  state <- new.env(parent = emptyenv())
  state$url <- sub("/+$", "", url)
  state$token <- bearer_token
  state$version <- client_version
  state$closed <- FALSE
  state$live <- NULL

  request <- function(operation, path, args = list()) {
    if (state$closed) convex_stop("convex_closed", "Convex client is closed")
    if (!is.character(path) || length(path) != 1L || !nzchar(path) || !is.list(args)) convex_stop("convex_protocol_error", "path and args must be a named JSON object", operation)
    endpoint <- paste0(state$url, "/api/", operation)
    headers <- c("Content-Type" = "application/json", "Accept" = "application/json", "Convex-Client" = state$version)
    if (nzchar(state$token)) headers <- c(headers, "Authorization" = paste("Bearer", state$token))
    response <- tryCatch(curl::curl_fetch_memory(endpoint, handle = curl::new_handle(postfields = jsonlite::toJSON(list(path = path, args = args, format = "json"), auto_unbox = TRUE, null = "null"), httpheader = headers, connecttimeout = 10, timeout = 30)), error = function(e) convex_stop("convex_transport_error", conditionMessage(e), operation))
    if (length(response$content) > 8 * 1024 * 1024) convex_stop("convex_transport_error", "response exceeds 8 MiB", operation)
    decoded <- tryCatch(jsonlite::fromJSON(rawToChar(response$content), simplifyVector = FALSE), error = function(e) convex_stop("convex_transport_error", paste("invalid Convex JSON:", conditionMessage(e)), operation))
    if (identical(decoded$status, "success") && !is.null(decoded$value)) return(convex_result(decoded$value, decoded$logLines %||% character()))
    if (identical(decoded$status, "error")) convex_stop("convex_function_error", decoded$errorMessage %||% "Convex function failed", operation, decoded$errorData, decoded$logLines %||% character())
    convex_stop("convex_protocol_error", sprintf("unexpected HTTP status %s", decoded$status %||% "<missing>"), operation)
  }
  list(query = function(path, args = list()) request("query", path, args), mutation = function(path, args = list()) request("mutation", path, args), action = function(path, args = list()) request("action", path, args), set_auth = function(token) { state$token <- token; invisible(NULL) }, subscribe = function(path, args = list()) { if (is.null(state$live)) state$live <- convex_live(state$url, state$version); state$live$subscribe(path, args) }, debug_disconnect_for_adapter = function() { if (is.null(state$live)) convex_stop("convex_transport_error", "Live WebSocket is not connected", "live"); state$live$debug_disconnect() }, close = function() { state$closed <- TRUE; if (!is.null(state$live)) state$live$close(); invisible(NULL) })
}

`%||%` <- function(x, y) if (is.null(x)) y else x
