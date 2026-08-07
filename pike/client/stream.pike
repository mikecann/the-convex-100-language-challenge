// Byte transport for the native Pike Convex client.
//
// This fragment is textually included by convex.pike. It is the only place that
// touches sockets or TLS. Everything above it (HTTP framing, RFC 6455 framing,
// the Convex sync state machine, and the adapter) talks to the Channel
// interface below, which is why those layers can be exercised deterministically
// with in-process fakes and no network at all.
#ifndef CONVEX_STREAM_PIKE
#define CONVEX_STREAM_PIKE

// gethrtime() is Pike's high-resolution microsecond clock. Deadlines are
// absolute milliseconds on that clock so a slow step cannot silently extend the
// budget the way a per-operation timeout would.
int now_ms()
{
  return gethrtime() / 1000;
}

int deadline_in(int milliseconds)
{
  return now_ms() + milliseconds;
}

// Every bounded wait in this client funnels through here. One absolute deadline
// therefore covers DNS, the TCP connect, the TLS handshake, the HTTP or 101
// exchange, and frame reassembly, instead of each of those restarting a timer.
//
// Callbacks must never call back into this function: the Pike backend is not
// reentrant. The adapter and Live owner honour that by only recording work in
// their callbacks and doing the waiting from their main flow.
int pump_until(function ready, int deadline_ms)
{
  while (!ready()) {
    int remaining = deadline_ms - now_ms();
    if (remaining <= 0)
      return 0;
    // Cap each backend slice so a deadline is observed promptly even when the
    // peer is completely idle and no callback ever fires.
    Pike.DefaultBackend(min(remaining, 50) / 1000.0);
  }
  return 1;
}

constant DEFAULT_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
constant MAX_PENDING_OUTPUT_BYTES = 4 * 1024 * 1024;

// A deliberately small URL parser. Convex deployment URLs are absolute and
// simple, and hand-parsing them keeps the accepted shape explicit: no user
// information, no query string, and a scheme this client actually implements.
mapping parse_url(string url, void|string operation)
{
  array(string) schemes = ({ "https", "http", "wss", "ws" });
  string scheme;
  foreach (schemes, string candidate)
    if (has_prefix(url, candidate + "://")) {
      scheme = candidate;
      break;
    }
  if (!scheme)
    throw(protocol_error("URL must be absolute http, https, ws, or wss",
                         operation));

  string rest = url[sizeof(scheme) + 3..];
  int cut = sizeof(rest);
  foreach (({ "/", "?", "#" }), string terminator) {
    int found = search(rest, terminator);
    if (found >= 0 && found < cut)
      cut = found;
  }
  string authority = rest[..cut - 1];
  string path = rest[cut..];
  if (search(path, "?") >= 0 || search(path, "#") >= 0)
    throw(protocol_error("URL must not carry a query or fragment", operation));
  if (!sizeof(path))
    path = "/";
  if (search(authority, "@") >= 0)
    throw(protocol_error("URL must not embed user information", operation));
  if (!sizeof(authority))
    throw(protocol_error("URL must include a host", operation));

  string host;
  int port = (scheme == "https" || scheme == "wss") ? 443 : 80;
  if (has_prefix(authority, "[")) {
    // IPv6 literal. The bracketed form is the only way a colon inside the host
    // can be told apart from the port separator.
    int close_bracket = search(authority, "]");
    if (close_bracket < 0)
      throw(protocol_error("URL has an unterminated IPv6 host", operation));
    host = authority[1..close_bracket - 1];
    string tail = authority[close_bracket + 1..];
    if (sizeof(tail)) {
      if (!has_prefix(tail, ":"))
        throw(protocol_error("URL has a malformed port", operation));
      port = parse_port(tail[1..], operation);
    }
  } else {
    int colon = search(authority, ":");
    if (colon < 0) {
      host = authority;
    } else {
      host = authority[..colon - 1];
      port = parse_port(authority[colon + 1..], operation);
    }
  }
  if (!sizeof(host))
    throw(protocol_error("URL must include a host", operation));

  return ([
    "scheme": scheme,
    "host": host,
    "port": port,
    "path": path,
    "tls": (scheme == "https" || scheme == "wss"),
    // The Host header and TLS SNI both need the port back when it is not the
    // scheme's default, so keep the exact authority the caller supplied.
    "authority": authority,
  ]);
}

int parse_port(string text, void|string operation)
{
  if (!sizeof(text) || sizeof(text) > 5)
    throw(protocol_error("URL has a malformed port", operation));
  foreach (text / "", string digit)
    if (digit < "0" || digit > "9")
      throw(protocol_error("URL has a malformed port", operation));
  int port = (int)text;
  if (port < 1 || port > 65535)
    throw(protocol_error("URL port is out of range", operation));
  return port;
}

// Split a PEM bundle into DER certificates. Doing this here rather than through
// a helper module keeps the CA closure requirement explicit and lets a
// deterministic test prove the parser against a fixture bundle.
array(string) pem_certificates(string bundle)
{
  string begin = "-----BEGIN CERTIFICATE-----";
  string end = "-----END CERTIFICATE-----";
  array(string) certificates = ({});
  int cursor = 0;
  while (1) {
    int start = search(bundle, begin, cursor);
    if (start < 0)
      break;
    int body = start + sizeof(begin);
    int stop = search(bundle, end, body);
    if (stop < 0)
      break;
    string der = MIME.decode_base64(bundle[body..stop - 1]);
    if (sizeof(der))
      certificates += ({ der });
    cursor = stop + sizeof(end);
  }
  return certificates;
}

object cached_tls_context;

// The OS CA bundle is generated once and then frozen inside whatever image
// ships this client, so by the time that image actually runs, some of its
// legacy roots (long-lived cross-signing roots such as "Baltimore CyberTrust
// Root" are the common case) have already gone past their own notAfter, and a
// handful of older roots never carried a keyUsage/basicConstraints extension
// modern profiles expect. SSL.Context()->set_trusted_issuers() runs both
// checks -- chain self-verification, then "is this leaf actually allowed to
// sign other certificates" -- against every chain it is handed, and aborts
// installing the entire trust store the moment ONE chain fails either check.
// A single stale or underspecified root would otherwise silently take out
// every other, still-good root with it instead of just itself. Run the exact
// same two checks up front, per candidate and isolated from the others, so
// only the roots this build can actually use ever reach the trust store.
array(string) verifiable_authorities(array(string) authorities)
{
  array(string) usable = ({});
  foreach (authorities, string der) {
    int accepted = 0;
    mixed failure = catch {
      mapping result =
        Standards.X509.verify_certificate_chain(({ der }), ([]), 0);
      if (result->verified) {
        object cert = result->certificates[-1];
        accepted = cert->ext_basicConstraints_cA &&
          (cert->ext_keyUsage & Standards.X509.KU_keyCertSign);
      }
    };
    // A certificate this build cannot even decode is exactly as unusable as
    // one that fails either check outright; either way it is left out.
    if (accepted)
      usable += ({ der });
  }
  return usable;
}

// Pike spells "trust exactly these DER certificate authorities" differently
// across releases. Probe the context's own identifiers instead of guessing, and
// refuse to open a TLS connection at all if no known spelling is present: an
// unverified HTTPS or WSS session would be worse than a clear failure.
void install_authorities(object context, array(string) authorities)
{
  array(string) members = indices(context);
  array(array(string)) chains = ({});
  foreach (authorities, string der)
    chains += ({ ({ der }) });

  if (search(members, "set_trusted_issuers") >= 0) {
    context->set_trusted_issuers(chains);
  } else if (search(members, "add_trusted_issuer") >= 0) {
    foreach (chains, array(string) chain)
      context->add_trusted_issuer(chain);
  } else if (search(members, "trusted_issuers") >= 0) {
    context->trusted_issuers = chains;
  } else if (search(members, "set_authorities") >= 0) {
    context->set_authorities(authorities);
  } else {
    throw(transport_error(
      "this Pike build exposes no known SSL.Context trust store API", "tls"));
  }

  // Ask for the strictest peer authentication the build offers. The constant is
  // resolved at runtime so an older SSL module cannot turn a hardening step
  // into a compile failure for the whole client.
  if (search(members, "auth_level") >= 0) {
    mixed required;
    catch { required = master()->resolv("SSL.Constants")->AUTHLEVEL_require; };
    if (intp(required))
      context->auth_level = required;
  }
}

object tls_context(void|string bundle_path)
{
  if (cached_tls_context)
    return cached_tls_context;
  string path = bundle_path || DEFAULT_CA_BUNDLE;
  string bundle = Stdio.read_file(path);
  if (!bundle)
    throw(transport_error("CA bundle " + path + " is not readable", "tls"));
  array(string) authorities = pem_certificates(bundle);
  if (!sizeof(authorities))
    throw(transport_error("CA bundle " + path + " contains no certificates",
                          "tls"));
  authorities = verifiable_authorities(authorities);
  if (!sizeof(authorities))
    throw(transport_error("CA bundle " + path +
                          " has no certificate this build can verify", "tls"));
  object context = SSL.Context();
  install_authorities(context, authorities);
  cached_tls_context = context;
  return context;
}

// The SSL.File members the socket channel below depends on, read from a real
// wrapped stream over a local pipe rather than from a socket. Nothing is
// negotiated: this only asks what this Pike build actually exposes, so a
// missing spelling fails a build or a language-local test instead of first
// appearing as a broken handshake against a hosted deployment.
array(string) tls_stream_members()
{
  Stdio.File local_end = Stdio.File();
  Stdio.File remote = local_end->pipe();
  if (!remote)
    throw(transport_error("could not open a pipe to inspect SSL.File", "tls"));
  array(string) members;
  mixed failed = catch {
    members = indices(SSL.File(local_end, SSL.Context()));
  };
  // Retire the raw descriptors rather than the wrapper. Closing the wrapper
  // would try to send a close_notify for a session that never started.
  catch { remote->close(); };
  catch { local_end->close(); };
  if (failed)
    throw(transport_error("SSL.File could not wrap a stream: " +
                          as_convex_error(failed)->message, "tls"));
  return members;
}

// The byte channel every protocol layer above sees. Implementations deliver
// inbound bytes by calling the data handler and announce a dead connection
// exactly once through the close handler.
class Channel
{
  function(string:void) data_handler;
  function(string:void) close_handler;

  void set_handlers(function(string:void) on_data,
                    function(string:void) on_close)
  {
    data_handler = on_data;
    close_handler = on_close;
  }

  // Returns 1 when the bytes were accepted for delivery, 0 when the channel is
  // already dead or its outgoing budget is exhausted.
  int write(string data)
  {
    error("Channel.write must be implemented\n");
    return 0;
  }

  // Drop the connection immediately without waiting for the peer.
  void hard_close(string reason)
  {
    error("Channel.hard_close must be implemented\n");
  }

  int is_open()
  {
    return 0;
  }

  // 1 once the channel can carry application bytes end to end.
  int is_ready()
  {
    return 0;
  }

  int pending_output()
  {
    return 0;
  }

  string failure_reason()
  {
    return "";
  }
}

// A real TCP or TLS connection. Connect, handshake, and I/O are all
// non-blocking and driven by the Pike backend, so the caller's absolute
// deadline in pump_until stays authoritative even when the peer never answers.
class SocketChannel
{
  inherit Channel;

  string host;
  int port;
  int want_tls;
  string ca_bundle_path;

  object raw;
  object stream;
  string out_buffer = "";
  // A completed TCP connect is not the fact any layer above cares about.
  // `established` is: the stream has told us it can accept application bytes,
  // which for TLS means the handshake finished rather than merely started.
  int established;
  int write_armed;
  // Pike spells "stop calling me when there is nothing to send" the same way on
  // Stdio.File and SSL.File, but this is probed rather than assumed so a build
  // without it keeps a permanently armed callback instead of failing outright.
  int can_disarm_writes;
  int dead;
  string failure = "";
  int announced;

  // Candidates still to try, most preferred first, drained one at a time by
  // try_next_candidate(). The plain host is always the last entry, so a
  // literal address or an IPv6-only name still resolves exactly the way it
  // did before any of this existed.
  array(string) pending_addresses;

  protected void create(string connect_host, int connect_port, int use_tls,
                        void|string bundle_path)
  {
    host = connect_host;
    port = connect_port;
    want_tls = use_tls;
    ca_bundle_path = bundle_path || DEFAULT_CA_BUNDLE;
    // Some networks advertise an AAAA record for a dual-stack host without
    // actually routing IPv6 traffic -- a plain Docker bridge network is
    // exactly this shape. async_connect(host, ...) resolves the hostname
    // itself and, per the platform resolver's address ordering, can pick
    // that unreachable address and give up instead of falling back to a
    // working one. Resolve the A records ourselves first and try each in
    // turn before ever falling back to async_connect's own hostname
    // resolution as the last candidate.
    pending_addresses = ipv4_candidates(host) + ({ host });
    try_next_candidate();
  }

  // gethostbyname() is Pike's legacy, IPv4-only resolver: it never returns
  // an AAAA record, so every address it hands back is one async_connect can
  // reach even from a network namespace with no IPv6 route at all. Anything
  // that keeps it from answering -- an IPv6-only name, a literal address it
  // does not parse, a resolver error -- yields an empty list rather than an
  // exception, leaving the plain hostname as the sole, original candidate.
  array(string) ipv4_candidates(string name)
  {
    array(string) addresses = ({});
    catch {
      array info = gethostbyname(name);
      if (info && sizeof(info) >= 2 && arrayp(info[1]))
        addresses = info[1];
    };
    return addresses;
  }

  // Pop the next candidate address and attempt it. Exhausting the list
  // (the plain host, tried last, already failed too) is reported the same
  // way a single failed attempt always was.
  void try_next_candidate()
  {
    if (!sizeof(pending_addresses)) {
      die(sprintf("could not connect to %s:%d", host, port));
      return;
    }
    string candidate = pending_addresses[0];
    pending_addresses = pending_addresses[1..];
    raw = Stdio.File();
    mixed failed =
      catch { raw->async_connect(candidate, port, tcp_connected); };
    // A synchronous throw for this candidate is exactly as unusable as an
    // async failure callback; move on to the next candidate the same way.
    if (failed)
      tcp_connected(0);
  }

  // Whoever installs handlers also inherits a close that already happened. A
  // connect refused inside create() would otherwise be lost, because the owner
  // above can only attach its handlers once this object exists.
  void set_handlers(function(string:void) on_data,
                    function(string:void) on_close)
  {
    ::set_handlers(on_data, on_close);
    announce();
  }

  void announce()
  {
    if (!dead || announced || !close_handler)
      return;
    announced = 1;
    close_handler(failure);
  }

  void tcp_connected(int success, mixed ... ignored)
  {
    if (dead)
      return;
    if (!success) {
      try_next_candidate();
      return;
    }
    mixed failed = catch {
      if (want_tls) {
        stream = SSL.File(raw, tls_context(ca_bundle_path));
        stream->set_nonblocking(socket_read, socket_writable, socket_close);
        // Start the client handshake. Nothing queued is written until the
        // stream reports itself writable below, so a half-finished handshake
        // can never be mistaken for a channel that carries bytes end to end.
        if (!stream->connect(host))
          error("TLS handshake could not be started\n");
      } else {
        stream = raw;
        stream->set_nonblocking(socket_read, socket_writable, socket_close);
      }
      can_disarm_writes = search(indices(stream), "set_write_callback") >= 0;
    };
    if (failed) {
      die(as_convex_error(failed)->message);
      return;
    }
    // set_nonblocking installed the write callback, so record it as armed
    // until the first flush decides whether it is still needed.
    if (!established)
      write_armed = 1;
  }

  void socket_read(mixed id, string data)
  {
    if (dead || !sizeof(data))
      return;
    if (data_handler)
      data_handler(data);
  }

  // The stream can take bytes. For TLS this is the first moment the handshake
  // is known to have finished, which is why readiness is decided here rather
  // than when the TCP connect returned.
  void socket_writable(mixed id)
  {
    if (dead)
      return;
    established = 1;
    flush();
  }

  void socket_close(mixed id)
  {
    die("peer closed the connection");
  }

  // An always-armed write callback fires on every backend pass while the socket
  // is writable, which would spin a mostly idle Live connection at full CPU for
  // the life of the process. Keep it on only while bytes are actually waiting.
  void arm_writes(int wanted)
  {
    if (dead || !stream)
      return;
    if (!can_disarm_writes) {
      write_armed = 1;
      return;
    }
    if (!!wanted == !!write_armed)
      return;
    mixed failed = catch {
      if (wanted)
        stream->set_write_callback(socket_writable);
      else
        stream->set_write_callback(0);
    };
    if (failed) {
      // Losing the ability to disarm costs CPU; losing the callback itself
      // would strand the connection, so put it back and stop switching it.
      can_disarm_writes = 0;
      write_armed = 1;
      catch { stream->set_write_callback(socket_writable); };
      return;
    }
    write_armed = !!wanted;
  }

  void flush()
  {
    if (!established || dead)
      return;
    if (sizeof(out_buffer)) {
      int written;
      mixed failed = catch { written = stream->write(out_buffer); };
      if (failed) {
        die(as_convex_error(failed)->message);
        return;
      }
      if (written < 0) {
        die("socket write failed");
        return;
      }
      out_buffer = out_buffer[written..];
    }
    arm_writes(sizeof(out_buffer));
  }

  int write(string data)
  {
    if (dead)
      return 0;
    if (sizeof(out_buffer) + sizeof(data) > MAX_PENDING_OUTPUT_BYTES) {
      die("outgoing socket buffer exceeded its byte budget");
      return 0;
    }
    out_buffer += data;
    if (established)
      flush();
    else
      arm_writes(1);
    // A flush that killed the connection means these bytes were not accepted,
    // so the caller learns it here rather than from the next failure.
    return !dead;
  }

  void die(string reason)
  {
    if (dead) {
      return;
    }
    dead = 1;
    established = 0;
    write_armed = 0;
    failure = reason;
    out_buffer = "";
    object closing = stream || raw;
    stream = 0;
    raw = 0;
    if (closing) {
      // A TLS close_notify exchange can stall on an unresponsive peer. Prefer
      // shutdown, which retires the descriptor without waiting for the peer.
      if (search(indices(closing), "shutdown") >= 0)
        catch { closing->shutdown(); };
      catch { closing->close(); };
    }
    announce();
  }

  void hard_close(string reason)
  {
    die(reason);
  }

  int is_open()
  {
    return !dead;
  }

  int is_ready()
  {
    return established && !dead;
  }

  int pending_output()
  {
    return sizeof(out_buffer);
  }

  string failure_reason()
  {
    return failure;
  }
}

// Open a channel and wait, against one absolute deadline, until it can carry
// application bytes or has failed.
Channel connect_channel(mapping target, int deadline_ms, void|string operation)
{
  SocketChannel channel = SocketChannel(target->host, target->port,
                                        target->tls);
  function ready = lambda() {
    return channel->is_ready() || !channel->is_open();
  };
  if (!pump_until(ready, deadline_ms)) {
    channel->hard_close("connect deadline expired");
    // Name the stage that ran out of time. A TLS deployment that resolves and
    // accepts TCP but never completes a handshake is a different diagnosis
    // from one that never answered at all.
    throw(transport_error(
      sprintf("%s to %s:%d timed out",
              target->tls ? "TLS handshake" : "connecting", target->host,
              target->port), operation));
  }
  if (!channel->is_open())
    throw(transport_error(channel->failure_reason(), operation));
  return channel;
}

#endif
