#include "convex.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <cassert>
#include <chrono>
#include <future>
#include <thread>
#include <vector>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;
using Json = convex::Json;

namespace convex {
struct SubscriptionTestAccess {
  static std::vector<Update> pending(Subscription &subscription) {
    return subscription.pending_updates_for_test();
  }
};
} // namespace convex

static Json version(int timestamp, int query_set = 1) {
  return {{"querySet", query_set},
          {"identity", 0},
          {"ts", timestamp == 0 ? "AAAAAAAAAAA=" : std::to_string(timestamp)}};
}

static void send_transition(websocket::stream<tcp::socket> &websocket,
                            int start, int end, Json modification) {
  Json message{{"type", "Transition"},
               {"startVersion", version(start, start == 0 ? 0 : 1)},
               {"endVersion", version(end)},
               {"modifications", Json::array({std::move(modification)})}};
  websocket.write(asio::buffer(message.dump()));
}

static Json read_json(websocket::stream<tcp::socket> &websocket) {
  beast::flat_buffer buffer;
  websocket.read(buffer);
  return Json::parse(beast::buffers_to_string(buffer.data()));
}

int main() {
  constexpr unsigned short overflow_port = 32124;
  std::promise<void> overflow_ready;
  std::promise<void> updates_sent;
  std::atomic<bool> error_consumed = false;
  std::atomic<bool> remove_seen = false;
  std::thread overflow_server([&] {
    asio::io_context io;
    tcp::acceptor acceptor(
        io, {asio::ip::make_address("127.0.0.1"), overflow_port});
    overflow_ready.set_value();
    tcp::socket socket(io);
    acceptor.accept(socket);
    websocket::stream<tcp::socket> websocket(std::move(socket));
    websocket.accept();
    auto connect = read_json(websocket);
    auto add = read_json(websocket);
    assert(connect.at("connectionCount") == 0);
    assert(add.at("modifications").at(0).at("type") == "Add");
    send_transition(websocket, 0, 1,
                    {{"type", "QueryFailed"},
                     {"queryId", 0},
                     {"errorMessage", "empty room"},
                     {"errorData", {{"code", "ROOM_EMPTY"}}},
                     {"logLines", Json::array({"failed"})}});
    while (!error_consumed)
      std::this_thread::yield();
    for (int value = 0; value < 20; ++value) {
      send_transition(websocket, value + 1, value + 2,
                      {{"type", "QueryUpdated"},
                       {"queryId", 0},
                       {"value", {{"count", value}}},
                       {"logLines", Json::array()}});
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    updates_sent.set_value();
    auto remove = read_json(websocket);
    remove_seen = remove.at("baseVersion") == 1 &&
                  remove.at("newVersion") == 2 &&
                  remove.at("modifications").at(0).at("type") == "Remove";
  });
  overflow_ready.get_future().wait();
  convex::Client overflow_client("http://127.0.0.1:" +
                                 std::to_string(overflow_port));
  auto overflowing =
      overflow_client.subscribe("demo:state", {{"room", "test"}});
  auto failed = overflowing->next_update();
  assert(failed && failed->error_data.at("code") == "ROOM_EMPTY" &&
         failed->logs == std::vector<std::string>{"failed"});
  error_consumed = true;
  updates_sent.get_future().wait();
  for (;;) {
    auto pending = convex::SubscriptionTestAccess::pending(*overflowing);
    if (pending.size() == 16 && pending.back().value.at("count") == 19)
      break;
    std::this_thread::yield();
  }
  std::vector<int> values;
  while (auto update = overflowing->next_update(20))
    values.push_back(update->value.at("count"));
  assert(values.size() == 16 && values.front() == 4 && values.back() == 19);
  auto close_started = std::chrono::steady_clock::now();
  overflowing->close();
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));
  overflow_server.join();
  assert(remove_seen);
  overflow_client.close();

  constexpr unsigned short reconnect_port = 32125;
  std::promise<void> reconnect_ready;
  std::array<std::promise<void>, 5> rehydrated;
  std::array<std::promise<void>, 5> send_changed;
  std::vector<int> counts;
  std::vector<std::string> close_reasons;
  std::vector<std::string> observed_timestamps;
  std::thread reconnect_server([&] {
    asio::io_context io;
    tcp::acceptor acceptor(
        io, {asio::ip::make_address("127.0.0.1"), reconnect_port});
    reconnect_ready.set_value();
    for (int connection = 0; connection < 6; ++connection) {
      tcp::socket socket(io);
      acceptor.accept(socket);
      websocket::stream<tcp::socket> websocket(std::move(socket));
      websocket.accept();
      auto connect = read_json(websocket);
      auto add = read_json(websocket);
      counts.push_back(connect.at("connectionCount"));
      close_reasons.push_back(connect.at("lastCloseReason"));
      observed_timestamps.push_back(connect.value("maxObservedTimestamp", ""));
      assert(add.at("modifications").at(0).at("type") == "Add");

      // Reconnect first rehydrates the value already seen by the consumer.
      // The client must suppress it, then deliver only the later external
      // change.
      const int rehydrated_count = connection == 0 ? 0 : connection - 1;
      send_transition(websocket, 0, 1,
                      {{"type", "QueryUpdated"},
                       {"queryId", 0},
                       {"value", {{"count", rehydrated_count}}},
                       {"logLines", Json::array()}});
      if (connection > 0) {
        rehydrated.at(connection - 1).set_value();
        send_changed.at(connection - 1).get_future().wait();
        send_transition(websocket, 1, 2,
                        {{"type", "QueryUpdated"},
                         {"queryId", 0},
                         {"value", {{"count", connection}}},
                         {"logLines", Json::array()}});
        if (connection == 5) {
          // Deduplication applies only to the first reconnect rehydration. A
          // later same-value transition is still a real server event.
          send_transition(websocket, 2, 3,
                          {{"type", "QueryUpdated"},
                           {"queryId", 0},
                           {"value", {{"count", connection}}},
                           {"logLines", Json::array({"same value"})}});
        }
      }
      beast::flat_buffer buffer;
      beast::error_code ignored;
      websocket.read(buffer, ignored);
    }
  });
  reconnect_ready.get_future().wait();
  convex::Client reconnect_client("http://127.0.0.1:" +
                                  std::to_string(reconnect_port));
  auto reconnecting =
      reconnect_client.subscribe("demo:state", {{"room", "reconnect"}});
  auto initial_reconnect_value = reconnecting->next_update(5000);
  assert(initial_reconnect_value && initial_reconnect_value->error.empty());
  assert(initial_reconnect_value->value.at("count") == 0);
  for (int connection = 1; connection < 6; ++connection) {
    reconnect_client.debug_disconnect_for_adapter();
    rehydrated.at(connection - 1).get_future().wait();
    assert(!reconnecting->next_update(100));
    send_changed.at(connection - 1).set_value();
    auto update = reconnecting->next_update(5000);
    assert(update && update->error.empty());
    assert(update->value.at("count") == connection);
    if (connection == 5) {
      auto same_value = reconnecting->next_update(5000);
      assert(same_value && same_value->error.empty());
      assert(same_value->value.at("count") == connection);
      assert(same_value->logs == std::vector<std::string>{"same value"});
    }
  }
  reconnecting->close();
  reconnect_server.join();
  assert(counts == std::vector<int>({0, 1, 2, 3, 4, 5}));
  assert(close_reasons.front() == "InitialConnect");
  assert(std::all_of(
      close_reasons.begin() + 1, close_reasons.end(),
      [](const auto &reason) { return reason == "DebugDisconnect"; }));
  assert(observed_timestamps.front().empty());
  assert(observed_timestamps.at(1) == "1");
  assert(std::all_of(observed_timestamps.begin() + 2, observed_timestamps.end(),
                     [](const auto &timestamp) { return timestamp == "2"; }));
  reconnect_client.close();

  // A peer can stop midway through a WebSocket frame. Closing must cancel that
  // in-flight read instead of waiting forever for the rest of the payload.
  constexpr unsigned short partial_port = 32126;
  std::promise<void> partial_ready;
  std::promise<void> partial_sent;
  std::atomic<bool> partial_peer_closed = false;
  std::thread partial_server([&] {
    asio::io_context io;
    tcp::acceptor acceptor(io,
                           {asio::ip::make_address("127.0.0.1"), partial_port});
    partial_ready.set_value();
    tcp::socket socket(io);
    acceptor.accept(socket);
    websocket::stream<tcp::socket> websocket(std::move(socket));
    websocket.accept();
    read_json(websocket);
    read_json(websocket);
    const std::array<unsigned char, 3> partial_frame{0x81, 0x05, '{'};
    asio::write(websocket.next_layer(), asio::buffer(partial_frame));
    partial_sent.set_value();
    std::array<char, 128> incoming{};
    beast::error_code error;
    while (websocket.next_layer().read_some(asio::buffer(incoming), error) >
           0) {
    }
    partial_peer_closed =
        error == asio::error::eof || error == asio::error::connection_reset;
  });
  partial_ready.get_future().wait();
  convex::Client partial_client("http://127.0.0.1:" +
                                std::to_string(partial_port));
  auto partial = partial_client.subscribe("demo:state", {{"room", "partial"}});
  partial_sent.get_future().wait();
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  close_started = std::chrono::steady_clock::now();
  partial->close();
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));
  partial_server.join();
  assert(partial_peer_closed);
  partial_client.close();

  // Closing must also interrupt a peer that accepts TCP but never completes
  // the WebSocket handshake. Cancellation covers resolve, connect, TLS, and
  // WebSocket setup instead of relying on a cooperative peer timeout.
  constexpr unsigned short handshake_port = 32130;
  std::promise<void> handshake_ready;
  std::promise<void> handshake_accepted;
  std::atomic<bool> handshake_peer_closed = false;
  std::thread handshake_server([&] {
    asio::io_context io;
    tcp::acceptor acceptor(
        io, {asio::ip::make_address("127.0.0.1"), handshake_port});
    handshake_ready.set_value();
    tcp::socket socket(io);
    acceptor.accept(socket);
    handshake_accepted.set_value();
    std::array<char, 512> incoming{};
    beast::error_code error;
    while (socket.read_some(asio::buffer(incoming), error) > 0) {
    }
    handshake_peer_closed =
        error == asio::error::eof || error == asio::error::connection_reset;
  });
  handshake_ready.get_future().wait();
  convex::Client handshake_client("http://127.0.0.1:" +
                                  std::to_string(handshake_port));
  auto handshaking =
      handshake_client.subscribe("demo:state", {{"room", "handshake"}});
  handshake_accepted.get_future().wait();
  close_started = std::chrono::steady_clock::now();
  handshaking->close();
  assert(std::chrono::steady_clock::now() - close_started <
         std::chrono::seconds(2));
  handshake_server.join();
  assert(handshake_peer_closed);
  handshake_client.close();

  // Successful handshakes reset transient-failure backoff. Six peers that
  // accept the WebSocket and then vanish should reconnect at the base delay.
  constexpr unsigned short backoff_port = 32129;
  std::promise<void> backoff_ready;
  std::vector<std::chrono::steady_clock::time_point> accepted_at;
  std::thread backoff_server([&] {
    asio::io_context io;
    tcp::acceptor acceptor(io,
                           {asio::ip::make_address("127.0.0.1"), backoff_port});
    backoff_ready.set_value();
    for (int connection = 0; connection < 6; ++connection) {
      tcp::socket socket(io);
      acceptor.accept(socket);
      websocket::stream<tcp::socket> websocket(std::move(socket));
      websocket.accept();
      read_json(websocket);
      read_json(websocket);
      accepted_at.push_back(std::chrono::steady_clock::now());
      beast::error_code ignored;
      websocket.next_layer().shutdown(tcp::socket::shutdown_both, ignored);
      websocket.next_layer().close(ignored);
    }
  });
  backoff_ready.get_future().wait();
  convex::Client backoff_client("http://127.0.0.1:" +
                                std::to_string(backoff_port));
  auto backing_off =
      backoff_client.subscribe("demo:state", {{"room", "backoff"}});
  for (int failure = 0; failure < 6; ++failure) {
    auto update = backing_off->next_update(5000);
    assert(update && update->error_name == "TransportError");
  }
  backing_off->close();
  backoff_server.join();
  assert(accepted_at.size() == 6);
  assert(accepted_at.back() - accepted_at.front() < std::chrono::seconds(2));
  backoff_client.close();
}
