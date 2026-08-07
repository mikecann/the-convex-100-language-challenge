*> One 2 MiB scratch region, shared by name across every program that
*> COPYs this member. EXTERNAL data is allocated once per run unit,
*> not once per program: two programs that both declare an item named
*> CVX-SHARED-SCRATCH with IS EXTERNAL are, by the COBOL standard,
*> referring to the very same storage. That is what lets convex-json.cbl's
*> one document slot and the adapter's command/escape/event-building
*> scratch occupy the same physical 2 MiB instead of each program
*> multiplying a "just in case" 2 MiB buffer by however many programs
*> happen to link into the final executable -- the root cause of this
*> client exceeding the shared adapter memory-growth budget.
*>
*> Every consumer redefines this one item rather than reading or
*> writing CVX-SHARED-SCRATCH directly, and each redefinition's own
*> comment records why its content is always fully consumed before the
*> next consumer in sequence writes here.
01 CVX-SHARED-SCRATCH PIC X(2097152) IS EXTERNAL.
