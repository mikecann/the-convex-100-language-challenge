(* The canonical Convex-from-Standard-ML example.

   It proves one shared counter goes from 0 to 1 and that three independent
   views of that change agree: the HTTP query, the mutation's own result, and
   the reactive Live update. *)

structure Example =
struct
  (* Generic JSON arrives as a Json.value. Narrow it to the non-negative
     integer this program's output contract needs, and say which step failed if
     it is anything else. *)
  fun exampleCount (value, step) =
    case Json.asInt (Json.getOr (value, "count", Json.Null)) of
        SOME count =>
          if count >= 0 andalso count <= 9223372036854775807 then count
          else raise Fail (step ^ " returned an out-of-range count")
      | NONE => raise Fail (step ^ " returned a non-integral count")

  (* runId is the mutation's idempotency key, so it has to be fresh and
     unpredictable. Reading the kernel's random pool keeps that inside the
     client rather than delegating to a CLI or a second runtime. *)
  fun freshRunId () = Rand.hex 16

  (* Live delivers either a value or a structured failure. Raise the failure
     rather than letting the example continue on a value it never received. *)
  fun nextLiveValue (subscription, step) =
    case Convex.next (subscription, 10.0) of
        NONE => raise Fail (step ^ " timed out")
      | SOME update =>
          (case Convex.updateError update of
               SOME failure => raise ConvexError.Error failure
             | NONE => Convex.updateValue update)

  fun room () =
    case CommandLine.arguments () of
        first :: _ => first
      | [] =>
          (* The verifier passes a unique room as the first argument; this
             default only exists for someone running the image by hand. *)
          (case OS.Process.getEnv "EXAMPLE_ROOM" of
               SOME name => name
             | NONE => "standard-ml-example")

  fun run () =
    let
      (* Configuration comes from the runtime container, never from a file
         baked into the image. *)
      val deployment =
        case OS.Process.getEnv "CONVEX_URL" of
            SOME url => if url = "" then raise Fail "CONVEX_URL is required" else url
          | NONE => raise Fail "CONVEX_URL is required"
      val space = room ()
      (* One client serves both the HTTP calls and the Live subscription. *)
      val client = Convex.client deployment
      val subscription = ref NONE
      fun cleanup () =
        ((case !subscription of
              SOME item => (Convex.unsubscribe item handle _ => ())
            | NONE => ());
         Convex.close client handle _ => ())
      fun body () =
        let
          (* Read the current state through Convex's documented HTTP endpoint. *)
          val {value = queried, ...} =
            Convex.query (client, "demo:state", Json.Object [("room", Json.String space)])
          val current = exampleCount (queried, "current query")
          val _ = print ("current count: " ^ IntInf.toString current ^ "\n")

          (* Subscribe before mutating. Starting Live first is what guarantees
             the reactive update cannot be missed. *)
          val live =
            Convex.subscribe (client, "demo:state", Json.Object [("room", Json.String space)])
          val _ = subscription := SOME live

          (* The first Live value hydrates the same state the query just read. *)
          val initial =
            exampleCount (nextLiveValue (live, "initial Live value"), "initial Live value")
          val _ =
            if initial = current then ()
            else raise Fail "initial Live count disagreed with the HTTP query"
          val _ = print ("live initial count: " ^ IntInf.toString initial ^ "\n")

          (* Apply exactly one increment. Reusing a runId returns the earlier
             result instead of incrementing twice. *)
          val {value = mutated, ...} =
            Convex.mutation
              (client, "demo:increment",
               Json.Object
                 [("room", Json.String space),
                  ("language", Json.String "standard-ml"),
                  ("runId", Json.String (freshRunId ()))])
          val applied = Json.asBool (Json.getOr (mutated, "applied", Json.Null))
          val mutationCount =
            exampleCount (Json.getOr (mutated, "state", Json.Null), "mutation")
          val expected = current + 1
          val _ = if applied = SOME true then () else raise Fail "mutation was not applied"
          val _ =
            if mutationCount = expected then ()
            else raise Fail "mutation returned an unexpected count"
          val _ = print "mutation applied: true\n"
          val _ = print ("mutation count: " ^ IntInf.toString mutationCount ^ "\n")

          (* Receive the same change reactively, without polling HTTP again. *)
          val updated =
            exampleCount (nextLiveValue (live, "updated Live value"), "updated Live value")
          val _ =
            if updated = expected then ()
            else raise Fail "updated Live count disagreed with the mutation"
          val _ = print ("live updated count: " ^ IntInf.toString updated ^ "\n")
        in
          (* Printed only after all three views have agreed. *)
          print ("verified count: " ^ IntInf.toString current ^ " -> "
                 ^ IntInf.toString updated ^ "\n")
        end
    in
      (body () handle exn => (cleanup (); raise exn));
      cleanup ()
    end

  fun main () =
    (run ();
     TextIO.flushOut TextIO.stdOut;
     OS.Process.exit OS.Process.success)
    handle exn =>
      (* Diagnostics belong on stderr: stdout is the verified transcript. *)
      (TextIO.output
         (TextIO.stdErr, "Standard ML example failed: " ^ ConvexError.describe exn ^ "\n");
       TextIO.flushOut TextIO.stdErr;
       TextIO.flushOut TextIO.stdOut;
       OS.Process.exit OS.Process.failure)
end
