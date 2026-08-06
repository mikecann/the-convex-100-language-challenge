(* A very small assertion helper shared by the language-local tests. Each test
   prints how many checks actually ran, so a silently skipped section is
   visible in the Docker build log. *)
structure Check =
struct
  val performed = ref 0

  fun that (label, truth) =
    (performed := !performed + 1;
     if truth then () else raise Fail ("check failed: " ^ label))

  fun raises (label, body) =
    that (label, (body (); false) handle _ => true)

  fun failureNamed (label, expected, body) =
    that
      (label,
       (body (); false)
       handle ConvexError.Error {name, ...} => name = expected
            | _ => false)

  fun report name =
    print (name ^ ": " ^ Int.toString (!performed) ^ " checks\n")

  (* An exported Poly/ML program has no top-level handler, so an escaping
     exception ends the process with exit 1 and no output whatsoever. Every test
     entry point goes through here instead, which is what makes a failure name
     itself in the Docker build log. *)
  fun run (name, body) =
    (body ();
     report name;
     TextIO.flushOut TextIO.stdOut)
    handle exn =>
      (TextIO.output
         (TextIO.stdErr,
          name ^ " FAILED after " ^ Int.toString (!performed) ^ " checks: "
          ^ ConvexError.describe exn ^ "\n");
       TextIO.flushOut TextIO.stdErr;
       TextIO.flushOut TextIO.stdOut;
       OS.Process.exit OS.Process.failure)
end
