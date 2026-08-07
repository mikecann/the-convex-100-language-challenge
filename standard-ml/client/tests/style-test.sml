(* The Standard ML style and lint gate.

   Poly/ML ships no formatter, and there is no de facto Standard ML equivalent
   of gofmt to defer to. Rather than claim a format step that does not exist,
   this is the repository's honest replacement: a fixed set of mechanical rules,
   short enough for a reviewer to read in full, applied to every checked-in
   Standard ML source in this language directory.

   It runs first in the Docker test stage, before anything is compiled for
   behaviour, so a source that drifts from the house style fails the build with
   the file and line rather than passing review unnoticed. *)

use "client/sources.sml";
use "client/tests/check.sml";

structure StyleTest =
struct
  (* The width every checked-in source already respects. The README and the
     website show this code verbatim inside a fixed code panel, so an overlong
     line becomes a horizontal scrollbar for a reader. *)
  val maxColumns = 100

  val roots = ["client", "examples"]

  (* Enough files that a gate which silently found nothing cannot pass. *)
  val minimumSources = 20

  fun complain (where_, reason) = raise Fail (where_ ^ " " ^ reason)

  (* ---- gathering ------------------------------------------------------- *)

  fun names directory =
    let
      val stream = OS.FileSys.openDir directory
      fun loop acc =
        case OS.FileSys.readDir stream of
            NONE => List.rev acc
          | SOME name => loop (name :: acc)
      val found = loop [] handle exn => (OS.FileSys.closeDir stream; raise exn)
    in
      OS.FileSys.closeDir stream;
      found
    end

  fun sources directory =
    List.concat
      (List.map
         (fn name =>
            let
              val path = directory ^ "/" ^ name
            in
              if OS.FileSys.isDir path then sources path
              else if String.isSuffix ".sml" name then [path]
              else []
            end)
         (names directory))

  (* Directory order is not defined, and a gate whose failures depend on it
     would be irreproducible. *)
  fun sorted paths =
    let
      fun insert (item, []) = [item]
        | insert (item, first :: rest) =
            if item <= first then item :: first :: rest else first :: insert (item, rest)
    in
      List.foldl insert [] paths
    end

  fun readFile path =
    let
      val stream = TextIO.openIn path
      val text = TextIO.inputAll stream handle exn => (TextIO.closeIn stream; raise exn)
    in
      TextIO.closeIn stream;
      text
    end

  (* ---- rules ------------------------------------------------------------ *)

  (* Printable ASCII and newline. This is the rule that rejects tabs, carriage
     returns, and stray control bytes in one place, and it is why every
     non-ASCII value in these sources is written as an explicit escape. *)
  fun checkBytes (path, text) =
    let
      val size = String.size text
      fun loop index =
        if index >= size then ()
        else
          let
            val value = Char.ord (String.sub (text, index))
          in
            if value = 10 then loop (index + 1)
            else if value < 32 orelse value > 126 then
              complain (path, "contains a byte outside printable ASCII and newline")
            else loop (index + 1)
          end
    in
      loop 0
    end

  fun checkTermination (path, text) =
    let
      val size = String.size text
    in
      if size = 0 then complain (path, "is empty")
      else if String.sub (text, size - 1) <> #"\n" then
        complain (path, "does not end with a newline")
      else if size >= 2 andalso String.sub (text, size - 2) = #"\n" then
        complain (path, "ends with a blank line")
      else ()
    end

  fun checkLines (path, text) =
    let
      (* Fields, not tokens: the empty stretch after the final newline has to be
         visible so a trailing blank line cannot hide. *)
      val all = String.fields (fn character => character = #"\n") text
      fun check (index, previousBlank, remaining) =
        case remaining of
            [] => ()
          | line :: rest =>
              let
                val at = path ^ ":" ^ Int.toString index
                val blank = line = ""
              in
                if String.size line > maxColumns then
                  complain (at, "exceeds " ^ Int.toString maxColumns ^ " columns")
                else if not blank
                        andalso Char.isSpace (String.sub (line, String.size line - 1)) then
                  complain (at, "has trailing whitespace")
                else if blank andalso previousBlank then
                  complain (at, "is the second of two consecutive blank lines")
                else check (index + 1, blank, rest)
              end
    in
      check (1, false, all)
    end

  (* Every file in this directory explains itself before it does anything. *)
  fun checkHeader (path, text) =
    if Text.startsWith ("(*", text) then ()
    else complain (path, "does not start with a documentation comment")

  (* Standard ML comments nest, so an unbalanced (* or *) is a real defect that
     no line-based rule can see. String literals are skipped, because a comment
     marker inside one is text rather than a marker. *)
  fun checkNesting (path, text) =
    let
      val size = String.size text
      fun at index = String.sub (text, index)
      fun pair (index, first, second) =
        index + 1 < size andalso at index = first andalso at (index + 1) = second
      (* Called just past an opening quote; returns the index just past the
         closing one. *)
      fun closing index =
        if index >= size then complain (path, "ends inside a string literal")
        else if at index = #"\\" then closing (index + 2)
        else if at index = #"\"" then index + 1
        else closing (index + 1)
      fun loop (index, depth) =
        if index >= size then
          (if depth = 0 then () else complain (path, "ends inside a comment"))
        else if pair (index, #"(", #"*") then loop (index + 2, depth + 1)
        else if pair (index, #"*", #")") then
          (if depth = 0 then complain (path, "closes a comment that was never opened")
           else loop (index + 2, depth - 1))
        else if depth > 0 then loop (index + 1, depth)
        else if at index = #"\"" then loop (closing (index + 1), 0)
        else loop (index + 1, 0)
    in
      loop (0, 0)
    end

  fun forbid (path, text, needle, reason) =
    if String.isSubstring needle text then complain (path, reason) else ()

  (* Every forbidden spelling is written in two halves. This file is scanned
     like any other, so a rule that named its own needle outright would fail
     itself and there would be no way to state the rule at all. *)
  fun checkLint (path, text) =
    (forbid (path, text, "TO" ^ "DO", "carries an unfinished work marker");
     forbid (path, text, "FIX" ^ "ME", "carries an unfinished repair marker");
     forbid (path, text, "Unsafe" ^ ".", "reaches into Poly/ML's unchecked structure");
     forbid (path, text, "OS.Process." ^ "system", "shells out through the system shell"))

  fun isTest path =
    String.isSubstring "/tests/" path orelse String.isSubstring "-test.sml" path

  (* The client and the canonical example are compiled into the shipped
     executables. Nothing there may reach into the test harness. *)
  fun checkPurity (path, text) =
    if isTest path then ()
    else
      (forbid (path, text, "Fixture.", "reaches into the test fixtures");
       forbid (path, text, "Check.", "reaches into the test harness"))

  (* The bounded-writer audit is a test-only executable, reached by building it
     rather than by setting anything at run time. The retired environment hook
     may not reappear in any checked-in source, which is also what makes the
     Docker assertion over the shipped binary meaningful. The name is spelled in
     two halves here so this rule does not trip over itself. *)
  fun checkInjection (path, text) =
    (forbid (path, text, "ADAPTER_" ^ "FLOOD_TEST", "names the retired adapter flood hook");
     forbid (path, text, "flood" ^ "Test", "names the retired adapter flood entry point"))

  fun checkFile path =
    let
      val text = readFile path
    in
      checkBytes (path, text);
      checkTermination (path, text);
      checkLines (path, text);
      checkHeader (path, text);
      checkNesting (path, text);
      checkLint (path, text);
      checkPurity (path, text);
      checkInjection (path, text)
    end

  fun run () =
    let
      val files = sorted (List.concat (List.map sources roots))
    in
      Check.that
        ("the style gate found the checked-in sources", List.length files >= minimumSources);
      Check.that
        ("the canonical example is covered",
         List.exists (fn path => path = "examples/basics/main.sml") files);
      Check.that
        ("the shipped adapter is covered",
         List.exists (fn path => path = "client/tests/conformance/adapter.sml") files);
      List.app (fn path => Check.that (path, (checkFile path; true))) files
    end
end

fun main () = Check.run ("style-test", StyleTest.run)
