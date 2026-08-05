source("client/convex.R")

assert <- function(value, message) {
  if (!isTRUE(value)) stop(message, call. = FALSE)
}

next_port <- local({
  port <- 24000L + (Sys.getpid() %% 10000L)
  function() {
    port <<- port + 1L
    port
  }
})

http_fixture <- function(response, call) {
  port <- next_port()
  job <- parallel::mcparallel(
    {
      server <- socketConnection(
        host = "127.0.0.1",
        port = port,
        server = TRUE,
        blocking = TRUE,
        open = "r+b"
      )
      on.exit(close(server))
      request_line <- readLines(server, n = 1L, warn = FALSE)
      headers <- list()
      repeat {
        line <- readLines(server, n = 1L, warn = FALSE)
        line <- sub("\\r$", "", line)
        if (!length(line) || !nzchar(line)) break
        pieces <- strsplit(line, ":", fixed = TRUE)[[1L]]
        name <- tolower(pieces[1L])
        value <- trimws(paste(pieces[-1L], collapse = ":"))
        headers[[name]] <- value
      }
      content_length <- as.integer(headers[["content-length"]] %||% "0")
      body <- if (content_length) readChar(server, nchars = content_length, useBytes = TRUE) else ""
      encoded <- charToRaw(as.character(jsonlite::toJSON(response, auto_unbox = TRUE, null = "null")))
      header <- charToRaw(paste0(
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", length(encoded), "\r\n",
        "Connection: close\r\n\r\n"
      ))
      writeBin(c(header, encoded), server)
      flush(server)
      list(
        request_line = request_line,
        headers = headers,
        raw_body = body,
        body = jsonlite::fromJSON(body, simplifyVector = FALSE)
      )
    },
    silent = TRUE
  )
  Sys.sleep(0.08)
  value <- call(sprintf("http://127.0.0.1:%d", port))
  request <- parallel::mccollect(job, wait = TRUE)[[1L]]
  list(value = value, request = request)
}

fixture <- http_fixture(
  list(status = "success", value = list(nested = list(works = TRUE)), logLines = list("[LOG] demo:echo")),
  function(url) convex_client(url, bearer_token = "opaque token")$query("demo:echo", list(nested = list(works = TRUE)))
)
assert(isTRUE(fixture$value$value$nested$works), "HTTP query lost nested JSON")
assert(identical(fixture$value$logs, "[LOG] demo:echo"), "HTTP query lost logs")
assert(fixture$request$request_line == "POST /api/query HTTP/1.1", "query used the wrong HTTP path")
assert(fixture$request$body$format == "json", "query omitted the JSON format")
assert(fixture$request$headers$authorization == "Bearer opaque token", "query lost the bearer token")
assert(fixture$request$headers[["convex-client"]] == "r-0.1.0", "query lost the client version")

fixture <- http_fixture(
  list(status = "error", errorMessage = "expected failure", errorData = list(code = "EXPECTED"), logLines = list("before failure")),
  function(url) tryCatch(convex_client(url)$query("demo:fail", list(code = "EXPECTED")), error = identity)
)
assert(inherits(fixture$value, "convex_function_error"), "function failure was not typed")
assert(fixture$value$data$code == "EXPECTED", "function failure lost errorData")
assert(identical(fixture$value$logs, "before failure"), "function failure lost logs")

fixture <- http_fixture(
  list(status = "success", value = NULL, logLines = list()),
  function(url) convex_client(url)$action("demo:null", list())
)
assert(is.null(fixture$value$value), "successful null value was rejected")
assert(grepl('"args":\\{\\}', fixture$request$raw_body), "empty args were encoded as an array")

assert(inherits(tryCatch(convex_client("ftp://example.com"), error = identity), "convex_protocol_error"), "invalid URL was accepted")
client <- convex_client("http://127.0.0.1:1")
assert(inherits(tryCatch(client$query("demo:echo", list("unnamed")), error = identity), "convex_protocol_error"), "array arguments were accepted")
client$close()
assert(inherits(tryCatch(client$query("demo:state", list()), error = identity), "convex_closed"), "closed client accepted a call")
cat("PASS R HTTP client fixtures\n")
