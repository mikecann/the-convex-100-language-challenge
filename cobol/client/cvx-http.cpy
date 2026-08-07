*> Request description shared between the client and the HTTP module.
*> Passed by reference as one group item so the call sites stay legible
*> instead of threading a dozen positional arguments.

01 CVX-HTTP-REQ.
   05 CVX-HR-HOST           PIC X(256).
   05 CVX-HR-HOST-LEN       BINARY-LONG.
   05 CVX-HR-PORT           BINARY-LONG.
   *> 1 when the deployment URL was https, which selects TLS and the
   *> certificate identity check in the native layer.
   05 CVX-HR-SECURE         BINARY-LONG.
   05 CVX-HR-PATH           PIC X(256).
   05 CVX-HR-PATH-LEN       BINARY-LONG.
   05 CVX-HR-TOKEN          PIC X(4096).
   05 CVX-HR-TOKEN-LEN      BINARY-LONG.
   05 CVX-HR-CLIENTV        PIC X(64).
   05 CVX-HR-CLIENTV-LEN    BINARY-LONG.
   *> Absolute monotonic deadline in milliseconds. Every read, write,
   *> and connect inside one request shares it, so a slow peer cannot
   *> extend the total by stalling in several phases.
   05 CVX-HR-DEADLINE       BINARY-DOUBLE.
   *> Filled in on return.
   05 CVX-HR-CODE           BINARY-LONG.
