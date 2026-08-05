source("client/convex.R")
source("client/live.R")

assert <- function(value, message) {
  if (!isTRUE(value)) stop(message, call. = FALSE)
}

next_port <- local({
  port <- 34000L + (Sys.getpid() %% 10000L)
  function() {
    port <<- port + 1L
    port
  }
})

websocket_accept <- function(key) {
  guid <- "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  hash <- digest::digest(charToRaw(paste0(key, guid)), algo = "sha1", serialize = FALSE, raw = TRUE)
  jsonlite::base64_enc(hash)
}

server_frame <- function(opcode, payload, final = TRUE) {
  payload <- if (is.raw(payload)) payload else charToRaw(enc2utf8(payload))
  first <- bitwOr(if (final) 0x80L else 0L, opcode)
  size <- length(payload)
  if (size < 126L) {
    header <- as.raw(c(first, size))
  } else {
    header <- as.raw(c(first, 126L, bitwShiftR(size, 8L), bitwAnd(size, 0xffL)))
  }
  c(header, payload)
}

accept_websocket <- function(port) {
  socket <- socketConnection(
    host = "127.0.0.1",
    port = port,
    server = TRUE,
    blocking = TRUE,
    open = "r+b"
  )
  finish_websocket_handshake(socket)
}

finish_websocket_handshake <- function(socket) {
  request <- readLines(socket, n = 1L, warn = FALSE)
  headers <- list()
  repeat {
    line <- sub("\\r$", "", readLines(socket, n = 1L, warn = FALSE))
    if (!length(line) || !nzchar(line)) break
    pieces <- strsplit(line, ":", fixed = TRUE)[[1L]]
    headers[[tolower(pieces[1L])]] <- trimws(paste(pieces[-1L], collapse = ":"))
  }
  stopifnot(grepl("^GET /api/sync HTTP/1.1", request))
  response <- paste0(
    "HTTP/1.1 101 Switching Protocols\r\n",
    "Upgrade: websocket\r\n",
    "Connection: Upgrade\r\n",
    "Sec-WebSocket-Accept: ", websocket_accept(headers[["sec-websocket-key"]]), "\r\n\r\n"
  )
  writeBin(charToRaw(response), socket)
  flush(socket)
  socket
}

read_exact <- function(socket, size) {
  value <- raw()
  while (length(value) < size) {
    chunk <- readBin(socket, "raw", n = size - length(value))
    if (!length(chunk)) stop("WebSocket peer closed mid-frame")
    value <- c(value, chunk)
  }
  value
}

read_client_frame <- function(socket) {
  header <- as.integer(read_exact(socket, 2L))
  size <- bitwAnd(header[2L], 0x7fL)
  if (size == 126L) {
    extended <- as.integer(read_exact(socket, 2L))
    size <- extended[1L] * 256L + extended[2L]
  } else if (size == 127L) {
    extended <- as.integer(read_exact(socket, 8L))
    if (any(extended[1:4] != 0L)) stop("fixture frame is too large")
    size <- sum(extended[5:8] * c(16777216, 65536, 256, 1))
  }
  masked <- bitwAnd(header[2L], 0x80L) != 0L
  mask <- if (masked) as.integer(read_exact(socket, 4L)) else integer()
  payload <- read_exact(socket, size)
  if (masked && size) {
    payload <- as.raw(bitwXor(as.integer(payload), mask[(seq_len(size) - 1L) %% 4L + 1L]))
  }
  list(opcode = bitwAnd(header[1L], 0x0fL), payload = payload)
}

read_client_json <- function(socket) {
  repeat {
    frame <- read_client_frame(socket)
    if (frame$opcode == 0x1L) {
      return(jsonlite::fromJSON(rawToChar(frame$payload), simplifyVector = FALSE))
    }
  }
}

port <- next_port()
job <- parallel::mcparallel(
  {
    socket <- accept_websocket(port)
    on.exit(close(socket))
    payload <- charToRaw(as.character(convex_json(list(
      type = "Transition",
      startVersion = list(querySet = 0L, identity = 0L, ts = "AAAAAAAAAAA="),
      endVersion = list(querySet = 1L, identity = 0L, ts = "AQAAAAAAAAA="),
      modifications = list(list(
        type = "QueryUpdated",
        queryId = 0L,
        value = list(text = "fragmented 🟨🟩🟦"),
        logLines = list()
      ))
    ))))
    emoji_start <- grepRaw(charToRaw("🟨"), payload, fixed = TRUE)[1L]
    split_at <- emoji_start + 1L
    writeBin(server_frame(0x1L, payload[seq_len(split_at)], final = FALSE), socket)
    # A control frame between fragments proves that transport parsing preserves
    # the message boundary while handling ping/pong.
    writeBin(server_frame(0x9L, charToRaw("ping"), final = TRUE), socket)
    writeBin(server_frame(0x0L, payload[(split_at + 1L):length(payload)], final = TRUE), socket)
    flush(socket)
    Sys.sleep(0.5)
    TRUE
  },
  silent = TRUE
)
Sys.sleep(0.08)
manager <- convex_live(sprintf("http://127.0.0.1:%d", port), "r-websocket-test")
subscription <- manager$subscribe("demo:echo", list())
update <- subscription$next_update(2)
assert(update$value$text == "fragmented 🟨🟩🟦", "fragmented UTF-8 WebSocket message was corrupted")
manager$close()
invisible(suppressWarnings(parallel::mccollect(job, wait = TRUE)))

# Drive five reconnects through six actual TCP/WebSocket handshakes. The peer
# records every Connect and Add, rehydrates with an unchanged value, then sends
# the changed value that should be the only post-disconnect delivery.
port <- next_port()
job <- parallel::mcparallel(
  {
    server <- serverSocket(port)
    on.exit(close(server))
    records <- list()
    for (connection_index in 0:5) {
      socket <- socketAccept(server, blocking = TRUE, open = "r+b")
      socket <- finish_websocket_handshake(socket)
      connect <- read_client_json(socket)
      add <- read_client_json(socket)
      records[[connection_index + 1L]] <- list(connect = connect, add = add)
      start <- list(querySet = 0L, identity = 0L, ts = "AAAAAAAAAAA=")
      hydrated <- list(querySet = 1L, identity = 0L, ts = paste0("real-hydrate-", connection_index))
      hydrated_count <- max(0L, connection_index - 1L)
      writeBin(server_frame(0x1L, as.character(convex_json(list(
        type = "Transition",
        startVersion = start,
        endVersion = hydrated,
        modifications = list(list(type = "QueryUpdated", queryId = 0L, value = list(count = hydrated_count), logLines = list()))
      )))), socket)
      if (connection_index > 0L) {
        changed <- list(querySet = 1L, identity = 0L, ts = paste0("real-change-", connection_index))
        writeBin(server_frame(0x1L, as.character(convex_json(list(
          type = "Transition",
          startVersion = hydrated,
          endVersion = changed,
          modifications = list(list(type = "QueryUpdated", queryId = 0L, value = list(count = connection_index), logLines = list()))
        )))), socket)
      }
      flush(socket)
      repeat {
        frame <- read_client_frame(socket)
        if (frame$opcode == 0x8L) break
      }
      writeBin(server_frame(0x8L, raw()), socket)
      flush(socket)
      close(socket)
    }
    records
  },
  silent = TRUE
)
Sys.sleep(0.08)
manager <- convex_live(sprintf("http://127.0.0.1:%d", port), "r-real-reconnect-test")
subscription <- manager$subscribe("demo:state", list(room = "real-reconnect"))
assert(subscription$next_update(2)$value$count == 0L, "real reconnect fixture lost the initial value")
for (attempt in 1:5) {
  manager$debug_disconnect()
  assert(subscription$next_update(2)$value$count == attempt, "real reconnect relayed hydration or lost the changed value")
}
manager$close()
records <- parallel::mccollect(job, wait = TRUE)[[1L]]
assert(length(records) == 6L, "real reconnect fixture did not open six sockets")
for (connection_index in 0:5) {
  record <- records[[connection_index + 1L]]
  assert(record$connect$type == "Connect", "real reconnect did not send Connect first")
  assert(record$connect$connectionCount == connection_index, "real reconnect lost connectionCount")
  assert(record$add$modifications[[1L]]$type == "Add", "real reconnect did not resend the active Add")
}

# Unsubscribe and close must also remain bounded while the peer continuously
# sends control frames. The library owns frame parsing, while this client keeps
# both operations nonblocking and invalidates delivery before touching I/O.
port <- next_port()
job <- parallel::mcparallel(
  {
    socket <- accept_websocket(port)
    on.exit(close(socket))
    tryCatch(
      repeat {
        writeBin(server_frame(0x9L, charToRaw("busy"), final = TRUE), socket)
        flush(socket)
        Sys.sleep(0.001)
      },
      error = function(error) invisible(NULL)
    )
    TRUE
  },
  silent = TRUE
)
Sys.sleep(0.08)
manager <- convex_live(sprintf("http://127.0.0.1:%d", port), "r-websocket-test")
subscription <- manager$subscribe("demo:state", list(room = "busy-peer"))
manager$pump(0.1)
started <- proc.time()[["elapsed"]]
subscription$close()
assert(proc.time()[["elapsed"]] - started < 0.5, "unsubscribe blocked on a continuously sending peer")
started <- proc.time()[["elapsed"]]
manager$close()
assert(proc.time()[["elapsed"]] - started < 0.5, "close blocked on a continuously sending peer")
tools::pskill(job$pid, tools::SIGTERM)
invisible(suppressWarnings(parallel::mccollect(job, wait = TRUE)))

# Once a partial frame has been consumed, close must not wait for the stalled
# peer or attempt to resume at a false frame boundary.
port <- next_port()
job <- parallel::mcparallel(
  {
    socket <- accept_websocket(port)
    on.exit(close(socket))
    writeBin(as.raw(c(0x81L, 126L, 1L, 0L, 0x7bL)), socket)
    flush(socket)
    Sys.sleep(5)
    TRUE
  },
  silent = TRUE
)
Sys.sleep(0.08)
manager <- convex_live(sprintf("http://127.0.0.1:%d", port), "r-websocket-test")
subscription <- manager$subscribe("demo:state", list(room = "partial-frame"))
manager$pump(0.1)
started <- proc.time()[["elapsed"]]
manager$close()
assert(proc.time()[["elapsed"]] - started < 0.5, "close blocked on a partial WebSocket frame")
tools::pskill(job$pid, tools::SIGTERM)
invisible(suppressWarnings(parallel::mccollect(job, wait = TRUE)))
cat("PASS R WebSocket fragmentation and bounded-close fixtures\n")
