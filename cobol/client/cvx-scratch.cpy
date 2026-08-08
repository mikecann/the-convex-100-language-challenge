*> One scratch region, shared by name across every program that COPYs
*> this member. EXTERNAL data is allocated once per run unit, not once
*> per program: two programs that both declare an item named
*> CVX-SHARED-SCRATCH with IS EXTERNAL are, by the COBOL standard,
*> referring to the very same storage. That is what lets convex-json.cbl's
*> one document slot occupy the adapter's own event-building buffer
*> instead of paying for a second 2 MiB region.
*>
*> Sized to the adapter's WS-EVT (2 MiB of value plus headroom for
*> boilerplate and up to 64 KiB of logs), the largest of the buffers
*> that redefine it. A smaller redefinition, such as convex-json.cbl's
*> WS-DOC-SRC, simply uses a leading slice.
*>
*> IMPORTANT: only ever redefine this with a buffer that is never
*> itself the *source* of a cvx-json-parse call whose *destination*
*> also redefines it. GnuCOBOL's generated code for a reference-
*> modified alphanumeric MOVE does not treat identical source and
*> destination addresses as a no-op the way the COBOL standard implies
*> it should; routing such a self-move through this shared region once
*> corrupted the very first byte read back out (a "hello" command's
*> own protocolVersion came back as something other than 1). Every
*> redefinition below is chosen so no consumer's copy into this region
*> is ever sourced from this same region.
01 CVX-SHARED-SCRATCH PIC X(2162688) IS EXTERNAL.
