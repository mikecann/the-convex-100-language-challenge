comment live-test.alg - deterministic tests for the Live sync engine,
   run with no live backend.
   livesubscribe and livepump each open their own transport internally,
   and ALGOL 60 has no second thread free to accept and answer a
   connect while one of those calls is in flight, so most tests here
   pre-seed livewshandle with one half of a real loopback TCP pair
   already opened by this process - exactly the state the manager
   would be in immediately after a real handshake - and then write and
   read genuine WebSocket frames on the other half. This is the same
   technique convex-live.fth's tests use, adapted to a language with
   no closures to hand a fixture a callback. This file is pasted
   inside the same enclosing block as convex-live.alg, exactly like
   the adapter and the example, because it reads and writes the
   manager's tables directly;

integer testliveout;
integer testliveerr;
integer testlivefailures;

procedure testlivereport(passed, description);
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
      testlivefailures := testlivefailures + 1
      end
   else
      discard := bufputstr(line, 256, linelen, "ok - ");
   discard := bufputstr(line, 256, linelen, description);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(
      if passed = 0 then testliveerr else testliveout, line, 0, linelen)
end testlivereport;

procedure testliveeq(expected, actual, description);
   value expected, actual;
   integer expected, actual;
   string description;
begin
   testlivereport(if expected = actual then 1 else 0, description)
end testliveeq;

procedure testliveloopback(clienth, serverh, port);
   value port;
   integer clienth, serverh, port;
begin
   integer array host[0:15];
   integer array portbuf[0:15];
   integer hostlen, portlen, listener, dummy;
   hostlen := 0; dummy := bufputstr(host, 16, hostlen, "127.0.0.1");
   portlen := 0; dummy := bufputint(portbuf, 16, portlen, port);
   listener := cxlisten(host, hostlen, portbuf, portlen);
   clienth := cxopen(host, hostlen, portbuf, portlen, 0, cxnowms + 3000);
   serverh := cxaccept(listener, 3000);
   dummy := cxclose(listener)
end testliveloopback;

comment reads exactly one raw WebSocket frame sent by the manager,
   using the server side of the loopback pair directly rather than
   through any convex-ws.alg procedure, so the test does not simply
   check the manager against its own framing code;
procedure testlivereadmask(handle, opcode, payload, payloadcap, payloadlen);
   value handle, payloadcap;
   integer array payload;
   integer handle, opcode, payloadcap, payloadlen;
begin
   integer array rbuf[0:8191];
   integer rlen, roff;
   rlen := 0; roff := 0;
   payloadlen := 0;
   begin
      integer array errbuf[0:255];
      integer errbuflen, errkind, fin;
      errbuflen := 0; errkind := 0;
      wsreadframe(handle, rbuf, 8192, rlen, roff, cxnowms + 3000,
         fin, opcode, payload, payloadcap, payloadlen,
         errbuf, errbuflen, errkind);
      testlivereport(if errkind = 0 then 1 else 0,
         "the frame read from the manager did not fail or time out")
   end
end testlivereadmask;

comment sends a raw, unmasked text frame, as a real Convex server
   would - servers never mask;
procedure testlivesendserverframe(handle, text);
   integer handle;
   string text;
begin
   integer array payload[0:2047];
   integer array frame[0:2079];
   integer payloadlen, framelen, discard, written, got, dummy;
   payloadlen := 0;
   discard := bufputstr(payload, 2048, payloadlen, text);
   framelen := 0;
   discard := bufputbyte(frame, 2080, framelen, 129);
   if payloadlen < 126 then
      discard := bufputbyte(frame, 2080, framelen, payloadlen)
   else
      begin
      discard := bufputbyte(frame, 2080, framelen, 126);
      discard := bufputbyte(frame, 2080, framelen, payloadlen % 256);
      discard := bufputbyte(frame, 2080, framelen, intmod(payloadlen, 256))
      end;
   discard := bufputbytes(frame, 2080, framelen, payload, 0, payloadlen);
   written := 0;
   for dummy := 1 while written < framelen do
      begin
      got := cxwrite(handle, frame, written, framelen - written);
      if got > 0 then written := written + got
      end
end testlivesendserverframe;

comment ---------------------------------------------------------------
   Version timestamps.
   ------------------------------------------------------------------;

procedure testtimestamps;
begin
   integer array buf[0:15];
   integer buflen, dummy, ok;
   real decoded;
   buflen := 0;
   timestampencode(0.0, buf, 16, buflen);
   testliveeq(12, buflen,
      "a timestamp always encodes to twelve base 64 characters");
   testtimestampdecodecheck(buf, buflen, 0.0,
      "zero round trips through timestamp encode and decode");
   buflen := 0;
   timestampencode(70000.0, buf, 16, buflen);
   testtimestampdecodecheck(buf, buflen, 70000.0,
      "a value larger than a 16-bit word round trips");
   begin
      integer array bad[0:15];
      integer badlen;
      badlen := 0;
      dummy := bufputstr(bad, 16, badlen, "not-canonical");
      timestampdecode(bad, 0, badlen, decoded, ok);
      testliveeq(0, ok, "a non-canonical timestamp is rejected")
   end
end testtimestamps;

procedure testtimestampdecodecheck(buf, buflen, expected, description);
   value buflen, expected;
   integer array buf;
   integer buflen;
   real expected;
   string description;
begin
   real decoded;
   integer ok;
   timestampdecode(buf, 0, buflen, decoded, ok);
   testlivereport(if ok != 0 & decoded = expected then 1 else 0, description)
end testtimestampdecodecheck;

comment ---------------------------------------------------------------
   Subscribe, an initial value, an external update, QueryFailed
   followed by recovery on the same subscription, and unsubscribe -
   all against one manufactured live connection.
   ------------------------------------------------------------------;

procedure testlivesubscribeflow;
begin
   integer clienth, serverh, sub;
   integer array pathbuf[0:31];
   integer array argsbuf[0:63];
   integer pathlen, argslen, dummy;
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   liveinit;
   testliveloopback(clienth, serverh, 45201);
   livewshandle := clienth;
   liveconnectioncount := 1;
   pathlen := 0; dummy := bufputstr(pathbuf, 32, pathlen, "demo:state");
   argslen := 0;
   dummy := bufputstr(argsbuf, 64, argslen, "{\"room\":\"t\"}");
   errbuflen := 0; errkind := 0;
   livesubscribe(pathbuf, pathlen, pathbuf, pathlen, 0,
      pathbuf, pathlen, argsbuf, 0, argslen, cxnowms + 3000,
      sub, errbuf, errbuflen, errkind);
   testliveeq(0, errkind,
      "subscribing on an already open connection does not attempt a new connect");
   begin
      integer opcode, payloadlen;
      integer array payload[0:511];
      testlivereadmask(serverh, opcode, payload, 512, payloadlen);
      testliveeq(1, if bufindexof(payload, 0, payloadlen, 34) >= 0 then 1 else 0,
         "the server received a modification frame");
      testliveeq(1, if opcode = 1 then 1 else 0,
         "the Add is sent as a text frame")
   end;
   testlivesendserverframe(serverh,
      "{\"type\":\"Transition\","
      "\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},"
      "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,"
      "\"value\":{\"count\":0},\"logLines\":[]}]}");
   begin
      integer kind, valuelen;
      integer array valuebytes[0:255];
      kind := livenext(sub, 3000);
      testliveeq(1, kind, "the initial QueryUpdated is delivered as a value");
      valuelen := 0;
      livetakencopyvalue(valuebytes, 256, valuelen);
      livereleasetaken;
      testliveeq(1,
         if bufeqstr(valuebytes, 0, valuelen, "{\"count\":0}") then 1 else 0,
         "the initial value's bytes are exactly what the server sent")
   end;
   testlivesendserverframe(serverh,
      "{\"type\":\"Transition\","
      "\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AgAAAAAAAAA=\"},"
      "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,"
      "\"value\":{\"count\":1},\"logLines\":[]}]}");
   begin
      integer kind, valuelen;
      integer array valuebytes[0:255];
      kind := livenext(sub, 3000);
      testliveeq(1, kind, "an external update is also delivered as a value");
      valuelen := 0;
      livetakencopyvalue(valuebytes, 256, valuelen);
      livereleasetaken;
      testliveeq(1,
         if bufeqstr(valuebytes, 0, valuelen, "{\"count\":1}") then 1 else 0,
         "the updated value reflects the external change")
   end;
   testlivesendserverframe(serverh,
      "{\"type\":\"Transition\","
      "\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AgAAAAAAAAA=\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AwAAAAAAAAA=\"},"
      "\"modifications\":[{\"type\":\"QueryFailed\",\"queryId\":0,"
      "\"errorMessage\":\"nope\",\"errorData\":{\"code\":\"E\"},"
      "\"logLines\":[]}]}");
   begin
      integer kind, msglen, hasdata, datalen;
      integer array msg[0:255];
      integer array data[0:255];
      kind := livenext(sub, 3000);
      testliveeq(2, kind, "QueryFailed is delivered as an error");
      testliveeq(1, livetakenerrkind,
         "a QueryFailed modification is reported as a FunctionError");
      msglen := 0;
      livetakencopymessage(msg, 256, msglen);
      testliveeq(1, if bufeqstr(msg, 0, msglen, "nope") then 1 else 0,
         "the error message matches the server's errorMessage");
      datalen := 0;
      livetakencopydata(data, 256, datalen, hasdata);
      livereleasetaken;
      testliveeq(1, hasdata, "errorData is carried through to the delivery")
   end;
   testlivesendserverframe(serverh,
      "{\"type\":\"Transition\","
      "\"startVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AwAAAAAAAAA=\"},"
      "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"BAAAAAAAAAA=\"},"
      "\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":0,"
      "\"value\":{\"count\":2},\"logLines\":[]}]}");
   begin
      integer kind, valuelen;
      integer array valuebytes[0:255];
      kind := livenext(sub, 3000);
      testliveeq(1, kind,
         "recovery after QueryFailed is delivered as a value on the same subscription");
      valuelen := 0;
      livetakencopyvalue(valuebytes, 256, valuelen);
      livereleasetaken;
      testliveeq(1,
         if bufeqstr(valuebytes, 0, valuelen, "{\"count\":2}") then 1 else 0,
         "the recovered value is correct")
   end;
   liveunsubscribe(sub, cxnowms + 3000);
   begin
      integer opcode, payloadlen;
      integer array payload[0:511];
      testlivereadmask(serverh, opcode, payload, 512, payloadlen);
      testliveeq(1, if bufindexof(payload, 0, payloadlen, 82) >= 0 then 1 else 0,
         "unsubscribe sends a Remove modification containing an R")
   end;
   testliveeq(0, subactive[sub],
      "the subscription slot is inactive after unsubscribe");
   dummy := cxclose(clienth);
   dummy := cxclose(serverh)
end testlivesubscribeflow;

comment ---------------------------------------------------------------
   debugDisconnect: refuses without a connection rather than faking an
   acknowledgement, and otherwise retires the connection and bumps the
   generation before acknowledging.
   ------------------------------------------------------------------;

procedure testlivedebugdisconnect;
begin
   integer array errbuf[0:255];
   integer errbuflen, errkind, gen, generationbefore;
   liveinit;
   errbuflen := 0; errkind := 0;
   gen := livedebugdisconnect(errbuf, errbuflen, errkind);
   testliveeq(1, if errkind != 0 then 1 else 0,
      "debugDisconnect refuses when there is no live connection");
   begin
      integer clienth, serverh, dummy;
      liveinit;
      testliveloopback(clienth, serverh, 45202);
      livewshandle := clienth;
      generationbefore := livegeneration;
      errbuflen := 0; errkind := 0;
      gen := livedebugdisconnect(errbuf, errbuflen, errkind);
      testliveeq(0, errkind, "debugDisconnect succeeds when a connection exists");
      testliveeq(generationbefore + 1, gen,
         "debugDisconnect advances the manager generation");
      testliveeq(1, if livewshandle < 0 then 1 else 0,
         "debugDisconnect actually retires the connection");
      dummy := cxclose(clienth);
      dummy := cxclose(serverh)
   end
end testlivedebugdisconnect;

comment ---------------------------------------------------------------
   The bounded delivery queue drops the oldest entry, not a newer one,
   and counts every drop.
   ------------------------------------------------------------------;

procedure testlivedeliveryqueue;
begin
   integer i, before;
   liveinit;
   subactive[0] := 1;
   subepoch[0] := 1;
   before := livedrops;
   for i := 1 step 1 until livemaxdeliveries + 4 do
      begin
      integer array valuebytes[0:15];
      integer valuelen, discard;
      valuelen := 0;
      discard := bufputint(valuebytes, 16, valuelen, i);
      livepublishvalue(0, valuebytes, 0, valuelen);
      subhavelast[0] := 0
      end;
   testliveeq(livemaxdeliveries, livequeuecount,
      "the delivery queue never exceeds its configured maximum");
   testliveeq(1, if livedrops > before then 1 else 0,
      "overflow is counted as a drop rather than silently discarded");
   begin
      integer kind, valuelen;
      integer array valuebytes[0:15];
      kind := livetakefor(0);
      valuelen := 0;
      livetakencopyvalue(valuebytes, 16, valuelen);
      livereleasetaken;
      testliveeq(1, if bufparseuint(valuebytes, 0, valuelen) > 4 then 1 else 0,
         "the oldest deliveries were dropped, not the newest")
   end
end testlivedeliveryqueue;

testlivefailures := 0;
testliveout := cxadopt(1);
testliveerr := cxadopt(2);
testtimestamps;
testlivesubscribeflow;
testlivedebugdisconnect;
testlivedeliveryqueue;
if testlivefailures > 0 then
   begin
   integer discard;
   discard := cxexit(1)
   end
