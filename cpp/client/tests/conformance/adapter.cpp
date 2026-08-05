#include "convex.hpp"
#include <boost/asio.hpp>
#include <cstdlib>
#include <array>
#include <sstream>
#include <iostream>
#include <memory>
#include <map>
#include <mutex>
#include <thread>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>

using Json = nlohmann::json;
static std::mutex output_lock;
static void write_event(std::ostream& out, const Json& event) { std::lock_guard lock(output_lock); out << event.dump() << '\n' << std::flush; }
static Json error_event(const Json& command, const std::exception& error) { Json body{{"name", "Error"}, {"message", error.what()}}; if (auto function = dynamic_cast<const convex::FunctionError*>(&error)) body["data"] = function->data; Json event{{"type", "error"}, {"error", body}}; if (command.contains("id")) event["id"] = command["id"]; return event; }
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
      else if (operation == "subscribe") { auto sub = client->subscribe(command.at("path"), command.value("args", Json::object())); subscriptions[command.at("subscriptionId")] = sub; write_event(out, {{"id",id},{"type","ack"}}); auto subscription_id = command.at("subscriptionId").get<std::string>(); std::thread([&out, sub, subscription_id] { while (auto update = sub->next_update(60000)) { if (!update->error.empty()) write_event(out, {{"type","subscription"},{"subscriptionId",subscription_id},{"error",{{"name","FunctionError"},{"message",update->error}}}}); else write_event(out, {{"type","subscription"},{"subscriptionId",subscription_id},{"value",update->value},{"logs",update->logs}}); } }).detach(); }
      else if (operation == "unsubscribe") { auto key = command.at("subscriptionId").get<std::string>(); if (auto it = subscriptions.find(key); it != subscriptions.end()) { it->second->close(); subscriptions.erase(it); } write_event(out, {{"id",id},{"type","ack"}}); }
      else throw convex::Error("unknown adapter operation");
    } catch (const std::exception& error) { write_event(out, error_event(command, error)); }
  }
}
int main() {
  const char* listen = std::getenv("ADAPTER_LISTEN");
  if (!listen || !*listen) { run(std::cin, std::cout); return 0; }
  try {
    std::string address(listen); auto separator = address.rfind(':');
    if (separator == std::string::npos) throw std::runtime_error("ADAPTER_LISTEN must be host:port");
    boost::asio::io_context io; boost::asio::ip::tcp::acceptor acceptor(io, {boost::asio::ip::make_address(address.substr(0, separator)), static_cast<unsigned short>(std::stoi(address.substr(separator + 1)))});
    std::cerr << "adapter listening on " << address << '\n'; boost::asio::ip::tcp::socket socket(io); acceptor.accept(socket);
    // The controller sends a finite NDJSON command stream ending in `close`.
    // Accumulate partial socket reads until that complete command arrives, then
    // reuse the exact stdin handler and send its newline-delimited events back.
    std::string commands; std::array<char, 4096> chunk{};
    for (;;) { boost::system::error_code ec; auto count = socket.read_some(boost::asio::buffer(chunk), ec); if (count) commands.append(chunk.data(), count); if (commands.find("\"op\":\"close\"") != std::string::npos) break; if (ec == boost::asio::error::eof) break; if (ec) throw boost::system::system_error(ec); }
    std::istringstream input(commands); std::ostringstream output; run(input, output); boost::asio::write(socket, boost::asio::buffer(output.str())); boost::system::error_code ignored; socket.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ignored); return 0;
  } catch (const std::exception& error) { std::cerr << "adapter TCP failure: " << error.what() << '\n'; return 1; }
}
