#define CONVEX_ADAPTER_NO_MAIN
#define CONVEX_ADAPTER_TESTING
#include "adapter.cpp"

#include <cassert>
#include <sstream>

int main() {
  std::ostringstream events;
  RelayGate gate;
  relay_test_pause.enabled = true;

  bool delivered = true;
  std::thread relay([&] {
    delivered = gate.write_if_active(events, {{"type", "subscription"},
                                              {"subscriptionId", "room"},
                                              {"value", {{"count", 1}}},
                                              {"logs", Json::array()}});
  });

  // Pause after dequeue, invalidate the old generation, and publish the ack.
  // Releasing the relay afterward must not let its stale value cross the ack.
  {
    std::unique_lock lock(relay_test_pause.mutex);
    relay_test_pause.cv.wait(lock, [] { return relay_test_pause.reached; });
  }
  gate.invalidate();
  write_event(events, {{"id", "unsubscribe"}, {"type", "ack"}});
  {
    std::lock_guard lock(relay_test_pause.mutex);
    relay_test_pause.released = true;
    relay_test_pause.cv.notify_all();
  }
  relay.join();

  assert(!delivered);
  std::string line;
  std::istringstream output(events.str());
  assert(std::getline(output, line));
  const auto event = Json::parse(line);
  assert(event.at("id") == "unsubscribe");
  assert(event.at("type") == "ack");
  assert(!std::getline(output, line));

  // Keep the included adapter lifecycle compiled in this test translation too.
  std::istringstream empty_input;
  std::ostringstream empty_output;
  run(empty_input, empty_output);
}
