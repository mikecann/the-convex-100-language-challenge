*> Shared contract between the COBOL client and the reviewed native
*> extension in convex-native.c. Every value here mirrors a #define in
*> convex-native.h; the two files must be changed together, because a COBOL
*> program comparing against a stale code would misread a live return value
*> as success.
*>
*> Copy this into WORKING-STORAGE. Level-78 items are compile-time constants
*> and occupy no storage, so including it in several programs costs nothing.

*> Status codes returned by every cvx_* entry point.
78 CVX-OK                      VALUE 0.
78 CVX-ERR                     VALUE -1.
78 CVX-TIMEOUT                 VALUE -2.
78 CVX-EOF                     VALUE -3.
78 CVX-TLS                     VALUE -4.
78 CVX-HANDLE                  VALUE -5.
78 CVX-LIMIT                   VALUE -6.
78 CVX-AGAIN                   VALUE -7.

*> Handle-table bound in the native extension. Reaching it returns CVX-LIMIT
*> rather than growing the table, so the COBOL side must retire a handle
*> before opening another.
78 CVX-MAX-HANDLES             VALUE 16.
