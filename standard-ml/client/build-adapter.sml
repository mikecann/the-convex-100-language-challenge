(* Compile the public client and its conformance entrypoint into one native
   executable, so the final image needs no Poly/ML source tree at run time. *)
use "client/sources.sml";
use "client/tests/conformance/adapter.sml";

fun main () = Adapter.main ();
