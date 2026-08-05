#include "convex.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <cassert>
#include <chrono>
#include <future>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;
using Json = convex::Json;

static Json version(int timestamp, int query_set = 1) {
  return {{"querySet", query_set},
          {"identity", 0},
          {"ts", timestamp == 0 ? "AAAAAAAAAAA=" : std::to_string(timestamp)}};
}

static Json read_websocket_json(websocket::stream<tcp::socket> &websocket) {
  beast::flat_buffer buffer;
  websocket.read(buffer);
  return Json::parse(beast::buffers_to_string(buffer.data()));
}

static void send_transition(websocket::stream<tcp::socket> &websocket,
                            int start, int end, Json modification) {
  Json message{{"type", "Transition"},
               {"startVersion", version(start, start == 0 ? 0 : 1)},
               {"endVersion", version(end)},
               {"modifications", Json::array({std::move(modification)})}};
  websocket.write(asio::buffer(message.dump()));
}

static Json read_controller_line(tcp::socket &socket, asio::streambuf &buffer) {
  asio::read_until(socket, buffer, '\n');
  std::istream input(&buffer);
  std::string text;
  std::getline(input, text);
  return Json::parse(text);
}

static void send_controller_line(tcp::socket &socket, Json command) {
  auto text = command.dump() + "\n";
  asio::write(socket, asio::buffer(text));
}

int main() {
  constexpr unsigned short websocket_port = 32127;
  constexpr unsigned short controller_port = 32128;
  std::promise<void> fixture_ready;
  std::promise<void> send_failure;
  std::promise<void> send_recovery;
  std::promise<void> send_malformed;
  auto failure_signal = send_failure.get_future();
  auto recovery_signal = send_recovery.get_future();
  auto malformed_signal = send_malformed.get_future();

  std::thread fixture([&] {
    asio::io_context io;
    tcp::acceptor acceptor(
        io, {asio::ip::make_address("127.0.0.1"), websocket_port});
    fixture_ready.set_value();
    for (int connection = 0; connection < 3; ++connection) {
      tcp::socket socket(io);
      acceptor.accept(socket);
      websocket::stream<tcp::socket> websocket(std::move(socket));
      websocket.accept();
      auto connect = read_websocket_json(websocket);
      auto add = read_websocket_json(websocket);
      assert(connect.at("connectionCount") == connection);
      assert(add.at("modifications").at(0).at("type") == "Add");

      send_transition(websocket, 0, 1,
                      {{"type", "QueryUpdated"},
                       {"queryId", 0},
                       {"value", {{"count", connection}}},
                       {"logLines", Json::array()}});
      if (connection == 0) {
        failure_signal.wait();
        send_transition(websocket, 1, 2,
                        {{"type", "QueryFailed"},
                         {"queryId", 0},
                         {"errorMessage", "empty"},
                         {"errorData", {{"code", "ROOM_EMPTY"}}},
                         {"logLines", Json::array({"failed"})}});
        recovery_signal.wait();
        send_transition(websocket, 2, 3,
                        {{"type", "QueryUpdated"},
                         {"queryId", 0},
                         {"value", {{"count", 10}}},
                         {"logLines", Json::array({"recovered"})}});
      } else if (connection == 1) {
        malformed_signal.wait();
        // A Transition with a missing endVersion exercises schema validation,
        // not merely the explicit unknown-message branch.
        Json malformed{{"type", "Transition"},
                       {"startVersion", version(1)},
                       {"modifications", Json::array()}};
        websocket.write(asio::buffer(malformed.dump()));
      }

      beast::flat_buffer buffer;
      beast::error_code error;
      websocket.read(buffer, error);
      if (connection == 2 && !error) {
        auto remove = Json::parse(beast::buffers_to_string(buffer.data()));
        assert(remove.at("baseVersion") == 1);
        assert(remove.at("newVersion") == 2);
        assert(remove.at("modifications").at(0).at("type") == "Remove");
      }
    }
  });

  fixture_ready.get_future().wait();
  pid_t adapter = fork();
  if (adapter == 0) {
    setenv("CONVEX_URL", "http://127.0.0.1:32127", 1);
    setenv("ADAPTER_LISTEN", "127.0.0.1:32128", 1);
    execl("/out/convex-adapter", "convex-adapter", nullptr);
    _exit(127);
  }

  asio::io_context io;
  tcp::socket controller(io);
  bool connected = false;
  for (int attempt = 0; attempt < 100; ++attempt) {
    beast::error_code error;
    controller.connect({asio::ip::make_address("127.0.0.1"), controller_port},
                       error);
    if (!error) {
      connected = true;
      break;
    }
    controller.close(error);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  assert(connected);

  asio::streambuf buffer;
  send_controller_line(
      controller, {{"protocolVersion", 1}, {"id", "hello"}, {"op", "hello"}});
  assert(read_controller_line(controller, buffer).at("type") == "ready");
  send_controller_line(controller, {{"id", "subscribe"},
                                    {"op", "subscribe"},
                                    {"subscriptionId", "room"},
                                    {"path", "demo:state"},
                                    {"args", Json::object()}});
  assert(read_controller_line(controller, buffer).at("type") == "ack");

  auto initial = read_controller_line(controller, buffer);
  assert(initial.at("subscriptionId") == "room");
  assert(initial.at("value").at("count") == 0);
  send_failure.set_value();
  auto failed = read_controller_line(controller, buffer);
  assert(failed.at("subscriptionId") == "room");
  assert(failed.at("error").at("name") == "FunctionError");
  assert(failed.at("error").at("message") == "empty");
  assert(failed.at("error").at("data").at("code") == "ROOM_EMPTY");
  assert(failed.at("logs") == Json::array({"failed"}));
  send_recovery.set_value();
  auto recovered = read_controller_line(controller, buffer);
  assert(recovered.at("value").at("count") == 10);
  assert(recovered.at("logs") == Json::array({"recovered"}));

  send_controller_line(controller,
                       {{"id", "disconnect"}, {"op", "debugDisconnect"}});
  auto disconnect = read_controller_line(controller, buffer);
  assert(disconnect.at("id") == "disconnect" && disconnect.at("type") == "ack");
  auto reconnected = read_controller_line(controller, buffer);
  assert(reconnected.at("value").at("count") == 1);
  send_malformed.set_value();
  auto protocol_error = read_controller_line(controller, buffer);
  assert(protocol_error.at("error").at("name") == "ProtocolError");
  auto protocol_recovery = read_controller_line(controller, buffer);
  assert(protocol_recovery.at("value").at("count") == 2);

  send_controller_line(controller, {{"id", "unsubscribe"},
                                    {"op", "unsubscribe"},
                                    {"subscriptionId", "room"}});
  auto unsubscribe = read_controller_line(controller, buffer);
  assert(unsubscribe.at("id") == "unsubscribe" &&
         unsubscribe.at("type") == "ack");
  auto close_started = std::chrono::steady_clock::now();
  send_controller_line(controller, {{"id", "close"}, {"op", "close"}});
  auto closed = read_controller_line(controller, buffer);
  assert(closed.at("id") == "close" && closed.at("type") == "closed");
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));

  fixture.join();
  int status;
  waitpid(adapter, &status, 0);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
