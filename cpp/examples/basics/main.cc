#include "convex.hpp"

#include <cstdlib>
#include <iostream>
#include <random>

// Give the mutation an idempotency key that is unique to this example run. If
// the request were retried, Convex could identify the same logical write.
static std::string run_id() {
  std::random_device random;
  return std::to_string(random()) + std::to_string(random());
}

int main(int argc, char **argv) {
  try {
    // Use the deployment selected by the verifier. This public counter does not
    // require authentication, so the example does not need an auth token.
    const char *url = std::getenv("CONVEX_URL");
    if (!url) {
      throw std::runtime_error("CONVEX_URL is required");
    }

    // Create the Convex client and select a unique room supplied by the shared
    // verifier. Both objects clean up their transports when they leave scope.
    convex::Client client(url);
    const std::string room = argc > 1 ? argv[1] : "cpp-example";

    // Query the current room over Convex's documented HTTP API, then decode its
    // JSON count into an ordinary, type-checked C++ integer.
    const auto current = client.query("demo:state", {{"room", room}});
    const int count = current.value.at("count").get<int>();
    if (count != 0) {
      throw std::runtime_error("initial HTTP count was not zero");
    }
    std::cout << "current count: " << count << '\n';

    // Start Live before the mutation so no state change can be missed. Its
    // initial value must agree with the HTTP query before we continue.
    auto subscription = client.subscribe("demo:state", {{"room", room}});
    const auto initial = subscription->next_update();
    if (!initial || !initial->error.empty() ||
        initial->value.at("count").get<int>() != count) {
      throw std::runtime_error("Live initial count differed from HTTP");
    }
    std::cout << "live initial count: " << count << '\n';

    // Apply one idempotent mutation over HTTP and require the expected 0 -> 1
    // result before trusting it or printing the next transcript lines.
    const auto mutation = client.mutation(
        "demo:increment",
        {{"room", room}, {"language", "cpp"}, {"runId", run_id()}});
    if (!mutation.value.at("applied").get<bool>()) {
      throw std::runtime_error("mutation was not applied");
    }
    std::cout << "mutation applied: true\n";

    const int changed = mutation.value.at("state").at("count").get<int>();
    if (changed != 1) {
      throw std::runtime_error("mutation count was not one");
    }
    std::cout << "mutation count: " << changed << '\n';

    // The next Live value must describe that same mutation. Only after HTTP and
    // Live agree do we report the universal happy-path verification line.
    const auto updated = subscription->next_update();
    if (!updated || !updated->error.empty() ||
        updated->value.at("count").get<int>() != changed) {
      throw std::runtime_error("Live update was unexpected");
    }
    std::cout << "live updated count: " << changed << '\n';
    subscription->close();

    std::cout << "verified count: " << count << " -> " << changed << '\n';
    client.close();
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
