#include "convex.hpp"
#include <boost/asio.hpp>
#include <cstdlib>
#include <cerrno>
#include <array>
#include <sstream>
#include <iostream>
#include <memory>
#include <map>
#include <mutex>
#include <system_error>
#include <thread>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>

using Json = nlohmann::json;
static std::mutex output_lock;
static void write_event(std::ostream& out, const Json& event) { std::lock_guard lock(output_lock); out << event.dump() << '\n' << std::flush; }
static Json error_event(const Json& command, const std::exception& error) { Json body{{"name", "Error"}, {"message", error.what()}}; Json event{{"type", "error"}, {"error", body}}; if (auto function = dynamic_cast<const convex::FunctionError*>(&error)) { event["error"]["name"] = "FunctionError"; event["error"]["data"] = function->data; event["logs"] = function->logs; } if (command.contains("id")) event["id"] = command["id"]; return event; }
static void run(std::istream& in, std::ostream& out) {
  std::unique_ptr<convex::Client> client;
  std::map<std::string, std::shared_ptr<convex::Subscription>> subscriptions;
  for (std::string line; std::getline(in, line);) {
    Json command;
    try {
      command = Json::parse(line); const auto id = command.value("id", ""); const auto operation = command.value("op", "");
      if (operation == "hello") { if (command.value("protocolVersion", 0) != 1) throw convex::Error("unsupported adapter protocol version"); write_event(out, {{"protocolVersion",1},{"id",id},{"type","ready"},{"language","cpp"},{"implementation","native-cpp-gcc-14.2.0"},{"runtime","native-cpp"}}); continue; }
      if (operation == "close") { for (auto& [_, sub] : subscriptions) sub->close(); if (client) client->close(); write_event(out, {{"id",id},{"type","closed"}}); return; }
      if (!client) { const char* url = std::getenv("CONVEX_URL"); if (!url) throw convex::Error("CONVEX_URL is required"); client = std::make_unique<convex::Client>(url, std::getenv("CONVEX_AUTH_TOKEN") ? std::getenv("CONVEX_AUTH_TOKEN") : ""); }
      if (operation == "query" || operation == "mutation" || operation == "action") { auto args = command.value("args", Json::object()); convex::Result result = operation == "query" ? client->query(command.at("path"), args) : operation == "mutation" ? client->mutation(command.at("path"), args) : client->action(command.at("path"), args); write_event(out, {{"id",id},{"type","result"},{"value",result.value},{"logs",result.logs}}); }
      else if (operation == "setAuth") { client->set_auth(command.value("token", "")); write_event(out, {{"id",id},{"type","ack"}}); }
      else if (operation == "debugDisconnect") { client->debug_disconnect_for_adapter(); write_event(out, {{"id",id},{"type","ack"}}); }
      else if (operation == "subscribe") { auto sub = client->subscribe(command.at("path"), command.value("args", Json::object())); subscriptions[command.at("subscriptionId")] = sub; write_event(out, {{"id",id},{"type","ack"}}); auto subscription_id = command.at("subscriptionId").get<std::string>(); std::thread([&out, sub, subscription_id] { while (auto update = sub->next_update(60000)) { if (!update->error.empty()) write_event(out, {{"type","subscription"},{"subscriptionId",subscription_id},{"error",{{"name",update->error_name},{"message",update->error},{"data",update->error_data}}},{"logs",update->logs}}); else write_event(out, {{"type","subscription"},{"subscriptionId",subscription_id},{"value",update->value},{"logs",update->logs}}); } }).detach(); }
      else if (operation == "unsubscribe") { auto key = command.at("subscriptionId").get<std::string>(); if (auto it = subscriptions.find(key); it != subscriptions.end()) { it->second->close(); subscriptions.erase(it); } write_event(out, {{"id",id},{"type","ack"}}); }
      else throw convex::Error("unknown adapter operation");
    } catch (const std::exception& error) { write_event(out, error_event(command, error)); }
  }
}
class SocketStreamBuf final : public std::streambuf {
 public:
  explicit SocketStreamBuf(boost::asio::ip::tcp::socket& socket) : socket_(socket) { setg(input_.data(), input_.data(), input_.data()); setp(output_.data(), output_.data() + output_.size()); }
  ~SocketStreamBuf() override { sync(); }
 protected:
  int_type underflow() override { ssize_t count; do { count = ::recv(socket_.native_handle(), input_.data(), input_.size(), 0); } while (count < 0 && errno == EINTR); if (count == 0) return traits_type::eof(); if (count < 0) throw std::system_error(errno, std::generic_category(), "adapter TCP read"); setg(input_.data(), input_.data(), input_.data() + count); return traits_type::to_int_type(*gptr()); }
  int_type overflow(int_type value) override { if (flush_output() != 0) return traits_type::eof(); if (!traits_type::eq_int_type(value, traits_type::eof())) { *pptr() = traits_type::to_char_type(value); pbump(1); } return value; }
  int sync() override { return flush_output(); }
 private:
  int flush_output() { auto count = pptr() - pbase(); char* next = pbase(); while (count > 0) { ssize_t sent; do { sent = ::send(socket_.native_handle(), next, static_cast<std::size_t>(count), MSG_NOSIGNAL); } while (sent < 0 && errno == EINTR); if (sent <= 0) return -1; next += sent; count -= sent; } setp(output_.data(), output_.data() + output_.size()); return 0; }
  boost::asio::ip::tcp::socket& socket_; std::array<char, 4096> input_{}; std::array<char, 4096> output_{};
};
int main() {
  const char* listen = std::getenv("ADAPTER_LISTEN");
  if (!listen || !*listen) { run(std::cin, std::cout); return 0; }
  try {
    std::string address(listen); auto separator = address.rfind(':');
    if (separator == std::string::npos) throw std::runtime_error("ADAPTER_LISTEN must be host:port");
    boost::asio::io_context io; boost::asio::ip::tcp::acceptor acceptor(io, {boost::asio::ip::make_address(address.substr(0, separator)), static_cast<unsigned short>(std::stoi(address.substr(separator + 1)))});
    std::cerr << "adapter listening on " << address << '\n'; boost::asio::ip::tcp::socket socket(io); acceptor.accept(socket);
    // Keep both stream and buffer state separate. The controller read blocks on
    // the main thread while subscription events are written by a worker thread.
    SocketStreamBuf input_buffer(socket), output_buffer(socket); std::istream input(&input_buffer); std::ostream output(&output_buffer); run(input, output); output.flush(); boost::system::error_code ignored; socket.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ignored); return 0;
  } catch (const std::exception& error) { std::cerr << "adapter TCP failure: " << error.what() << '\n'; return 1; }
}
