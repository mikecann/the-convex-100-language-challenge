(* The bounded-writer runtime audit as its own test-only binary.

   The real adapter sink runs here while the caller deliberately never reads
   stdout, so the queue and an in-flight write both come under pressure. The
   audit lives outside the shipped adapter so the flood switch and its
   diagnostics cannot be compiled into the exported production heap; the
   Docker test stage greps the shipped binary to prove they are absent. *)

use "client/sources.sml";
use "client/tests/conformance/adapter.sml";

fun main () =
  let
    val sink =
      Adapter.newSink
        (fn text => (TextIO.output (TextIO.stdOut, text); TextIO.flushOut TextIO.stdOut))
    (* Forty droppable events of a third of a megabyte each overrun the output
       budget many times over while nothing drains stdout, so the sink must
       coalesce under pressure rather than grow without bound. *)
    val large = CharVector.tabulate (350000, fn _ => #"x")
    fun loop index =
      if index >= 40 then ()
      else
        (ignore
           (Adapter.publish
              (sink,
               Json.Object
                 [("type", Json.String "subscription"),
                  ("subscriptionId", Json.String "memory"),
                  ("value",
                   Json.Object
                     [("index", Json.Int (IntInf.fromInt index)),
                      ("text", Json.String large)])],
               true, 5.0));
         loop (index + 1))
  in
    loop 0;
    (* The stderr line is the only signal the Docker gate waits for; it must
       appear while stdout is still blocked to prove the queue stayed bounded. *)
    Adapter.note "adapter flood queue ready";
    Clock.sleep 3.0;
    Adapter.closeSink (sink, false)
  end;
