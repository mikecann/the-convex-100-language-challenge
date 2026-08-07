(* SHA-1 and Base64, written in Standard ML because the RFC 6455 opening
   handshake needs both and the Basis Library provides neither. They are
   ordinary encoding facilities, not Convex behaviour. *)

structure Sha1 =
struct
  fun rotate (value, bits) =
    Word32.orb (Word32.<< (value, bits), Word32.>> (value, Word.- (0w32, bits)))

  (* Returns the 20 raw digest bytes. *)
  fun hash message =
    let
      val size = String.size message
      val zeros = (64 - ((size + 9) mod 64)) mod 64
      val padded =
        String.concat
          [message,
           "\128",
           CharVector.tabulate (zeros, fn _ => #"\000"),
           Bytes.u64 (IntInf.fromInt size * 8)]
      val state : Word32.word array =
        Array.fromList [0wx67452301, 0wxEFCDAB89, 0wx98BADCFE, 0wx10325476, 0wxC3D2E1F0]
      val schedule : Word32.word array = Array.array (80, 0w0)

      fun loadSchedule offset =
        let
          fun byte index = Word32.fromInt (Bytes.byteAt (padded, offset + index))
          fun first index =
            Word32.orb
              (Word32.<< (byte (index * 4), 0w24),
               Word32.orb
                 (Word32.<< (byte (index * 4 + 1), 0w16),
                  Word32.orb (Word32.<< (byte (index * 4 + 2), 0w8), byte (index * 4 + 3))))
          fun expand index =
            if index >= 80 then ()
            else
              (Array.update
                 (schedule,
                  index,
                  rotate
                    (Word32.xorb
                       (Word32.xorb
                          (Array.sub (schedule, index - 3),
                           Array.sub (schedule, index - 8)),
                        Word32.xorb
                          (Array.sub (schedule, index - 14),
                           Array.sub (schedule, index - 16))),
                     0w1));
               expand (index + 1))
          fun load index =
            if index >= 16 then ()
            else (Array.update (schedule, index, first index); load (index + 1))
        in
          load 0;
          expand 16
        end

      fun round offset =
        let
          val _ = loadSchedule offset
          fun step (index, a, b, c, d, e) =
            if index >= 80 then
              (Array.update (state, 0, Word32.+ (Array.sub (state, 0), a));
               Array.update (state, 1, Word32.+ (Array.sub (state, 1), b));
               Array.update (state, 2, Word32.+ (Array.sub (state, 2), c));
               Array.update (state, 3, Word32.+ (Array.sub (state, 3), d));
               Array.update (state, 4, Word32.+ (Array.sub (state, 4), e)))
            else
              let
                val (mix, constant) =
                  if index < 20 then
                    (Word32.orb (Word32.andb (b, c), Word32.andb (Word32.notb b, d)), 0wx5A827999)
                  else if index < 40 then
                    (Word32.xorb (Word32.xorb (b, c), d), 0wx6ED9EBA1)
                  else if index < 60 then
                    (Word32.orb
                       (Word32.orb (Word32.andb (b, c), Word32.andb (b, d)),
                        Word32.andb (c, d)),
                     0wx8F1BBCDC)
                  else (Word32.xorb (Word32.xorb (b, c), d), 0wxCA62C1D6)
                val next =
                  Word32.+
                    (Word32.+ (Word32.+ (rotate (a, 0w5), mix), Word32.+ (e, constant)),
                     Array.sub (schedule, index))
              in
                step (index + 1, next, a, rotate (b, 0w30), c, d)
              end
        in
          step
            (0, Array.sub (state, 0), Array.sub (state, 1), Array.sub (state, 2),
             Array.sub (state, 3), Array.sub (state, 4))
        end

      fun blocks offset =
        if offset >= String.size padded then ()
        else (round offset; blocks (offset + 64))
    in
      blocks 0;
      String.concat
        (List.tabulate
           (5,
            fn index =>
              let
                val word = Array.sub (state, index)
                fun byte shift =
                  Char.chr (Word32.toInt (Word32.andb (Word32.>> (word, shift), 0wxFF)))
              in
                String.implode [byte 0w24, byte 0w16, byte 0w8, byte 0w0]
              end))
    end
end

structure Base64 =
struct
  val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  fun encode text =
    let
      val size = String.size text
      fun byte index = if index < size then Bytes.byteAt (text, index) else 0
      fun symbol value = String.str (String.sub (alphabet, value))
      fun group offset =
        let
          val a = byte offset
          val b = byte (offset + 1)
          val c = byte (offset + 2)
          val remaining = size - offset
        in
          String.concat
            [symbol (a div 4),
             symbol ((a mod 4) * 16 + b div 16),
             if remaining >= 2 then symbol ((b mod 16) * 4 + c div 64) else "=",
             if remaining >= 3 then symbol (c mod 64) else "="]
        end
      fun loop offset =
        if offset >= size then [] else group offset :: loop (offset + 3)
    in
      String.concat (loop 0)
    end

  fun valueOf character =
    if character >= #"A" andalso character <= #"Z" then
      SOME (Char.ord character - Char.ord #"A")
    else if character >= #"a" andalso character <= #"z" then
      SOME (26 + Char.ord character - Char.ord #"a")
    else if Char.isDigit character then SOME (52 + Char.ord character - Char.ord #"0")
    else if character = #"+" then SOME 62
    else if character = #"/" then SOME 63
    else NONE

  (* Strict: the length must be a multiple of four, padding may only appear at
     the end, and unused low bits must be zero. Convex timestamps round-trip
     through this, so a sloppy decoder would let a non-canonical version pass. *)
  fun decode text =
    let
      val size = String.size text
      val _ =
        if size mod 4 <> 0 then raise Fail "base64 length is not a multiple of four" else ()
      fun group offset =
        let
          val padding =
            if size = 0 then 0
            else if offset + 4 < size then 0
            else if String.sub (text, size - 1) <> #"=" then 0
            else if String.sub (text, size - 2) = #"=" then 2
            else 1
          fun digit index =
            case valueOf (String.sub (text, offset + index)) of
                SOME value => value
              | NONE => raise Fail "base64 contains an invalid character"
          val a = digit 0
          val b = digit 1
          val c = if padding >= 2 then 0 else digit 2
          val d = if padding >= 1 then 0 else digit 3
          val _ =
            if padding >= 2 andalso b mod 16 <> 0 then
              raise Fail "base64 padding carries non-zero bits"
            else if padding = 1 andalso c mod 4 <> 0 then
              raise Fail "base64 padding carries non-zero bits"
            else ()
          val bytes =
            [Char.chr (a * 4 + b div 16),
             Char.chr ((b mod 16) * 16 + c div 4),
             Char.chr ((c mod 4) * 64 + d)]
        in
          String.implode (List.take (bytes, 3 - padding))
        end
      fun loop offset =
        if offset >= size then [] else group offset :: loop (offset + 4)
    in
      String.concat (loop 0)
    end
end
