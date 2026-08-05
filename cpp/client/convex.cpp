#include "convex.hpp"
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/ssl.hpp>
#include <openssl/ssl.h>

namespace convex {
namespace asio = boost::asio; namespace beast = boost::beast; namespace http = beast::http; namespace ssl = asio::ssl; using tcp = asio::ip::tcp;
struct Parts { std::string host, port, base; bool secure; };
template <typename Stream> static Result perform_http(Stream& stream, const Parts& p, const std::string& token, const std::string& op, const std::string& path, const Json& args) {
  http::request<http::string_body> req{http::verb::post, p.base + "/api/" + op, 11}; req.set(http::field::host, p.host); req.set(http::field::content_type, "application/json"); req.set(http::field::accept, "application/json"); req.set("Convex-Client", "cpp-0.1.0"); if (!token.empty()) req.set(http::field::authorization, "Bearer " + token); req.body() = Json{{"path",path},{"args",args},{"format","json"}}.dump(); req.prepare_payload(); http::write(stream, req);
  beast::flat_buffer buffer; http::response<http::string_body> response; http::read(stream, buffer, response); if (response.body().size() > 2 * 1024 * 1024) throw Error("response exceeds 2097152 bytes"); Json decoded; try { decoded = Json::parse(response.body()); } catch (...) { throw Error("HTTP response was not a Convex response"); } auto logs = decoded.value("logLines", std::vector<std::string>{}); if (decoded.value("status", "") == "success") { if (!decoded.contains("value")) throw Error("success response omitted value"); return {decoded["value"], logs}; } if (decoded.value("status", "") == "error") throw FunctionError(decoded.value("errorMessage", "Convex function failed"), decoded.value("errorData", Json()), logs); throw Error("HTTP response has unknown Convex status");
}
static Parts parse_url(const std::string& value) {
  auto scheme = value.find("://"); if (scheme == std::string::npos) throw Error("Convex deployment URL must use http or https");
  Parts p; auto name = value.substr(0, scheme); p.secure = name == "https"; if (!p.secure && name != "http") throw Error("Convex deployment URL must use http or https");
  const auto start = scheme + 3;
  const auto slash = value.find('/', start);
  const auto authority = value.substr(start, slash - start);
  if (authority.empty() || authority.find('@') != std::string::npos) throw Error("Convex deployment URL must include a host and not user information");
  auto colon = authority.rfind(':'); p.host = colon == std::string::npos ? authority : authority.substr(0, colon); p.port = colon == std::string::npos ? (p.secure ? "443" : "80") : authority.substr(colon + 1); p.base = slash == std::string::npos ? "" : value.substr(slash); while (!p.base.empty() && p.base.back() == '/') p.base.pop_back(); return p;
}
Client::Client(std::string url, std::string token) : url_(std::move(url)), token_(std::move(token)) { parse_url(url_); }
void Client::set_auth(std::string token) { if (closed_) throw Error("Convex client is closed"); token_ = std::move(token); }
void Client::close() { closed_ = true; }
void Client::debug_disconnect_for_adapter() { if (closed_) throw Error("Convex client is closed"); bool disconnected = false; for (auto it = subscriptions_.begin(); it != subscriptions_.end();) { if (auto subscription = it->lock()) { subscription->debug_disconnect(); disconnected = true; ++it; } else it = subscriptions_.erase(it); } if (!disconnected) throw Error("Live WebSocket is not connected"); }
Result Client::query(const std::string& path, const Json& args) { return call("query", path, args); }
Result Client::mutation(const std::string& path, const Json& args) { return call("mutation", path, args); }
Result Client::action(const std::string& path, const Json& args) { return call("action", path, args); }
std::shared_ptr<Subscription> Client::subscribe(const std::string& path, const Json& args) { if (closed_) throw Error("Convex client is closed"); if (path.empty() || !args.is_object()) throw Error("Live query requires a path and named JSON arguments"); auto subscription = std::shared_ptr<Subscription>(new Subscription(url_, path, args)); subscriptions_.push_back(subscription); return subscription; }
Result Client::call(const std::string& op, const std::string& path, const Json& args) {
  if (closed_) throw Error("Convex client is closed");
  if (path.empty()) throw Error("Convex function path is required");
  if (!args.is_object()) throw Error("Convex arguments must be a named JSON object");
  auto p = parse_url(url_);
  asio::io_context io; tcp::resolver resolver(io); auto endpoints = resolver.resolve(p.host, p.port);
  if (!p.secure) { beast::tcp_stream stream(io); stream.connect(endpoints); return perform_http(stream, p, token_, op, path, args); }
  ssl::context ctx(ssl::context::tls_client); ctx.set_default_verify_paths(); ctx.set_verify_mode(ssl::verify_peer); beast::ssl_stream<beast::tcp_stream> stream(io, ctx); stream.set_verify_callback(ssl::host_name_verification(p.host));
  if (!SSL_set_tlsext_host_name(stream.native_handle(), p.host.c_str())) throw Error("configure TLS server name");
  beast::get_lowest_layer(stream).connect(endpoints);
  stream.handshake(ssl::stream_base::client);
  auto result = perform_http(stream, p, token_, op, path, args);
  beast::error_code ignored; stream.shutdown(ignored); return result;
}
}
