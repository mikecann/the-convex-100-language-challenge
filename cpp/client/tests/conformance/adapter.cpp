#include "convex.hpp"

#include <boost/asio.hpp>

#include <array>
#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <sys/socket.h>
#include <system_error>
#include <thread>
#include <unistd.h>

using Json = nlohmann::json;

namespace {
std::mutex output_lock;

void write_event(std::ostream &output, const Json &event) {
  std::lock_guard lock(output_lock);
  output << event.dump() << '\n' << std::flush;
}

Json error_event(const Json &command, const std::exception &error) {
  Json body{{"name", "Error"}, {"message", error.what()}};
  Json event{{"type", "error"}, {"error", body}};
  if (const auto *function =
          dynamic_cast<const convex::FunctionError *>(&error)) {
    event["error"]["name"] = "FunctionError";
    event["error"]["data"] = function->data;
    event["logs"] = function->logs;
  } else if (dynamic_cast<const convex::ProtocolError *>(&error)) {
    event["error"]["name"] = "ProtocolError";
  } else if (dynamic_cast<const convex::TransportError *>(&error)) {
    event["error"]["name"] = "TransportError";
  }
  if (command.contains("id")) {
    event["id"] = command["id"];
  }
  return event;
}

Json subscription_event(const std::string &subscription_id,
                        const convex::Update &update) {
  Json event{{"type", "subscription"},
             {"subscriptionId", subscription_id},
             {"logs", update.logs}};
  if (!update.error.empty()) {
    event["error"] = {{"name", update.error_name},
                      {"message", update.error},
                      {"data", update.error_data}};
  } else {
    event["value"] = update.value;
  }
  return event;
}

#ifdef CONVEX_ADAPTER_TESTING
struct RelayTestPause {
  std::mutex mutex;
  std::condition_variable cv;
  bool enabled = false;
  bool reached = false;
  bool released = false;
};

RelayTestPause relay_test_pause;

void pause_relay_after_dequeue_for_test() {
  std::unique_lock lock(relay_test_pause.mutex);
  if (!relay_test_pause.enabled) {
    return;
  }
  relay_test_pause.reached = true;
  relay_test_pause.cv.notify_all();
  relay_test_pause.cv.wait(lock, [] { return relay_test_pause.released; });
}
#else
void pause_relay_after_dequeue_for_test() {}
#endif

// A relay gate is invalidated before unsubscribe or replacement is
// acknowledged. Holding its mutex through the write means an already-dequeued
// update either finishes before invalidation or is discarded after it. It can
// never cross the acknowledgement.
struct RelayGate {
  std::mutex mutex;
  bool active = true;

  void invalidate() {
    std::lock_guard lock(mutex);
    active = false;
  }

  bool write_if_active(std::ostream &output, const Json &event) {
    pause_relay_after_dequeue_for_test();
    std::lock_guard lock(mutex);
    if (!active) {
      return false;
    }
    write_event(output, event);
    return true;
  }
};

class SubscriptionRelay {
public:
  SubscriptionRelay(std::shared_ptr<convex::Subscription> subscription,
                    std::string subscription_id, std::ostream &output)
      : subscription_(std::move(subscription)),
        subscription_id_(std::move(subscription_id)), output_(output),
        gate_(std::make_shared<RelayGate>()) {}

  SubscriptionRelay(const SubscriptionRelay &) = delete;
  SubscriptionRelay &operator=(const SubscriptionRelay &) = delete;

  ~SubscriptionRelay() { stop(); }

  void start() {
    worker_ = std::thread([this, gate = gate_] {
      while (auto update = subscription_->next_update(60000)) {
        if (!gate->write_if_active(
                output_, subscription_event(subscription_id_, *update))) {
          return;
        }
      }
    });
  }

  void stop() {
    if (!gate_) {
      return;
    }
    gate_->invalidate();
    subscription_->close();
    if (worker_.joinable()) {
      worker_.join();
    }
    gate_.reset();
  }

private:
  std::shared_ptr<convex::Subscription> subscription_;
  std::string subscription_id_;
  std::ostream &output_;
  std::shared_ptr<RelayGate> gate_;
  std::thread worker_;
};

void stop_relay(
    std::map<std::string, std::unique_ptr<SubscriptionRelay>> &subscriptions,
    const std::string &key) {
  const auto iterator = subscriptions.find(key);
  if (iterator == subscriptions.end()) {
    return;
  }
  iterator->second->stop();
  subscriptions.erase(iterator);
}

void run(std::istream &input, std::ostream &output) {
  std::unique_ptr<convex::Client> client;
  std::map<std::string, std::unique_ptr<SubscriptionRelay>> subscriptions;

  for (std::string line; std::getline(input, line);) {
    Json command;
    try {
      command = Json::parse(line);
      const auto id = command.value("id", "");
      const auto operation = command.value("op", "");

      if (operation == "hello") {
        if (command.value("protocolVersion", 0) != 1) {
          throw convex::Error("unsupported adapter protocol version");
        }
        write_event(output, {{"protocolVersion", 1},
                             {"id", id},
                             {"type", "ready"},
                             {"language", "cpp"},
                             {"implementation", "native-cpp-gcc-14.2.0"},
                             {"runtime", "native-cpp"}});
        continue;
      }

      if (operation == "close") {
        while (!subscriptions.empty()) {
          stop_relay(subscriptions, subscriptions.begin()->first);
        }
        if (client) {
          client->close();
        }
        write_event(output, {{"id", id}, {"type", "closed"}});
        return;
      }

      if (!client) {
        const char *url = std::getenv("CONVEX_URL");
        if (!url) {
          throw convex::Error("CONVEX_URL is required");
        }
        const char *token = std::getenv("CONVEX_AUTH_TOKEN");
        client = std::make_unique<convex::Client>(url, token ? token : "");
      }

      if (operation == "query" || operation == "mutation" ||
          operation == "action") {
        const auto args = command.value("args", Json::object());
        convex::Result result = operation == "query"
                                    ? client->query(command.at("path"), args)
                                : operation == "mutation"
                                    ? client->mutation(command.at("path"), args)
                                    : client->action(command.at("path"), args);
        write_event(output, {{"id", id},
                             {"type", "result"},
                             {"value", result.value},
                             {"logs", result.logs}});
      } else if (operation == "setAuth") {
        client->set_auth(command.value("token", ""));
        write_event(output, {{"id", id}, {"type", "ack"}});
      } else if (operation == "debugDisconnect") {
        client->debug_disconnect_for_adapter();
        write_event(output, {{"id", id}, {"type", "ack"}});
      } else if (operation == "subscribe") {
        const auto subscription_id =
            command.at("subscriptionId").get<std::string>();
        auto subscription = client->subscribe(
            command.at("path"), command.value("args", Json::object()));
        auto relay = std::make_unique<SubscriptionRelay>(
            std::move(subscription), subscription_id, output);

        // Replacing an ID retires and joins the old relay before publishing the
        // new acknowledgement. The old worker cannot leak an event afterward.
        stop_relay(subscriptions, subscription_id);
        subscriptions[subscription_id] = std::move(relay);
        write_event(output, {{"id", id}, {"type", "ack"}});
        subscriptions.at(subscription_id)->start();
      } else if (operation == "unsubscribe") {
        const auto key = command.at("subscriptionId").get<std::string>();
        stop_relay(subscriptions, key);
        write_event(output, {{"id", id}, {"type", "ack"}});
      } else {
        throw convex::Error("unknown adapter operation");
      }
    } catch (const std::exception &error) {
      write_event(output, error_event(command, error));
    }
  }

  // EOF is also shutdown. Join relay threads before `output` can be destroyed.
  while (!subscriptions.empty()) {
    stop_relay(subscriptions, subscriptions.begin()->first);
  }
  if (client) {
    client->close();
  }
}

class SocketStreamBuf final : public std::streambuf {
public:
  explicit SocketStreamBuf(boost::asio::ip::tcp::socket &socket)
      : socket_(socket) {
    setg(input_.data(), input_.data(), input_.data());
    setp(output_.data(), output_.data() + output_.size());
  }

  ~SocketStreamBuf() override { sync(); }

protected:
  int_type underflow() override {
    ssize_t count;
    do {
      count = ::recv(socket_.native_handle(), input_.data(), input_.size(), 0);
    } while (count < 0 && errno == EINTR);
    if (count == 0) {
      return traits_type::eof();
    }
    if (count < 0) {
      throw std::system_error(errno, std::generic_category(),
                              "adapter TCP read");
    }
    setg(input_.data(), input_.data(), input_.data() + count);
    return traits_type::to_int_type(*gptr());
  }

  int_type overflow(int_type value) override {
    if (flush_output() != 0) {
      return traits_type::eof();
    }
    if (!traits_type::eq_int_type(value, traits_type::eof())) {
      *pptr() = traits_type::to_char_type(value);
      pbump(1);
    }
    return value;
  }

  int sync() override { return flush_output(); }

private:
  int flush_output() {
    auto count = pptr() - pbase();
    char *next = pbase();
    while (count > 0) {
      ssize_t sent;
      do {
        sent = ::send(socket_.native_handle(), next,
                      static_cast<std::size_t>(count), MSG_NOSIGNAL);
      } while (sent < 0 && errno == EINTR);
      if (sent <= 0) {
        return -1;
      }
      next += sent;
      count -= sent;
    }
    setp(output_.data(), output_.data() + output_.size());
    return 0;
  }

  boost::asio::ip::tcp::socket &socket_;
  std::array<char, 4096> input_{};
  std::array<char, 4096> output_{};
};
} // namespace

#ifndef CONVEX_ADAPTER_NO_MAIN
int main() {
  const char *listen = std::getenv("ADAPTER_LISTEN");
  if (!listen || !*listen) {
    run(std::cin, std::cout);
    return 0;
  }

  try {
    std::string address(listen);
    const auto separator = address.rfind(':');
    if (separator == std::string::npos) {
      throw std::runtime_error("ADAPTER_LISTEN must be host:port");
    }

    boost::asio::io_context io;
    boost::asio::ip::tcp::acceptor acceptor(
        io, {boost::asio::ip::make_address(address.substr(0, separator)),
             static_cast<unsigned short>(
                 std::stoi(address.substr(separator + 1)))});
    std::cerr << "adapter listening on " << address << '\n';
    boost::asio::ip::tcp::socket socket(io);
    acceptor.accept(socket);

    // Keep both stream and buffer state separate. The controller read blocks on
    // the main thread while subscription events are written by a relay thread.
    SocketStreamBuf input_buffer(socket);
    SocketStreamBuf output_buffer(socket);
    std::istream input(&input_buffer);
    std::ostream output(&output_buffer);
    run(input, output);
    output.flush();

    boost::system::error_code ignored;
    socket.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ignored);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "adapter TCP failure: " << error.what() << '\n';
    return 1;
  }
}
#endif
