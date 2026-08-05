#include "convex.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
using tcp = asio::ip::tcp;

static void serve_http_fixture(unsigned short port) {
  asio::io_context io;
  tcp::acceptor acceptor(io, {asio::ip::make_address("127.0.0.1"), port});
  for (int call = 0; call < 2; ++call) {
    tcp::socket socket(io);
    acceptor.accept(socket);
    beast::flat_buffer buffer;
    http::request<http::string_body> request;
    http::read(socket, buffer, request);
    auto body =
        call == 0
            ? R"({"status":"success","value":{"count":7},"logLines":["ok"]})"
            : R"({"status":"error","errorMessage":"empty room","errorData":{"code":"ROOM_EMPTY"},"logLines":["failed"]})";
    http::response<http::string_body> response{http::status::ok, 11};
    response.set(http::field::content_type, "application/json");
    response.body() = body;
    response.prepare_payload();
    http::write(socket, response);
  }
}

int main() {
  bool bad_url = false;
  try {
    convex::Client client("ftp://example.test");
  } catch (const convex::Error &) {
    bad_url = true;
  }
  assert(bad_url);
  constexpr unsigned short port = 32123;
  std::thread fixture(serve_http_fixture, port);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  convex::Client http_client("http://127.0.0.1:" + std::to_string(port));
  auto result = http_client.query("demo:state", {{"room", "test"}});
  assert(result.value.at("count") == 7);
  assert(result.logs == std::vector<std::string>{"ok"});
  bool structured = false;
  try {
    http_client.query("demo:empty", convex::Json::object());
  } catch (const convex::FunctionError &error) {
    structured = error.data.at("code") == "ROOM_EMPTY" &&
                 error.logs == std::vector<std::string>{"failed"};
  }
  assert(structured);
  fixture.join();
  convex::Client client("https://example.test");
  bool bad_args = false;
  try {
    client.query("demo:state", 1);
  } catch (const convex::Error &) {
    bad_args = true;
  }
  assert(bad_args);
  client.close();
  bool closed = false;
  try {
    client.query("demo:state", convex::Json::object());
  } catch (const convex::Error &) {
    closed = true;
  }
  assert(closed);
  std::cout << "client tests passed\n";
}
