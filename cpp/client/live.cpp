#include "convex.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/beast/websocket.hpp>
#include <openssl/ssl.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <random>
#include <thread>

namespace convex {
namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
namespace ssl = asio::ssl;
using tcp = asio::ip::tcp;

namespace {
constexpr const char *zero_timestamp = "AAAAAAAAAAA=";
constexpr std::size_t maximum_live_message_bytes = 2 * 1024 * 1024;
constexpr auto owner_poll_interval = std::chrono::milliseconds(25);

struct LiveParts {
  std::string host;
  std::string port;
  std::string target;
  bool secure;
};

LiveParts parse_live_url(std::string url) {
  const auto scheme_end = url.find("://");
  if (scheme_end == std::string::npos) {
    throw Error("invalid Convex deployment URL");
  }

  const auto scheme = url.substr(0, scheme_end);
  LiveParts parts;
  parts.secure = scheme == "https";
  if (!parts.secure && scheme != "http") {
    throw Error("Convex deployment URL must use http or https");
  }

  const auto authority_start = scheme_end + 3;
  const auto slash = url.find('/', authority_start);
  const auto authority = url.substr(authority_start, slash - authority_start);
  if (authority.empty() || authority.find('@') != std::string::npos) {
    throw Error("Convex deployment URL contains an invalid authority");
  }

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

  parts.target = slash == std::string::npos ? "" : url.substr(slash);
  while (!parts.target.empty() && parts.target.back() == '/') {
    parts.target.pop_back();
  }
  parts.target += "/api/sync";
  return parts;
}

std::string new_session_id() {
  std::random_device random;
  std::mt19937_64 generator(random());
  char output[37];
  std::snprintf(
      output, sizeof output, "%08x-%04x-4%03x-8%03x-%012llx",
      static_cast<unsigned>(generator()),
      static_cast<unsigned>(generator() & 0xffff),
      static_cast<unsigned>(generator() & 0xfff),
      static_cast<unsigned>(generator() & 0xfff),
      static_cast<unsigned long long>(generator() & 0xffffffffffffULL));
  return output;
}
} // namespace

struct Subscription::State : std::enable_shared_from_this<Subscription::State> {
  enum class Command { none, debug_disconnect };

  struct StopRequested {};
  struct DebugDisconnectRequested {
    std::uint64_t ticket;
  };

  explicit State(std::string deployment_url, std::string function_path,
                 Json function_args)
      : parts(parse_live_url(std::move(deployment_url))),
        path(std::move(function_path)), args(std::move(function_args)) {}

  LiveParts parts;
  std::string path;
  Json args;

  std::mutex mutex;
  std::condition_variable cv;
  std::deque<Update> queue;
  bool stopped = false;
  bool connected = false;
  Command command = Command::none;
  std::uint64_t next_debug_ticket = 0;
  std::uint64_t completed_debug_ticket = 0;

  std::uint64_t connection_count = 0;
  std::string last_close_reason = "InitialConnect";
  std::string max_observed_timestamp;
  bool have_last_value = false;
  bool last_delivery_was_error = false;
  Json last_value;
  std::thread worker;

  bool stop_requested() {
    std::lock_guard lock(mutex);
    return stopped;
  }

  void push(Update update) {
    std::lock_guard lock(mutex);
    if (stopped) {
      return;
    }
    if (queue.size() == 16) {
      queue.pop_front();
    }
    queue.push_back(std::move(update));
    cv.notify_one();
  }

  template <typename Cancel>
  void pump_until(asio::io_context &io, bool &done, Cancel cancel) {
    bool cancelled = false;
    while (!done) {
      io.restart();
      io.run_for(owner_poll_interval);
      if (!cancelled && stop_requested()) {
        cancelled = true;
        cancel();
      }
    }
    if (cancelled) {
      throw StopRequested{};
    }
  }

  template <typename Stream>
  static void retire_socket(Stream &stream, asio::io_context &io) {
    beast::error_code ignored;
    auto &socket = beast::get_lowest_layer(stream).socket();
    socket.cancel(ignored);
    socket.shutdown(tcp::socket::shutdown_both, ignored);
    socket.close(ignored);
    // The caller pumps only until its own outstanding operation completes.
    // io.run() would also wait for Beast's internal handshake timer and turn a
    // cancelled handshake into a 30-second close.
    io.restart();
  }

  template <typename WebSocket>
  void write_json(WebSocket &socket, asio::io_context &io, const Json &value) {
    const auto encoded = value.dump();
    bool done = false;
    beast::error_code error;
    socket.async_write(asio::buffer(encoded),
                       [&](beast::error_code write_error, std::size_t) {
                         error = write_error;
                         done = true;
                       });
    pump_until(io, done, [&] { retire_socket(socket, io); });
    if (error) {
      throw boost::system::system_error(error);
    }
  }

  template <typename WebSocket>
  void send_remove_before_close(WebSocket &socket, asio::io_context &io) {
    const Json remove{
        {"type", "ModifyQuerySet"},
        {"baseVersion", 1},
        {"newVersion", 2},
        {"modifications", Json::array({{{"type", "Remove"}, {"queryId", 0}}})}};
    const auto encoded = remove.dump();
    bool done = false;
    socket.async_write(asio::buffer(encoded),
                       [&](beast::error_code, std::size_t) { done = true; });

    // Cleanup is best effort, but bounded. The peer may be idle, continuously
    // sending, or stalled halfway through a frame.
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    while (!done && std::chrono::steady_clock::now() < deadline) {
      io.restart();
      io.run_for(owner_poll_interval);
    }
    if (!done) {
      retire_socket(socket, io);
      while (!done) {
        io.restart();
        io.run_for(owner_poll_interval);
      }
    }
  }

  void validate_and_deliver_transition(const Json &message, Json &version,
                                       unsigned &attempts,
                                       bool &awaiting_rehydration) {
    try {
      if (!message.is_object() || message.value("type", "") != "Transition") {
        throw ProtocolError("unexpected Live server message");
      }
      if (!message.contains("startVersion") ||
          message.at("startVersion") != version) {
        throw ProtocolError("Live transition version mismatch");
      }
      if (!message.contains("endVersion") ||
          !message.at("endVersion").is_object() ||
          !message.at("endVersion").contains("ts") ||
          !message.at("endVersion").at("ts").is_string()) {
        throw ProtocolError("Live transition has an invalid endVersion");
      }
      if (!message.contains("modifications") ||
          !message.at("modifications").is_array()) {
        throw ProtocolError("Live transition modifications must be an array");
      }

      std::vector<Update> updates;
      for (const auto &change : message.at("modifications")) {
        if (!change.is_object() || !change.contains("queryId") ||
            !change.at("queryId").is_number_integer() ||
            !change.contains("type") || !change.at("type").is_string()) {
          throw ProtocolError("Live transition modification is malformed");
        }
        if (change.at("queryId").get<int>() != 0) {
          continue;
        }

        const auto type = change.at("type").get<std::string>();
        if (type == "QueryUpdated") {
          if (!change.contains("value")) {
            throw ProtocolError("QueryUpdated omitted value");
          }
          updates.push_back(
              {change.at("value"),
               change.value("logLines", std::vector<std::string>{}), "", Json(),
               ""});
        } else if (type == "QueryFailed") {
          if (!change.contains("errorMessage") ||
              !change.at("errorMessage").is_string()) {
            throw ProtocolError("QueryFailed omitted errorMessage");
          }
          updates.push_back(
              {Json(), change.value("logLines", std::vector<std::string>{}),
               change.at("errorMessage").get<std::string>(),
               change.value("errorData", Json()), "FunctionError"});
        } else if (type != "QueryRemoved") {
          throw ProtocolError("unknown Live transition modification");
        }
      }

      // Commit the complete transition before publishing any part of it.
      version = message.at("endVersion");
      max_observed_timestamp = version.at("ts").get<std::string>();
      attempts = 0;

      for (auto &update : updates) {
        if (!update.error.empty()) {
          awaiting_rehydration = false;
          last_delivery_was_error = true;
          push(std::move(update));
          continue;
        }

        // A reconnect normally rehydrates the current value. Do not deliver an
        // unchanged snapshot across debugDisconnect, because the controller's
        // exact sequence is initial value, disconnect ack, external change.
        if (awaiting_rehydration && have_last_value &&
            !last_delivery_was_error && update.value == last_value) {
          awaiting_rehydration = false;
          continue;
        }
        awaiting_rehydration = false;
        last_value = update.value;
        have_last_value = true;
        last_delivery_was_error = false;
        push(std::move(update));
      }
    } catch (const ProtocolError &) {
      throw;
    } catch (const Json::exception &error) {
      throw ProtocolError(std::string("decode Live transition: ") +
                          error.what());
    }
  }

  template <typename WebSocket>
  void exchange(WebSocket &socket, asio::io_context &io, unsigned &attempts,
                bool is_reconnect) {
    Json version{{"querySet", 0}, {"identity", 0}, {"ts", zero_timestamp}};
    bool awaiting_rehydration = is_reconnect;

    struct ConnectedGuard {
      State &state;
      ~ConnectedGuard() {
        std::lock_guard lock(state.mutex);
        state.connected = false;
        state.cv.notify_all();
      }
    } guard{*this};

    for (;;) {
      beast::flat_buffer buffer;
      bool read_done = false;
      beast::error_code read_error;
      socket.async_read(buffer, [&](beast::error_code error, std::size_t) {
        read_error = error;
        read_done = true;
      });

      while (!read_done) {
        Command pending = Command::none;
        std::uint64_t ticket = 0;
        bool should_stop = false;
        {
          std::lock_guard lock(mutex);
          should_stop = stopped;
          if (!should_stop) {
            pending = command;
            ticket = next_debug_ticket;
            command = Command::none;
          }
        }

        if (should_stop) {
          send_remove_before_close(socket, io);
          retire_socket(socket, io);
          while (!read_done) {
            io.restart();
            io.run_for(owner_poll_interval);
          }
          throw StopRequested{};
        }
        if (pending == Command::debug_disconnect) {
          retire_socket(socket, io);
          while (!read_done) {
            io.restart();
            io.run_for(owner_poll_interval);
          }
          throw DebugDisconnectRequested{ticket};
        }

        io.restart();
        io.run_for(owner_poll_interval);
      }

      if (read_error) {
        throw boost::system::system_error(read_error);
      }

      Json message;
      try {
        message = Json::parse(beast::buffers_to_string(buffer.data()));
      } catch (const Json::exception &error) {
        throw ProtocolError(std::string("decode Live message: ") +
                            error.what());
      }

      if (!message.is_object() || !message.contains("type") ||
          !message.at("type").is_string()) {
        throw ProtocolError("Live server message omitted a string type");
      }
      if (message.at("type").get<std::string>() == "Ping") {
        attempts = 0;
        continue;
      }
      validate_and_deliver_transition(message, version, attempts,
                                      awaiting_rehydration);
    }
  }

  template <typename WebSocket>
  void send_connect_and_add(WebSocket &socket, asio::io_context &io,
                            std::uint64_t count) {
    Json connect{{"type", "Connect"},
                 {"sessionId", new_session_id()},
                 {"connectionCount", count},
                 {"lastCloseReason", last_close_reason},
                 {"clientTs", 0}};
    if (!max_observed_timestamp.empty()) {
      connect["maxObservedTimestamp"] = max_observed_timestamp;
    }
    write_json(socket, io, connect);

    const Json add{
        {"type", "ModifyQuerySet"},
        {"baseVersion", 0},
        {"newVersion", 1},
        {"modifications", Json::array({{{"type", "Add"},
                                        {"queryId", 0},
                                        {"udfPath", path},
                                        {"args", Json::array({args})}}})}};
    write_json(socket, io, add);
  }

  void session(unsigned &attempts) {
    asio::io_context io;
    tcp::resolver resolver(io);
    tcp::resolver::results_type endpoints;
    bool resolved = false;
    beast::error_code resolve_error;
    resolver.async_resolve(
        parts.host, parts.port,
        [&](beast::error_code error, tcp::resolver::results_type results) {
          resolve_error = error;
          endpoints = std::move(results);
          resolved = true;
        });
    pump_until(io, resolved, [&] { resolver.cancel(); });
    if (resolve_error) {
      throw boost::system::system_error(resolve_error);
    }

    const auto count = connection_count++;
    if (parts.secure) {
      ssl::context context(ssl::context::tls_client);
      context.set_default_verify_paths();
      context.set_verify_mode(ssl::verify_peer);
      beast::ssl_stream<beast::tcp_stream> tls(io, context);
      tls.set_verify_callback(ssl::host_name_verification(parts.host));
      if (!SSL_set_tlsext_host_name(tls.native_handle(), parts.host.c_str())) {
        throw TransportError("configure Live TLS server name");
      }

      bool connected_to_tcp = false;
      beast::error_code connect_error;
      beast::get_lowest_layer(tls).async_connect(
          endpoints, [&](beast::error_code error, const tcp::endpoint &) {
            connect_error = error;
            connected_to_tcp = true;
          });
      pump_until(io, connected_to_tcp, [&] { retire_socket(tls, io); });
      if (connect_error) {
        throw boost::system::system_error(connect_error);
      }

      bool tls_ready = false;
      beast::error_code tls_error;
      tls.async_handshake(ssl::stream_base::client,
                          [&](beast::error_code error) {
                            tls_error = error;
                            tls_ready = true;
                          });
      pump_until(io, tls_ready, [&] { retire_socket(tls, io); });
      if (tls_error) {
        throw boost::system::system_error(tls_error);
      }

      websocket::stream<beast::ssl_stream<beast::tcp_stream>> socket(
          std::move(tls));
      socket.set_option(
          websocket::stream_base::timeout::suggested(beast::role_type::client));
      socket.read_message_max(maximum_live_message_bytes);
      bool websocket_ready = false;
      beast::error_code websocket_error;
      socket.async_handshake(parts.host, parts.target,
                             [&](beast::error_code error) {
                               websocket_error = error;
                               websocket_ready = true;
                             });
      pump_until(io, websocket_ready, [&] { retire_socket(socket, io); });
      if (websocket_error) {
        throw boost::system::system_error(websocket_error);
      }

      attempts = 0;
      send_connect_and_add(socket, io, count);
      {
        std::lock_guard lock(mutex);
        connected = true;
        cv.notify_all();
      }
      exchange(socket, io, attempts, count > 0);
      return;
    }

    beast::tcp_stream tcp_stream(io);
    bool connected_to_tcp = false;
    beast::error_code connect_error;
    tcp_stream.async_connect(
        endpoints, [&](beast::error_code error, const tcp::endpoint &) {
          connect_error = error;
          connected_to_tcp = true;
        });
    pump_until(io, connected_to_tcp, [&] { retire_socket(tcp_stream, io); });
    if (connect_error) {
      throw boost::system::system_error(connect_error);
    }

    websocket::stream<beast::tcp_stream> socket(std::move(tcp_stream));
    socket.set_option(
        websocket::stream_base::timeout::suggested(beast::role_type::client));
    socket.read_message_max(maximum_live_message_bytes);
    bool websocket_ready = false;
    beast::error_code websocket_error;
    socket.async_handshake(parts.host, parts.target,
                           [&](beast::error_code error) {
                             websocket_error = error;
                             websocket_ready = true;
                           });
    pump_until(io, websocket_ready, [&] { retire_socket(socket, io); });
    if (websocket_error) {
      throw boost::system::system_error(websocket_error);
    }

    attempts = 0;
    send_connect_and_add(socket, io, count);
    {
      std::lock_guard lock(mutex);
      connected = true;
      cv.notify_all();
    }
    exchange(socket, io, attempts, count > 0);
  }

  void run() {
    unsigned attempts = 0;
    while (true) {
      if (stop_requested()) {
        return;
      }

      try {
        session(attempts);
      } catch (const StopRequested &) {
        return;
      } catch (const DebugDisconnectRequested &debug) {
        // At this point the old socket is closed and the owner is about to loop
        // directly into reconnect work. Only now may debugDisconnect ack.
        last_close_reason = "DebugDisconnect";
        attempts = 0;
        {
          std::lock_guard lock(mutex);
          completed_debug_ticket = debug.ticket;
          cv.notify_all();
        }
        continue;
      } catch (const ProtocolError &error) {
        last_close_reason = error.what();
        push({Json(), {}, error.what(), Json(), "ProtocolError"});
      } catch (const std::exception &error) {
        last_close_reason = error.what();
        push({Json(),
              {},
              std::string("Live transport: ") + error.what(),
              Json(),
              "TransportError"});
      }

      std::unique_lock lock(mutex);
      if (stopped) {
        return;
      }
      const auto exponent = std::min(attempts++, 7u);
      const auto delay =
          std::chrono::milliseconds(std::min(15000u, 100u << exponent));
      cv.wait_for(lock, delay, [&] { return stopped; });
    }
  }
};

Subscription::Subscription(std::string url, std::string path, Json args)
    : state_(std::make_shared<State>(std::move(url), std::move(path),
                                     std::move(args))) {
  state_->worker = std::thread([state = state_] { state->run(); });
}

Subscription::~Subscription() { close(); }

std::optional<Update> Subscription::next_update(int timeout_ms) {
  std::unique_lock lock(state_->mutex);
  if (!state_->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
        return state_->stopped || !state_->queue.empty();
      })) {
    return std::nullopt;
  }
  if (state_->queue.empty()) {
    return std::nullopt;
  }
  auto update = std::move(state_->queue.front());
  state_->queue.pop_front();
  return update;
}

void Subscription::close() {
  if (!state_) {
    return;
  }
  {
    std::lock_guard lock(state_->mutex);
    state_->stopped = true;
    state_->cv.notify_all();
  }
  if (state_->worker.joinable()) {
    state_->worker.join();
  }
}

void Subscription::debug_disconnect() {
  std::unique_lock lock(state_->mutex);
  if (!state_->connected || state_->stopped) {
    throw Error("Live WebSocket is not connected");
  }
  const auto ticket = ++state_->next_debug_ticket;
  state_->command = State::Command::debug_disconnect;
  state_->cv.notify_all();
  if (!state_->cv.wait_for(lock, std::chrono::seconds(2), [&] {
        return state_->stopped || state_->completed_debug_ticket >= ticket;
      })) {
    throw TransportError("debugDisconnect timed out retiring the old socket");
  }
  if (state_->stopped) {
    throw Error("Live subscription is closed");
  }
}

#ifdef CONVEX_CLIENT_TESTING
std::vector<Update> Subscription::pending_updates_for_test() {
  std::lock_guard lock(state_->mutex);
  return {state_->queue.begin(), state_->queue.end()};
}
#endif
} // namespace convex
