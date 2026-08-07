comment convex-json.alg - strict JSON, read and written over byte buffers.
   Convex's HTTP and sync protocols are JSON. This client mostly treats
   incoming JSON as data it locates and re-emits rather than data it must
   fully understand -- an argument object handed to it by the adapter
   protocol, or a value returned by a Convex function, is validated for
   well-formedness and passed through byte for byte rather than rebuilt
   from a parsed tree, exactly like this project's other native clients.
   Full parsing is used only for the handful of envelope and sync fields
   this client actually reads - status, value presence, errorMessage,
   logLines, and the small set of version fields the Live state machine
   needs.
   Every procedure that walks JSON text takes a depth parameter and
   refuses to recurse past jsonmaxdepth, so a maliciously or accidentally
   deep document cannot exhaust the call stack. ALGOL 60 has no
   standalone while statement and no way to leave a loop early, so every
   scan below is written as a for statement with a while clause over an
   unused control variable, or as a single pass that keeps scanning but
   only acts the first time a condition becomes true;

integer procedure jsonmaxdepth;
begin
   jsonmaxdepth := 32
end jsonmaxdepth;

integer procedure jsondigit(b);
   value b;
   integer b;
begin
   jsondigit := if b >= 48 & b <= 57 then 1 else 0
end jsondigit;

integer procedure jsonfirstnonwhite(buf, off, len);
   comment the offset of the first non-whitespace byte at or after off,
   within the next len bytes, or off + len when every remaining byte is
   whitespace;
   value off, len;
   integer array buf;
   integer off, len;
begin
   integer i, found;
   found := off + len;
   for i := 0 step 1 until len - 1 do
      if found = off + len then
         if buf[off + i] != 32 & buf[off + i] != 9 & buf[off + i] != 10
               & buf[off + i] != 13 then found := off + i;
   jsonfirstnonwhite := found
end jsonfirstnonwhite;

procedure jsonfail(msg, errbuf, errbuflen, errkind);
   comment records a ProtocolError with the given literal message;
   integer array errbuf;
   integer errbuflen, errkind;
   string msg;
begin
   integer discard;
   errbuflen := 0;
   errkind := 2;
   discard := bufputstr(errbuf, 256, errbuflen, msg)
end jsonfail;

procedure jsonskipstring(buf, off, limit, endoff, errbuf, errbuflen, errkind);
   comment buf[off] must be a double quote. Scans a JSON string,
   honouring backslash escapes, and reports the offset one past the
   closing quote through endoff. limit is the exclusive upper bound on
   valid offsets;
   value off, limit;
   integer array buf, errbuf;
   integer off, limit, endoff, errbuflen, errkind;
begin
   integer i, ch, bad, closed, skipnext;
   bad := 0;
   closed := 0;
   if off >= limit then bad := 1
   else if buf[off] != 34 then bad := 1;
   if bad = 0 then
      begin
      skipnext := 0;
      for i := off + 1 step 1 until limit - 1 do
         if closed = 0 & bad = 0 then
            begin
            ch := buf[i];
            if skipnext != 0 then skipnext := 0
            else if ch = 92 then skipnext := 1
            else if ch = 34 then closed := i + 1
            else if ch < 32 then bad := 1
            end
      end;
   if closed = 0 & bad = 0 then bad := 1;
   if bad != 0 then
      begin
      jsonfail("malformed JSON string", errbuf, errbuflen, errkind);
      endoff := off
      end
   else
      endoff := closed
end jsonskipstring;

procedure jsonscanintpart(buf, off, limit, endoff);
   comment advances past a run of one or more ASCII digits, starting at
   off. endoff equals off when no digit was found there;
   value off, limit;
   integer array buf;
   integer off, limit, endoff;
begin
   integer i, dummy;
   i := off;
   for dummy := 1 while i < limit & jsondigit(buf[i]) != 0 do
      i := i + 1;
   endoff := i
end jsonscanintpart;

procedure jsonskipnumber(buf, off, limit, endoff, errbuf, errbuflen, errkind);
   comment buf[off] must begin a JSON number. Reports the offset one
   past its last byte through endoff;
   value off, limit;
   integer array buf, errbuf;
   integer off, limit, endoff, errbuflen, errkind;
begin
   integer i, bad, after;
   bad := 0;
   i := off;
   if i < limit & buf[i] = 45 then i := i + 1;
   if i < limit & buf[i] = 48 then i := i + 1
   else
      begin
      jsonscanintpart(buf, i, limit, after);
      if after = i then bad := 1;
      i := after
      end;
   if bad = 0 & i < limit & buf[i] = 46 then
      begin
      i := i + 1;
      jsonscanintpart(buf, i, limit, after);
      if after = i then bad := 1;
      i := after
      end;
   if bad = 0 & i < limit & (buf[i] = 101 | buf[i] = 69) then
      begin
      i := i + 1;
      if i < limit & (buf[i] = 43 | buf[i] = 45) then i := i + 1;
      jsonscanintpart(buf, i, limit, after);
      if after = i then bad := 1;
      i := after
      end;
   if bad != 0 then
      begin
      jsonfail("malformed JSON number", errbuf, errbuflen, errkind);
      endoff := off
      end
   else
      endoff := i
end jsonskipnumber;

procedure jsonskipliteral(buf, off, limit, lit, endoff, errbuf, errbuflen, errkind);
   comment matches the literal keyword lit (true, false or null) at
   off;
   value off, limit;
   integer array buf, errbuf;
   integer off, limit, endoff, errbuflen, errkind;
   string lit;
begin
   integer array scratch[0:15];
   integer n, i, ok;
   n := cxstrbytes(lit, scratch, 16);
   ok := 1;
   if off + n > limit then ok := 0
   else
      for i := 0 step 1 until n - 1 do
         if buf[off + i] != scratch[i] then ok := 0;
   if ok = 0 then
      begin
      jsonfail("unexpected JSON literal", errbuf, errbuflen, errkind);
      endoff := off
      end
   else
      endoff := off + n
end jsonskipliteral;

procedure jsonskipvalue(buf, off, limit, depth, endoff, errbuf, errbuflen, errkind);
   comment scans exactly one JSON value beginning at or after off,
   skipping leading whitespace, reporting the offset one past it
   through endoff. Objects and arrays recurse into their members,
   bounded by jsonmaxdepth;
   value off, limit, depth;
   integer array buf, errbuf;
   integer off, limit, depth, endoff, errbuflen, errkind;
begin
   integer start, ch;
   errkind := 0;
   start := jsonfirstnonwhite(buf, off, limit - off);
   if start >= limit then
      begin
      jsonfail("unexpected end of JSON", errbuf, errbuflen, errkind);
      endoff := off
      end
   else if depth > jsonmaxdepth then
      begin
      jsonfail("JSON nesting is too deep", errbuf, errbuflen, errkind);
      endoff := off
      end
   else
      begin
      ch := buf[start];
      if ch = 34 then
         jsonskipstring(buf, start, limit, endoff, errbuf, errbuflen, errkind)
      else if ch = 123 then
         jsonskipcontainer(buf, start, limit, depth, 125, 1, endoff, errbuf, errbuflen, errkind)
      else if ch = 91 then
         jsonskipcontainer(buf, start, limit, depth, 93, 0, endoff, errbuf, errbuflen, errkind)
      else if ch = 116 then
         jsonskipliteral(buf, start, limit, "true", endoff, errbuf, errbuflen, errkind)
      else if ch = 102 then
         jsonskipliteral(buf, start, limit, "false", endoff, errbuf, errbuflen, errkind)
      else if ch = 110 then
         jsonskipliteral(buf, start, limit, "null", endoff, errbuf, errbuflen, errkind)
      else if ch = 45 | jsondigit(ch) != 0 then
         jsonskipnumber(buf, start, limit, endoff, errbuf, errbuflen, errkind)
      else
         begin
         jsonfail("unexpected byte in JSON", errbuf, errbuflen, errkind);
         endoff := start
         end
      end
end jsonskipvalue;

procedure jsonskipcontainer(buf, off, limit, depth, closebyte, iskeyed, endoff, errbuf, errbuflen, errkind);
   comment scans a JSON object, when closebyte is a closing brace and
   iskeyed is 1, or a JSON array, when closebyte is a closing bracket
   and iskeyed is 0, whose opening byte is at buf[off];
   value off, limit, depth, closebyte, iskeyed;
   integer array buf, errbuf;
   integer off, limit, depth, closebyte, iskeyed, endoff, errbuflen, errkind;
begin
   integer pos, first, done, keyend, colon, dummy;
   pos := off + 1;
   first := 1;
   done := 0;
   for dummy := 1 while done = 0 & errkind = 0 do
      begin
      pos := jsonfirstnonwhite(buf, pos, limit - pos);
      if pos >= limit then
         begin
         jsonfail("unterminated JSON container", errbuf, errbuflen, errkind);
         done := 1
         end
      else if buf[pos] = closebyte then
         begin
         pos := pos + 1;
         done := 1
         end
      else if first = 0 & buf[pos] = 44 then
         begin
         pos := pos + 1;
         pos := jsonfirstnonwhite(buf, pos, limit - pos)
         end
      else if first = 0 then
         begin
         jsonfail("expected comma in JSON container", errbuf, errbuflen, errkind);
         done := 1
         end;
      if done = 0 & errkind = 0 then
         begin
         if iskeyed != 0 then
            begin
            if pos >= limit then
               jsonfail("unterminated JSON container", errbuf, errbuflen, errkind)
            else if buf[pos] != 34 then
               jsonfail("expected a JSON object key", errbuf, errbuflen, errkind)
            else
               begin
               jsonskipstring(buf, pos, limit, keyend, errbuf, errbuflen, errkind);
               if errkind = 0 then
                  begin
                  colon := jsonfirstnonwhite(buf, keyend, limit - keyend);
                  if colon >= limit | buf[colon] != 58 then
                     jsonfail("expected colon after JSON object key", errbuf, errbuflen, errkind)
                  else
                     pos := colon + 1
                  end
               end
            end;
         if errkind = 0 then
            begin
            jsonskipvalue(buf, pos, limit, depth + 1, pos, errbuf, errbuflen, errkind);
            first := 0
            end
         end
      end;
   endoff := pos
end jsonskipcontainer;

comment ---------------------------------------------------------------
   Reading fields out of a JSON object.
   ------------------------------------------------------------------;

procedure jsonfindfield(buf, off, limit, key, valoff, vallen, found, errbuf, errbuflen, errkind);
   comment buf[off] must be the opening brace of a JSON object. Scans
   its top-level members only. When a member's key exactly equals the
   literal key (compared as raw JSON string bytes, which is safe
   because every key this client looks for is a plain ASCII identifier
   no JSON encoder would ever escape), reports that member's raw value
   byte range through valoff and vallen and sets found to 1. Otherwise
   sets found to 0. Every member is still scanned so a malformed later
   member is still reported through errkind;
   value off, limit;
   integer array buf, errbuf;
   integer off, limit, valoff, vallen, found, errbuflen, errkind;
   string key;
begin
   integer pos, first, done, keyend, colon, valstart, valend, dummy, match;
   found := 0;
   pos := off + 1;
   first := 1;
   done := 0;
   for dummy := 1 while done = 0 & errkind = 0 do
      begin
      pos := jsonfirstnonwhite(buf, pos, limit - pos);
      if pos >= limit then
         begin
         jsonfail("unterminated JSON object", errbuf, errbuflen, errkind);
         done := 1
         end
      else if buf[pos] = 125 then
         done := 1
      else if first = 0 & buf[pos] = 44 then
         begin
         pos := pos + 1;
         pos := jsonfirstnonwhite(buf, pos, limit - pos)
         end
      else if first = 0 then
         begin
         jsonfail("expected comma in JSON object", errbuf, errbuflen, errkind);
         done := 1
         end;
      if done = 0 & errkind = 0 then
         begin
         if buf[pos] != 34 then
            jsonfail("expected a JSON object key", errbuf, errbuflen, errkind)
         else
            begin
            jsonskipstring(buf, pos, limit, keyend, errbuf, errbuflen, errkind);
            if errkind = 0 then
               begin
               match := bufeqstrraw(buf, pos + 1, keyend - pos - 2, key);
               colon := jsonfirstnonwhite(buf, keyend, limit - keyend);
               if colon >= limit | buf[colon] != 58 then
                  jsonfail("expected colon after JSON object key", errbuf, errbuflen, errkind)
               else
                  begin
                  valstart := jsonfirstnonwhite(buf, colon + 1, limit - colon - 1);
                  jsonskipvalue(buf, valstart, limit, 1, valend, errbuf, errbuflen, errkind);
                  if errkind = 0 & match != 0 & found = 0 then
                     begin
                     found := 1;
                     valoff := valstart;
                     vallen := valend - valstart
                     end;
                  pos := valend;
                  first := 0
                  end
               end
            end
         end
      end
end jsonfindfield;

integer procedure bufeqstrraw(buf, off, blen, s);
   comment the same comparison as bufeqstr, kept as a distinct name in
   this file for JSON key comparisons - returns 1 when equal, 0
   otherwise, so it composes with the integer bookkeeping above;
   value off, blen;
   integer array buf;
   integer off, blen;
   string s;
begin
   bufeqstrraw := if bufeqstr(buf, off, blen, s) then 1 else 0
end bufeqstrraw;

comment ---------------------------------------------------------------
   String content - unescaping for the handful of fields this client
   reads as text, and escaping for the handful it builds.
   ------------------------------------------------------------------;

integer procedure hexnibble(b);
   value b;
   integer b;
begin
   hexnibble := hexdigitvalue(b)
end hexnibble;

integer procedure jsonstringcontent(buf, off, limit, dst, cap, dstlen);
   comment buf[off] must be the opening quote of a JSON string already
   proven well formed by jsonskipstring. Appends its unescaped content
   to dst at dstlen, encoding a unicode escape as UTF-8 and passing
   every raw byte of a multi-byte UTF-8 sequence through unchanged.
   Returns 0 on success or 1 if dst has no room. Surrogate pairs are
   combined into one code point, and an unpaired surrogate is encoded
   as the Unicode replacement character;
   value off, limit;
   integer array buf, dst;
   integer off, limit, cap, dstlen;
begin
   integer i, ch, result, codeval, hi, lo, cp;
   result := 0;
   i := off + 1;
   begin
      integer stop, dummy;
      stop := 0;
      for dummy := 1 while stop = 0 & result = 0 do
         begin
         ch := buf[i];
         if ch = 34 then stop := 1
         else if ch = 92 then
            begin
            i := i + 1;
            ch := buf[i];
            if ch = 34 then
               begin if bufputbyte(dst, cap, dstlen, 34) = 1 then result := 1; i := i + 1 end
            else if ch = 92 then
               begin if bufputbyte(dst, cap, dstlen, 92) = 1 then result := 1; i := i + 1 end
            else if ch = 47 then
               begin if bufputbyte(dst, cap, dstlen, 47) = 1 then result := 1; i := i + 1 end
            else if ch = 98 then
               begin if bufputbyte(dst, cap, dstlen, 8) = 1 then result := 1; i := i + 1 end
            else if ch = 102 then
               begin if bufputbyte(dst, cap, dstlen, 12) = 1 then result := 1; i := i + 1 end
            else if ch = 110 then
               begin if bufputbyte(dst, cap, dstlen, 10) = 1 then result := 1; i := i + 1 end
            else if ch = 114 then
               begin if bufputbyte(dst, cap, dstlen, 13) = 1 then result := 1; i := i + 1 end
            else if ch = 116 then
               begin if bufputbyte(dst, cap, dstlen, 9) = 1 then result := 1; i := i + 1 end
            else if ch = 117 then
               begin
               codeval := hexnibble(buf[i + 1]) * 4096 + hexnibble(buf[i + 2]) * 256
                  + hexnibble(buf[i + 3]) * 16 + hexnibble(buf[i + 4]);
               i := i + 5;
               if codeval >= 55296 & codeval <= 56319 & buf[i] = 92 & buf[i + 1] = 117 then
                  begin
                  hi := codeval;
                  lo := hexnibble(buf[i + 2]) * 4096 + hexnibble(buf[i + 3]) * 256
                     + hexnibble(buf[i + 4]) * 16 + hexnibble(buf[i + 5]);
                  i := i + 6;
                  cp := 65536 + (hi - 55296) * 1024 + (lo - 56320)
                  end
               else
                  cp := codeval;
               if jsonpututf8(dst, cap, dstlen, cp) = 1 then result := 1
               end
            else
               begin
               result := 1;
               i := i + 1
               end
            end
         else
            begin
            if bufputbyte(dst, cap, dstlen, ch) = 1 then result := 1;
            i := i + 1
            end
         end
   end;
   jsonstringcontent := result
end jsonstringcontent;

integer procedure jsonpututf8(dst, cap, dstlen, cp);
   comment appends one Unicode code point to dst, UTF-8 encoded. A code
   point outside the valid range, including an unpaired surrogate, is
   encoded as the replacement character U+FFFD;
   value cap, cp;
   integer array dst;
   integer cap, dstlen, cp;
begin
   integer c, result;
   c := cp;
   if c < 0 | (c >= 55296 & c <= 57343) | c > 1114111 then c := 65533;
   if c <= 127 then
      result := bufputbyte(dst, cap, dstlen, c)
   else if c <= 2047 then
      begin
      result := bufputbyte(dst, cap, dstlen, 192 + c % 64);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 64))
      end
   else if c <= 65535 then
      begin
      result := bufputbyte(dst, cap, dstlen, 224 + c % 4096);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 4096) % 64);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 64))
      end
   else
      begin
      result := bufputbyte(dst, cap, dstlen, 240 + c % 262144);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 262144) % 4096);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 4096) % 64);
      if result = 0 then result := bufputbyte(dst, cap, dstlen, 128 + intmod(c, 64))
      end;
   jsonpututf8 := result
end jsonpututf8;

integer procedure jsonwritestring(buf, cap, len, src, srcoff, srclen);
   comment appends a JSON string literal, including its quotes, holding
   the bytes src from srcoff for srclen, to buf at len. Control
   characters, the quote character and the backslash are escaped, and
   already-encoded UTF-8 continuation bytes are passed through
   unchanged, which is valid because JSON only requires escaping the
   handful of ASCII characters checked here;
   value cap, srcoff, srclen;
   integer array buf, src;
   integer cap, srcoff, srclen, len;
begin
   integer i, ch, result;
   result := bufputbyte(buf, cap, len, 34);
   for i := 0 step 1 until srclen - 1 do
      if result = 0 then
         begin
         ch := src[srcoff + i];
         if ch = 34 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 34)
            end
         else if ch = 92 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 92)
            end
         else if ch = 10 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 110)
            end
         else if ch = 13 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 114)
            end
         else if ch = 9 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 116)
            end
         else if ch < 32 then
            begin
            result := bufputbyte(buf, cap, len, 92);
            if result = 0 then result := bufputbyte(buf, cap, len, 117);
            if result = 0 then result := bufputbyte(buf, cap, len, 48);
            if result = 0 then result := bufputbyte(buf, cap, len, 48);
            if result = 0 then result := bufputbyte(buf, cap, len, 48 + ch % 16);
            if result = 0 then result := bufputbyte(buf, cap, len,
               if intmod(ch, 16) < 10 then 48 + intmod(ch, 16) else 87 + intmod(ch, 16))
            end
         else
            result := bufputbyte(buf, cap, len, ch)
         end;
   if result = 0 then result := bufputbyte(buf, cap, len, 34);
   jsonwritestring := result
end jsonwritestring;

comment ---------------------------------------------------------------
   Numbers. Convex may encode an integral value in decimal form such as
   0.0 or 1.0, so a JSON number is accepted as an integer exactly when
   its mathematical value is a whole number that fits a 32-bit signed
   integer, regardless of whether it was spelled with a fraction or an
   exponent.
   ------------------------------------------------------------------;

integer procedure jsonparseint(buf, off, len, ok);
   comment parses the JSON number occupying buf from off for len bytes.
   Sets ok to 1 and returns the value when it is mathematically
   integral and fits a 32-bit signed integer, otherwise sets ok to 0
   and returns 0. Numbers are restricted to plain decimal or exponent
   form without a leading plus sign, matching the JSON grammar;
   value off, len;
   integer array buf;
   integer off, len, ok;
begin
   integer i, neg, intpart, frac, fracdigits, exp, expneg, ch, bad, result;
   bad := 0;
   i := off;
   neg := 0;
   intpart := 0;
   frac := 0;
   fracdigits := 0;
   exp := 0;
   expneg := 0;
   if len <= 0 then bad := 1
   else if buf[i] = 45 then begin neg := 1; i := i + 1 end;
   if bad = 0 & i >= off + len then bad := 1
   else if bad = 0 & jsondigit(buf[i]) = 0 then bad := 1;
   if bad = 0 then
      begin
      if buf[i] = 48 then i := i + 1
      else
         begin
         integer stop, dummy;
         stop := 0;
         intpart := 0;
         for dummy := 1 while stop = 0 do
            begin
            if i >= off + len then stop := 1
            else if jsondigit(buf[i]) = 0 then stop := 1
            else
               begin
               if intpart > 200000000 then bad := 1;
               intpart := intpart * 10 + (buf[i] - 48);
               i := i + 1
               end
            end
         end
      end;
   if bad = 0 & i < off + len & buf[i] = 46 then
      begin
      i := i + 1;
      if i >= off + len | jsondigit(buf[i]) = 0 then bad := 1
      else
         begin
         integer stop, dummy;
         stop := 0;
         for dummy := 1 while stop = 0 do
            begin
            if i >= off + len then stop := 1
            else if jsondigit(buf[i]) = 0 then stop := 1
            else
               begin
               if buf[i] != 48 then frac := 1;
               fracdigits := fracdigits + 1;
               i := i + 1
               end
            end
         end
      end;
   if bad = 0 & i < off + len & (buf[i] = 101 | buf[i] = 69) then
      begin
      i := i + 1;
      if i < off + len & (buf[i] = 43 | buf[i] = 45) then
         begin
         expneg := if buf[i] = 45 then 1 else 0;
         i := i + 1
         end;
      if i >= off + len | jsondigit(buf[i]) = 0 then bad := 1
      else
         begin
         integer stop, dummy;
         stop := 0;
         exp := 0;
         for dummy := 1 while stop = 0 do
            begin
            if i >= off + len then stop := 1
            else if jsondigit(buf[i]) = 0 then stop := 1
            else
               begin
               if exp < 100 then exp := exp * 10 + (buf[i] - 48);
               i := i + 1
               end
            end
         end
      end;
   if bad = 0 & i != off + len then bad := 1;
   if bad = 0 & frac != 0 & expneg = 0 & exp < fracdigits then bad := 1;
   if bad = 0 & frac != 0 & expneg != 0 then bad := 1;
   if bad = 0 & expneg = 0 & exp > 9 then bad := 1;
   result := intpart;
   if bad = 0 & expneg = 0 then
      begin
      integer k;
      for k := 1 step 1 until exp - fracdigits do
         begin
         if result > 200000000 then bad := 1;
         result := result * 10
         end
      end;
   if bad = 0 & result > 2147483647 then bad := 1;
   ok := if bad = 0 then 1 else 0;
   jsonparseint := if bad = 0 then (if neg != 0 then -result else result) else 0
end jsonparseint;

comment ---------------------------------------------------------------
   Array elements. Scans from the start of the array on every call
   rather than keeping a cursor, which is fine for the short arrays -
   a handful of Live query-set modifications - this client ever reads
   this way.
   ------------------------------------------------------------------;

procedure jsonarrayelementat(buf, off, limit, index, elemoff, elemlen, found, errbuf, errbuflen, errkind);
   comment buf[off] must be the opening bracket of a JSON array.
   Reports the byte range of its index-th element, zero based, through
   elemoff and elemlen, and sets found to 1. Sets found to 0, without
   an error, when the array has index or fewer elements;
   value off, limit, index;
   integer array buf, errbuf;
   integer off, limit, index, elemoff, elemlen, found, errbuflen, errkind;
begin
   integer pos, first, done, at, valend, dummy;
   found := 0;
   pos := off + 1;
   first := 1;
   done := 0;
   at := 0;
   for dummy := 1 while done = 0 & errkind = 0 do
      begin
      pos := jsonfirstnonwhite(buf, pos, limit - pos);
      if pos >= limit then
         begin
         jsonfail("unterminated JSON array", errbuf, errbuflen, errkind);
         done := 1
         end
      else if buf[pos] = 93 then
         done := 1
      else if first = 0 & buf[pos] = 44 then
         begin
         pos := pos + 1;
         pos := jsonfirstnonwhite(buf, pos, limit - pos)
         end
      else if first = 0 then
         begin
         jsonfail("expected comma in JSON array", errbuf, errbuflen, errkind);
         done := 1
         end;
      if done = 0 & errkind = 0 then
         begin
         jsonskipvalue(buf, pos, limit, 1, valend, errbuf, errbuflen, errkind);
         if errkind = 0 then
            begin
            if at = index then
               begin
               found := 1;
               elemoff := jsonfirstnonwhite(buf, pos, limit - pos);
               elemlen := valend - elemoff;
               done := 1
               end
            else
               begin
               pos := valend;
               first := 0;
               at := at + 1
               end
            end
         end
      end
end jsonarrayelementat;
