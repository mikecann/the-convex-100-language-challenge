module c3_adapter;

import std::io;

// This is deliberately the smallest C3-owned adapter seed. Subsequent
// milestones add the strict NDJSON command dispatcher and client calls here;
// no Convex protocol work is delegated to the C transport shim.
fn void main()
{
    io::printn("c3 adapter seed");
}
