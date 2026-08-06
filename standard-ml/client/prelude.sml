(* Small facilities the JSON, HTTP, WebSocket, and Live layers all need.
   Standard ML's Basis Library is deliberately small, so this file collects the
   byte-string, deadline, and thread-handshake primitives once instead of
   letting each layer invent its own. *)

structure Clock =
struct
  (* Every bounded operation in this client is expressed as an absolute
     deadline rather than a duration, so a retry loop can never silently
     restart the caller's budget. *)
  fun now () = Time.now ()

  fun deadlineIn seconds = Time.+ (Time.now (), Time.fromReal seconds)

  fun remaining deadline =
    let
      val current = Time.now ()
    in
      if Time.<= (deadline, current) then Time.zeroTime
      else Time.- (deadline, current)
    end

  fun expired deadline = Time.<= (deadline, Time.now ())

  fun remainingSeconds deadline = Time.toReal (remaining deadline)

  (* Poly/ML has no per-thread sleep primitive. Waiting on a condition variable
     nothing ever signals pauses only the calling thread, which matters because
     the Live owner and the adapter relays share the process. *)
  fun sleep seconds =
    let
      val mutex = Thread.Mutex.mutex ()
      val cond = Thread.ConditionVar.conditionVar ()
      val deadline = deadlineIn seconds
      fun loop () =
        if expired deadline then ()
        else (Thread.ConditionVar.waitUntil (cond, mutex, deadline); loop ())
    in
      Thread.Mutex.lock mutex;
      loop ();
      Thread.Mutex.unlock mutex
    end
end

structure Latch =
struct
  (* Poly/ML threads cannot be joined directly, so a released-once latch is the
     primitive used to wait for a fixture, a writer, or a relay to finish. *)
  type t =
    {mutex: Thread.Mutex.mutex,
     cond: Thread.ConditionVar.conditionVar,
     released: bool ref}

  fun new () : t =
    {mutex = Thread.Mutex.mutex (),
     cond = Thread.ConditionVar.conditionVar (),
     released = ref false}

  fun release ({mutex, cond, released} : t) =
    (Thread.Mutex.lock mutex;
     released := true;
     Thread.ConditionVar.broadcast cond;
     Thread.Mutex.unlock mutex)

  (* Returns false when the deadline passed before the latch was released. *)
  fun await ({mutex, cond, released} : t, deadline) =
    let
      fun loop () =
        if !released then true
        else if Clock.expired deadline then false
        else (Thread.ConditionVar.waitUntil (cond, mutex, deadline); loop ())
      val _ = Thread.Mutex.lock mutex
      val result = loop ()
    in
      Thread.Mutex.unlock mutex;
      result
    end

  fun awaitSeconds (latch, seconds) = await (latch, Clock.deadlineIn seconds)
end

structure Guard =
struct
  (* Run a body under a mutex and always unlock, even when the body raises.
     Every critical section in this client goes through here so a structured
     Convex failure can never leave a lock held. *)
  fun critical (mutex, body) =
    let
      val _ = Thread.Mutex.lock mutex
      val result = body () handle exn => (Thread.Mutex.unlock mutex; raise exn)
    in
      Thread.Mutex.unlock mutex;
      result
    end
end

structure Text =
struct
  fun startsWith (prefix, text) =
    String.size prefix <= String.size text
    andalso String.substring (text, 0, String.size prefix) = prefix

  fun indexFrom (text, character, start) =
    let
      val size = String.size text
      fun loop index =
        if index >= size then NONE
        else if String.sub (text, index) = character then SOME index
        else loop (index + 1)
    in
      if start < 0 then NONE else loop start
    end

  fun lastIndex (text, character) =
    let
      fun loop index =
        if index < 0 then NONE
        else if String.sub (text, index) = character then SOME index
        else loop (index - 1)
    in
      loop (String.size text - 1)
    end

  fun contains (text, character) = Option.isSome (indexFrom (text, character, 0))

  fun lower text = String.map Char.toLower text

  fun trim text =
    let
      val size = String.size text
      fun start index =
        if index < size andalso Char.isSpace (String.sub (text, index)) then
          start (index + 1)
        else index
      val first = start 0
      fun finish index =
        if index > first andalso Char.isSpace (String.sub (text, index - 1)) then
          finish (index - 1)
        else index
      val last = finish size
    in
      String.substring (text, first, last - first)
    end

  (* A header value that can carry CR or LF would let a caller inject an extra
     request line, so every value spliced into the wire is checked first. *)
  fun headerSafe text =
    not (contains (text, #"\r")) andalso not (contains (text, #"\n"))

  (* Standard ML strings are byte strings here. Validating the encoding at the
     boundary keeps every later size and slicing decision deterministic even for
     hostile input. *)
  fun utf8Valid text =
    let
      val size = String.size text
      fun byte index = Char.ord (String.sub (text, index))
      fun continuation index = index < size andalso byte index >= 128 andalso byte index <= 191
      fun between (index, low, high) =
        index < size andalso byte index >= low andalso byte index <= high
      fun loop index =
        if index >= size then true
        else
          let
            val first = byte index
          in
            if first <= 127 then loop (index + 1)
            else if first >= 194 andalso first <= 223 andalso continuation (index + 1) then
              loop (index + 2)
            else if first = 224 andalso between (index + 1, 160, 191)
                    andalso continuation (index + 2) then
              loop (index + 3)
            else if ((first >= 225 andalso first <= 236) orelse (first >= 238 andalso first <= 239))
                    andalso continuation (index + 1) andalso continuation (index + 2) then
              loop (index + 3)
            else if first = 237 andalso between (index + 1, 128, 159)
                    andalso continuation (index + 2) then
              loop (index + 3)
            else if first = 240 andalso between (index + 1, 144, 191)
                    andalso continuation (index + 2) andalso continuation (index + 3) then
              loop (index + 4)
            else if first >= 241 andalso first <= 243 andalso continuation (index + 1)
                    andalso continuation (index + 2) andalso continuation (index + 3) then
              loop (index + 4)
            else if first = 244 andalso between (index + 1, 128, 143)
                    andalso continuation (index + 2) andalso continuation (index + 3) then
              loop (index + 4)
            else false
          end
    in
      loop 0
    end

  (* Encode a Unicode scalar value the JSON parser recovered from \uXXXX. *)
  fun utf8Encode code =
    let
      fun chr value = Char.chr (IntInf.toInt value)
    in
      if code < 0x80 then String.str (chr code)
      else if code < 0x800 then
        String.implode
          [chr (0xC0 + IntInf.div (code, 0x40)), chr (0x80 + IntInf.mod (code, 0x40))]
      else if code < 0x10000 then
        String.implode
          [chr (0xE0 + IntInf.div (code, 0x1000)),
           chr (0x80 + IntInf.mod (IntInf.div (code, 0x40), 0x40)),
           chr (0x80 + IntInf.mod (code, 0x40))]
      else
        String.implode
          [chr (0xF0 + IntInf.div (code, 0x40000)),
           chr (0x80 + IntInf.mod (IntInf.div (code, 0x1000), 0x40)),
           chr (0x80 + IntInf.mod (IntInf.div (code, 0x40), 0x40)),
           chr (0x80 + IntInf.mod (code, 0x40))]
    end

  (* Live uses this fingerprint to notice that a rehydrated value is unchanged
     without retaining a second copy of the value itself. Poly/ML's word is 63
     bits, so the 64-bit FNV-1a offset basis does not fit; two independent
     in-range FNV-1a passes are combined instead. *)
  fun fingerprint text =
    let
      val size = String.size text
      fun fold (basis, prime) =
        let
          fun loop (index, hash) =
            if index >= size then hash
            else
              loop
                (index + 1,
                 Word.* (Word.xorb (hash, Word.fromInt (Char.ord (String.sub (text, index)))),
                         prime))
        in
          loop (0, basis)
        end
      val low = Word.andb (fold (0wx811c9dc5, 0wx01000193), 0wx7fffffff)
      val high = Word.andb (fold (0wx9e3779b1, 0wx1000193b), 0wx7fffffff)
    in
      Word.orb (Word.<< (high, 0w31), low)
    end
end

structure Buffer =
struct
  (* Appending to an immutable string is quadratic, so accumulate reversed
     chunks and concatenate once. *)
  type t = {chunks: string list ref, size: int ref}

  fun new () : t = {chunks = ref [], size = ref 0}

  fun add ({chunks, size} : t, text) =
    (chunks := text :: !chunks; size := !size + String.size text)

  fun addChar (buffer, character) = add (buffer, String.str character)

  fun size ({size = total, ...} : t) = !total

  fun contents ({chunks, ...} : t) = String.concat (List.rev (!chunks))
end

structure Bytes =
struct
  fun toString bytes = Byte.bytesToString bytes

  fun fromString text = Byte.stringToBytes text

  fun byteAt (text, index) = Char.ord (String.sub (text, index))

  fun ofByte value = String.str (Char.chr value)

  (* Big-endian helpers for RFC 6455 frame headers. *)
  fun u16 value = String.implode [Char.chr (value div 256), Char.chr (value mod 256)]

  fun u64 value =
    let
      fun digit index =
        Char.chr (IntInf.toInt (IntInf.mod (IntInf.div (value, IntInf.pow (256, index)), 256)))
    in
      String.implode (List.tabulate (8, fn index => digit (7 - index)))
    end

  fun readU16 (text, offset) = byteAt (text, offset) * 256 + byteAt (text, offset + 1)

  fun readU64 (text, offset) =
    let
      fun loop (index, acc) =
        if index = 8 then acc
        else loop (index + 1, acc * 256 + IntInf.fromInt (byteAt (text, offset + index)))
    in
      loop (0, 0 : IntInf.int)
    end

  fun xorMask (payload, mask) =
    let
      val size = String.size payload
    in
      CharVector.tabulate
        (size,
         fn index =>
           Char.chr
             (Word.toInt
                (Word.xorb
                   (Word.fromInt (byteAt (payload, index)),
                    Word.fromInt (byteAt (mask, index mod 4))))))
    end

  fun toHex text =
    let
      val digits = "0123456789abcdef"
      fun hex value = String.sub (digits, value)
    in
      String.concat
        (List.tabulate
           (String.size text,
            fn index =>
              let val value = byteAt (text, index)
              in String.implode [hex (value div 16), hex (value mod 16)] end))
    end

  fun fromHex text =
    let
      fun value character =
        if Char.isDigit character then Char.ord character - Char.ord #"0"
        else if character >= #"a" andalso character <= #"f" then
          10 + Char.ord character - Char.ord #"a"
        else if character >= #"A" andalso character <= #"F" then
          10 + Char.ord character - Char.ord #"A"
        else raise Fail "invalid hexadecimal digit"
    in
      if String.size text mod 2 <> 0 then raise Fail "odd-length hexadecimal string"
      else
        CharVector.tabulate
          (String.size text div 2,
           fn index =>
             Char.chr
               (value (String.sub (text, index * 2)) * 16
                + value (String.sub (text, index * 2 + 1))))
    end
end

structure Rand =
struct
  (* WebSocket masks, session identifiers, and the example's idempotency key all
     need unpredictable bytes. Reading the kernel pool keeps that inside the
     client instead of delegating to a CLI or a second runtime. *)
  fun bytes count =
    let
      val stream = BinIO.openIn "/dev/urandom"
      val data = BinIO.inputN (stream, count) handle exn => (BinIO.closeIn stream; raise exn)
    in
      BinIO.closeIn stream;
      if Word8Vector.length data <> count then
        raise Fail "could not read /dev/urandom"
      else Bytes.toString data
    end

  fun hex count = Bytes.toHex (bytes count)
end
