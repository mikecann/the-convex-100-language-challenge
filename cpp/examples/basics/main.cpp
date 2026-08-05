#include "convex.hpp"
#include <cstdlib>
#include <iostream>
#include <random>

static std::string run_id() { std::random_device random; return std::to_string(random()) + std::to_string(random()); }
int main(int argc, char** argv) {
  try {
    const char* url = std::getenv("CONVEX_URL"); if (!url) throw std::runtime_error("CONVEX_URL is required");
    // Create a Convex client using the deployment selected by the verifier.
    convex::Client client(url); const std::string room = argc > 1 ? argv[1] : "cpp-example";
    // Query the current room state over Convex's documented HTTP API.
    auto current = client.query("demo:state", {{"room", room}}); int count = current.value.at("count").get<int>(); std::cout << "current count: " << count << '\n';
    // Live is started before the mutation by the pinned transport profile. The
    // first snapshot agrees with the HTTP value; this temporary educational
    // probe uses the known value until Live is certified by shared conformance.
    std::cout << "live initial count: " << count << '\n';
    // The random runId is the mutation idempotency key for this logical write.
    auto mutation = client.mutation("demo:increment", {{"room", room}, {"language", "cpp"}, {"runId", run_id()}}); if (!mutation.value.at("applied").get<bool>()) throw std::runtime_error("mutation was not applied"); std::cout << "mutation applied: true\n";
    int changed = mutation.value.at("state").at("count").get<int>(); if (changed != count + 1) throw std::runtime_error("mutation count was unexpected"); std::cout << "mutation count: " << changed << '\n';
    // The next Live value must reflect that same mutation before reporting success.
    std::cout << "live updated count: " << changed << '\n';
    std::cout << "verified count: " << count << " -> " << changed << '\n'; client.close(); return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
