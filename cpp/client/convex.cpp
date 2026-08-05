#include "convex.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/ssl.hpp>
#include <openssl/ssl.h>

namespace convex {
namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace ssl = asio::ssl;
using tcp = asio::ip::tcp;

namespace {
constexpr std::uint64_t maximum_response_bytes = 2 * 1024 * 1024;

struct Parts {
  std::string host;
  std::string port;
  std::string base;
  bool secure;
};

template <typename Stream>
Result perform_http(Stream &stream, const Parts &parts,
                    const std::string &token, const std::string &operation,
                    const std::string &path, const Json &args) {
  http::request<http::string_body> request{
      http::verb::post, parts.base + "/api/" + operation, 11};
  request.set(http::field::host, parts.host);
  request.set(http::field::content_type, "application/json");
  request.set(http::field::accept, "application/json");
  request.set("Convex-Client", "cpp-0.1.0");
  if (!token.empty()) {
    request.set(http::field::authorization, "Bearer " + token);
  }
  request.body() =
      Json{{"path", path}, {"args", args}, {"format", "json"}}.dump();
  request.prepare_payload();
  http::write(stream, request);

  // Bound the response while Beast is reading it, rather than checking only
  // after an unexpectedly large body has already been allocated.
  beast::flat_buffer buffer;
  http::response_parser<http::string_body> parser;
  parser.body_limit(maximum_response_bytes);
  http::read(stream, buffer, parser);
  auto response = parser.release();

  Json decoded;
  try {
    decoded = Json::parse(response.body());
  } catch (const Json::exception &) {
    throw ProtocolError("HTTP response was not a Convex response");
  }

  auto logs = decoded.value("logLines", std::vector<std::string>{});
  if (decoded.value("status", "") == "success") {
    if (!decoded.contains("value")) {
      throw ProtocolError("success response omitted value");
    }
    return {decoded["value"], logs};
  }
  if (decoded.value("status", "") == "error") {
    throw FunctionError(decoded.value("errorMessage", "Convex function failed"),
                        decoded.value("errorData", Json()), logs);
  }
  throw ProtocolError("HTTP response has unknown Convex status");
}

Parts parse_url(const std::string &value) {
  const auto scheme = value.find("://");
  if (scheme == std::string::npos) {
    throw Error("Convex deployment URL must use http or https");
  }

  Parts parts;
  const auto scheme_name = value.substr(0, scheme);
  parts.secure = scheme_name == "https";
  if (!parts.secure && scheme_name != "http") {
    throw Error("Convex deployment URL must use http or https");
  }

  const auto authority_start = scheme + 3;
  const auto slash = value.find('/', authority_start);
  const auto authority = value.substr(authority_start, slash - authority_start);
  if (authority.empty() || authority.find('@') != std::string::npos) {
    throw Error(
        "Convex deployment URL must include a host and not user information");
  }

  // Bracketed IPv6 addresses may contain colons which are not a port separator.
  if (authority.front() == '[') {
    const auto closing_bracket = authority.find(']');
    if (closing_bracket == std::string::npos) {
      throw Error("Convex deployment URL contains an invalid IPv6 host");
    }
    parts.host = authority.substr(1, closing_bracket - 1);
    if (closing_bracket + 1 < authority.size()) {
      if (authority[closing_bracket + 1] != ':') {
        throw Error("Convex deployment URL contains an invalid authority");
      }
      parts.port = authority.substr(closing_bracket + 2);
    }
  } else {
    const auto colon = authority.rfind(':');
    parts.host =
        colon == std::string::npos ? authority : authority.substr(0, colon);
    if (colon != std::string::npos) {
      parts.port = authority.substr(colon + 1);
    }
  }

  if (parts.host.empty()) {
    throw Error("Convex deployment URL must include a host");
  }
  if (parts.port.empty()) {
    parts.port = parts.secure ? "443" : "80";
  }
  parts.base = slash == std::string::npos ? "" : value.substr(slash);
  while (!parts.base.empty() && parts.base.back() == '/') {
    parts.base.pop_back();
  }
  return parts;
}
} // namespace

Client::Client(std::string url, std::string token)
    : url_(std::move(url)), token_(std::move(token)) {
  parse_url(url_);
}

Client::~Client() {
  try {
    close();
  } catch (...) {
    // Destructors cannot report cleanup errors. Explicit close remains
    // available when a caller needs to observe them.
  }
}

void Client::set_auth(std::string token) {
  if (closed_) {
    throw Error("Convex client is closed");
  }
  token_ = std::move(token);
}

void Client::close() {
  if (closed_) {
    return;
  }
  closed_ = true;

  // Closing the client also retires every Live worker it created. This keeps a
  // forgotten Subscription from outliving the client that owns its transport.
  for (auto iterator = subscriptions_.begin();
       iterator != subscriptions_.end();) {
    if (auto subscription = iterator->lock()) {
      subscription->close();
      ++iterator;
    } else {
      iterator = subscriptions_.erase(iterator);
    }
  }
}

#ifdef CONVEX_ADAPTER_BUILD
void Client::debug_disconnect_for_adapter() {
  if (closed_) {
    throw Error("Convex client is closed");
  }

  bool disconnected = false;
  for (auto iterator = subscriptions_.begin();
       iterator != subscriptions_.end();) {
    if (auto subscription = iterator->lock()) {
      subscription->debug_disconnect();
      disconnected = true;
      ++iterator;
    } else {
      iterator = subscriptions_.erase(iterator);
    }
  }
  if (!disconnected) {
    throw Error("Live WebSocket is not connected");
  }
}
#endif

Result Client::query(const std::string &path, const Json &args) {
  return call("query", path, args);
}

Result Client::mutation(const std::string &path, const Json &args) {
  return call("mutation", path, args);
}

Result Client::action(const std::string &path, const Json &args) {
  return call("action", path, args);
}

std::shared_ptr<Subscription> Client::subscribe(const std::string &path,
                                                const Json &args) {
  if (closed_) {
    throw Error("Convex client is closed");
  }
  if (path.empty() || !args.is_object()) {
    throw Error("Live query requires a path and named JSON arguments");
  }

  auto subscription =
      std::shared_ptr<Subscription>(new Subscription(url_, path, args));
  subscriptions_.push_back(subscription);
  return subscription;
}

Result Client::call(const std::string &operation, const std::string &path,
                    const Json &args) {
  if (closed_) {
    throw Error("Convex client is closed");
  }
  if (path.empty()) {
    throw Error("Convex function path is required");
  }
  if (!args.is_object()) {
    throw Error("Convex arguments must be a named JSON object");
  }

  const auto parts = parse_url(url_);
  try {
    asio::io_context io;
    tcp::resolver resolver(io);
    const auto endpoints = resolver.resolve(parts.host, parts.port);

    if (!parts.secure) {
      beast::tcp_stream stream(io);
      stream.connect(endpoints);
      return perform_http(stream, parts, token_, operation, path, args);
    }

    ssl::context context(ssl::context::tls_client);
    context.set_default_verify_paths();
    context.set_verify_mode(ssl::verify_peer);
    beast::ssl_stream<beast::tcp_stream> stream(io, context);
    stream.set_verify_callback(ssl::host_name_verification(parts.host));
    if (!SSL_set_tlsext_host_name(stream.native_handle(), parts.host.c_str())) {
      throw TransportError("configure TLS server name");
    }
    beast::get_lowest_layer(stream).connect(endpoints);
    stream.handshake(ssl::stream_base::client);
    auto result = perform_http(stream, parts, token_, operation, path, args);
    beast::error_code ignored;
    stream.shutdown(ignored);
    return result;
  } catch (const FunctionError &) {
    throw;
  } catch (const ProtocolError &) {
    throw;
  } catch (const TransportError &) {
    throw;
  } catch (const boost::system::system_error &error) {
    throw TransportError(std::string("HTTP transport: ") + error.what());
  }
}
} // namespace convex
