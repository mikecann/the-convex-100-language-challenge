(* The client in dependency order.
   Every executable and every test loads exactly this list, so the canonical
   example, the conformance adapter, and the language-local tests can never
   drift onto different implementations. *)

use "client/prelude.sml";
use "client/json.sml";
use "client/error.sml";
use "client/digest.sml";
use "client/openssl.sml";
use "client/transport.sml";
use "client/http.sml";
use "client/websocket.sml";
use "client/live.sml";
use "client/convex.sml";
