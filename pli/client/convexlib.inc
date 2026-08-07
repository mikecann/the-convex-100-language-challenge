 /********************************************************************/
 /* Convex client for PL/I -- procedures.                            */
 /*                                                                  */
 /* %included at the end of the program block so that PL/I's         */
 /* sequential flow never falls into an internal procedure. These    */
 /* procedures share the enclosing block's storage, which is where   */
 /* the client's state lives.                                        */
 /********************************************************************/

 /*==================================================================*/
 /* Byte buffers                                                     */
 /*                                                                  */
 /* A buffer is libc storage plus a used length. Buffers are         */
 /* addressed by a small index rather than a pointer so that PL/I    */
 /* never has to describe a structure it does not own.               */
 /*==================================================================*/

 /* Reserve room for 'need' more bytes, doubling so that appending a */
 /* byte at a time stays linear overall.                             */
 bgrow: proc( b, need );
   dcl   b                   fixed bin(31);
   dcl   need                fixed bin(31);
   dcl   want                fixed bin(31);
   dcl   fresh               ptr;
   if bcap(b) - blen(b) >= need then return;
   want = bcap(b);
   if want < 256 then want = 256;
   do while( want - blen(b) < need );
     want = want * 2;
     end;
   fresh = c_realloc( bdata(b), want );
   if fresh = sysnull() then call panic( 'out of memory' );
   bdata(b) = fresh;
   bcap(b)  = want;
   end bgrow;

 /* Forget the contents without releasing the storage, so a buffer   */
 /* reused every iteration settles at its high-water mark.           */
 bclear: proc( b );
   dcl   b                   fixed bin(31);
   blen(b) = 0;
   end bclear;

 bput: proc( b, src, n );
   dcl   b                   fixed bin(31);
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   ignore              ptr;
   if n <= 0 then return;
   call bgrow( b, n );
   ignore = c_memcpy( ptradd( bdata(b), blen(b) ), src, n );
   blen(b) = blen(b) + n;
   end bput;

 /* Append one byte given as a one character string.                 */
 bputb: proc( b, c );
   dcl   b                   fixed bin(31);
   dcl   c                   char(1);
   dcl   here                ptr;
   call bgrow( b, 1 );
   here = ptradd( bdata(b), blen(b) );
   here->byte1 = c;
   blen(b) = blen(b) + 1;
   end bputb;

 /* Append a short literal. The parameter is a fixed length string   */
 /* because this compiler cannot build an adjustable dummy argument, */
 /* so trailing blanks mark the end. No JSON punctuation or Convex   */
 /* field name this client writes ends in a blank.                   */
 bputt: proc( b, t );
   dcl   b                   fixed bin(31);
   dcl   t                   char(64);
   dcl   i                   fixed bin(31);
   dcl   n                   fixed bin(31);
   n = 0;
   do i = 1 to 64;
     if substr( t, i, 1 ) ^= ' ' then n = i;
     end;
   if n = 0 then return;
   call bput( b, addr(t), n );
   end bputt;

 /* Append a signed decimal integer. PL/I's own arithmetic to        */
 /* character conversion pads and aligns for stream output, which is */
 /* the wrong shape for a byte stream that has to match exactly.     */
 bputi: proc( b, v );
   dcl   b                   fixed bin(31);
   dcl   v                   fixed bin(31);
   dcl   digits              char(16);
   dcl   n                   fixed bin(31);
   dcl   rest                fixed bin(31);
   dcl   i                   fixed bin(31);
   if v = 0 then do;
     call bputb( b, '0' );
     return;
     end;
   rest = v;
   if rest < 0 then do;
     call bputb( b, '-' );
     rest = -rest;
     end;
   n = 0;
   do while( rest > 0 );
     n = n + 1;
     substr( digits, n, 1 ) = substr( hexdigits, mod(rest,10) + 1, 1 );
     rest = rest / 10;
     end;
   do i = n to 1 by -1;
     call bputb( b, substr( digits, i, 1 ) );
     end;
   end bputi;

 /* Append text as a JSON string body -- quotes are the caller's.    */
 /* Control characters below 0x20 become \u00xx, which keeps the     */
 /* output valid for any byte the adapter might have to echo.        */
 bputesc: proc( b, src, n );
   dcl   b                   fixed bin(31);
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   code                fixed bin(31);
   dcl   here                ptr;
   dcl   c                   char(1);
   do i = 0 to n - 1;
     here = ptradd( src, i );
     c = here->byte1;
     code = byteval( here );
     if c = '"' then call bputt( b, '\"' );
     else if c = '\' then call bputt( b, '\\' );
     else if code = 8 then call bputt( b, '\b' );
     else if code = 9 then call bputt( b, '\t' );
     else if code = 10 then call bputt( b, '\n' );
     else if code = 12 then call bputt( b, '\f' );
     else if code = 13 then call bputt( b, '\r' );
     else if code < 32 then do;
       call bputt( b, '\u00' );
       call bputb( b, substr( hexdigits, code / 16 + 1, 1 ) );
       call bputb( b, substr( hexdigits, mod(code,16) + 1, 1 ) );
       end;
     else call bputb( b, c );
     end;
   end bputesc;

 /* NUL terminate in place without counting the NUL as content, so   */
 /* the result can be handed to a C entry point expecting a string.  */
 bcstr: proc( b ) returns( ptr );
   dcl   b                   fixed bin(31);
   dcl   here                ptr;
   call bgrow( b, 1 );
   here = ptradd( bdata(b), blen(b) );
   here->byte1 = '00'x;
   return( bdata(b) );
   end bcstr;

 /* PL/I has no unsigned type and no character-to-ordinal builtin    */
 /* that agrees with a byte stream, so a byte is converted by         */
 /* dropping it into the low end of a zeroed 32 bit word. These two   */
 /* procedures are the only place that overlay happens.               */
 byteof: proc( c ) returns( fixed bin(31) );
   dcl   c                   char(1);
   dcl   w                   fixed bin(31);
   w = 0;
   substr( addr(w)->byte4, 1, 1 ) = c;
   return( w );
   end byteof;

 chrv: proc( v ) returns( char(1) );
   dcl   v                   fixed bin(31);
   dcl   w                   fixed bin(31);
   w = mod( v, 256 );
   return( addr(w)->byte1 );
   end chrv;

 byteval: proc( p ) returns( fixed bin(31) );
   dcl   p                   ptr;
   return( byteof( p->byte1 ) );
   end byteval;

 /*==================================================================*/
 /* JSON                                                             */
 /*                                                                  */
 /* The parser validates a document and records where every value    */
 /* starts and ends. Values are handed back as the exact text slice  */
 /* they were parsed from: a Convex value therefore travels through  */
 /* this client byte for byte, with no PL/I value tree in the middle */
 /* to lose a large integer or reorder an object.                    */
 /*==================================================================*/

 /* Read one field of node 'i' of document 'd'. Nodes are a flat     */
 /* array of 32 bit words because the compiler's structure support   */
 /* does not extend to an array of structures in libc storage.       */
 nf: proc( d, i, f ) returns( fixed bin(31) );
   dcl  (d,i,f)              fixed bin(31);
   dcl   here                ptr;
   here = ptradd( dnodes(d), (i * 7 + f) * 4 );
   return( here->word32 );
   end nf;

 setnf: proc( d, i, f, v );
   dcl  (d,i,f,v)            fixed bin(31);
   dcl   here                ptr;
   here = ptradd( dnodes(d), (i * 7 + f) * 4 );
   here->word32 = v;
   end setnf;

 /* Field numbers within a node.                                     */
 /* 0 kind, 1 start, 2 stop, 3 first child, 4 next sibling,          */
 /* 5 member name start, 6 member name length.                       */

 jbyte: proc( d, at ) returns( fixed bin(31) );
   dcl  (d,at)               fixed bin(31);
   if at < 0 then return( -1 );
   if at >= dtlen(d) then return( -1 );
   return( byteval( ptradd( dtext(d), at ) ) );
   end jbyte;

 jskipws: proc( d );
   dcl   d                   fixed bin(31);
   dcl   c                   fixed bin(31);
   do while( '1'b );
     c = jbyte( d, dpos(d) );
     if c = 32 | c = 9 | c = 10 | c = 13 then dpos(d) = dpos(d) + 1;
     else return;
     end;
   end jskipws;

 jnewnode: proc( d ) returns( fixed bin(31) );
   dcl   d                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   dcl   fresh               ptr;
   if dcount(d) >= dcap(d) then do;
     if dcap(d) >= MAX_JSON_NODES then do;
       dok(d) = 0;
       return( -1 );
       end;
     dcap(d) = dcap(d) * 2;
     if dcap(d) < 64 then dcap(d) = 64;
     if dcap(d) > MAX_JSON_NODES then dcap(d) = MAX_JSON_NODES;
     fresh = c_realloc( dnodes(d), dcap(d) * 28 );
     if fresh = sysnull() then call panic( 'out of memory' );
     dnodes(d) = fresh;
     end;
   idx = dcount(d);
   dcount(d) = dcount(d) + 1;
   call setnf( d, idx, 0, J_NULL );
   call setnf( d, idx, 1, 0 );
   call setnf( d, idx, 2, 0 );
   call setnf( d, idx, 3, -1 );
   call setnf( d, idx, 4, -1 );
   call setnf( d, idx, 5, 0 );
   call setnf( d, idx, 6, 0 );
   return( idx );
   end jnewnode;

 /* Parse the whole of 'text' as one JSON document. Returns the root */
 /* node index, or -1 when the text is not valid JSON or has         */
 /* anything but blanks after the value.                             */
 jparse: proc( d, text, textlen ) returns( fixed bin(31) );
   dcl   d                   fixed bin(31);
   dcl   text                ptr;
   dcl   textlen             fixed bin(31);
   dcl   root                fixed bin(31);
   dtext(d)  = text;
   dtlen(d)  = textlen;
   dcount(d) = 0;
   dpos(d)   = 0;
   ddepth(d) = 0;
   dok(d)    = 1;
   root = jvalue( d );
   if dok(d) = 0 then return( -1 );
   call jskipws( d );
   if dpos(d) ^= dtlen(d) then return( -1 );
   return( root );
   end jparse;

 jvalue: proc( d ) returns( fixed bin(31) ) recursive;
   dcl   d                   fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   if dok(d) = 0 then return( -1 );
   ddepth(d) = ddepth(d) + 1;
   if ddepth(d) > 64 then do;
     dok(d) = 0;
     ddepth(d) = ddepth(d) - 1;
     return( -1 );
     end;
   call jskipws( d );
   c = jbyte( d, dpos(d) );
   select;
     when( c = 123 ) idx = jobject( d );          /* {                */
     when( c = 91 )  idx = jarray( d );           /* [                */
     when( c = 34 )  idx = jstring( d );          /* "                */
     when( c = 116 ) idx = jliteral( d, 'true    ', J_TRUE );
     when( c = 102 ) idx = jliteral( d, 'false   ', J_FALSE );
     when( c = 110 ) idx = jliteral( d, 'null    ', J_NULL );
     when( c = 45 | ( c >= 48 & c <= 57 ) ) idx = jnumber( d );
     otherwise do;
       dok(d) = 0;
       idx = -1;
       end;
     end;
   ddepth(d) = ddepth(d) - 1;
   return( idx );
   end jvalue;

 jliteral: proc( d, want, kind ) returns( fixed bin(31) );
   dcl   d                   fixed bin(31);
   dcl   want                char(8);
   dcl   kind                fixed bin(31);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   n = 0;
   do i = 1 to 8;
     if substr( want, i, 1 ) ^= ' ' then n = i;
     end;
   do i = 1 to n;
     if jbyte( d, dpos(d) + i - 1 ) ^= byteof( substr(want,i,1) ) then do;
       dok(d) = 0;
       return( -1 );
       end;
     end;
   idx = jnewnode( d );
   if idx < 0 then return( -1 );
   call setnf( d, idx, 0, kind );
   call setnf( d, idx, 1, dpos(d) );
   call setnf( d, idx, 2, dpos(d) + n );
   dpos(d) = dpos(d) + n;
   return( idx );
   end jliteral;

 jnumber: proc( d ) returns( fixed bin(31) );
   dcl   d                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   digits              fixed bin(31);
   at = dpos(d);
   if jbyte( d, at ) = 45 then at = at + 1;
   digits = 0;
   do while( '1'b );
     c = jbyte( d, at );
     if c >= 48 & c <= 57 then do;
       digits = digits + 1;
       at = at + 1;
       end;
     else leave;
     end;
   if digits = 0 then do;
     dok(d) = 0;
     return( -1 );
     end;
   /* JSON forbids a leading zero on a multi digit integer part.      */
   /* Accepting one would let 01 through as a number and quietly      */
   /* change what the client believes the backend sent.               */
   if digits > 1 & jbyte( d, at - digits ) = 48 then do;
     dok(d) = 0;
     return( -1 );
     end;
   if jbyte( d, at ) = 46 then do;                /* .                */
     at = at + 1;
     digits = 0;
     do while( '1'b );
       c = jbyte( d, at );
       if c >= 48 & c <= 57 then do;
         digits = digits + 1;
         at = at + 1;
         end;
       else leave;
       end;
     if digits = 0 then do;
       dok(d) = 0;
       return( -1 );
       end;
     end;
   c = jbyte( d, at );
   if c = 101 | c = 69 then do;                   /* e E              */
     at = at + 1;
     c = jbyte( d, at );
     if c = 43 | c = 45 then at = at + 1;
     digits = 0;
     do while( '1'b );
       c = jbyte( d, at );
       if c >= 48 & c <= 57 then do;
         digits = digits + 1;
         at = at + 1;
         end;
       else leave;
       end;
     if digits = 0 then do;
       dok(d) = 0;
       return( -1 );
       end;
     end;
   idx = jnewnode( d );
   if idx < 0 then return( -1 );
   call setnf( d, idx, 0, J_NUMBER );
   call setnf( d, idx, 1, dpos(d) );
   call setnf( d, idx, 2, at );
   dpos(d) = at;
   return( idx );
   end jnumber;

 /* Scan a string, validating escapes. The node records the quoted   */
 /* extent so a caller can copy the raw text back out unchanged.     */
 jstring: proc( d ) returns( fixed bin(31) );
   dcl   d                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   i                   fixed bin(31);
   at = dpos(d) + 1;
   do while( '1'b );
     c = jbyte( d, at );
     if c < 0 then do;
       dok(d) = 0;
       return( -1 );
       end;
     if c = 34 then leave;                        /* "                */
     if c = 92 then do;                           /* \                */
       at = at + 1;
       c = jbyte( d, at );
       select;
         when( c = 34 | c = 92 | c = 47 | c = 98 | c = 102 | c = 110 |
               c = 114 | c = 116 ) at = at + 1;
         when( c = 117 ) do;                      /* u                */
           at = at + 1;
           do i = 1 to 4;
             c = jbyte( d, at );
             if ^( ( c >= 48 & c <= 57 ) | ( c >= 65 & c <= 70 ) |
                   ( c >= 97 & c <= 102 ) ) then do;
               dok(d) = 0;
               return( -1 );
               end;
             at = at + 1;
             end;
           end;
         otherwise do;
           dok(d) = 0;
           return( -1 );
           end;
         end;
       end;
     else if c < 32 then do;
       dok(d) = 0;
       return( -1 );
       end;
     else at = at + 1;
     end;
   idx = jnewnode( d );
   if idx < 0 then return( -1 );
   call setnf( d, idx, 0, J_STRING );
   call setnf( d, idx, 1, dpos(d) );
   call setnf( d, idx, 2, at + 1 );
   dpos(d) = at + 1;
   return( idx );
   end jstring;

 jarray: proc( d ) returns( fixed bin(31) ) recursive;
   dcl   d                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   dcl   kid                 fixed bin(31);
   dcl   prev                fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   at                  fixed bin(31);
   at  = dpos(d);
   idx = jnewnode( d );
   if idx < 0 then return( -1 );
   call setnf( d, idx, 0, J_ARRAY );
   call setnf( d, idx, 1, at );
   dpos(d) = at + 1;
   prev = -1;
   call jskipws( d );
   if jbyte( d, dpos(d) ) = 93 then do;           /* ]                */
     dpos(d) = dpos(d) + 1;
     call setnf( d, idx, 2, dpos(d) );
     return( idx );
     end;
   do while( '1'b );
     kid = jvalue( d );
     if dok(d) = 0 then return( -1 );
     if prev < 0 then call setnf( d, idx, 3, kid );
     else call setnf( d, prev, 4, kid );
     prev = kid;
     call jskipws( d );
     c = jbyte( d, dpos(d) );
     if c = 44 then dpos(d) = dpos(d) + 1;        /* ,                */
     else if c = 93 then do;
       dpos(d) = dpos(d) + 1;
       call setnf( d, idx, 2, dpos(d) );
       return( idx );
       end;
     else do;
       dok(d) = 0;
       return( -1 );
       end;
     end;
   end jarray;

 jobject: proc( d ) returns( fixed bin(31) ) recursive;
   dcl   d                   fixed bin(31);
   dcl   idx                 fixed bin(31);
   dcl   kid                 fixed bin(31);
   dcl   nameidx             fixed bin(31);
   dcl   prev                fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   at                  fixed bin(31);
   at  = dpos(d);
   idx = jnewnode( d );
   if idx < 0 then return( -1 );
   call setnf( d, idx, 0, J_OBJECT );
   call setnf( d, idx, 1, at );
   dpos(d) = at + 1;
   prev = -1;
   call jskipws( d );
   if jbyte( d, dpos(d) ) = 125 then do;          /* }                */
     dpos(d) = dpos(d) + 1;
     call setnf( d, idx, 2, dpos(d) );
     return( idx );
     end;
   do while( '1'b );
     call jskipws( d );
     if jbyte( d, dpos(d) ) ^= 34 then do;
       dok(d) = 0;
       return( -1 );
       end;
     nameidx = jstring( d );
     if dok(d) = 0 then return( -1 );
     call jskipws( d );
     if jbyte( d, dpos(d) ) ^= 58 then do;        /* :                */
       dok(d) = 0;
       return( -1 );
       end;
     dpos(d) = dpos(d) + 1;
     kid = jvalue( d );
     if dok(d) = 0 then return( -1 );
     /* The member name node is folded into the value node so that a */
     /* lookup walks one chain instead of two.                       */
     call setnf( d, kid, 5, nf( d, nameidx, 1 ) + 1 );
     call setnf( d, kid, 6, nf( d, nameidx, 2 ) - nf( d, nameidx, 1 ) - 2 );
     if prev < 0 then call setnf( d, idx, 3, kid );
     else call setnf( d, prev, 4, kid );
     prev = kid;
     call jskipws( d );
     c = jbyte( d, dpos(d) );
     if c = 44 then dpos(d) = dpos(d) + 1;
     else if c = 125 then do;
       dpos(d) = dpos(d) + 1;
       call setnf( d, idx, 2, dpos(d) );
       return( idx );
       end;
     else do;
       dok(d) = 0;
       return( -1 );
       end;
     end;
   end jobject;

 /* Find a member of an object by name. The name is compared without */
 /* unescaping, which is safe because every name this client looks   */
 /* for is plain ASCII.                                              */
 jmember: proc( d, obj, name ) returns( fixed bin(31) );
   dcl  (d,obj)              fixed bin(31);
   dcl   name                char(32);
   dcl   want                fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   kid                 fixed bin(31);
   if obj < 0 then return( -1 );
   if nf( d, obj, 0 ) ^= J_OBJECT then return( -1 );
   want = 0;
   do i = 1 to 32;
     if substr( name, i, 1 ) ^= ' ' then want = i;
     end;
   kid = nf( d, obj, 3 );
   do while( kid >= 0 );
     if nf( d, kid, 6 ) = want then
       if c_memcmp( ptradd( dtext(d), nf( d, kid, 5 ) ),
                    addr(name), want ) = 0 then return( kid );
     kid = nf( d, kid, 4 );
     end;
   return( -1 );
   end jmember;

 /* Copy a node's exact source text into a buffer.                   */
 jcopy: proc( b, d, idx );
   dcl   b                   fixed bin(31);
   dcl  (d,idx)              fixed bin(31);
   if idx < 0 then do;
     call bputt( b, 'null' );
     return;
     end;
   call bput( b, ptradd( dtext(d), nf( d, idx, 1 ) ),
              nf( d, idx, 2 ) - nf( d, idx, 1 ) );
   end jcopy;

 /* Decode a JSON string node into a buffer as raw bytes.            */
 junquote: proc( b, d, idx );
   dcl   b                   fixed bin(31);
   dcl  (d,idx)              fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   code                fixed bin(31);
   dcl   i                   fixed bin(31);
   if idx < 0 then return;
   if nf( d, idx, 0 ) ^= J_STRING then return;
   at   = nf( d, idx, 1 ) + 1;
   stop = nf( d, idx, 2 ) - 1;
   do while( at < stop );
     c = jbyte( d, at );
     if c ^= 92 then do;
       call bputb( b, ptradd( dtext(d), at )->byte1 );
       at = at + 1;
       end;
     else do;
       at = at + 1;
       c = jbyte( d, at );
       at = at + 1;
       select;
         when( c = 98 )  call bputb( b, '08'x );
         when( c = 102 ) call bputb( b, '0c'x );
         when( c = 110 ) call bputb( b, '0a'x );
         when( c = 114 ) call bputb( b, '0d'x );
         when( c = 116 ) call bputb( b, '09'x );
         when( c = 117 ) do;
           code = 0;
           do i = 1 to 4;
             code = code * 16 + hexval( jbyte( d, at ) );
             at = at + 1;
             end;
           call bpututf8( b, code );
           end;
         otherwise call bputb( b, chrv( c ) );
         end;
       end;
     end;
   end junquote;

 hexval: proc( c ) returns( fixed bin(31) );
   dcl   c                   fixed bin(31);
   if c >= 48 & c <= 57  then return( c - 48 );
   if c >= 97 & c <= 102 then return( c - 87 );
   if c >= 65 & c <= 70  then return( c - 55 );
   return( 0 );
   end hexval;

 /* Encode one code point. Surrogate halves are written through      */
 /* unchanged rather than paired, because no Convex field this       */
 /* client reads uses \u escapes above the basic plane.              */
 bpututf8: proc( b, code );
   dcl   b                   fixed bin(31);
   dcl   code                fixed bin(31);
   if code < 128 then call bputb( b, chrv( code ) );
   else if code < 2048 then do;
     call bputb( b, chrv( 192 + code / 64 ) );
     call bputb( b, chrv( 128 + mod(code,64) ) );
     end;
   else do;
     call bputb( b, chrv( 224 + code / 4096 ) );
     call bputb( b, chrv( 128 + mod(code/64,64) ) );
     call bputb( b, chrv( 128 + mod(code,64) ) );
     end;
   end bpututf8;

 /*==================================================================*/
 /* Diagnostics                                                      */
 /*==================================================================*/

 /* Diagnostics go to standard error. Standard out belongs to the    */
 /* adapter protocol and to the example's fixed transcript.          */
 note: proc( t );
   dcl   t                   char(120);
   dcl   line                char(121);
   dcl   i                   fixed bin(31);
   dcl   n                   fixed bin(31);
   dcl   ignore              fixed bin(31);
   n = 0;
   do i = 1 to 120;
     if substr( t, i, 1 ) ^= ' ' then n = i;
     end;
   line = t;
   substr( line, n+1, 1 ) = '0a'x;
   ignore = c_write( 2, addr(line), n + 1 );
   end note;

 panic: proc( t );
   dcl   t                   char(120);
   call note( t );
   call c_exit( 70 );
   end panic;

 /*==================================================================*/
 /* Start-up                                                         */
 /*==================================================================*/

 /* Put every buffer, document slot and piece of client state into    */
 /* its empty state. This is not housekeeping: PL/I AUTOMATIC storage */
 /* starts as whatever the stack happened to contain, so a state      */
 /* variable left unset is genuinely random. The cached TLS context   */
 /* is the sharp example -- an unset sslctx reads as a non-null       */
 /* pointer, tlsctx believes a context already exists, and OpenSSL is */
 /* handed a garbage SSL_CTX on the first https call. Everything a    */
 /* procedure below tests before assigning belongs in here.           */
 /*                                                                   */
 /* A null data pointer is a legal starting point for a buffer        */
 /* because realloc(NULL,n) is malloc(n), so bgrow needs no separate  */
 /* first-allocation path.                                            */
 cvxinit: proc;
   dcl   i                   fixed bin(31);
   dcl   j                   fixed bin(31);
   do i = 1 to NBUFFERS;
     bdata(i) = sysnull();
     blen(i)  = 0;
     bcap(i)  = 0;
     end;
   do i = 1 to NDOCS;
     dtext(i)  = sysnull();
     dtlen(i)  = 0;
     dnodes(i) = sysnull();
     dcount(i) = 0;
     dcap(i)   = 0;
     dpos(i)   = 0;
     ddepth(i) = 0;
     dok(i)    = 1;
     end;
   cvxtls      = 0;
   sslctx      = sysnull();
   httpfd      = -1;
   httpssl     = sysnull();
   httpstatus  = 0;
   callok      = 0;
   callvalue   = -1;
   calllogs    = -1;
   callerrdata = -1;
   callerrname = ' ';
   livestarted = 0;
   liveclosing = 0;
   livefailed  = 0;
   liveiserror = 0;
   wsfd        = -1;
   wsssl       = sysnull();
   wsconnected = 0;
   wsfragmented = 0;
   wsmsgopcode = 0;
   qsversion   = 0;
   remoteqs    = 0;
   remoteid    = 0;
   connectioncount = 0;
   nextqueryid = 0;
   reconnectat = 0;
   backoffms   = 100;
   qbytes      = 0;
   do i = 1 to MAX_SUBSCRIPTIONS;
     subused(i)    = 0;
     subactive(i)  = 0;
     subaddpend(i) = 0;
     subrempend(i) = 0;
     subremdone(i) = 0;
     subrehyd(i)   = 0;
     subhaslast(i) = 0;
     subqid(i)     = -1;
     sublastp(i)   = sysnull();
     sublastn(i)   = 0;
     subnamep(i)   = sysnull();
     subnamen(i)   = 0;
     subpathp(i)   = sysnull();
     subpathn(i)   = 0;
     subargsp(i)   = sysnull();
     subargsn(i)   = 0;
     subqstart(i)  = 0;
     subqcount(i)  = 0;
     do j = 1 to QUEUE_CAPACITY;
       qtextp(i,j)   = sysnull();
       qtextn(i,j)   = 0;
       qiserror(i,j) = 0;
       end;
     end;
   end cvxinit;

 /*==================================================================*/
 /* Transport                                                        */
 /*                                                                  */
 /* One TCP socket, optionally wrapped in TLS. libc resolves and     */
 /* connects and OpenSSL performs the handshake and record layer;    */
 /* everything above that -- HTTP/1.1 framing, WebSocket framing and */
 /* the Convex sync protocol -- is written here.                     */
 /*==================================================================*/

 errno: proc returns( fixed bin(31) );
   return( c_errno_location()->word32 );
   end errno;

 /* Split a Convex deployment URL into the pieces the transport      */
 /* needs. Only http and https are accepted; anything else is a      */
 /* configuration mistake worth failing loudly on.                   */
 cvxseturl: proc( url, urllen ) returns( fixed bin(31) );
   dcl   url                 ptr;
   dcl   urllen              fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   sawcolon            fixed bin(31);
   call bclear( B_HOST );
   call bclear( B_PORT );
   if urllen > 8 then
     if c_memcmp( url, addr(litscheme_s), 8 ) = 0 then do;
       cvxtls = 1;
       at = 8;
       end;
     else at = -1;
   else at = -1;
   if at < 0 then do;
     if urllen > 7 then
       if c_memcmp( url, addr(litscheme_p), 7 ) = 0 then do;
         cvxtls = 0;
         at = 7;
         end;
     end;
   if at < 0 then return( 0 );
   /* Trailing slashes are trimmed so that building an endpoint by  */
   /* concatenation never produces a doubled separator.             */
   stop = urllen;
   do while( stop > at );
     if byteval( ptradd( url, stop - 1 ) ) = 47 then stop = stop - 1;
     else leave;
     end;
   sawcolon = 0;
   do while( at < stop );
     c = byteval( ptradd( url, at ) );
     if c = 47 then leave;
     if c = 58 then sawcolon = 1;
     else if sawcolon = 1 then
       call bputb( B_PORT, ptradd( url, at )->byte1 );
     else call bputb( B_HOST, ptradd( url, at )->byte1 );
     at = at + 1;
     end;
   if blen(B_HOST) = 0 then return( 0 );
   if blen(B_PORT) = 0 then
     if cvxtls = 1 then call bputt( B_PORT, '443' );
     else call bputt( B_PORT, '80' );
   return( 1 );
   end cvxseturl;

 /* Resolve and connect. IPv4 only: Docker's default bridge has no   */
 /* IPv6 route, so asking for AF_UNSPEC risks returning a AAAA       */
 /* record that can never be reached.                                */
 tcpconnect: proc returns( fixed bin(31) );
   dcl   rc                  fixed bin(31);
   dcl   fd                  fixed bin(31);
   dcl   pres                ptr;
   dcl   phost               ptr;
   dcl   pport               ptr;
   dcl 1 hints,
         5 h_flags           fixed bin(31),
         5 h_family          fixed bin(31),
         5 h_socktype        fixed bin(31),
         5 h_protocol        fixed bin(31),
         5 h_addrlen         fixed bin(31),
         5 h_addr            ptr,
         5 h_canonname       ptr,
         5 h_next            ptr;
   dcl 1 timeout,
         5 tv_sec            fixed bin(31),
         5 tv_usec           fixed bin(31);
   phost = bcstr( B_HOST );
   pport = bcstr( B_PORT );
   h_flags     = 0;
   h_family    = AF_INET;
   h_socktype  = SOCK_STREAM;
   h_protocol  = 0;
   h_addrlen   = 0;
   h_addr      = sysnull();
   h_canonname = sysnull();
   h_next      = sysnull();
   pres        = sysnull();
   rc = c_getaddrinfo( phost, pport, addr(hints), addr(pres) );
   if rc ^= 0 | pres = sysnull() then return( -1 );
   fd = c_socket( AF_INET, SOCK_STREAM, 0 );
   if fd < 0 then do;
     call c_freeaddrinfo( pres );
     return( -1 );
     end;
   /* A read or write that never completes would strand the adapter, */
   /* so both directions carry a deadline from the moment the socket */
   /* exists rather than relying on a caller to poll.                */
   tv_sec  = 30;
   tv_usec = 0;
   rc = c_setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, addr(timeout), 8 );
   rc = c_setsockopt( fd, SOL_SOCKET, SO_SNDTIMEO, addr(timeout), 8 );
   rc = c_connect( fd, ptradd(pres,20)->aptr, ptradd(pres,16)->word32 );
   call c_freeaddrinfo( pres );
   if rc ^= 0 then do;
     rc = c_close( fd );
     return( -1 );
     end;
   return( fd );
   end tcpconnect;

 /* One process-wide TLS context. Verification is switched on and    */
 /* the peer name is pinned, so a wrong certificate fails the        */
 /* handshake instead of quietly succeeding.                         */
 tlsctx: proc returns( ptr );
   dcl   rc                  fixed bin(31);
   if sslctx ^= sysnull() then return( sslctx );
   sslctx = SSL_CTX_new( TLS_client_method() );
   if sslctx = sysnull() then return( sysnull() );
   rc = SSL_CTX_set_default_verify_paths( sslctx );
   if rc ^= 1 then do;
     call SSL_CTX_free( sslctx );
     sslctx = sysnull();
     return( sysnull() );
     end;
   return( sslctx );
   end tlsctx;

 tlswrap: proc( fd ) returns( ptr );
   dcl   fd                  fixed bin(31);
   dcl   ctx                 ptr;
   dcl   ssl                 ptr;
   dcl   rc                  fixed bin(31);
   dcl   phost               ptr;
   ctx = tlsctx();
   if ctx = sysnull() then return( sysnull() );
   ssl = SSL_new( ctx );
   if ssl = sysnull() then return( sysnull() );
   rc = SSL_set_fd( ssl, fd );
   phost = bcstr( B_HOST );
   /* Server Name Indication and the verification host name are two */
   /* different settings; a client that sets only the first talks to */
   /* the right server but will accept any certificate it presents.  */
   rc = SSL_ctrl( ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, phost );
   rc = SSL_set1_host( ssl, phost );
   call SSL_set_verify( ssl, SSL_VERIFY_PEER, sysnull() );
   call ERR_clear_error();
   rc = SSL_connect( ssl );
   if rc ^= 1 then do;
     call SSL_free( ssl );
     return( sysnull() );
     end;
   return( ssl );
   end tlswrap;

 tclose: proc( fd, ssl );
   dcl   fd                  fixed bin(31);
   dcl   ssl                 ptr;
   dcl   rc                  fixed bin(31);
   if ssl ^= sysnull() then do;
     rc = SSL_shutdown( ssl );
     call SSL_free( ssl );
     end;
   if fd >= 0 then rc = c_close( fd );
   end tclose;

 /* Write every byte, or report failure. Both transports can accept  */
 /* a partial write, so neither result is treated as complete until  */
 /* the whole buffer has gone.                                       */
 tsendall: proc( fd, ssl, src, n ) returns( fixed bin(31) );
   dcl   fd                  fixed bin(31);
   dcl   ssl                 ptr;
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   sent                fixed bin(31);
   dcl   rc                  fixed bin(31);
   dcl   werr                fixed bin(31);
   sent = 0;
   do while( sent < n );
     if ssl ^= sysnull() then do;
       call ERR_clear_error();
       rc = SSL_write( ssl, ptradd( src, sent ), n - sent );
       if rc <= 0 then do;
         werr = ssl_geterror( ssl, rc );
         if werr = SSL_ERROR_WANT_READ | werr = SSL_ERROR_WANT_WRITE then
           if twait( fd, POLLOUT, 1000 ) >= 0 then iterate;
         return( 0 );
         end;
       end;
     else do;
       rc = c_write( fd, ptradd( src, sent ), n - sent );
       if rc <= 0 then do;
         if errno() = EINTR | errno() = EAGAIN then
           if twait( fd, POLLOUT, 1000 ) >= 0 then iterate;
         return( 0 );
         end;
       end;
     sent = sent + rc;
     end;
   return( 1 );
   end tsendall;

 /* Read once. Returns the byte count, 0 when the peer closed, -1 on */
 /* error and -2 when the transport has no data yet.                 */
 trecv: proc( fd, ssl, dst, n ) returns( fixed bin(31) );
   dcl   fd                  fixed bin(31);
   dcl   ssl                 ptr;
   dcl   dst                 ptr;
   dcl   n                   fixed bin(31);
   dcl   rc                  fixed bin(31);
   dcl   rerr                fixed bin(31);
   if ssl ^= sysnull() then do;
     call ERR_clear_error();
     rc = SSL_read( ssl, dst, n );
     if rc > 0 then return( rc );
     rerr = ssl_geterror( ssl, rc );
     if rerr = SSL_ERROR_WANT_READ | rerr = SSL_ERROR_WANT_WRITE then
       return( -2 );
     if rc = 0 then return( 0 );
     return( -1 );
     end;
   rc = c_read( fd, dst, n );
   if rc > 0 then return( rc );
   if rc = 0 then return( 0 );
   if errno() = EAGAIN | errno() = EINTR then return( -2 );
   return( -1 );
   end trecv;

 /* Wait for a socket to become ready. Returns 1 ready, 0 timed out, */
 /* -1 failed.                                                       */
 twait: proc( fd, events, ms ) returns( fixed bin(31) );
   dcl  (fd,events,ms)       fixed bin(31);
   dcl   rc                  fixed bin(31);
   dcl 1 pfd,
         5 p_fd              fixed bin(31),
         5 p_events          fixed bin(15),
         5 p_revents         fixed bin(15);
   p_fd      = fd;
   p_events  = events;
   p_revents = 0;
   rc = c_poll( addr(pfd), 1, ms );
   if rc > 0 then return( 1 );
   if rc = 0 then return( 0 );
   if errno() = EINTR then return( 0 );
   return( -1 );
   end twait;

 setnonblocking: proc( fd );
   dcl   fd                  fixed bin(31);
   dcl   flags               fixed bin(31);
   dcl   rc                  fixed bin(31);
   flags = c_fcntl( fd, F_GETFL, 0 );
   if flags < 0 then return;
   rc = c_fcntl( fd, F_SETFL, flags + O_NONBLOCK );
   end setnonblocking;

 /*==================================================================*/
 /* HTTP/1.1                                                         */
 /*                                                                  */
 /* Convex's documented HTTP functions are one POST each. The        */
 /* request and response framing below is written out rather than    */
 /* delegated, so the client owns its own protocol behaviour.        */
 /*==================================================================*/

 /* Case-insensitive comparison of a header name against a literal.  */
 hdrmatch: proc( at, name ) returns( fixed bin(31) );
   dcl   at                  fixed bin(31);
   dcl   name                char(32);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   got                 fixed bin(31);
   dcl   want                fixed bin(31);
   n = 0;
   do i = 1 to 32;
     if substr( name, i, 1 ) ^= ' ' then n = i;
     end;
   if at + n > blen(B_RESP) then return( 0 );
   do i = 1 to n;
     got  = byteval( ptradd( bdata(B_RESP), at + i - 1 ) );
     want = byteof( substr( name, i, 1 ) );
     if got >= 65 & got <= 90 then got = got + 32;
     if want >= 65 & want <= 90 then want = want + 32;
     if got ^= want then return( 0 );
     end;
   return( 1 );
   end hdrmatch;

 /* Find the offset just past CR LF CR LF, or -1 while the header    */
 /* block is still incomplete.                                       */
 hdrend: proc returns( fixed bin(31) );
   dcl   i                   fixed bin(31);
   do i = 0 to blen(B_RESP) - 4;
     if byteval( ptradd( bdata(B_RESP), i ) ) = 13 then
       if byteval( ptradd( bdata(B_RESP), i+1 ) ) = 10 then
         if byteval( ptradd( bdata(B_RESP), i+2 ) ) = 13 then
           if byteval( ptradd( bdata(B_RESP), i+3 ) ) = 10 then
             return( i + 4 );
     end;
   return( -1 );
   end hdrend;

 /* Read the decimal value that follows a header name, if the header */
 /* is present in the block that ends at 'stop'. Returns -1 when the */
 /* header is absent.                                                */
 hdrnumber: proc( stop, name ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   dcl   name                char(32);
   dcl   at                  fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   value               fixed bin(31);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   n = 0;
   do i = 1 to 32;
     if substr( name, i, 1 ) ^= ' ' then n = i;
     end;
   at = linestart( stop );
   do while( at >= 0 );
     if hdrmatch( at, name ) = 1 then do;
       at = at + n;
       do while( at < stop );
         c = byteval( ptradd( bdata(B_RESP), at ) );
         if c = 32 | c = 9 then at = at + 1;
         else leave;
         end;
       value = 0;
       do while( at < stop );
         c = byteval( ptradd( bdata(B_RESP), at ) );
         if c < 48 | c > 57 then leave;
         value = value * 10 + c - 48;
         at = at + 1;
         end;
       return( value );
       end;
     at = nextline( at, stop );
     end;
   return( -1 );
   end hdrnumber;

 /* Is the named header present with the given value, ignoring case? */
 hdrhas: proc( stop, name, want ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   dcl   name                char(32);
   dcl   want                char(32);
   dcl   at                  fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   n = 0;
   do i = 1 to 32;
     if substr( name, i, 1 ) ^= ' ' then n = i;
     end;
   at = linestart( stop );
   do while( at >= 0 );
     if hdrmatch( at, name ) = 1 then do;
       at = at + n;
       do while( at < stop );
         c = byteval( ptradd( bdata(B_RESP), at ) );
         if c = 32 | c = 9 then at = at + 1;
         else leave;
         end;
       if hdrmatch( at, want ) = 1 then return( 1 );
       end;
     at = nextline( at, stop );
     end;
   return( 0 );
   end hdrhas;

 /* Offset of the first header line, which is the line after the     */
 /* status line.                                                     */
 linestart: proc( stop ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   return( nextline( 0, stop ) );
   end linestart;

 nextline: proc( at, stop ) returns( fixed bin(31) );
   dcl  (at,stop)            fixed bin(31);
   dcl   i                   fixed bin(31);
   do i = at to stop - 2;
     if byteval( ptradd( bdata(B_RESP), i ) ) = 13 then
       if byteval( ptradd( bdata(B_RESP), i+1 ) ) = 10 then do;
         if i + 2 >= stop then return( -1 );
         return( i + 2 );
         end;
     end;
   return( -1 );
   end nextline;

 /* Build and send one Convex HTTP request, then decode the reply    */
 /* into B_BODY. Returns 1 when a complete response arrived.         */
 httpsend: proc( op, pathp, pathn, argsp, argsn ) returns( fixed bin(31) );
   dcl   op                  char(16);
   dcl   pathp              ptr;
   dcl   pathn              fixed bin(31);
   dcl   argsp              ptr;
   dcl   argsn              fixed bin(31);
   dcl   ok                  fixed bin(31);

   /* Body first, because its length has to appear in the headers.   */
   call bclear( B_BODY );
   call bputt( B_BODY, '{"path":"' );
   call bputesc( B_BODY, pathp, pathn );
   call bputt( B_BODY, '","args":' );
   if argsn > 0 then call bput( B_BODY, argsp, argsn );
   else call bputt( B_BODY, '{}' );
   call bputt( B_BODY, ',"format":"json"}' );

   call bclear( B_REQ );
   call bputt( B_REQ, 'POST /api/' );
   call bputt( B_REQ, op );
   call bputt( B_REQ, ' HTTP/1.1' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Host: ' );
   call bput( B_REQ, bdata(B_HOST), blen(B_HOST) );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Content-Type: application/json' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Accept: application/json' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Convex-Client: ' );
   call bputt( B_REQ, clientversion );
   call bputcrlf( B_REQ );
   /* HTTP/1.1 keep-alive is declined so that one request is one     */
   /* connection. It costs a handshake per call and removes a whole  */
   /* class of half-consumed-response bugs from an educational       */
   /* client.                                                        */
   call bputt( B_REQ, 'Connection: close' );
   call bputcrlf( B_REQ );
   if blen(B_TOKEN) > 0 then do;
     call bputt( B_REQ, 'Authorization: Bearer ' );
     call bput( B_REQ, bdata(B_TOKEN), blen(B_TOKEN) );
     call bputcrlf( B_REQ );
     end;
   call bputt( B_REQ, 'Content-Length: ' );
   call bputi( B_REQ, blen(B_BODY) );
   call bputcrlf( B_REQ );
   call bputcrlf( B_REQ );
   call bput( B_REQ, bdata(B_BODY), blen(B_BODY) );

   httpfd  = tcpconnect();
   httpssl = sysnull();
   if httpfd < 0 then return( 0 );
   if cvxtls = 1 then do;
     httpssl = tlswrap( httpfd );
     if httpssl = sysnull() then do;
       call tclose( httpfd, sysnull() );
       httpfd = -1;
       return( 0 );
       end;
     end;
   ok = tsendall( httpfd, httpssl, bdata(B_REQ), blen(B_REQ) );
   if ok = 1 then ok = httpreceive();
   call tclose( httpfd, httpssl );
   httpfd  = -1;
   httpssl = sysnull();
   return( ok );
   end httpsend;

 bputcrlf: proc( b );
   dcl   b                   fixed bin(31);
   call bputb( b, '0d'x );
   call bputb( b, '0a'x );
   end bputcrlf;

 /* Read a whole response. The body is bounded so a hostile or       */
 /* runaway peer cannot grow this process without limit.             */
 httpreceive: proc returns( fixed bin(31) );
   dcl   chunk               char(16384);
   dcl   got                 fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   want                fixed bin(31);
   dcl   chunked             fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   i                   fixed bin(31);
   call bclear( B_RESP );
   stop = -1;
   do while( '1'b );
     if blen(B_RESP) > MAX_PAYLOAD then return( 0 );
     got = trecv( httpfd, httpssl, addr(chunk), 16384 );
     if got = -2 then do;
       if twait( httpfd, POLLIN, 30000 ) <= 0 then return( 0 );
       iterate;
       end;
     if got < 0 then return( 0 );
     if got = 0 then leave;
     call bput( B_RESP, addr(chunk), got );
     stop = hdrend();
     if stop >= 0 then do;
       /* Once the headers are complete the exact remaining length   */
       /* is known, so the loop stops rather than waiting for the    */
       /* peer to close.                                             */
       chunked = hdrhas( stop, 'transfer-encoding:', 'chunked' );
       if chunked = 0 then do;
         want = hdrnumber( stop, 'content-length:' );
         if want >= 0 then
           if blen(B_RESP) >= stop + want then leave;
         end;
       else if chunkcomplete( stop ) = 1 then leave;
       end;
     end;
   if stop < 0 then do;
     stop = hdrend();
     if stop < 0 then return( 0 );
     end;
   /* Status code from the "HTTP/1.1 NNN" status line.               */
   httpstatus = 0;
   i = 9;
   do while( i < blen(B_RESP) );
     c = byteval( ptradd( bdata(B_RESP), i ) );
     if c < 48 | c > 57 then leave;
     httpstatus = httpstatus * 10 + c - 48;
     i = i + 1;
     end;
   call bclear( B_BODY );
   if hdrhas( stop, 'transfer-encoding:', 'chunked' ) = 1 then
     return( dechunk( stop ) );
   want = hdrnumber( stop, 'content-length:' );
   if want < 0 then want = blen(B_RESP) - stop;
   if stop + want > blen(B_RESP) then return( 0 );
   call bput( B_BODY, ptradd( bdata(B_RESP), stop ), want );
   return( 1 );
   end httpreceive;

 /* Has the whole chunked body arrived? A zero length chunk followed */
 /* by its terminator ends the body.                                 */
 chunkcomplete: proc( stop ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   size                fixed bin(31);
   at = stop;
   do while( '1'b );
     size = chunksize( at );
     if size < 0 then return( 0 );
     at = chunkbody( at );
     if at < 0 then return( 0 );
     if size = 0 then return( 1 );
     at = at + size + 2;
     if at > blen(B_RESP) then return( 0 );
     end;
   end chunkcomplete;

 chunksize: proc( at ) returns( fixed bin(31) );
   dcl   at                  fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   size                fixed bin(31);
   dcl   seen                fixed bin(31);
   size = 0;
   seen = 0;
   i = at;
   do while( i < blen(B_RESP) );
     c = byteval( ptradd( bdata(B_RESP), i ) );
     if ( c >= 48 & c <= 57 ) | ( c >= 97 & c <= 102 ) |
        ( c >= 65 & c <= 70 ) then do;
       size = size * 16 + hexval( c );
       seen = seen + 1;
       i = i + 1;
       end;
     else leave;
     end;
   if seen = 0 then return( -1 );
   return( size );
   end chunksize;

 /* Offset of the first byte after a chunk header line.              */
 chunkbody: proc( at ) returns( fixed bin(31) );
   dcl   at                  fixed bin(31);
   dcl   i                   fixed bin(31);
   do i = at to blen(B_RESP) - 2;
     if byteval( ptradd( bdata(B_RESP), i ) ) = 13 then
       if byteval( ptradd( bdata(B_RESP), i+1 ) ) = 10 then return( i + 2 );
     end;
   return( -1 );
   end chunkbody;

 dechunk: proc( stop ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   size                fixed bin(31);
   at = stop;
   do while( '1'b );
     size = chunksize( at );
     if size < 0 then return( 0 );
     at = chunkbody( at );
     if at < 0 then return( 0 );
     if size = 0 then return( 1 );
     if at + size > blen(B_RESP) then return( 0 );
     if blen(B_BODY) + size > MAX_PAYLOAD then return( 0 );
     call bput( B_BODY, ptradd( bdata(B_RESP), at ), size );
     at = at + size + 2;
     end;
   end dechunk;

 /*==================================================================*/
 /* Convex HTTP functions                                            */
 /*==================================================================*/

 /* Run one Convex query, mutation or action. On success callok is 1 */
 /* and callvalue indexes the returned value inside D_HTTP; on a     */
 /* function failure callok is 0, callerrname says which kind of     */
 /* failure it was, B_TMP2 holds the message and callerrdata indexes */
 /* the structured error payload.                                    */
 cvxcall: proc( op, pathp, pathn, argsp, argsn );
   dcl   op                  char(16);
   dcl   pathp               ptr;
   dcl   pathn               fixed bin(31);
   dcl   argsp               ptr;
   dcl   argsn               fixed bin(31);
   dcl   root                fixed bin(31);
   dcl   status              fixed bin(31);
   callok      = 0;
   callvalue   = -1;
   calllogs    = -1;
   callerrdata = -1;
   callerrname = 'TransportError';
   call bclear( B_TMP2 );
   if httpsend( op, pathp, pathn, argsp, argsn ) = 0 then do;
     call bputt( B_TMP2, 'Convex HTTP request did not complete' );
     return;
     end;
   callerrname = 'ProtocolError';
   root = jparse( D_HTTP, bdata(B_BODY), blen(B_BODY) );
   if root < 0 then do;
     call bputt( B_TMP2, 'HTTP response was not valid Convex JSON' );
     return;
     end;
   status   = jmember( D_HTTP, root, 'status' );
   calllogs = jmember( D_HTTP, root, 'logLines' );
   if status < 0 then do;
     call bputt( B_TMP2, 'HTTP response omitted a status' );
     return;
     end;
   if jtexteq( D_HTTP, status, '"success"' ) = 1 then do;
     callvalue = jmember( D_HTTP, root, 'value' );
     if callvalue < 0 then do;
       call bputt( B_TMP2, 'Convex success response omitted a value' );
       return;
       end;
     callok = 1;
     return;
     end;
   if jtexteq( D_HTTP, status, '"error"' ) = 1 then do;
     callerrname = 'FunctionError';
     callerrdata = jmember( D_HTTP, root, 'errorData' );
     call junquote( B_TMP2, D_HTTP,
                    jmember( D_HTTP, root, 'errorMessage' ) );
     if blen(B_TMP2) = 0 then call bputt( B_TMP2, 'Convex function failed' );
     return;
     end;
   call bputt( B_TMP2, 'HTTP response had an unknown status' );
   end cvxcall;

 /* Compare a node's exact source text with a literal.               */
 jtexteq: proc( d, idx, want ) returns( fixed bin(31) );
   dcl  (d,idx)              fixed bin(31);
   dcl   want                char(32);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   if idx < 0 then return( 0 );
   n = 0;
   do i = 1 to 32;
     if substr( want, i, 1 ) ^= ' ' then n = i;
     end;
   if nf( d, idx, 2 ) - nf( d, idx, 1 ) ^= n then return( 0 );
   if c_memcmp( ptradd( dtext(d), nf( d, idx, 1 ) ), addr(want), n ) = 0 then
     return( 1 );
   return( 0 );
   end jtexteq;

 /*==================================================================*/
 /* RFC 6455 WebSocket                                               */
 /*                                                                  */
 /* Handshake, framing and masking are written here. OpenSSL         */
 /* supplies SHA-1, base64 and random bytes; the protocol that uses  */
 /* them is this client's own.                                       */
 /*==================================================================*/

 /* Read the monotonic clock in milliseconds. Wall clock time would  */
 /* let a clock adjustment reorder a backoff deadline.               */
 nowms: proc returns( fixed bin(31) );
   dcl 1 ts,
         5 tv_sec            fixed bin(31),
         5 tv_nsec           fixed bin(31);
   dcl   rc                  fixed bin(31);
   rc = c_clock_gettime( CLOCK_MONOTONIC, addr(ts) );
   /* Only differences are ever taken, so wrapping the seconds into  */
   /* a 32 bit millisecond counter is harmless and keeps the         */
   /* arithmetic in one machine word.                                */
   return( mod( tv_sec, 1000000 ) * 1000 + tv_nsec / 1000000 );
   end nowms;

 /* Base64 of arbitrary bytes, using OpenSSL's encoder so the        */
 /* handshake key and its expected answer are produced the same way. */
 b64: proc( b, src, n );
   dcl   b                   fixed bin(31);
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   out                 ptr;
   dcl   got                 fixed bin(31);
   out = c_malloc( ( ( n + 2 ) / 3 ) * 4 + 8 );
   if out = sysnull() then call panic( 'out of memory' );
   got = EVP_EncodeBlock( out, src, n );
   if got > 0 then call bput( b, out, got );
   call c_free( out );
   end b64;

 /* A version 4 style session identifier. Convex only needs it to be */
 /* unique per connection attempt.                                   */
 sessionid: proc( b );
   dcl   b                   fixed bin(31);
   dcl   raw                 char(16);
   dcl   rc                  fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   v                   fixed bin(31);
   rc = RAND_bytes( addr(raw), 16 );
   if rc ^= 1 then call panic( 'no random bytes for the Live session id' );
   substr( raw, 7, 1 ) = chrv( 64 + mod( byteof( substr(raw,7,1) ), 16 ) );
   substr( raw, 9, 1 ) = chrv( 128 + mod( byteof( substr(raw,9,1) ), 64 ) );
   do i = 1 to 16;
     if i = 5 | i = 7 | i = 9 | i = 11 then call bputb( b, '-' );
     v = byteof( substr( raw, i, 1 ) );
     call bputb( b, substr( hexdigits, v / 16 + 1, 1 ) );
     call bputb( b, substr( hexdigits, mod(v,16) + 1, 1 ) );
     end;
   end sessionid;

 /* Open the Live socket and complete the RFC 6455 handshake. The    */
 /* server's Sec-WebSocket-Accept is recomputed and compared, so a   */
 /* plain HTTP responder cannot be mistaken for a WebSocket peer.    */
 wsopen: proc returns( fixed bin(31) );
   dcl   raw                 char(16);
   dcl   digest              char(20);
   dcl   rc                  fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   ignore              ptr;
   wsfd  = tcpconnect();
   wsssl = sysnull();
   if wsfd < 0 then return( 0 );
   if cvxtls = 1 then do;
     wsssl = tlswrap( wsfd );
     if wsssl = sysnull() then do;
       call tclose( wsfd, sysnull() );
       wsfd = -1;
       return( 0 );
       end;
     end;
   rc = RAND_bytes( addr(raw), 16 );
   if rc ^= 1 then call panic( 'no random bytes for the WebSocket key' );
   call bclear( B_KEY );
   call b64( B_KEY, addr(raw), 16 );

   call bclear( B_REQ );
   call bputt( B_REQ, 'GET /api/sync HTTP/1.1' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Host: ' );
   call bput( B_REQ, bdata(B_HOST), blen(B_HOST) );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Upgrade: websocket' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Connection: Upgrade' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Sec-WebSocket-Version: 13' );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Sec-WebSocket-Key: ' );
   call bput( B_REQ, bdata(B_KEY), blen(B_KEY) );
   call bputcrlf( B_REQ );
   call bputt( B_REQ, 'Convex-Client: ' );
   call bputt( B_REQ, clientversion );
   call bputcrlf( B_REQ );
   call bputcrlf( B_REQ );
   if tsendall( wsfd, wsssl, bdata(B_REQ), blen(B_REQ) ) = 0 then do;
     call wsclose( 'handshake write failed' );
     return( 0 );
     end;

   /* The expected answer is base64( SHA1( key || GUID ) ).          */
   call bclear( B_TMP );
   call bput( B_TMP, bdata(B_KEY), blen(B_KEY) );
   call bputt( B_TMP, wsguid );
   ignore = c_sha1( bdata(B_TMP), blen(B_TMP), addr(digest) );
   call bclear( B_ACCEPT );
   call b64( B_ACCEPT, addr(digest), 20 );

   stop = wsreadhandshake();
   if stop < 0 then do;
     call wsclose( 'handshake read failed' );
     return( 0 );
     end;
   if httpstatus ^= 101 then do;
     call wsclose( 'Live endpoint refused the upgrade' );
     return( 0 );
     end;
   if hdrhasvalue( stop, 'sec-websocket-accept:', B_ACCEPT ) = 0 then do;
     call wsclose( 'Live peer returned the wrong handshake key' );
     return( 0 );
     end;
   /* Any bytes read past the header block are the first frames.     */
   call bclear( B_WSRAW );
   if blen(B_RESP) > stop then
     call bput( B_WSRAW, ptradd( bdata(B_RESP), stop ), blen(B_RESP) - stop );
   call setnonblocking( wsfd );
   call bclear( B_WSIN );
   wsfragmented = 0;
   wsmsgopcode  = 0;
   return( 1 );
   end wsopen;

 /* Read until the handshake response headers are complete.          */
 wsreadhandshake: proc returns( fixed bin(31) );
   dcl   chunk               char(4096);
   dcl   got                 fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   c                   fixed bin(31);
   call bclear( B_RESP );
   do while( '1'b );
     if blen(B_RESP) > 65536 then return( -1 );
     got = trecv( wsfd, wsssl, addr(chunk), 4096 );
     if got = -2 then do;
       if twait( wsfd, POLLIN, 15000 ) <= 0 then return( -1 );
       iterate;
       end;
     if got <= 0 then return( -1 );
     call bput( B_RESP, addr(chunk), got );
     stop = hdrend();
     if stop >= 0 then leave;
     end;
   httpstatus = 0;
   i = 9;
   do while( i < blen(B_RESP) );
     c = byteval( ptradd( bdata(B_RESP), i ) );
     if c < 48 | c > 57 then leave;
     httpstatus = httpstatus * 10 + c - 48;
     i = i + 1;
     end;
   return( stop );
   end wsreadhandshake;

 /* Compare a header's value against a buffer rather than a literal, */
 /* which is what the recomputed handshake key needs.                */
 hdrhasvalue: proc( stop, name, want ) returns( fixed bin(31) );
   dcl   stop                fixed bin(31);
   dcl   name                char(32);
   dcl   want                fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   n = 0;
   do i = 1 to 32;
     if substr( name, i, 1 ) ^= ' ' then n = i;
     end;
   at = linestart( stop );
   do while( at >= 0 );
     if hdrmatch( at, name ) = 1 then do;
       at = at + n;
       do while( at < stop );
         c = byteval( ptradd( bdata(B_RESP), at ) );
         if c = 32 | c = 9 then at = at + 1;
         else leave;
         end;
       if at + blen(want) > blen(B_RESP) then return( 0 );
       if c_memcmp( ptradd( bdata(B_RESP), at ), bdata(want),
                    blen(want) ) = 0 then return( 1 );
       return( 0 );
       end;
     at = nextline( at, stop );
     end;
   return( 0 );
   end hdrhasvalue;

 wsclose: proc( reason );
   dcl   reason              char(64);
   if wsfd >= 0 | wsssl ^= sysnull() then call tclose( wsfd, wsssl );
   wsfd        = -1;
   wsssl       = sysnull();
   wsconnected = 0;
   call bclear( B_CLOSE );
   call bputt( B_CLOSE, reason );
   end wsclose;

 /* Send one masked frame. Every client frame is masked, as RFC 6455 */
 /* requires; an unmasked one is a protocol violation the server is  */
 /* entitled to close the connection over.                           */
 wssend: proc( opcode, src, n ) returns( fixed bin(31) );
   dcl   opcode              fixed bin(31);
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   mask                char(4);
   dcl   rc                  fixed bin(31);
   dcl   i                   fixed bin(31);
   call bclear( B_WSOUT );
   call bputb( B_WSOUT, chrv( 128 + opcode ) );
   if n < 126 then call bputb( B_WSOUT, chrv( 128 + n ) );
   else if n < 65536 then do;
     call bputb( B_WSOUT, chrv( 128 + 126 ) );
     call bputb( B_WSOUT, chrv( n / 256 ) );
     call bputb( B_WSOUT, chrv( mod( n, 256 ) ) );
     end;
   else do;
     call bputb( B_WSOUT, chrv( 128 + 127 ) );
     call bputb( B_WSOUT, '00'x );
     call bputb( B_WSOUT, '00'x );
     call bputb( B_WSOUT, '00'x );
     call bputb( B_WSOUT, '00'x );
     call bputb( B_WSOUT, chrv( n / 16777216 ) );
     call bputb( B_WSOUT, chrv( mod( n / 65536, 256 ) ) );
     call bputb( B_WSOUT, chrv( mod( n / 256, 256 ) ) );
     call bputb( B_WSOUT, chrv( mod( n, 256 ) ) );
     end;
   rc = RAND_bytes( addr(mask), 4 );
   if rc ^= 1 then call panic( 'no random bytes for the frame mask' );
   call bput( B_WSOUT, addr(mask), 4 );
   do i = 0 to n - 1;
     call bputb( B_WSOUT,
       chrv( xor8( byteval( ptradd( src, i ) ),
                   byteof( substr( mask, mod(i,4) + 1, 1 ) ) ) ) );
     end;
   return( tsendall( wsfd, wsssl, bdata(B_WSOUT), blen(B_WSOUT) ) );
   end wssend;

 /* Exclusive or of two bytes. PL/I's bit operators work on BIT      */
 /* strings, and converting through one per byte would dominate the  */
 /* cost of masking, so the arithmetic form is used instead.         */
 xor8: proc( a, b ) returns( fixed bin(31) );
   dcl  (a,b)                fixed bin(31);
   dcl   result              fixed bin(31);
   dcl   weight              fixed bin(31);
   dcl  (x,y)                fixed bin(31);
   result = 0;
   weight = 1;
   x = a;
   y = b;
   do while( weight < 256 );
     if mod( x, 2 ) ^= mod( y, 2 ) then result = result + weight;
     x = x / 2;
     y = y / 2;
     weight = weight * 2;
     end;
   return( result );
   end xor8;

 /* Take one complete frame out of B_WSRAW.                          */
 /* Returns 1 when a whole application message is now in B_WSIN,     */
 /* 0 when more bytes are needed, -1 on a transport level close and  */
 /* -2 on a protocol violation.                                      */
 wstakeframe: proc returns( fixed bin(31) );
   dcl   have                fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   b0                  fixed bin(31);
   dcl   b1                  fixed bin(31);
   dcl   fin                 fixed bin(31);
   dcl   opcode              fixed bin(31);
   dcl   masked              fixed bin(31);
   dcl   paylen              fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   total               fixed bin(31);
   dcl   rest                fixed bin(31);
   dcl   ignore              ptr;
   have = blen(B_WSRAW);
   if have < 2 then return( 0 );
   b0 = byteval( bdata(B_WSRAW) );
   b1 = byteval( ptradd( bdata(B_WSRAW), 1 ) );
   fin    = b0 / 128;
   opcode = mod( b0, 16 );
   masked = b1 / 128;
   paylen = mod( b1, 128 );
   at = 2;
   if paylen = 126 then do;
     if have < 4 then return( 0 );
     paylen = byteval( ptradd( bdata(B_WSRAW), 2 ) ) * 256 +
              byteval( ptradd( bdata(B_WSRAW), 3 ) );
     at = 4;
     end;
   else if paylen = 127 then do;
     if have < 10 then return( 0 );
     /* Anything needing more than 31 bits is already past this       */
     /* client's payload bound, so the high word only has to be       */
     /* checked for zero.                                             */
     do i = 2 to 5;
       if byteval( ptradd( bdata(B_WSRAW), i ) ) ^= 0 then return( -2 );
       end;
     paylen = 0;
     do i = 6 to 9;
       paylen = paylen * 256 + byteval( ptradd( bdata(B_WSRAW), i ) );
       if paylen > MAX_PAYLOAD then return( -2 );
       end;
     at = 10;
     end;
   if masked = 1 then return( -2 );
   if paylen < 0 | paylen > MAX_PAYLOAD then return( -2 );
   total = at + paylen;
   if have < total then return( 0 );

   /* A control frame is a message in its own right and may arrive   */
   /* between the fragments of a text message, so it is handled      */
   /* without touching the reassembly state.                         */
   if opcode >= 8 then do;
     if fin = 0 then return( -2 );
     if paylen > 125 then return( -2 );
     if opcode = WS_PING then
       if wssend( WS_PONG, ptradd( bdata(B_WSRAW), at ), paylen ) = 0 then
         return( -1 );
     call wsconsume( total );
     if opcode = WS_CLOSE then return( -1 );
     return( 0 );
     end;

   if opcode = WS_CONT then do;
     if wsfragmented = 0 then return( -2 );
     end;
   else do;
     if wsfragmented = 1 then return( -2 );
     if opcode ^= WS_TEXT then return( -2 );
     wsmsgopcode = opcode;
     call bclear( B_WSIN );
     end;
   if blen(B_WSIN) + paylen > MAX_PAYLOAD then return( -2 );
   call bput( B_WSIN, ptradd( bdata(B_WSRAW), at ), paylen );
   call wsconsume( total );
   if fin = 0 then do;
     wsfragmented = 1;
     return( 0 );
     end;
   wsfragmented = 0;
   /* UTF-8 is validated once, on the reassembled message, because a */
   /* multi byte sequence may legally straddle a fragment boundary.  */
   if utf8valid( bdata(B_WSIN), blen(B_WSIN) ) = 0 then return( -2 );
   return( 1 );
   end wstakeframe;

 wsconsume: proc( n );
   dcl   n                   fixed bin(31);
   dcl   rest                fixed bin(31);
   dcl   ignore              ptr;
   rest = blen(B_WSRAW) - n;
   if rest > 0 then
     ignore = c_memmove( bdata(B_WSRAW), ptradd( bdata(B_WSRAW), n ), rest );
   blen(B_WSRAW) = rest;
   end wsconsume;

 utf8valid: proc( src, n ) returns( fixed bin(31) );
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   extra               fixed bin(31);
   dcl   code                fixed bin(31);
   dcl   k                   fixed bin(31);
   dcl   cc                  fixed bin(31);
   i = 0;
   do while( i < n );
     c = byteval( ptradd( src, i ) );
     if c < 128 then do;
       i = i + 1;
       iterate;
       end;
     if c >= 194 & c <= 223 then do;
       extra = 1;
       code  = c - 192;
       end;
     else if c >= 224 & c <= 239 then do;
       extra = 2;
       code  = c - 224;
       end;
     else if c >= 240 & c <= 244 then do;
       extra = 3;
       code  = c - 240;
       end;
     else return( 0 );
     if i + extra >= n then return( 0 );
     do k = 1 to extra;
       cc = byteval( ptradd( src, i + k ) );
       if cc < 128 | cc > 191 then return( 0 );
       code = code * 64 + cc - 128;
       end;
     if extra = 2 then
       if code < 2048 then return( 0 );
       else if code >= 55296 & code <= 57343 then return( 0 );
     if extra = 3 then
       if code < 65536 | code > 1114111 then return( 0 );
     i = i + extra + 1;
     end;
   return( 1 );
   end utf8valid;

 /*==================================================================*/
 /* Convex sync protocol                                             */
 /*==================================================================*/

 livestart: proc;
   dcl   i                   fixed bin(31);
   if livestarted = 1 then return;
   livestarted     = 1;
   liveclosing     = 0;
   livefailed      = 0;
   wsfd            = -1;
   wsssl           = sysnull();
   wsconnected     = 0;
   qsversion       = 0;
   remoteqs        = 0;
   remoteid        = 0;
   connectioncount = 0;
   nextqueryid     = 0;
   reconnectat     = 0;
   backoffms       = 100;
   qbytes          = 0;
   call bclear( B_TS );
   call bputt( B_TS, initialts );
   call bclear( B_MAXTS );
   call bclear( B_CLOSE );
   call bputt( B_CLOSE, 'InitialConnect' );
   do i = 1 to MAX_SUBSCRIPTIONS;
     subused(i)   = 0;
     subqcount(i) = 0;
     subqstart(i) = 0;
     end;
   end livestart;

 /* Register a subscription. The Add itself is sent by the pump, so  */
 /* subscribing never blocks on the socket.                          */
 livesub: proc( namep, namen, pathp, pathn, argsp, argsn )
          returns( fixed bin(31) );
   dcl  (namep,pathp,argsp)  ptr;
   dcl  (namen,pathn,argsn)  fixed bin(31);
   dcl   slot                fixed bin(31);
   dcl   i                   fixed bin(31);
   call livestart();
   slot = -1;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 0 then do;
       slot = i;
       leave;
       end;
     end;
   if slot < 0 then return( -1 );
   subused(slot)    = 1;
   subactive(slot)  = 1;
   subaddpend(slot) = 1;
   subrempend(slot) = 0;
   subremdone(slot) = 0;
   subrehyd(slot)   = 0;
   subhaslast(slot) = 0;
   sublastp(slot)   = sysnull();
   sublastn(slot)   = 0;
   subqstart(slot)  = 0;
   subqcount(slot)  = 0;
   subqid(slot)     = nextqueryid;
   nextqueryid      = nextqueryid + 1;
   subnamep(slot) = keepbytes( namep, namen );
   subnamen(slot) = namen;
   subpathp(slot) = keepbytes( pathp, pathn );
   subpathn(slot) = pathn;
   subargsp(slot) = keepbytes( argsp, argsn );
   subargsn(slot) = argsn;
   return( slot );
   end livesub;

 keepbytes: proc( src, n ) returns( ptr );
   dcl   src                 ptr;
   dcl   n                   fixed bin(31);
   dcl   copy                ptr;
   dcl   ignore              ptr;
   if n <= 0 then return( sysnull() );
   copy = c_malloc( n );
   if copy = sysnull() then call panic( 'out of memory' );
   ignore = c_memcpy( copy, src, n );
   return( copy );
   end keepbytes;

 findsub: proc( namep, namen ) returns( fixed bin(31) );
   dcl   namep               ptr;
   dcl   namen               fixed bin(31);
   dcl   i                   fixed bin(31);
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then
       if subnamen(i) = namen then
         if c_memcmp( subnamep(i), namep, namen ) = 0 then return( i );
     end;
   return( -1 );
   end findsub;

 /* Mark a subscription for removal. Its queue is dropped before the */
 /* caller is told the removal is under way, so no stale update can  */
 /* cross the acknowledgement.                                       */
 liveunsub: proc( slot );
   dcl   slot                fixed bin(31);
   if slot < 1 then return;
   if subused(slot) = 0 then return;
   call dropqueue( slot );
   subrempend(slot) = 1;
   subremdone(slot) = 0;
   end liveunsub;

 dropqueue: proc( slot );
   dcl   slot                fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   held                fixed bin(31);
   /* The loop bound is copied into a scalar first: this compiler    */
   /* rejects a subscripted reference as a DO limit expression.      */
   held = subqcount(slot);
   do i = 1 to held;
     at = mod( subqstart(slot) + i - 1, QUEUE_CAPACITY ) + 1;
     qbytes = qbytes - qtextn(slot,at);
     call c_free( qtextp(slot,at) );
     qtextp(slot,at) = sysnull();
     qtextn(slot,at) = 0;
     end;
   subqcount(slot) = 0;
   subqstart(slot) = 0;
   end dropqueue;

 releasesub: proc( slot );
   dcl   slot                fixed bin(31);
   call dropqueue( slot );
   if subnamep(slot) ^= sysnull() then call c_free( subnamep(slot) );
   if subpathp(slot) ^= sysnull() then call c_free( subpathp(slot) );
   if subargsp(slot) ^= sysnull() then call c_free( subargsp(slot) );
   if sublastp(slot) ^= sysnull() then call c_free( sublastp(slot) );
   subnamep(slot) = sysnull();
   subpathp(slot) = sysnull();
   subargsp(slot) = sysnull();
   sublastp(slot) = sysnull();
   subused(slot)  = 0;
   subactive(slot)= 0;
   end releasesub;

 /* Append one already rendered update. The queue is bounded twice:  */
 /* by entries per subscription and by total bytes held, so a slow   */
 /* or stopped consumer drops the oldest update rather than growing  */
 /* this process.                                                    */
 enqueue: proc( slot, src, n, iserr );
   dcl   slot                fixed bin(31);
   dcl   src                 ptr;
   dcl  (n,iserr)            fixed bin(31);
   dcl   at                  fixed bin(31);
   do while( subqcount(slot) >= QUEUE_CAPACITY |
             qbytes + n > MAX_QUEUE_BYTES );
     if subqcount(slot) = 0 then return;
     at = subqstart(slot) + 1;
     qbytes = qbytes - qtextn(slot,at);
     call c_free( qtextp(slot,at) );
     qtextp(slot,at) = sysnull();
     subqstart(slot) = mod( subqstart(slot) + 1, QUEUE_CAPACITY );
     subqcount(slot) = subqcount(slot) - 1;
     end;
   at = mod( subqstart(slot) + subqcount(slot), QUEUE_CAPACITY ) + 1;
   qtextp(slot,at)   = keepbytes( src, n );
   qtextn(slot,at)   = n;
   qiserror(slot,at) = iserr;
   qbytes            = qbytes + n;
   subqcount(slot)   = subqcount(slot) + 1;
   end enqueue;

 /* Move the oldest update for a subscription into B_MSG. Returns 1  */
 /* when one was available, and sets liveiserror.                    */
 livetake: proc( slot ) returns( fixed bin(31) );
   dcl   slot                fixed bin(31);
   dcl   at                  fixed bin(31);
   if slot < 1 then return( 0 );
   if subqcount(slot) = 0 then return( 0 );
   at = subqstart(slot) + 1;
   call bclear( B_MSG );
   call bput( B_MSG, qtextp(slot,at), qtextn(slot,at) );
   liveiserror = qiserror(slot,at);
   qbytes = qbytes - qtextn(slot,at);
   call c_free( qtextp(slot,at) );
   qtextp(slot,at) = sysnull();
   qtextn(slot,at) = 0;
   subqstart(slot) = mod( subqstart(slot) + 1, QUEUE_CAPACITY );
   subqcount(slot) = subqcount(slot) - 1;
   return( 1 );
   end livetake;

 activecount: proc returns( fixed bin(31) );
   dcl   i                   fixed bin(31);
   dcl   n                   fixed bin(31);
   n = 0;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then n = n + 1;
     end;
   return( n );
   end activecount;

 /*------------------------------------------------------------------*/
 /* Outgoing sync messages                                           */
 /*------------------------------------------------------------------*/

 sendconnect: proc returns( fixed bin(31) );
   call bclear( B_MSG );
   call bputt( B_MSG, '{"type":"Connect","sessionId":"' );
   call sessionid( B_MSG );
   call bputt( B_MSG, '","connectionCount":' );
   call bputi( B_MSG, connectioncount );
   call bputt( B_MSG, ',"lastCloseReason":"' );
   call bputesc( B_MSG, bdata(B_CLOSE), blen(B_CLOSE) );
   call bputb( B_MSG, '"' );
   if blen(B_MAXTS) > 0 then do;
     call bputt( B_MSG, ',"maxObservedTimestamp":"' );
     call bput( B_MSG, bdata(B_MAXTS), blen(B_MAXTS) );
     call bputb( B_MSG, '"' );
     end;
   call bputt( B_MSG, ',"clientTs":0}' );
   return( wssend( WS_TEXT, bdata(B_MSG), blen(B_MSG) ) );
   end sendconnect;

 /* Build a ModifyQuerySet. 'only' selects one subscription, or 0    */
 /* for every active one, which is what a fresh connection resends.  */
 sendmodify: proc( only, removing ) returns( fixed bin(31) );
   dcl  (only,removing)      fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   first               fixed bin(31);
   call bclear( B_MSG );
   call bputt( B_MSG, '{"type":"ModifyQuerySet","baseVersion":' );
   call bputi( B_MSG, qsversion );
   call bputt( B_MSG, ',"newVersion":' );
   call bputi( B_MSG, qsversion + 1 );
   call bputt( B_MSG, ',"modifications":[' );
   first = 1;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if only > 0 & i ^= only then iterate;
     if subused(i) = 0 then iterate;
     if only = 0 then do;
       if subactive(i) = 0 | subrempend(i) = 1 then iterate;
       end;
     if first = 0 then call bputb( B_MSG, ',' );
     first = 0;
     if removing = 1 then do;
       call bputt( B_MSG, '{"type":"Remove","queryId":' );
       call bputi( B_MSG, subqid(i) );
       call bputb( B_MSG, '}' );
       end;
     else do;
       call bputt( B_MSG, '{"type":"Add","queryId":' );
       call bputi( B_MSG, subqid(i) );
       call bputt( B_MSG, ',"udfPath":"' );
       call bputesc( B_MSG, subpathp(i), subpathn(i) );
       call bputt( B_MSG, '","args":[' );
       if subargsn(i) > 0 then call bput( B_MSG, subargsp(i), subargsn(i) );
       else call bputt( B_MSG, '{}' );
       call bputt( B_MSG, ']}' );
       end;
     end;
   call bputt( B_MSG, ']}' );
   return( wssend( WS_TEXT, bdata(B_MSG), blen(B_MSG) ) );
   end sendmodify;

 /*------------------------------------------------------------------*/
 /* The pump: one worker owns every socket operation                 */
 /*------------------------------------------------------------------*/

 /* Advance Live by at most 'ms' milliseconds, also watching an      */
 /* unrelated descriptor so the caller's own input is not starved.   */
 /* Returns 1 when 'extra' became readable.                          */
 livepump: proc( extra, ms ) returns( fixed bin(31) );
   dcl  (extra,ms)           fixed bin(31);
   dcl   chunk               char(16384);
   dcl   got                 fixed bin(31);
   dcl   taken               fixed bin(31);
   dcl   rc                  fixed bin(31);
   dcl   i                   fixed bin(31);
   dcl   extraready          fixed bin(31);
   dcl 1 pfds(2),
         5 p_fd              fixed bin(31),
         5 p_events          fixed bin(15),
         5 p_revents         fixed bin(15);

   if livestarted = 0 then do;
     if extra < 0 then return( 0 );
     if twait( extra, POLLIN, ms ) = 1 then return( 1 );
     return( 0 );
     end;

   /* A subscription removed while the socket is down completes here */
   /* rather than waiting for a connection that may never come.      */
   if wsconnected = 0 then
     do i = 1 to MAX_SUBSCRIPTIONS;
       if subused(i) = 1 & subrempend(i) = 1 & subremdone(i) = 0 then do;
         subactive(i)  = 0;
         subremdone(i) = 1;
         end;
       end;

   if wsconnected = 0 & activecount() > 0 & liveclosing = 0 then
     if elapsed( reconnectat ) >= 0 then call livereconnect();

   if wsconnected = 1 then call liveflush();

   extraready = 0;
   if wsconnected = 1 then do;
     pfds(1).p_fd      = wsfd;
     pfds(1).p_events  = POLLIN;
     pfds(1).p_revents = 0;
     pfds(2).p_fd      = extra;
     pfds(2).p_events  = POLLIN;
     pfds(2).p_revents = 0;
     if extra < 0 then rc = c_poll( addr(pfds(1)), 1, ms );
     else rc = c_poll( addr(pfds(1)), 2, ms );
     if rc > 0 then do;
       if extra >= 0 then
         if pfds(2).p_revents ^= 0 then extraready = 1;
       if pfds(1).p_revents ^= 0 then do;
         got = trecv( wsfd, wsssl, addr(chunk), 16384 );
         if got > 0 then call bput( B_WSRAW, addr(chunk), got );
         else if got = 0 then call livedrop( 'Live peer closed', 0 );
         else if got = -1 then call livedrop( 'Live read failed', 0 );
         end;
       end;
     end;
   else do;
     if extra >= 0 then
       if twait( extra, POLLIN, ms ) = 1 then extraready = 1;
     end;

   /* Data already inside the TLS record layer would not show up in  */
   /* poll, so any buffered bytes are drained before waiting again.  */
   if wsconnected = 1 & wsssl ^= sysnull() then
     do while( SSL_pending( wsssl ) > 0 );
       got = trecv( wsfd, wsssl, addr(chunk), 16384 );
       if got > 0 then call bput( B_WSRAW, addr(chunk), got );
       else leave;
       end;

   do while( wsconnected = 1 );
     taken = wstakeframe();
     if taken = 0 then leave;
     if taken = 1 then call liveonmessage();
     else if taken = -2 then do;
       call livepublisherror( 'ProtocolError',
                              'Live framing was invalid', 0 );
       call livedrop( 'ProtocolError', 0 );
       end;
     else call livedrop( 'TransportError', 0 );
     end;
   return( extraready );
   end livepump;

 /* Milliseconds since a deadline, tolerating the counter wrapping.  */
 elapsed: proc( deadline ) returns( fixed bin(31) );
   dcl   deadline            fixed bin(31);
   return( nowms() - deadline );
   end elapsed;

 livereconnect: proc;
   dcl   i                   fixed bin(31);
   if wsopen() = 0 then do;
     connectioncount = connectioncount + 1;
     reconnectat = nowms() + backoffms;
     call growbackoff();
     return;
     end;
   if sendconnect() = 0 then do;
     call livedrop( 'Live handshake write failed', 1 );
     return;
     end;
   qsversion = 0;
   if activecount() > 0 then do;
     if sendmodify( 0, 0 ) = 0 then do;
       call livedrop( 'Live query set write failed', 1 );
       return;
       end;
     qsversion = 1;
     /* Every subscription that existed when the snapshot was built  */
     /* has now been resent, so none of them is still pending.       */
     do i = 1 to MAX_SUBSCRIPTIONS;
       if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then
         subaddpend(i) = 0;
       end;
     end;
   wsconnected = 1;
   /* A connection that reached a valid handshake resets the backoff */
   /* so a healthy connection does not inherit an old maximum delay. */
   backoffms = 100;
   end livereconnect;

 growbackoff: proc;
   if backoffms < 7500 then backoffms = backoffms * 2;
   else backoffms = 15000;
   end growbackoff;

 /* Send whatever query set changes are outstanding, one per pump so */
 /* that a failure is always attributable to a single modification.  */
 liveflush: proc;
   dcl   i                   fixed bin(31);
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subaddpend(i) = 1 &
        subrempend(i) = 0 then do;
       if sendmodify( i, 0 ) = 0 then do;
         call livedrop( 'Live add write failed', 0 );
         return;
         end;
       qsversion     = qsversion + 1;
       subaddpend(i) = 0;
       return;
       end;
     end;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subrempend(i) = 1 & subremdone(i) = 0 then do;
       if sendmodify( i, 1 ) = 0 then do;
         call livedrop( 'Live remove write failed', 0 );
         return;
         end;
       qsversion     = qsversion + 1;
       subactive(i)  = 0;
       subremdone(i) = 1;
       return;
       end;
     end;
   end liveflush;

 /* Retire the current connection. Every still-active subscription   */
 /* is marked for rehydration so the value the next connection       */
 /* replays can be recognised as unchanged and suppressed.           */
 livedrop: proc( reason, quiet );
   dcl   reason              char(64);
   dcl   quiet               fixed bin(31);
   dcl   i                   fixed bin(31);
   call wsclose( reason );
   connectioncount = connectioncount + 1;
   qsversion = 0;
   remoteqs  = 0;
   remoteid  = 0;
   call bclear( B_TS );
   call bputt( B_TS, initialts );
   call bclear( B_WSRAW );
   call bclear( B_WSIN );
   wsfragmented = 0;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then do;
       subrehyd(i)   = 1;
       subaddpend(i) = 0;
       end;
     end;
   reconnectat = nowms() + backoffms;
   call growbackoff();
   end livedrop;

 /* Publish one error to every established subscription.             */
 livepublisherror: proc( name, message, establishedonly );
   dcl   name                char(32);
   dcl   message             char(64);
   dcl   establishedonly     fixed bin(31);
   dcl   i                   fixed bin(31);
   call bclear( B_TMP );
   call bputt( B_TMP, '{"name":"' );
   call bputt( B_TMP, name );
   call bputt( B_TMP, '","message":"' );
   call bputt( B_TMP, message );
   call bputt( B_TMP, '"}' );
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then
       if establishedonly = 0 | subaddpend(i) = 0 then
         call enqueue( i, bdata(B_TMP), blen(B_TMP), 1 );
     end;
   end livepublisherror;

 /*------------------------------------------------------------------*/
 /* Incoming sync messages                                           */
 /*------------------------------------------------------------------*/

 liveonmessage: proc;
   dcl   root                fixed bin(31);
   dcl   kind                fixed bin(31);
   root = jparse( D_WS, bdata(B_WSIN), blen(B_WSIN) );
   if root < 0 then do;
     call livepublisherror( 'ProtocolError',
                            'Live message was not valid JSON', 0 );
     call livedrop( 'ProtocolError', 0 );
     return;
     end;
   kind = jmember( D_WS, root, 'type' );
   if kind < 0 then do;
     call livepublisherror( 'ProtocolError',
                            'Live message omitted its type', 0 );
     call livedrop( 'ProtocolError', 0 );
     return;
     end;
   if jtexteq( D_WS, kind, '"Transition"' ) = 1 then do;
     call handletransition( root );
     return;
     end;
   /* Ping and the mutation and action responses this client does    */
   /* not use are accepted and ignored; anything else is drift.      */
   if jtexteq( D_WS, kind, '"Ping"' ) = 1 then return;
   if jtexteq( D_WS, kind, '"MutationResponse"' ) = 1 then return;
   if jtexteq( D_WS, kind, '"ActionResponse"' ) = 1 then return;
   call livepublisherror( 'ProtocolError',
                          'Live server sent an unexpected message', 0 );
   call livedrop( 'ProtocolError', 0 );
   end liveonmessage;

 handletransition: proc( root );
   dcl   root                fixed bin(31);
   dcl   startv              fixed bin(31);
   dcl   endv                fixed bin(31);
   dcl   mods                fixed bin(31);
   dcl   mod1                fixed bin(31);
   dcl   kind                fixed bin(31);
   dcl   qid                 fixed bin(31);
   dcl   slot                fixed bin(31);
   dcl   value               fixed bin(31);
   dcl   logs                fixed bin(31);
   dcl   data                fixed bin(31);
   dcl   text                fixed bin(31);
   dcl   unchanged           fixed bin(31);
   startv = jmember( D_WS, root, 'startVersion' );
   endv   = jmember( D_WS, root, 'endVersion' );
   mods   = jmember( D_WS, root, 'modifications' );
   if startv < 0 | endv < 0 | mods < 0 then do;
     call livepublisherror( 'ProtocolError',
                            'Transition omitted a required field', 0 );
     call livedrop( 'ProtocolError', 0 );
     return;
     end;
   if nf( D_WS, mods, 0 ) ^= J_ARRAY then do;
     call livepublisherror( 'ProtocolError',
                            'Transition modifications must be an array', 0 );
     call livedrop( 'ProtocolError', 0 );
     return;
     end;
   /* A Transition whose start version is not the one this client    */
   /* last recorded means the stream has been reordered or lost, so  */
   /* the connection is abandoned rather than applied out of order.  */
   if versionmatch( startv ) = 0 then do;
     call livepublisherror( 'ProtocolError',
                            'Transition start version did not match', 0 );
     call livedrop( 'ProtocolError', 0 );
     return;
     end;
   mod1 = nf( D_WS, mods, 3 );
   do while( mod1 >= 0 );
     kind = jmember( D_WS, mod1, 'type' );
     qid  = jmember( D_WS, mod1, 'queryId' );
     if kind < 0 | qid < 0 then do;
       call livepublisherror( 'ProtocolError',
                              'Transition modification was malformed', 0 );
       call livedrop( 'ProtocolError', 0 );
       return;
       end;
     slot = slotforquery( jinteger( D_WS, qid ) );
     logs = jmember( D_WS, mod1, 'logLines' );
     if slot > 0 then do;
       if jtexteq( D_WS, kind, '"QueryUpdated"' ) = 1 then do;
         value = jmember( D_WS, mod1, 'value' );
         if value < 0 then do;
           call livepublisherror( 'ProtocolError',
                                  'QueryUpdated omitted its value', 0 );
           call livedrop( 'ProtocolError', 0 );
           return;
           end;
         unchanged = 0;
         if subhaslast(slot) = 1 then
           if sublastn(slot) =
              nf( D_WS, value, 2 ) - nf( D_WS, value, 1 ) then
             if c_memcmp( sublastp(slot),
                          ptradd( dtext(D_WS), nf( D_WS, value, 1 ) ),
                          sublastn(slot) ) = 0 then unchanged = 1;
         if sublastp(slot) ^= sysnull() then call c_free( sublastp(slot) );
         sublastn(slot) = nf( D_WS, value, 2 ) - nf( D_WS, value, 1 );
         sublastp(slot) = keepbytes(
                            ptradd( dtext(D_WS), nf( D_WS, value, 1 ) ),
                            sublastn(slot) );
         subhaslast(slot) = 1;
         /* A reconnection replays the current value. Publishing it   */
         /* again would make a caller waiting for the next change     */
         /* see the old one, so an unchanged rehydration is dropped.  */
         if subrehyd(slot) = 1 & unchanged = 1 then subrehyd(slot) = 0;
         else do;
           subrehyd(slot) = 0;
           call bclear( B_TMP );
           call jcopy( B_TMP, D_WS, value );
           call enqueue( slot, bdata(B_TMP), blen(B_TMP), 0 );
           end;
         end;
       else if jtexteq( D_WS, kind, '"QueryFailed"' ) = 1 then do;
         text = jmember( D_WS, mod1, 'errorMessage' );
         data = jmember( D_WS, mod1, 'errorData' );
         call bclear( B_TMP2 );
         call junquote( B_TMP2, D_WS, text );
         if blen(B_TMP2) = 0 then
           call bputt( B_TMP2, 'Live query failed' );
         call bclear( B_TMP );
         call bputt( B_TMP, '{"name":"FunctionError","message":"' );
         call bputesc( B_TMP, bdata(B_TMP2), blen(B_TMP2) );
         call bputb( B_TMP, '"' );
         if data >= 0 then do;
           call bputt( B_TMP, ',"data":' );
           call jcopy( B_TMP, D_WS, data );
           end;
         if logs >= 0 then do;
           call bputt( B_TMP, ',"logs":' );
           call jcopy( B_TMP, D_WS, logs );
           end;
         call bputb( B_TMP, '}' );
         if sublastp(slot) ^= sysnull() then call c_free( sublastp(slot) );
         sublastp(slot)   = sysnull();
         sublastn(slot)   = 0;
         subhaslast(slot) = 0;
         subrehyd(slot)   = 0;
         call enqueue( slot, bdata(B_TMP), blen(B_TMP), 1 );
         end;
       end;
     mod1 = nf( D_WS, mod1, 4 );
     end;
   call adoptversion( endv );
   end handletransition;

 versionmatch: proc( version ) returns( fixed bin(31) );
   dcl   version             fixed bin(31);
   dcl   q                   fixed bin(31);
   dcl   ident               fixed bin(31);
   dcl   ts                  fixed bin(31);
   q     = jmember( D_WS, version, 'querySet' );
   ident = jmember( D_WS, version, 'identity' );
   ts    = jmember( D_WS, version, 'ts' );
   if q < 0 | ident < 0 | ts < 0 then return( 0 );
   if jinteger( D_WS, q ) ^= remoteqs then return( 0 );
   if jinteger( D_WS, ident ) ^= remoteid then return( 0 );
   call bclear( B_TMP );
   call junquote( B_TMP, D_WS, ts );
   if blen(B_TMP) ^= blen(B_TS) then return( 0 );
   if c_memcmp( bdata(B_TMP), bdata(B_TS), blen(B_TS) ) ^= 0 then return( 0 );
   return( 1 );
   end versionmatch;

 adoptversion: proc( version );
   dcl   version             fixed bin(31);
   dcl   ts                  fixed bin(31);
   remoteqs = jinteger( D_WS, jmember( D_WS, version, 'querySet' ) );
   remoteid = jinteger( D_WS, jmember( D_WS, version, 'identity' ) );
   ts = jmember( D_WS, version, 'ts' );
   call bclear( B_TS );
   call junquote( B_TS, D_WS, ts );
   call bclear( B_MAXTS );
   call bput( B_MAXTS, bdata(B_TS), blen(B_TS) );
   end adoptversion;

 slotforquery: proc( qid ) returns( fixed bin(31) );
   dcl   qid                 fixed bin(31);
   dcl   i                   fixed bin(31);
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 & subactive(i) = 1 & subrempend(i) = 0 then
       if subqid(i) = qid then return( i );
     end;
   return( -1 );
   end slotforquery;

 /* Read a JSON number node as an integer. Convex sends integral      */
 /* values in decimal form such as 1.0, which has to be accepted;     */
 /* a genuinely fractional value is refused by returning the sentinel.*/
 jinteger: proc( d, idx ) returns( fixed bin(31) );
   dcl  (d,idx)              fixed bin(31);
   dcl   at                  fixed bin(31);
   dcl   stop                fixed bin(31);
   dcl   c                   fixed bin(31);
   dcl   value               fixed bin(31);
   dcl   sign                fixed bin(31);
   dcl   seen                fixed bin(31);
   if idx < 0 then return( -2147483647 );
   if nf( d, idx, 0 ) ^= J_NUMBER then return( -2147483647 );
   at   = nf( d, idx, 1 );
   stop = nf( d, idx, 2 );
   sign = 1;
   if jbyte( d, at ) = 45 then do;
     sign = -1;
     at = at + 1;
     end;
   value = 0;
   seen  = 0;
   do while( at < stop );
     c = jbyte( d, at );
     if c >= 48 & c <= 57 then do;
       if value > 214748363 then return( -2147483647 );
       value = value * 10 + c - 48;
       seen  = seen + 1;
       at    = at + 1;
       end;
     else leave;
     end;
   if seen = 0 then return( -2147483647 );
   /* A fractional part is only acceptable when every digit is zero.  */
   if at < stop then do;
     if jbyte( d, at ) ^= 46 then return( -2147483647 );
     at = at + 1;
     do while( at < stop );
       if jbyte( d, at ) ^= 48 then return( -2147483647 );
       at = at + 1;
       end;
     end;
   return( sign * value );
   end jinteger;

 /* Retire the current connection on request. Used only by the       */
 /* conformance adapter's debugDisconnect command.                   */
 livedebugdisconnect: proc returns( fixed bin(31) );
   if livestarted = 0 | wsconnected = 0 then return( 0 );
   backoffms = 100;
   call livedrop( 'DebugDisconnect', 1 );
   /* The next attempt is scheduled promptly: the point of the test  */
   /* is a real reconnect, not a backoff measurement.                */
   reconnectat = nowms() + 100;
   backoffms   = 100;
   return( 1 );
   end livedebugdisconnect;

 liveshutdown: proc;
   dcl   i                   fixed bin(31);
   if livestarted = 0 then return;
   liveclosing = 1;
   if wsconnected = 1 then do;
     i = wssend( WS_CLOSE, sysnull(), 0 );
     call wsclose( 'ClientClose' );
     end;
   do i = 1 to MAX_SUBSCRIPTIONS;
     if subused(i) = 1 then call releasesub( i );
     end;
   livestarted = 0;
   end liveshutdown;
