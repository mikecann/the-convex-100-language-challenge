module c3_adapter;

import std::io;
import c3_http;
import c3_values;
import c3_response;

// This is deliberately the smallest C3-owned adapter seed. Subsequent
// milestones add the strict NDJSON command dispatcher and client calls here;
// no Convex protocol work is delegated to the C transport shim.
fn void main()
{
    // Keep the transport boundary compiled while the command dispatcher grows.
    io::printn("c3 adapter seed");
}
