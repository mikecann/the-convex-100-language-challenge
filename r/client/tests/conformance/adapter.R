#!/usr/local/bin/Rscript
source(file.path(Sys.getenv("CONVEX_CLIENT_PATH", "/opt/convex/client"), "convex.R"))
source(file.path(Sys.getenv("CONVEX_CLIENT_PATH", "/opt/convex/client"), "live.R"))

write_event <- function(io, event) { writeLines(jsonlite::toJSON(event, auto_unbox = TRUE, null = "null"), io); flush(io) }
error_event <- function(id, error, subscription_id = NULL) { event <- list(type = if (is.null(subscription_id)) "error" else "subscription", error = list(name = class(error)[1], message = conditionMessage(error))); if (!is.null(id)) event$id <- id; if (!is.null(subscription_id)) event$subscriptionId <- subscription_id; event }
run_adapter <- function(input, output) {
  client <- NULL; subscriptions <- list()
  ensure_client <- function() { if (is.null(client)) client <<- convex_client(Sys.getenv("CONVEX_URL")); client }
  repeat {
    line <- readLines(input, n = 1L, warn = FALSE); if (!length(line)) break
    command <- tryCatch(jsonlite::fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(command)) { write_event(output, error_event(NULL, convex_error("convex_protocol_error", "invalid NDJSON"))); next }
    id <- command$id
    tryCatch({
      if (identical(command$op, "hello")) write_event(output, list(protocolVersion = 1, id = id, type = "ready", language = "r", implementation = paste0("native-r-", getRversion()), runtime = paste0("R-", getRversion())))
      else if (command$op %in% c("query", "mutation", "action")) { result <- do.call(ensure_client()[[command$op]], list(command$path, command$args %||% list())); write_event(output, list(id = id, type = "result", value = result$value, logs = result$logs)) }
      else if (identical(command$op, "setAuth")) { ensure_client()$set_auth(command$token); write_event(output, list(id = id, type = "ack")) }
      else if (identical(command$op, "subscribe")) { subscriptions[[command$subscriptionId]] <- ensure_client()$subscribe(command$path, command$args %||% list()); write_event(output, list(id = id, type = "ack")) }
      else if (identical(command$op, "unsubscribe")) { subscriptions[[command$subscriptionId]]$close(); subscriptions[[command$subscriptionId]] <- NULL; write_event(output, list(id = id, type = "ack")) }
      else if (identical(command$op, "debugDisconnect")) { ensure_client()$debug_disconnect_for_adapter(); write_event(output, list(id = id, type = "ack")) }
      else if (identical(command$op, "close")) { lapply(subscriptions, function(subscription) subscription$close()); if (!is.null(client)) client$close(); write_event(output, list(id = id, type = "closed")); return(invisible(NULL)) }
      else convex_stop("convex_protocol_error", "unknown adapter operation")
    }, error = function(e) write_event(output, error_event(id, e)))
  }
}
address <- Sys.getenv("ADAPTER_LISTEN", "")
if (!nzchar(address)) run_adapter(stdin(), stdout()) else { pieces <- strsplit(address, ":", fixed = TRUE)[[1]]; socket <- socketConnection(host = pieces[1], port = as.integer(pieces[2]), server = TRUE, blocking = TRUE, open = "r+"); on.exit(close(socket)); run_adapter(socket, socket) }
