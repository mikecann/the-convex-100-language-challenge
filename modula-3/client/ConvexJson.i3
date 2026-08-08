(* ConvexJson - a minimal JSON value representation, encoder, and parser.
   This is generic JSON support, not Convex protocol knowledge: the rest
   of the client (ConvexHttp, ConvexLive) builds and reads ConvexJson.T
   values, but this interface has no idea what a query, mutation, or
   subscription is. *)
INTERFACE ConvexJson;

TYPE
  Kind = {Null, False, True, Number, Str, Arr, Obj};

  (* T is only partially revealed here: callers can read "kind" (useful
     for a generic value-forwarding walk, e.g. the conformance adapter),
     but the payload fields behind each kind are hidden and reachable
     only through the accessors below. *)
  Public = OBJECT
             kind: Kind;
           END;
  T <: Public;

EXCEPTION Error(TEXT);

(* -- constructors -------------------------------------------------- *)

PROCEDURE NewNull(): T;
PROCEDURE NewBool(b: BOOLEAN): T;

(* A JSON number that prints without a decimal point when it is a
   mathematical integer in range, matching how Convex itself spells a
   whole count ("1", not "1.0"). *)
PROCEDURE NewInt(n: INTEGER): T;

(* A JSON number that always prints with a decimal point, even when the
   value happens to be a whole number (Convex sometimes spells a whole
   count this way too, e.g. "0.0"; ConvexJson.NumOf accepts either). *)
PROCEDURE NewFloat(n: LONGREAL): T;

PROCEDURE NewString(s: TEXT): T;

(* A new, empty, growable array. Use ArrayAppend to add elements. *)
PROCEDURE NewArray(): T;

(* A new, empty object. Keys are kept in insertion order; ObjectSet on
   an existing key replaces its value in place without moving it. *)
PROCEDURE NewObject(): T;

(* -- array / object mutation and access ------------------------------ *)

PROCEDURE ArrayAppend(a: T; v: T);
PROCEDURE ArrayLen(a: T): CARDINAL;
PROCEDURE ArrayGet(a: T; i: CARDINAL): T;

PROCEDURE ObjectSet(o: T; key: TEXT; v: T);
(* NIL if "key" is absent. *)
PROCEDURE ObjectGet(o: T; key: TEXT): T;
PROCEDURE ObjectHas(o: T; key: TEXT): BOOLEAN;
(* The number of entries and the key at position "i", for iterating an
   object's fields in insertion order (used by the adapter, which must
   forward arbitrary Convex values without knowing their shape). *)
PROCEDURE ObjectLen(o: T): CARDINAL;
PROCEDURE ObjectKeyAt(o: T; i: CARDINAL): TEXT;

(* -- scalar accessors, all RAISE Error on a kind mismatch ------------- *)

PROCEDURE IsNull(v: T): BOOLEAN;
PROCEDURE BoolOf(v: T): BOOLEAN RAISES {Error};
PROCEDURE NumOf(v: T): LONGREAL RAISES {Error};
PROCEDURE StrOf(v: T): TEXT RAISES {Error};

(* -- whole encode / decode -------------------------------------------- *)

PROCEDURE Encode(v: T): TEXT;
PROCEDURE Decode(s: TEXT): T RAISES {Error};

END ConvexJson.
