*> Records exchanged between the client, the example, and the adapter.
*> Callers own the storage, which keeps every large buffer in one
*> statically sized place instead of hidden inside the client.

*> A structured failure. Name is one of ConfigError, TransportError,
*> ProtocolError, FunctionError, or ClosedError, matching the shape the
*> shared adapter schema expects under "error".
01 CVX-ERROR.
   05 CVX-E-NAME            PIC X(32).
   05 CVX-E-NAME-LEN        BINARY-LONG.
   05 CVX-E-MSG             PIC X(1024).
   05 CVX-E-MSG-LEN         BINARY-LONG.
   *> Raw JSON span for errorData, or empty when Convex sent none.
   05 CVX-E-DATA            PIC X(8192).
   05 CVX-E-DATA-LEN        BINARY-LONG.

*> A successful value plus its log lines, both carried as raw JSON
*> spans so nothing is re-encoded on the way to an adapter event.
01 CVX-RESULT.
   05 CVX-R-VALUE           PIC X(2097152).
   05 CVX-R-VALUE-LEN       BINARY-LONG.
   05 CVX-R-LOGS            PIC X(65536).
   05 CVX-R-LOGS-LEN        BINARY-LONG.
   05 CVX-R-HAS-LOGS        BINARY-LONG.
   *> 1 when this delivery carries an error rather than a value.
   05 CVX-R-IS-ERROR        BINARY-LONG.
