#define main convex_adapter_program_main
#include "adapter.cpp"
#undef main

#include <boost/beast/http.hpp>
#include <boost/beast/core/flat_buffer.hpp>
#include <cassert>
#include <chrono>
#include <sstream>

namespace adapter_test { namespace http = boost::beast::http; using tcp = boost::asio::ip::tcp;
void serve(unsigned short port) { boost::asio::io_context io; tcp::acceptor acceptor(io, {boost::asio::ip::make_address("127.0.0.1"), port}); for (int call = 0; call < 4; ++call) { tcp::socket socket(io); acceptor.accept(socket); boost::beast::flat_buffer buffer; http::request<http::string_body> request; http::read(socket, buffer, request); auto body = call < 3 ? Json{{"status","success"},{"value",{{"call",call}}},{"logLines",Json::array({"ok"})}} : Json{{"status","error"},{"errorMessage","empty room"},{"errorData",{{"code","ROOM_EMPTY"}}},{"logLines",Json::array({"failed"})}}; http::response<http::string_body> response{http::status::ok, 11}; response.body() = body.dump(); response.prepare_payload(); http::write(socket, response); } }
}

int main() {
  constexpr unsigned short port = 32126; std::thread fixture(adapter_test::serve, port); std::this_thread::sleep_for(std::chrono::milliseconds(50)); setenv("CONVEX_URL", "http://127.0.0.1:32126", 1);
  std::istringstream commands(
    "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n"
    "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}\n"
    "{\"id\":\"m\",\"op\":\"mutation\",\"path\":\"demo:increment\",\"args\":{}}\n"
    "{\"id\":\"a\",\"op\":\"action\",\"path\":\"demo:action\",\"args\":{}}\n"
    "{\"id\":\"e\",\"op\":\"query\",\"path\":\"demo:empty\",\"args\":{}}\n"
    "{\"id\":\"close\",\"op\":\"close\"}\n");
  std::ostringstream events; run(commands, events); fixture.join(); std::istringstream lines(events.str()); std::vector<Json> parsed; for (std::string line; std::getline(lines, line);) parsed.push_back(Json::parse(line)); assert(parsed.size() == 6); assert(parsed[0].at("type") == "ready"); for (int call = 0; call < 3; ++call) { assert(parsed[call + 1].at("type") == "result"); assert(parsed[call + 1].at("value").at("call") == call); assert(parsed[call + 1].at("logs").at(0) == "ok"); } assert(parsed[4].at("type") == "error"); assert(parsed[4].at("error").at("name") == "FunctionError"); assert(parsed[4].at("error").at("data").at("code") == "ROOM_EMPTY"); assert(parsed[4].at("logs").at(0) == "failed"); assert(parsed[5].at("type") == "closed");
}
