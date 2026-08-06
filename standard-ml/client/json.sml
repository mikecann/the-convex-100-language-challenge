(* A bounded JSON reader and writer written directly in Standard ML.
   Convex speaks JSON on both transports, so this is the one place where
   untrusted bytes become a Standard ML value. Every limit here exists to stop
   hostile input before it can exhaust the 128 MiB runtime the shared
   verification policy allows. *)

structure Json =
struct
  datatype value =
      Null
    | Bool of bool
    (* Numbers are split so an integral counter stays exact. Convex may still
       spell an integral number as 0.0, which arrives as Real and is accepted
       by asInt below. *)
    | Int of IntInf.int
    | Real of real
    | String of string
    | Array of value list
    | Object of (string * value) list

  exception JsonError of string

  val maxBytes = 2 * 1024 * 1024
  val maxDepth = 128
  val maxNodes = 8192

  fun fail message = raise JsonError message

  (* ---- inspection -------------------------------------------------- *)

  fun get (Object entries, key) =
        (case List.find (fn (name, _) => name = key) entries of
             SOME (_, found) => SOME found
           | NONE => NONE)
    | get _ = NONE

  fun has (object, key) = Option.isSome (get (object, key))

  fun getOr (object, key, default) =
    case get (object, key) of SOME found => found | NONE => default

  fun isObject (Object _) = true
    | isObject _ = false

  fun asString (String text) = SOME text
    | asString _ = NONE

  fun asBool (Bool flag) = SOME flag
    | asBool _ = NONE

  fun asList (Array items) = SOME items
    | asList _ = NONE

  fun asEntries (Object entries) = SOME entries
    | asEntries _ = NONE

  (* Accept any mathematically integral number, including the decimal spelling
     Convex sometimes uses, while rejecting fractional, quoted, non-finite, and
     out-of-range values. *)
  fun asInt (Int number) = SOME number
    | asInt (Real number) =
        if Real.isFinite number andalso Real.== (number, Real.realFloor number) then
          SOME (Real.toLargeInt IEEEReal.TO_NEAREST number)
        else NONE
    | asInt _ = NONE

  fun asUInt32 (value, who) =
    case asInt value of
        SOME number =>
          if number >= 0 andalso number <= 4294967295 then number
          else fail (who ^ " expected an unsigned 32-bit integer")
      | NONE => fail (who ^ " expected an unsigned 32-bit integer")

  fun stringList value =
    case value of
        Array items =>
          List.map
            (fn String text => text
              | _ => fail "logLines must be an array of strings")
            items
      | _ => fail "logLines must be an array of strings"

  (* ---- writing ----------------------------------------------------- *)

  fun escape (text, buffer) =
    let
      fun push chunk = Buffer.add (buffer, chunk)
      fun loop index =
        if index >= String.size text then ()
        else
          let
            val character = String.sub (text, index)
            val code = Char.ord character
          in
            (case character of
                 #"\"" => push "\\\""
               | #"\\" => push "\\\\"
               | #"\n" => push "\\n"
               | #"\r" => push "\\r"
               | #"\t" => push "\\t"
               | #"\b" => push "\\b"
               | #"\f" => push "\\f"
               | _ =>
                   if code < 0x20 then
                     push (String.concat
                             ["\\u00",
                              String.str (String.sub ("0123456789abcdef", code div 16)),
                              String.str (String.sub ("0123456789abcdef", code mod 16))])
                   else push (String.str character));
            loop (index + 1)
          end
    in
      push "\"";
      loop 0;
      push "\""
    end

  (* Standard ML writes negatives with a tilde and may use an uppercase
     exponent; JSON accepts neither spelling of the sign. *)
  fun realText number =
    if not (Real.isFinite number) then
      fail "JSON cannot represent a non-finite number"
    else
      String.translate
        (fn #"~" => "-" | character => String.str character)
        (Real.fmt (StringCvt.GEN NONE) number)

  fun writeValue (value, buffer) =
    case value of
        Null => Buffer.add (buffer, "null")
      | Bool true => Buffer.add (buffer, "true")
      | Bool false => Buffer.add (buffer, "false")
      | Int number =>
          Buffer.add
            (buffer,
             String.translate
               (fn #"~" => "-" | character => String.str character)
               (IntInf.toString number))
      | Real number => Buffer.add (buffer, realText number)
      | String text =>
          if Text.utf8Valid text then escape (text, buffer)
          else fail "JSON strings must be valid UTF-8"
      | Array items =>
          let
            fun loop (first, []) = ()
              | loop (first, item :: rest) =
                  (if first then () else Buffer.add (buffer, ",");
                   writeValue (item, buffer);
                   loop (false, rest))
          in
            Buffer.add (buffer, "[");
            loop (true, items);
            Buffer.add (buffer, "]")
          end
      | Object entries =>
          let
            fun loop (first, []) = ()
              | loop (first, (key, item) :: rest) =
                  (if first then () else Buffer.add (buffer, ",");
                   escape (key, buffer);
                   Buffer.add (buffer, ":");
                   writeValue (item, buffer);
                   loop (false, rest))
          in
            Buffer.add (buffer, "{");
            loop (true, entries);
            Buffer.add (buffer, "}")
          end

  fun encode value =
    let
      val buffer = Buffer.new ()
    in
      writeValue (value, buffer);
      Buffer.contents buffer
    end

  fun byteLength value = String.size (encode value)

  (* ---- reading ----------------------------------------------------- *)

  fun decode text =
    let
      val size = String.size text
      val _ =
        if size > maxBytes then fail "JSON exceeds byte limit" else ()
      val _ =
        if Text.utf8Valid text then () else fail "JSON is not valid UTF-8"
      val position = ref 0
      val nodes = ref 0

      fun peek () =
        if !position >= size then NONE else SOME (String.sub (text, !position))

      fun advance () = position := !position + 1

      fun skipSpace () =
        case peek () of
            SOME character =>
              if character = #" " orelse character = #"\t"
                 orelse character = #"\n" orelse character = #"\r"
              then (advance (); skipSpace ())
              else ()
          | NONE => ()

      fun expect character =
        case peek () of
            SOME found =>
              if found = character then advance ()
              else fail ("JSON expected " ^ String.str character)
          | NONE => fail "JSON ended unexpectedly"

      fun literal (word, result) =
        if !position + String.size word <= size
           andalso String.substring (text, !position, String.size word) = word
        then (position := !position + String.size word; result)
        else fail "JSON has an unknown literal"

      (* Counting nodes as they are produced keeps a dense but shallow payload
         from allocating millions of small values before any check runs. *)
      fun countNode () =
        (nodes := !nodes + 1;
         if !nodes > maxNodes then fail "JSON exceeds structural node limit" else ())

      fun hexDigit character =
        if Char.isDigit character then Char.ord character - Char.ord #"0"
        else if character >= #"a" andalso character <= #"f" then
          10 + Char.ord character - Char.ord #"a"
        else if character >= #"A" andalso character <= #"F" then
          10 + Char.ord character - Char.ord #"A"
        else fail "JSON has an invalid \\u escape"

      fun readHex4 () =
        if !position + 4 > size then fail "JSON \\u escape is truncated"
        else
          let
            fun digit offset = hexDigit (String.sub (text, !position + offset))
            val value = ((digit 0 * 16 + digit 1) * 16 + digit 2) * 16 + digit 3
          in
            position := !position + 4;
            value
          end

      fun readEscape buffer =
        case peek () of
            NONE => fail "JSON escape is truncated"
          | SOME character =>
              (advance ();
               case character of
                   #"\"" => Buffer.add (buffer, "\"")
                 | #"\\" => Buffer.add (buffer, "\\")
                 | #"/" => Buffer.add (buffer, "/")
                 | #"b" => Buffer.add (buffer, "\b")
                 | #"f" => Buffer.add (buffer, "\f")
                 | #"n" => Buffer.add (buffer, "\n")
                 | #"r" => Buffer.add (buffer, "\r")
                 | #"t" => Buffer.add (buffer, "\t")
                 | #"u" =>
                     let
                       val first = readHex4 ()
                     in
                       (* A high surrogate is only meaningful when its low
                          partner follows, so reassemble the pair here rather
                          than emitting an unpaired code point. *)
                       if first >= 0xD800 andalso first <= 0xDBFF then
                         (expect #"\\";
                          expect #"u";
                          let
                            val second = readHex4 ()
                          in
                            if second >= 0xDC00 andalso second <= 0xDFFF then
                              Buffer.add
                                (buffer,
                                 Text.utf8Encode
                                   (IntInf.fromInt
                                      (0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00))))
                            else fail "JSON has an unpaired surrogate"
                          end)
                       else if first >= 0xDC00 andalso first <= 0xDFFF then
                         fail "JSON has an unpaired surrogate"
                       else Buffer.add (buffer, Text.utf8Encode (IntInf.fromInt first))
                     end
                 | _ => fail "JSON has an unknown escape")

      fun readString () =
        let
          val buffer = Buffer.new ()
          fun loop () =
            case peek () of
                NONE => fail "JSON string is unterminated"
              | SOME #"\"" => (advance (); Buffer.contents buffer)
              | SOME #"\\" => (advance (); readEscape buffer; loop ())
              | SOME character =>
                  if Char.ord character < 0x20 then
                    fail "JSON string contains a raw control character"
                  else (advance (); Buffer.addChar (buffer, character); loop ())
        in
          expect #"\"";
          loop ()
        end

      fun readNumber () =
        let
          val start = !position
          (* Remember whether the literal carried a fraction or exponent. An
             integral counter must stay exact, so only that spelling goes
             through the floating-point reader. *)
          val fractional = ref false
          fun digits () =
            let
              fun loop count =
                case peek () of
                    SOME character =>
                      if Char.isDigit character then (advance (); loop (count + 1)) else count
                  | NONE => count
            in
              loop 0
            end
          (* JSON requires at least one digit in each of these positions. A
             lenient reader would accept 1. or 1e and hand a surprising value to
             the caller. *)
          fun required where' =
            if digits () = 0 then fail ("JSON number has no digits " ^ where') else ()
          fun sign () =
            case peek () of
                SOME #"+" => advance ()
              | SOME #"-" => advance ()
              | _ => ()
          fun fraction () =
            case peek () of
                SOME #"." =>
                  (fractional := true; advance (); required "after the decimal point")
              | _ => ()
          fun exponent () =
            case peek () of
                SOME #"e" => (fractional := true; advance (); sign (); required "in the exponent")
              | SOME #"E" => (fractional := true; advance (); sign (); required "in the exponent")
              | _ => ()
          val _ = (case peek () of SOME #"-" => advance () | _ => ())
          val integerStart = !position
          val _ = required "before the decimal point"
          (* JSON also forbids a leading zero, so 01 is not another spelling
             of 1. *)
          val _ =
            if !position - integerStart > 1
               andalso String.sub (text, integerStart) = #"0" then
              fail "JSON number has a leading zero"
            else ()
          val _ = fraction ()
          val _ = exponent ()
          val token = String.substring (text, start, !position - start)
        in
          if token = "" orelse token = "-" then fail "JSON has a malformed number"
          else if !fractional then
            (case Real.fromString token of
                 SOME number =>
                   if Real.isFinite number then Real number
                   else fail "JSON number is not finite"
               | NONE => fail "JSON has a malformed number")
          else
            (case IntInf.fromString token of
                 SOME number => Int number
               | NONE => fail "JSON has a malformed number")
        end

      fun readValue depth =
        let
          val _ =
            if depth > maxDepth then fail "JSON exceeds nesting limit" else ()
          val _ = countNode ()
          val _ = skipSpace ()
        in
          case peek () of
              NONE => fail "JSON ended unexpectedly"
            | SOME #"{" => readObject depth
            | SOME #"[" => readArray depth
            | SOME #"\"" => String (readString ())
            | SOME #"t" => literal ("true", Bool true)
            | SOME #"f" => literal ("false", Bool false)
            | SOME #"n" => literal ("null", Null)
            | SOME _ => readNumber ()
        end

      and readArray depth =
        let
          val _ = expect #"["
          val _ = skipSpace ()
        in
          case peek () of
              SOME #"]" => (advance (); Array [])
            | _ =>
                let
                  fun loop acc =
                    let
                      val item = readValue (depth + 1)
                      val _ = skipSpace ()
                    in
                      case peek () of
                          SOME #"," => (advance (); loop (item :: acc))
                        | SOME #"]" => (advance (); Array (List.rev (item :: acc)))
                        | _ => fail "JSON array is malformed"
                    end
                in
                  loop []
                end
        end

      and readObject depth =
        let
          val _ = expect #"{"
          val _ = skipSpace ()
        in
          case peek () of
              SOME #"}" => (advance (); Object [])
            | _ =>
                let
                  fun entry () =
                    let
                      val _ = skipSpace ()
                      val key = readString ()
                      val _ = skipSpace ()
                      val _ = expect #":"
                    in
                      (key, readValue (depth + 1))
                    end
                  fun loop acc =
                    let
                      val pair = entry ()
                      val _ = skipSpace ()
                    in
                      case peek () of
                          SOME #"," => (advance (); loop (pair :: acc))
                        | SOME #"}" => (advance (); Object (List.rev (pair :: acc)))
                        | _ => fail "JSON object is malformed"
                    end
                in
                  loop []
                end
        end

      val result = readValue 0
      val _ = skipSpace ()
    in
      if !position <> size then fail "JSON has trailing data" else result
    end
end
