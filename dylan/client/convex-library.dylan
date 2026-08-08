module: dylan-user

// This file, and only this file, is compiled with the bootstrap module
// dylan-user. Every other source file in this client declares
// "module: convex" and lives inside the single module defined below.
// Dylan's separate-compilation story is per-library, and this client is
// small enough that giving every layer (transport, JSON, HTTP, WebSocket,
// sync) its own module would mean writing "export" lists no reader would
// ever consult; one module keeps the layering visible in file names
// instead, which is where a reader actually looks for it.
define library convex
  use dylan;
  use common-dylan;
  use io;
  use c-ffi;
end library convex;

define module convex
  use dylan;
  use common-dylan;
  use format-out;
  use format;
  use streams;
  use standard-io;
  use c-ffi;
  use byte-vector;
end module convex;
