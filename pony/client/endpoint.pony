// Parsing of the Convex deployment URL.
//
// The URL is the one piece of configuration every operation depends on, so it
// is validated once, up front, into a value that already knows the host header
// to send, the TCP service to connect to, and whether TLS is required. Nothing
// below this line has to re-derive any of that, and a malformed URL fails at
// construction rather than at the first request.

primitive ConvexLimits
  """
  Byte budgets shared by the HTTP and Live layers.

  These are deliberately conservative. The shared conformance harness caps an
  adapter process at 128 MiB, and Convex payloads in this demonstration are
  kilobytes, so a request or frame that approaches these numbers is a fault
  rather than a large legitimate value.
  """

  fun max_request_bytes(): USize => 2 * 1024 * 1024
  fun max_response_bytes(): USize => 2 * 1024 * 1024
  fun max_header_bytes(): USize => 16 * 1024
  fun max_header_count(): USize => 64
  fun max_status_line_bytes(): USize => 512
  fun max_websocket_frame_bytes(): USize => 1024 * 1024
  fun max_websocket_message_bytes(): USize => 2 * 1024 * 1024

class val ConvexEndpoint
  """
  A parsed `http://` or `https://` Convex deployment URL.
  """

  let secure: Bool
  let host: String
  let service: String
  let authority: String
  let prefix: String

  new val create(url: String) ? =>
    """
    Accepts `scheme://host[:port][/prefix]` and rejects everything else.

    Query strings, fragments, and embedded credentials are rejected rather than
    ignored: silently dropping a credential a caller believed was being sent
    would be worse than refusing the URL.
    """
    var position: USize = 0
    if Bytes.starts_with(url, "https://") then
      secure = true
      position = 8
    elseif Bytes.starts_with(url, "http://") then
      secure = false
      position = 7
    else
      error
    end

    var authority_end = url.size()
    var index = position
    while index < url.size() do
      let byte = url(index)?
      if byte == '/' then
        authority_end = index
        break
      elseif (byte == '?') or (byte == '#') then
        error
      elseif byte == '@' then
        // Userinfo in a deployment URL is always a mistake here.
        error
      end
      index = index + 1
    end

    var host_end = authority_end
    var port: String = ""
    index = position
    while index < authority_end do
      if url(index)? == ':' then
        host_end = index
        var port_index = index + 1
        var digits: String iso = String(5)
        while port_index < authority_end do
          let byte = url(port_index)?
          if (byte < '0') or (byte > '9') then error end
          digits.push(byte)
          port_index = port_index + 1
        end
        port = consume digits
        break
      end
      index = index + 1
    end
    if host_end <= position then error end

    var host_text: String iso = String(host_end - position)
    index = position
    while index < host_end do
      let byte = url(index)?
      // A host that could smuggle a header terminator or an extra header must
      // never reach the request writer.
      if (byte <= 0x20) or (byte >= 0x7f) then error end
      host_text.push(byte)
      index = index + 1
    end
    host = consume host_text

    if port.size() > 0 then
      if port.size() > 5 then error end
      service = port
      authority = host + ":" + port
    else
      service = if secure then "443" else "80" end
      // The default port is omitted from the Host header, which is what every
      // server expects and what keeps virtual hosting working.
      authority = host
    end

    var prefix_text: String iso = String(url.size() - authority_end)
    index = authority_end
    while index < url.size() do
      let byte = url(index)?
      if (byte <= 0x20) or (byte >= 0x7f) then error end
      prefix_text.push(byte)
      index = index + 1
    end
    // A trailing slash would produce `//api/query`, which some proxies reject.
    while (prefix_text.size() > 0) and
      (try prefix_text(prefix_text.size() - 1)? == '/' else false end)
    do
      prefix_text.truncate(prefix_text.size() - 1)
    end
    prefix = consume prefix_text

  fun function_path(operation: String): String =>
    prefix + "/api/" + operation

  fun sync_path(): String =>
    prefix + "/api/sync"

class val ConvexConfig
  """
  Everything a client needs that is not a per-call argument.
  """

  let endpoint: ConvexEndpoint
  let client_version: String
  let auth_token: String

  new val create(
    endpoint': ConvexEndpoint,
    client_version': String = "pony-0.1.0",
    auth_token': String = "")
  =>
    endpoint = endpoint'
    client_version = client_version'
    auth_token = auth_token'

  fun with_auth(token: String): ConvexConfig =>
    ConvexConfig(endpoint, client_version, token)
