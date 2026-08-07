(*
** convex: the actual Convex client. Everything below this line is the
** demonstration: the HTTP envelope, the pinned sync protocol's message
** shapes, version/timestamp validation, and how a Live transition becomes
** a delivered update. convex_transport supplies bytes and convex_json
** supplies a value tree; this module supplies meaning.
*)

staload "./convex_json.sats"
staload "./convex_transport.sats"

(* ---- client and HTTP ---- *)

datatype client = Client of (string, str_opt)   (* normalized url, bearer token *)
datatype client_opt = CONone | COSome of client

fun new_client(url_in: string): client_opt
fun set_auth(token: string, c: client): client
fun clear_auth(c: client): client

datatype convex_error =
  | FunctionErr of (string, json, strlist)   (* message, errorData, logs *)
  | ProtocolErr of string
  | TransportErr of string

datatype call_result = CallOk of (json, strlist) | CallErr of convex_error

fun http_query(c: client, path: string, args: json): call_result
fun http_mutation(c: client, path: string, args: json): call_result
fun http_action(c: client, path: string, args: json): call_result

(* ---- Live ---- *)

datatype live_conn = LiveConn of sslconn

datatype active_sub = ActiveSub of (int, string, json, str_opt)  (* queryId, path, args, lastKey *)
datatype activelist = ALNil | ALCons of (active_sub, activelist)

datatype live_state = LiveState of (int, int, int, string, int, activelist)
  (* queryVersion, remoteQuerySet, remoteIdentity, remoteTs, nextId, active *)

datatype live_ok = LiveOkConn of (live_conn, live_state) | LiveErr of convex_error

fun live_connect(c: client): live_ok
fun live_close(conn: live_conn): void
fun live_fd(conn: live_conn): int

datatype live_change =
  | LiveValue of (int, json, strlist)          (* queryId, value, logs *)
  | LiveQueryError of (int, convex_error, strlist)

datatype changelist = CLNil | CLCons of (live_change, changelist)

datatype live_poll_result =
  | LiveTransition of (live_state, changelist)
  | LivePing
  | LiveIgnored
  | LiveWouldBlock
  | LiveProtocolError of string
  | LivePeerClosed

fun live_poll(conn: live_conn, st: live_state): live_poll_result

datatype add_result = AddOk of (int, live_state) | AddErr of string

fun live_add(conn: live_conn, st: live_state, path: string, args: json): add_result

fun live_remove(conn: live_conn, st: live_state, query_id: int): live_state

(* For debugDisconnect: every currently active (queryId, path, args,
   lastKey) so the adapter can reconnect and resubscribe them all,
   preserving each one's change-detection key so an unchanged rehydration
   after reconnect is not redelivered as a spurious update. *)
fun live_active_list(st: live_state): activelist

datatype resub_result = ResubOk of (int, live_state)  (* newQueryId, state *)

fun live_add_resubscribe(conn: live_conn, st: live_state, sub: active_sub): resub_result

fun error_message(e: convex_error): string
