// A native Convex client for Pike.
//
// This file is the whole client: compiling it yields an object that exposes
// every class and helper below. Pike's Standards.JSON, Stdio, SSL, MIME, and
// Crypto modules supply ordinary JSON, sockets, TLS, base64, and SHA-1 only.
// Convex's request envelopes, response classification, RFC 6455 framing, and
// the pinned Live sync state machine are all implemented here in Pike.
//
// The parts are separate files for readability and are textually included, so
// consumers compile exactly one program:
//
//   object convex = compile_file("client/convex.pike")();
//   object client = convex->Client("https://example.convex.cloud");
//
// This is an educational demonstration, not an official or supported SDK.

#include "errors.pike"
#include "json.pike"
#include "stream.pike"
#include "http.pike"
#include "websocket.pike"
#include "live.pike"

// Sent as the Convex-Client header on both HTTP calls and the Live upgrade, so
// a deployment's logs can attribute traffic to this demonstration.
constant CLIENT_VERSION = "pike-0.1.0";

// Convex addresses a function as "file:export", optionally under a directory.
// Reject anything else before it reaches the deployment: a malformed path is a
// caller mistake, not a Convex failure.
string require_function_path(string path, string operation)
{
  if (!stringp(path) || sizeof(path) < 3)
    throw(protocol_error("a Convex function path is required", operation));
  if (search(path, ":") < 1)
    throw(protocol_error("a Convex function path must name file:export",
                         operation));
  foreach ((array(int))path, int character)
    if (character <= 32 || character == 127)
      throw(protocol_error("a Convex function path must not contain whitespace",
                           operation));
  return path;
}

class Client
{
  string deployment_url;
  mapping target;
  HttpTransport transport;
  string bearer_token = "";
  string client_version = CLIENT_VERSION;
  LiveOwner live;
  function(mapping:Channel) channel_factory;
  int closed;

  // options may carry "auth_token", "client_version", "transport" (an
  // HttpTransport for tests), and "channel_factory" (a Channel factory the Live
  // owner uses instead of a real socket).
  protected void create(string url, void|mapping options)
  {
    mapping settings = options || ([]);
    target = parse_url(url, "client");
    if (target->scheme != "http" && target->scheme != "https")
      throw(protocol_error("a Convex deployment URL must be http or https",
                           "client"));
    // Keep the exact base the caller gave, minus any trailing slash, so the
    // /api paths below are appended once and only once.
    string path = target->path;
    while (sizeof(path) > 1 && path[-1] == '/')
      path = path[..sizeof(path) - 2];
    if (path == "/")
      path = "";
    target->path = path;
    deployment_url = sprintf("%s://%s%s", target->scheme, target->authority,
                             path);
    if (settings->client_version)
      client_version = settings->client_version;
    bearer_token = settings->auth_token || "";
    transport = settings->transport || SocketHttpTransport();
    channel_factory = settings->channel_factory;
  }

  // Convex authenticates with a bearer token. An empty token clears it, which
  // is how the conformance suite proves a replaced and then removed identity.
  void set_auth(string token)
  {
    if (closed)
      throw(closed_error("Convex client is closed", "client"));
    bearer_token = token || "";
  }

  CallResult query(string path, void|mapping args)
  {
    return call("query", path, args);
  }

  CallResult mutation(string path, void|mapping args)
  {
    return call("mutation", path, args);
  }

  CallResult action(string path, void|mapping args)
  {
    return call("action", path, args);
  }

  CallResult call(string operation, string path, void|mapping args)
  {
    if (closed)
      throw(closed_error("Convex client is closed", operation));
    if (operation != "query" && operation != "mutation" &&
        operation != "action")
      throw(protocol_error("unknown Convex operation " + operation, operation));
    require_function_path(path, operation);
    mapping arguments = args || ([]);
    require_object(arguments, "Convex arguments", operation);

    // Convex's documented JSON HTTP API: one POST per call, carrying the
    // function path, its named arguments, and the JSON value format.
    string body = json_bytes(([
      "path": path,
      "args": arguments,
      "format": "json",
    ]));
    mapping(string:string) headers = ([
      "accept": "application/json",
      "content-type": "application/json",
      "convex-client": client_version,
    ]);
    if (sizeof(bearer_token))
      headers->authorization = "Bearer " + bearer_token;

    HttpResponse response = transport->request(
      target, "POST", target->path + "/api/" + operation, headers, body,
      deadline_in(HTTP_REQUEST_TIMEOUT_MS), operation);
    return decode_envelope(response, operation);
  }

  LiveOwner live_owner()
  {
    if (closed)
      throw(closed_error("Convex client is closed", "live"));
    if (!live)
      live = LiveOwner(deployment_url, client_version, channel_factory);
    return live;
  }

  Subscription subscribe(string path, void|mapping args)
  {
    require_function_path(path, "live");
    mapping arguments = args || ([]);
    require_object(arguments, "Convex arguments", "live");
    return live_owner()->subscribe(path, arguments);
  }

  // Adapter-only hook, documented in manifest.yaml. It is deliberately not part
  // of the educational API a reader would use.
  void debug_disconnect_for_adapter()
  {
    if (!live)
      throw(transport_error("Live WebSocket is not connected", "live"));
    live->debug_disconnect();
  }

  // Let the Live owner run its reconnect timers and frame deadlines. Callers
  // that only use HTTP never need it.
  void poll()
  {
    if (live)
      live->poll();
  }

  void close()
  {
    if (closed)
      return;
    closed = 1;
    if (live)
      live->close();
    live = 0;
  }
}
