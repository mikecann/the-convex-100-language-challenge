definition module Convex.HTTP

// A small hand-written HTTP/1.1 client, just capable enough for Convex's
// documented JSON `/api/query`, `/api/mutation`, and `/api/action`
// endpoints (and, later, the WebSocket upgrade handshake `/api/sync`
// needs). Clean's distribution ships no HTTP client of its own reachable
// over this project's hand-rolled transport (`Convex.Transport`), so
// request framing, status-line and header parsing, and both
// Content-Length and chunked body decoding are implemented here, matching
// this project's other native clients (see `hare/client/http.ha`).

from Convex.Result import :: Result
from Convex.Transport import :: Transport
from Convex.Deadline import :: Deadline
from Convex.Wire import :: JSON
from StdMaybe import :: Maybe

:: Endpoint =
	{ epTls :: !Bool
	, epHost :: !String
	, epPort :: !Int
	// The URL's own path with any trailing slash trimmed, so appending
	// "/api/query" never doubles a separator. Convex deployment URLs
	// ordinarily have none; a self-hosted deployment mounted under a path
	// prefix keeps working too.
	, epBasePath :: !String
	}

// Parses a Convex deployment URL ("https://foo.convex.cloud",
// "http://127.0.0.1:3210") into its connection parameters. Only `http` and
// `https` are accepted; `ws`/`wss` reuse the same connection logic once the
// Live layer exists but are spelled as `http`/`https` by every caller in
// this client, matching this project's other native clients.
parseEndpoint :: !String -> Maybe Endpoint

// One Convex query/mutation/action's outcome. `crFailure` distinguishes a
// function that ran and threw (`crValue` is `JNull`, `crFailure` carries the
// server's message and optional structured `data`) from one that returned
// normally.
:: CallResult =
	{ crValue :: !JSON
	, crLogs :: !JSON
	, crFailure :: !Maybe (!String, !Maybe JSON)
	}

// Connects, sends one `path`/`args` call as `operation` ("query", "mutation",
// or "action"), and decodes the response. `authToken`, when present, is sent
// as `Authorization: Bearer <token>`. The connection is always closed
// afterward: Convex query/mutation/action calls are infrequent enough that
// reconnecting per call is simpler than pooling, matching this project's
// other native clients.
httpCall :: !Endpoint !(Maybe String) !String !String !JSON !Deadline !*World -> (!Result CallResult, !*World)

// --- shared with Convex.WebSocket -----------------------------------------
//
// The WebSocket upgrade handshake is still an HTTP/1.1 request/response, so
// Convex.WebSocket reuses this module's own header reading and lookup
// helpers rather than duplicating them.

// Searches `hay` for `needle`, starting the search at or after `start`.
findSubstrFrom :: !String !String !Int -> Maybe Int

trimStr :: !String -> String

// Looks up one header's value, case-insensitively, from header text shaped
// like `readHeaders`'s own first result (status line plus each header line,
// separated by bare "\r\n", none trailing the last one).
headerValue :: !String !String -> Maybe String

parseStatusLine :: !String -> Maybe Int

// Reads until the blank-line header terminator is seen, returning the
// header text and whatever body (or, for a WebSocket upgrade, first frame)
// bytes were already read past it.
readHeaders :: !Transport !String !Deadline !*World -> (!Result (!String, !String), !*World)
