comment client-test.alg - deterministic tests for the buffer, JSON and
   HTTP layers, run with no live backend. HTTP is exercised over a real
   loopback TCP pair, opened and accepted within this one process,
   because ALGOL 60 has no threads to run a separate fixture peer on.
   This file is a complete standalone program - unlike convex-live.alg
   it declares no state that a code procedure or another file needs to
   share, so it opens its own begin block rather than being pasted
   into one;

begin
integer teststdout;
integer teststderr;
integer testfailures;

procedure testreport(passed, description);
   value passed;
   integer passed;
   string description;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   if passed = 0 then
      begin
      discard := bufputstr(line, 256, linelen, "not ok - ");
      testfailures := testfailures + 1
      end
   else
      discard := bufputstr(line, 256, linelen, "ok - ");
   discard := bufputstr(line, 256, linelen, description);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(if passed = 0 then teststderr else teststdout, line, 0, linelen)
end testreport;

procedure asserteq(expected, actual, description);
   value expected, actual;
   integer expected, actual;
   string description;
begin
   testreport(if expected = actual then 1 else 0, description)
end asserteq;

comment ---------------------------------------------------------------
   Buffer primitives.
   ------------------------------------------------------------------;

procedure testbuffers;
begin
   integer array a[0:63];
   integer alen, dummy;
   alen := 0;
   dummy := bufputstr(a, 64, alen, "Hello, ");
   dummy := bufputint(a, 64, alen, 42);
   dummy := bufputstr(a, 64, alen, "!");
   asserteq(1, if bufeqstr(a, 0, alen, "Hello, 42!") then 1 else 0, "bufputstr/bufputint build the expected bytes");
   asserteq(1, if bufieqstr(a, 0, 5, "HELLO") then 1 else 0, "bufieqstr is case insensitive");
   asserteq(42, bufparseuint(a, 7, 2), "bufparseuint reads the digits written by bufputint");
   asserteq(-1, bufparseuint(a, 0, 5), "bufparseuint rejects non-digit bytes");
   begin
      integer array small[0:3];
      integer smalllen, i, overflowed;
      smalllen := 0;
      overflowed := 0;
      for i := 1 step 1 until 6 do
         if bufputbyte(small, 4, smalllen, 65) = 1 then overflowed := 1;
      asserteq(1, overflowed, "bufputbyte reports overflow instead of writing past capacity");
      asserteq(4, smalllen, "bufputbyte stops advancing length once full")
   end;
   begin
      integer array raw[0:15];
      integer array enc[0:31];
      integer array dec[0:15];
      integer rawlen, enclen, declen, i, same;
      rawlen := 0;
      for i := 0 step 1 until 9 do dummy := bufputbyte(raw, 16, rawlen, i * 7 + 1);
      enclen := 0;
      dummy := b64encode(raw, 0, rawlen, enc, 32, enclen);
      asserteq(0, intmod(enclen, 4), "base 64 output length is a multiple of four");
      declen := 0;
      for i := 0 step 4 until enclen - 1 do
         dummy := b64decode(enc, i, 4, dec, 16, declen);
      same := if declen = rawlen then 1 else 0;
      if same = 1 then
         for i := 0 step 1 until rawlen - 1 do
            if dec[i] != raw[i] then same := 0;
      asserteq(1, same, "base 64 round trips arbitrary bytes")
   end
end testbuffers;

comment ---------------------------------------------------------------
   JSON.
   ------------------------------------------------------------------;

procedure testjson;
begin
   integer array doc[0:1023];
   integer array errbuf[0:255];
   integer doclen, errbuflen, errkind, dummy, endoff;
   doclen := 0;
   dummy := bufputstr(doc, 1024, doclen,
      "{\"status\":\"success\",\"value\":{\"count\":5,\"note\":\"caf\\u00e9\\nx\",\"list\":[1,2,3]},\"logLines\":[]}");
   errbuflen := 0; errkind := 0;
   jsonskipvalue(doc, 0, doclen, 1, endoff, errbuf, errbuflen, errkind);
   asserteq(0, errkind, "a well formed envelope parses without error");
   asserteq(doclen, endoff, "jsonskipvalue consumes the entire document");

   begin
      integer voff, vlen, found;
      jsonfindfield(doc, 0, doclen, "value", voff, vlen, found, errbuf, errbuflen, errkind);
      asserteq(1, found, "jsonfindfield locates a top level object field");
      begin
         integer coff, clen, cfound, cval, cok;
         jsonfindfield(doc, voff, voff + vlen, "count", coff, clen, cfound, errbuf, errbuflen, errkind);
         asserteq(1, cfound, "jsonfindfield descends into a nested object when given its range");
         cval := jsonparseint(doc, coff, clen, cok);
         asserteq(1, cok, "jsonparseint accepts a plain integer");
         asserteq(5, cval, "jsonparseint reads the correct value")
      end;
      begin
         integer noff, nlen, nfound;
         integer array decoded[0:63];
         integer decodedlen, wr;
         jsonfindfield(doc, voff, voff + vlen, "note", noff, nlen, nfound, errbuf, errbuflen, errkind);
         asserteq(1, nfound, "jsonfindfield locates the note field");
         decodedlen := 0;
         wr := jsonstringcontent(doc, noff, noff + nlen, decoded, 64, decodedlen);
         asserteq(0, wr, "jsonstringcontent decodes a unicode escape and a control escape");
         asserteq(7, decodedlen, "the decoded bytes are caf, two UTF-8 bytes for e-acute, a newline and x");
         asserteq(1, if decoded[5] = 10 then 1 else 0, "the decoded newline is a single 0x0A byte")
      end
   end;

   comment AGENTS.md requires accepting an integral number in decimal
      form, such as 0.0, and rejecting a fractional, quoted or
      overflowing one;
   begin
      integer array n1[0:7];
      integer array n2[0:7];
      integer array n3[0:7];
      integer array n4[0:7];
      integer n1len, n2len, n3len, n4len, ok, v, dummy2;
      n1len := 0; dummy2 := bufputstr(n1, 8, n1len, "0.0");
      v := jsonparseint(n1, 0, n1len, ok);
      asserteq(1, ok, "0.0 is accepted as integral");
      asserteq(0, v, "0.0 parses to zero");
      n2len := 0; dummy2 := bufputstr(n2, 8, n2len, "1.5");
      v := jsonparseint(n2, 0, n2len, ok);
      asserteq(0, ok, "1.5 is rejected as not integral");
      n3len := 0; dummy2 := bufputstr(n3, 8, n3len, "1e2");
      v := jsonparseint(n3, 0, n3len, ok);
      asserteq(1, ok, "1e2 is accepted as integral");
      asserteq(100, v, "1e2 parses to one hundred");
      n4len := 0; dummy2 := bufputstr(n4, 8, n4len, "3000000000");
      v := jsonparseint(n4, 0, n4len, ok);
      asserteq(0, ok, "an out of range magnitude is rejected")
   end;

   begin
      integer array esc[0:31];
      integer array written[0:63];
      integer esclen, wlen, dummy3;
      esclen := 0;
      dummy3 := bufputstr(esc, 32, esclen, "he said \"hi\"");
      wlen := 0;
      dummy3 := jsonwritestring(written, 64, wlen, esc, 0, esclen);
      asserteq(1, if bufeqstr(written, 0, wlen, "\"he said \\\"hi\\\"\"") then 1 else 0,
         "jsonwritestring escapes an embedded quote")
   end
end testjson;

comment ---------------------------------------------------------------
   HTTP, over a real loopback TCP pair opened within this process.
   ------------------------------------------------------------------;

procedure loopbackpair(clienthandle, serverhandle, port);
   value port;
   integer clienthandle, serverhandle, port;
begin
   integer array host[0:15];
   integer array portbuf[0:15];
   integer hostlen, portlen, listener, dummy;
   hostlen := 0; dummy := bufputstr(host, 16, hostlen, "127.0.0.1");
   portlen := 0; dummy := bufputint(portbuf, 16, portlen, port);
   listener := cxlisten(host, hostlen, portbuf, portlen);
   clienthandle := cxopen(host, hostlen, portbuf, portlen, 0, cxnowms + 3000);
   serverhandle := cxaccept(listener, 3000);
   dummy := cxclose(listener)
end loopbackpair;

procedure servewrite(handle, text);
   value handle;
   integer handle;
   string text;
begin
   integer array line[0:2047];
   integer linelen, discard, written, got, dummy;
   linelen := 0;
   discard := bufputstr(line, 2048, linelen, text);
   written := 0;
   for dummy := 1 while written < linelen do
      begin
      got := cxwrite(handle, line, written, linelen - written);
      if got > 0 then written := written + got
      end
end servewrite;

procedure testhttpchunked;
begin
   integer clienth, serverh;
   integer array host[0:15];
   integer array port[0:15];
   integer array authbuf[0:1];
   integer array pathbuf[0:31];
   integer array argsbuf[0:15];
   integer array msgbuf[0:255];
   integer array bodybuf[0:2047];
   integer array errbuf[0:255];
   integer hostlen, portlen, pathlen, argslen, msglen, errbuflen, errkind;
   integer statuscode, kind, valoff, vallen, hasdata, dataoff, datalen, haslogs, logsoff, logslen, dummy;
   loopbackpair(clienth, serverh, 45101);
   servewrite(serverh,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
      "Transfer-Encoding: chunked\r\n\r\n20\r\n{\"status\":\"success\","
      "\"value\":{\"co\r\n16\r\nunt\":9},\"logLines\":[]}\r\n0\r\n\r\n");
   hostlen := 0; dummy := bufputstr(host, 16, hostlen, "127.0.0.1");
   portlen := 0; dummy := bufputint(port, 16, portlen, 45101);
   pathlen := 0; dummy := bufputstr(pathbuf, 32, pathlen, "demo:state");
   argslen := 0; dummy := bufputstr(argsbuf, 16, argslen, "{}");
   errbuflen := 0; errkind := 0;
   begin
      integer array reqbuf[0:8191];
      integer array bodyreq[0:8191];
      integer reqlen, bodyreqlen, rlen, roff, contentlength, chunked, bodylen, discard2;
      integer array linebuf[0:2047];
      httpbuildbody(bodyreq, 8192, bodyreqlen, "query", pathbuf, pathlen, argsbuf, 0, argslen);
      httpbuildrequest(reqbuf, 8192, reqlen, "query", host, hostlen, port, portlen, 0, authbuf, 0, bodyreq, bodyreqlen);
      discard2 := cxwrite(clienth, reqbuf, 0, reqlen);
      rlen := 0; roff := 0;
      begin
         integer statuslinelen;
         statuslinelen := 0;
         streamline(clienth, reqbuf, 8192, rlen, roff, cxnowms + 3000, linebuf, 2048, statuslinelen, errbuf, errbuflen,
            errkind);
         statuscode := httpstatuscode(linebuf, statuslinelen, errbuf, errbuflen, errkind)
      end;
      httpreadheaders(clienth, reqbuf, 8192, rlen, roff, cxnowms + 3000, linebuf, 2048, contentlength, chunked, errbuf,
         errbuflen, errkind);
      asserteq(1, chunked, "chunked transfer encoding is detected");
      httpreadbody(clienth, reqbuf, 8192, rlen, roff, cxnowms + 3000, contentlength, chunked, bodybuf, 2048, bodylen,
         linebuf, 2048, errbuf, errbuflen, errkind);
      asserteq(0, errkind, "a chunked body spanning two chunks is reassembled without error");
      httpdecodeenvelope(bodybuf, bodylen, statuscode, kind, valoff, vallen, haslogs, logsoff, logslen,
         msgbuf, 256, msglen, hasdata, dataoff, datalen, errbuf, errbuflen, errkind);
      asserteq(0, errkind, "the reassembled envelope decodes without error");
      asserteq(0, kind, "the reassembled envelope reports success");
      begin
         integer coff, clen, cfound, cval, cok;
         jsonfindfield(bodybuf, valoff, valoff + vallen, "count", coff, clen, cfound, errbuf, errbuflen, errkind);
         cval := jsonparseint(bodybuf, coff, clen, cok);
         asserteq(9, cval, "the count split across a chunk boundary reassembles to the right value")
      end
   end;
   dummy := cxclose(clienth);
   dummy := cxclose(serverh)
end testhttpchunked;

comment convexcall opens its own connection internally, so it cannot
   be driven against a loopback pair this same single-threaded process
   already holds both ends of - there is no second thread free to
   accept and answer while convexcall's own connect is in flight. This
   test therefore exercises the response side the same way
   testhttpchunked does: a real loopback pair, fed by servewrite, read
   back through the same streamline, httpreadheaders, httpreadbody and
   httpdecodeenvelope procedures convexcall itself calls;
procedure testhttpstructurederror;
begin
   integer clienth, serverh;
   integer array msgbuf[0:255];
   integer array bodybuf[0:2047];
   integer array errbuf[0:255];
   integer msglen, errbuflen, errkind, dummy;
   integer statuscode, kind, valoff, vallen, hasdata, dataoff, datalen, haslogs, logsoff, logslen;
   loopbackpair(clienth, serverh, 45102);
   servewrite(serverh,
      "HTTP/1.1 560 Convex Function Error\r\nContent-Type: application/json\r\n"
      "Content-Length: 79\r\nConnection: close\r\n\r\n{\"status\":\"error\","
      "\"errorMessage\":\"boom\",\"errorData\":{\"code\":\"X\"},\"logLines\":[]}");
   errbuflen := 0; errkind := 0;
   begin
      integer array reqbuf[0:2047];
      integer array linebuf[0:2047];
      integer rlen, roff, contentlength, chunked, bodylen, statuslinelen;
      rlen := 0; roff := 0;
      statuslinelen := 0;
      streamline(clienth, reqbuf, 2048, rlen, roff, cxnowms + 3000, linebuf, 2048, statuslinelen, errbuf, errbuflen,
         errkind);
      statuscode := httpstatuscode(linebuf, statuslinelen, errbuf, errbuflen, errkind);
      httpreadheaders(clienth, reqbuf, 2048, rlen, roff, cxnowms + 3000, linebuf, 2048, contentlength, chunked, errbuf,
         errbuflen, errkind);
      httpreadbody(clienth, reqbuf, 2048, rlen, roff, cxnowms + 3000, contentlength, chunked, bodybuf, 2048, bodylen,
         linebuf, 2048, errbuf, errbuflen, errkind);
      asserteq(0, errkind, "a 560 response with a declared Content-Length is read without a transport error");
      asserteq(560, statuscode, "the unusual 560 HTTP status is parsed correctly");
      httpdecodeenvelope(bodybuf, bodylen, statuscode, kind, valoff, vallen, haslogs, logsoff, logslen,
         msgbuf, 256, msglen, hasdata, dataoff, datalen, errbuf, errbuflen, errkind);
      asserteq(0, errkind, "a structured Convex error envelope decodes without a protocol error");
      asserteq(1, kind, "an envelope with status error is reported as a function error");
      asserteq(1, if bufeqstr(msgbuf, 0, msglen, "boom") then 1 else 0,
         "the decoded error message matches errorMessage");
      asserteq(1, hasdata, "errorData is reported as present")
   end;
   dummy := cxclose(clienth);
   dummy := cxclose(serverh)
end testhttpstructurederror;

testfailures := 0;
teststdout := cxadopt(1);
teststderr := cxadopt(2);
testbuffers;
testjson;
testhttpchunked;
testhttpstructurederror;
if testfailures > 0 then
   begin
   integer discard;
   discard := cxexit(1)
   end
end
