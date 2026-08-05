#include "convex.hpp"
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>

using Json = nlohmann::json;
static std::mutex output_lock;
static void write_event(std::ostream& out, const Json& event) { std::lock_guard lock(output_lock); out << event.dump() << '\n' << std::flush; }
static Json error_event(const Json& command, const std::exception& error) { Json body{{"name", "Error"}, {"message", error.what()}}; if (auto function = dynamic_cast<const convex::FunctionError*>(&error)) body["data"] = function->data; Json event{{"type", "error"}, {"error", body}}; if (command.contains("id")) event["id"] = command["id"]; return event; }
static void run(std::istream& in, std::ostream& out) {
  std::unique_ptr<convex::Client> client;
  for (std::string line; std::getline(in, line);) {
    Json command;
    try {
      command = Json::parse(line); const auto id = command.value("id", ""); const auto operation = command.value("op", "");
      if (operation == "hello") { if (command.value("protocolVersion", 0) != 1) throw convex::Error("unsupported adapter protocol version"); write_event(out, {{"protocolVersion",1},{"id",id},{"type","ready"},{"language","cpp"},{"implementation","native-cpp-gcc-14.2.0"},{"runtime","native-cpp"}}); continue; }
      if (operation == "close") { if (client) client->close(); write_event(out, {{"id",id},{"type","closed"}}); return; }
      if (!client) { const char* url = std::getenv("CONVEX_URL"); if (!url) throw convex::Error("CONVEX_URL is required"); client = std::make_unique<convex::Client>(url, std::getenv("CONVEX_AUTH_TOKEN") ? std::getenv("CONVEX_AUTH_TOKEN") : ""); }
      if (operation == "query" || operation == "mutation" || operation == "action") { auto args = command.value("args", Json::object()); convex::Result result = operation == "query" ? client->query(command.at("path"), args) : operation == "mutation" ? client->mutation(command.at("path"), args) : client->action(command.at("path"), args); write_event(out, {{"id",id},{"type","result"},{"value",result.value},{"logs",result.logs}}); }
      else if (operation == "setAuth") { client->set_auth(command.value("token", "")); write_event(out, {{"id",id},{"type","ack"}}); }
      else if (operation == "debugDisconnect") { client->debug_disconnect_for_adapter(); write_event(out, {{"id",id},{"type","ack"}}); }
      else if (operation == "subscribe" || operation == "unsubscribe") { throw convex::Error("Live subscription is pending conformance"); }
      else throw convex::Error("unknown adapter operation");
    } catch (const std::exception& error) { write_event(out, error_event(command, error)); }
  }
}
int main() { run(std::cin, std::cout); }
