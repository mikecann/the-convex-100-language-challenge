#include "convex.hpp"
#include <cassert>
#include <iostream>
int main() {
  bool bad_url = false; try { convex::Client client("ftp://example.test"); } catch (const convex::Error&) { bad_url = true; } assert(bad_url);
  convex::Client client("https://example.test"); bool bad_args = false; try { client.query("demo:state", 1); } catch (const convex::Error&) { bad_args = true; } assert(bad_args);
  client.close(); bool closed = false; try { client.query("demo:state", {}); } catch (const convex::Error&) { closed = true; } assert(closed); std::cout << "client tests passed\n";
}
