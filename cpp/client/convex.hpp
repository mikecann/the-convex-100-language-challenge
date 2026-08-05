#pragma once

#include <nlohmann/json.hpp>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace convex {
using Json = nlohmann::json;

struct Error : std::runtime_error { using std::runtime_error::runtime_error; };
struct FunctionError : Error { Json data; std::vector<std::string> logs; FunctionError(std::string message, Json value, std::vector<std::string> lines) : Error(std::move(message)), data(std::move(value)), logs(std::move(lines)) {} };
struct Result { Json value; std::vector<std::string> logs; };
struct Update { Json value; std::vector<std::string> logs; std::string error; };
class Subscription {
 public:
  ~Subscription();
  std::optional<Update> next_update(int timeout_ms = 10000);
  void close();
  void debug_disconnect();
 private:
  friend class Client;
  explicit Subscription(std::string url, std::string path, Json args);
  struct State;
  std::shared_ptr<State> state_;
};

// This class owns Convex-specific request encoding and response decoding. Beast
// and OpenSSL are used only as ordinary HTTPS transport libraries.
class Client {
 public:
  explicit Client(std::string deployment_url, std::string token = "");
  Result query(const std::string& path, const Json& args = Json::object());
  Result mutation(const std::string& path, const Json& args = Json::object());
  Result action(const std::string& path, const Json& args = Json::object());
  std::shared_ptr<Subscription> subscribe(const std::string& path, const Json& args = Json::object());
  void set_auth(std::string token);
  void close();
  void debug_disconnect_for_adapter();
 private:
  Result call(const std::string& operation, const std::string& path, const Json& args);
  std::string url_, token_;
  std::vector<std::weak_ptr<Subscription>> subscriptions_;
  bool closed_ = false;
};
}
