#include "convex.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/beast/websocket.hpp>
#include <atomic>
#include <cassert>
#include <chrono>
#include <future>
#include <thread>

namespace asio = boost::asio; namespace beast = boost::beast; namespace websocket = beast::websocket; using tcp = asio::ip::tcp; using Json = convex::Json;
static Json version(int ts, int query_set = 1) { return {{"querySet",query_set},{"identity",0},{"ts",ts == 0 ? "AAAAAAAAAAA=" : std::to_string(ts)}}; }
static void send_transition(websocket::stream<tcp::socket>& ws, int start, int end, Json modification) { Json message{{"type","Transition"},{"startVersion",version(start, start == 0 ? 0 : 1)},{"endVersion",version(end)},{"modifications",Json::array({std::move(modification)})}}; ws.write(asio::buffer(message.dump())); }
static Json read_json(websocket::stream<tcp::socket>& ws) { beast::flat_buffer buffer; ws.read(buffer); return Json::parse(beast::buffers_to_string(buffer.data())); }

int main() {
  constexpr unsigned short port = 32124; std::promise<void> ready; std::atomic<bool> error_consumed = false; std::atomic<bool> remove_seen = false;
  std::thread server([&] { asio::io_context io; tcp::acceptor acceptor(io, {asio::ip::make_address("127.0.0.1"), port}); ready.set_value(); tcp::socket socket(io); acceptor.accept(socket); websocket::stream<tcp::socket> ws(std::move(socket)); ws.accept(); auto connect = read_json(ws); auto add = read_json(ws); assert(connect.at("connectionCount") == 0); assert(add.at("modifications").at(0).at("type") == "Add"); send_transition(ws, 0, 1, {{"type","QueryFailed"},{"queryId",0},{"errorMessage","empty room"},{"errorData",{{"code","ROOM_EMPTY"}}},{"logLines",Json::array({"failed"})}}); while (!error_consumed) std::this_thread::yield(); for (int value = 0; value < 20; ++value) send_transition(ws, value + 1, value + 2, {{"type","QueryUpdated"},{"queryId",0},{"value",{{"count",value}}},{"logLines",Json::array()}}); auto remove = read_json(ws); remove_seen = remove.at("baseVersion") == 1 && remove.at("newVersion") == 2 && remove.at("modifications").at(0).at("type") == "Remove"; });
  ready.get_future().wait(); convex::Client client("http://127.0.0.1:" + std::to_string(port)); auto subscription = client.subscribe("demo:state", {{"room","test"}}); auto failed = subscription->next_update(); assert(failed && failed->error_data.at("code") == "ROOM_EMPTY" && failed->logs == std::vector<std::string>{"failed"}); error_consumed = true; std::this_thread::sleep_for(std::chrono::milliseconds(100)); std::vector<int> values; while (auto update = subscription->next_update(20)) values.push_back(update->value.at("count")); assert(values.size() == 16 && values.front() == 4 && values.back() == 19); auto started = std::chrono::steady_clock::now(); subscription->close(); assert(std::chrono::steady_clock::now() - started < std::chrono::seconds(2)); server.join(); assert(remove_seen); client.close();

  constexpr unsigned short reconnect_port = 32125; std::promise<void> reconnect_ready; std::vector<int> counts;
  std::thread reconnect_server([&] { asio::io_context io; tcp::acceptor acceptor(io, {asio::ip::make_address("127.0.0.1"), reconnect_port}); reconnect_ready.set_value(); for (int connection = 0; connection < 6; ++connection) { tcp::socket socket(io); acceptor.accept(socket); websocket::stream<tcp::socket> ws(std::move(socket)); ws.accept(); auto connect = read_json(ws); auto add = read_json(ws); counts.push_back(connect.at("connectionCount")); assert(add.at("modifications").at(0).at("type") == "Add"); send_transition(ws, 0, 1, {{"type","QueryUpdated"},{"queryId",0},{"value",{{"count",connection}}},{"logLines",Json::array()}}); beast::flat_buffer buffer; beast::error_code ignored; ws.read(buffer, ignored); } });
  reconnect_ready.get_future().wait(); convex::Client reconnect_client("http://127.0.0.1:" + std::to_string(reconnect_port)); auto reconnecting = reconnect_client.subscribe("demo:state", {{"room","reconnect"}}); for (int connection = 0; connection < 6; ++connection) { auto update = reconnecting->next_update(5000); assert(update && update->error.empty() && update->value.at("count") == connection); if (connection < 5) reconnect_client.debug_disconnect_for_adapter(); } reconnecting->close(); reconnect_server.join(); assert(counts == std::vector<int>({0,1,2,3,4,5})); reconnect_client.close();
}
