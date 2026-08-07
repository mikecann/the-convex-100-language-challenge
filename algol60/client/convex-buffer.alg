comment convex-buffer.alg - byte buffers over ALGOL 60 integer arrays.
   ALGOL 60 has no byte, character or string variable, so every buffer in
   this client is an integer array holding one byte, 0 to 255, per
   element, paired with an ordinary integer variable that the caller owns
   and passes by name to record how many of those elements are in use.
   Every procedure here either returns 0 for success and 1 when the
   destination buffer's capacity would be exceeded, or is a pure query
   that cannot fail. Capacity is always enforced before anything is
   written, so a buffer this module has appended to is never left holding
   a partial byte;

integer procedure bufputbyte(buf, cap, len, b);
   comment appends one byte, masked to 0 through 255, to buf at
   position len, then advances len;
   value cap, b;
   integer array buf;
   integer cap, b, len;
begin
   integer result;
   if len < 0 then len := 0;
   if len >= cap then result := 1
   else
      begin
      buf[len] := if b < 0 then 0 else if b > 255 then b - (b % 256) * 256 else b;
      len := len + 1;
      result := 0
      end;
   bufputbyte := result
end bufputbyte;

integer procedure bufputbytes(buf, cap, len, src, srcoff, srclen);
   comment appends srclen bytes from src, starting at srcoff, to buf at
   position len. Writes nothing at all if the whole run would not fit;
   value cap, srcoff, srclen;
   integer array buf, src;
   integer cap, srcoff, srclen, len;
begin
   integer i, result;
   if len < 0 then len := 0;
   if srclen < 0 then srclen := 0;
   if len + srclen > cap then result := 1
   else
      begin
      for i := 0 step 1 until srclen - 1 do
         buf[len + i] := src[srcoff + i];
      len := len + srclen;
      result := 0
      end;
   bufputbytes := result
end bufputbytes;

comment a fixed scratch capacity for one literal-string append. Every
   protocol fragment this client writes as a quoted literal -- request
   lines, header names, fixed JSON punctuation -- fits comfortably inside
   it, and the length is asserted by cxstrbytes truncating rather than
   overrunning;
integer procedure bufputstr(buf, cap, len, s);
   comment appends the bytes of a quoted ALGOL 60 string literal to buf
   at position len;
   value cap;
   integer array buf;
   integer cap, len;
   string s;
begin
   integer array scratch[0:511];
   integer n, result;
   n := cxstrbytes(s, scratch, 512);
   result := bufputbytes(buf, cap, len, scratch, 0, n);
   bufputstr := result
end bufputstr;

integer procedure bufputint(buf, cap, len, n);
   comment appends the decimal text of n, which may be negative, to buf
   at position len;
   value cap, n;
   integer array buf;
   integer cap, n, len;
begin
   integer array digits[0:19];
   integer magnitude, count, i, result, dummy;
   result := 0;
   magnitude := if n < 0 then -n else n;
   count := 0;
   if magnitude = 0 then
      begin
      digits[0] := 48;
      count := 1
      end
   else
      begin
      for dummy := 1 while magnitude > 0 do
         begin
         digits[count] := 48 + (magnitude - (magnitude % 10) * 10);
         magnitude := magnitude % 10;
         count := count + 1
         end
      end;
   if n < 0 then
      if bufputbyte(buf, cap, len, 45) = 1 then result := 1;
   if result = 0 then
      for i := count - 1 step -1 until 0 do
         if bufputbyte(buf, cap, len, digits[i]) = 1 then result := 1;
   bufputint := result
end bufputint;

Boolean procedure bufeqstr(buf, off, blen, s);
   comment reports whether buf, starting at off for blen bytes, is
   exactly equal to the quoted string literal s;
   value off, blen;
   integer array buf;
   integer off, blen;
   string s;
begin
   integer array scratch[0:511];
   integer n, i;
   Boolean same;
   n := cxstrbytes(s, scratch, 512);
   same := n = blen;
   if same then
      for i := 0 step 1 until blen - 1 do
         if buf[off + i] != scratch[i] then same := false;
   bufeqstr := same
end bufeqstr;

integer procedure upperbyte(b);
   comment folds one ASCII lower case letter to upper case, leaving
   every other byte value unchanged;
   value b;
   integer b;
begin
   upperbyte := if b >= 97 & b <= 122 then b - 32 else b
end upperbyte;

Boolean procedure bufieqstr(buf, off, blen, s);
   comment an ASCII case-insensitive form of bufeqstr, used for HTTP
   header names;
   value off, blen;
   integer array buf;
   integer off, blen;
   string s;
begin
   integer array scratch[0:511];
   integer n, i;
   Boolean same;
   n := cxstrbytes(s, scratch, 512);
   same := n = blen;
   if same then
      for i := 0 step 1 until blen - 1 do
         if upperbyte(buf[off + i]) != upperbyte(scratch[i]) then
            same := false;
   bufieqstr := same
end bufieqstr;

integer procedure bufindexof(buf, off, blen, ch);
   comment the absolute index of the first occurrence of byte ch within
   buf, starting at off for blen bytes, or negative one when absent;
   value off, blen, ch;
   integer array buf;
   integer off, blen, ch;
begin
   integer i, found;
   found := -1;
   for i := 0 step 1 until blen - 1 do
      if buf[off + i] = ch & found < 0 then found := off + i;
   bufindexof := found
end bufindexof;

comment trims ASCII space and horizontal tab from both ends of a byte
   range, reporting the trimmed offset and length through by-name
   parameters;
procedure buftrim(buf, off, blen, trimoff, trimlen);
   value off, blen;
   integer array buf;
   integer off, blen, trimoff, trimlen;
begin
   integer lo, hi, dummy;
   lo := off;
   hi := off + blen - 1;
   for dummy := 1 while lo <= hi & (buf[lo] = 32 | buf[lo] = 9) do lo := lo + 1;
   for dummy := 1 while hi >= lo & (buf[hi] = 32 | buf[hi] = 9) do hi := hi - 1;
   trimoff := lo;
   trimlen := if hi < lo then 0 else hi - lo + 1
end buftrim;

integer procedure bufparseuint(buf, off, blen);
   comment parses an unquoted, non-negative decimal integer occupying
   exactly buf from off for blen bytes. Returns negative one if blen is
   zero, any byte is not an ASCII digit, or the value would not fit a
   32-bit signed integer;
   value off, blen;
   integer array buf;
   integer off, blen;
begin
   integer i, numvalue, digit, result;
   numvalue := 0;
   result := -1;
   if blen > 0 & blen <= 9 then
      begin
      result := 0;
      for i := 0 step 1 until blen - 1 do
         begin
         digit := buf[off + i] - 48;
         if digit < 0 | digit > 9 then result := -1
         else numvalue := numvalue * 10 + digit
         end
      end;
   bufparseuint := if result < 0 then -1 else numvalue
end bufparseuint;

integer procedure hexdigitvalue(b);
   comment the value of one ASCII hexadecimal digit, or negative one;
   value b;
   integer b;
begin
   hexdigitvalue :=
      if b >= 48 & b <= 57 then b - 48
      else if b >= 97 & b <= 102 then b - 97 + 10
      else if b >= 65 & b <= 70 then b - 65 + 10
      else -1
end hexdigitvalue;

integer procedure bufparsehex(buf, off, blen);
   comment parses a hexadecimal chunk size, as used by HTTP chunked
   transfer encoding. Returns negative one for an empty or invalid run,
   or if the value would exceed the client's byte budget;
   value off, blen;
   integer array buf;
   integer off, blen;
begin
   integer i, numvalue, digit, bad;
   numvalue := 0;
   bad := 0;
   if blen <= 0 | blen > 6 then bad := 1
   else
      for i := 0 step 1 until blen - 1 do
         begin
         digit := hexdigitvalue(buf[off + i]);
         if digit < 0 then bad := 1
         else numvalue := numvalue * 16 + digit
         end;
   bufparsehex := if bad = 1 then -1 else numvalue
end bufparsehex;

integer procedure intmod(a, b);
   comment the non-negative remainder of a divided by b, for a, b >= 0.
   ALGOL 60's percent operator is truncating integer division, not
   remainder, so every mod in this client is written through this
   procedure instead of reimplementing the subtraction each time;
   value a, b;
   integer a, b;
begin
   intmod := a - (a % b) * b
end intmod;

comment base 64 encoding, RFC 4648, standard alphabet with equals-sign
   padding. Used for the Live sync profile's version timestamps and for
   the WebSocket handshake's Sec-WebSocket-Key;
integer procedure b64char(sextet);
   value sextet;
   integer sextet;
begin
   b64char :=
      if sextet < 26 then sextet + 65
      else if sextet < 52 then sextet - 26 + 97
      else if sextet < 62 then sextet - 52 + 48
      else if sextet = 62 then 43
      else 47
end b64char;

integer procedure b64value(ch);
   comment the six-bit value of one base 64 alphabet character, or
   negative one when ch is not part of the alphabet;
   value ch;
   integer ch;
begin
   b64value :=
      if ch >= 65 & ch <= 90 then ch - 65
      else if ch >= 97 & ch <= 122 then ch - 97 + 26
      else if ch >= 48 & ch <= 57 then ch - 48 + 52
      else if ch = 43 then 62
      else if ch = 47 then 63
      else -1
end b64value;

integer procedure b64encode(src, srcoff, srclen, dst, cap, dstlen);
   comment appends the base 64 encoding of srclen bytes from src,
   starting at srcoff, to dst at position dstlen, including equals-sign
   padding so the output length is always a multiple of four;
   value srcoff, srclen, cap;
   integer array src, dst;
   integer srcoff, srclen, cap, dstlen;
begin
   integer i, n, b0, b1, b2, result, dummy;
   result := 0;
   i := 0;
   for dummy := 1 while i < srclen & result = 0 do
      begin
      n := srclen - i;
      b0 := src[srcoff + i];
      b1 := if n > 1 then src[srcoff + i + 1] else 0;
      b2 := if n > 2 then src[srcoff + i + 2] else 0;
      if bufputbyte(dst, cap, dstlen, b64char(b0 % 4)) = 1 then result := 1;
      if result = 0 then
         if bufputbyte(dst, cap, dstlen,
               b64char(intmod(b0, 4) * 16 + b1 % 16)) = 1 then result := 1;
      if result = 0 then
         if n > 1 then
            begin
            if bufputbyte(dst, cap, dstlen,
                  b64char(intmod(b1, 16) * 4 + b2 % 64)) = 1 then result := 1
            end
         else
            if bufputbyte(dst, cap, dstlen, 61) = 1 then result := 1;
      if result = 0 then
         if n > 2 then
            begin
            if bufputbyte(dst, cap, dstlen, b64char(intmod(b2, 64))) = 1 then
               result := 1
            end
         else
            if bufputbyte(dst, cap, dstlen, 61) = 1 then result := 1;
      i := i + 3
      end;
   b64encode := result
end b64encode;

integer procedure b64decode(src, srcoff, srclen, dst, cap, dstlen);
   comment decodes exactly one base 64 group of four characters,
   starting at srcoff, appending its bytes to dst at position dstlen.
   Returns 0 on success, or 1 if srclen is not four, the characters are
   not valid base 64, or dst has no room. A trailing equals-sign pad
   character is honoured;
   value srcoff, srclen, cap;
   integer array src, dst;
   integer srcoff, srclen, cap, dstlen;
begin
   integer v0, v1, v2, v3, pad, result;
   result := 0;
   if srclen != 4 then result := 1
   else
      begin
      pad := 0;
      if src[srcoff + 3] = 61 then pad := pad + 1;
      if src[srcoff + 2] = 61 then pad := pad + 1;
      v0 := b64value(src[srcoff]);
      v1 := b64value(src[srcoff + 1]);
      v2 := if pad >= 2 then 0 else b64value(src[srcoff + 2]);
      v3 := if pad >= 1 then 0 else b64value(src[srcoff + 3]);
      if v0 < 0 | v1 < 0 | v2 < 0 | v3 < 0 then result := 1
      else
         begin
         if bufputbyte(dst, cap, dstlen, v0 * 4 + v1 % 16) = 1 then result := 1;
         if result = 0 & pad < 2 then
            if bufputbyte(dst, cap, dstlen, intmod(v1, 16) * 16 + v2 % 4) = 1 then
               result := 1;
         if result = 0 & pad < 1 then
            if bufputbyte(dst, cap, dstlen, intmod(v2, 4) * 64 + v3) = 1 then
               result := 1
         end
      end;
   b64decode := result
end b64decode;

comment hexadecimal encoding, lower case, used for the Live session id;
integer procedure hexencode(src, srcoff, srclen, dst, cap, dstlen);
   value srcoff, srclen, cap;
   integer array src, dst;
   integer srcoff, srclen, cap, dstlen;
begin
   integer i, b, hi, lo, result;
   result := 0;
   for i := 0 step 1 until srclen - 1 do
      begin
      b := src[srcoff + i];
      hi := b % 16;
      lo := intmod(b, 16);
      if bufputbyte(dst, cap, dstlen, if hi < 10 then hi + 48 else hi - 10 + 97) = 1 then
         result := 1;
      if bufputbyte(dst, cap, dstlen, if lo < 10 then lo + 48 else lo - 10 + 97) = 1 then
         result := 1
      end;
   hexencode := result
end hexencode;
