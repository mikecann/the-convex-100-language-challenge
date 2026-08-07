comment adapter.alg - the NDJSON adapter protocol v1, in ALGOL 60.
   This file is test infrastructure, not public client code - it exists
   so the shared conformance controller can drive the real client
   through the same handful of ALGOL 60 procedures the example uses:
   convexcall, livesubscribe, livenext, and their neighbours. stdout is
   reserved for protocol events, and every diagnostic goes to the sigma
   channel, ALGOL 60's own name for stderr, through cxadopt(2).
   Framing: newline-delimited JSON, one command or one event per line.
   Transport: stdin and stdout by default, but when the environment
   variable ADAPTER_LISTEN is set, this file listens on that host colon
   port instead, accepts exactly one controller connection, and carries
   the same NDJSON stream over it. This file must be assembled together
   with convex-live.alg inside one enclosing block, because it reads
   and writes the Live manager's tables directly rather than through
   parameters - see convex-live.alg for why ALGOL 60 leaves no other
   way to share that state across files;

comment ---------------------------------------------------------------
   Adapter state.
   ------------------------------------------------------------------;

integer ctrlhandle;
integer stdouthandle;
integer stderrhandle;
integer array ctrlrbuf[0:8191];
integer ctrlrlen;
integer ctrlroff;
integer array outbuf[0:65535];
integer outlen;

integer array cfghost[0:255];
integer cfghostlen;
integer array cfgport[0:15];
integer cfgportlen;
integer cfgtls;
integer array cfgauth[0:511];
integer cfgauthlen;

integer array subidbuf[0:3, 0:127];
integer array subidlen[0:3];

integer adapterrunning;
integer array runtimename[0:63];
integer runtimenamelen;

comment ---------------------------------------------------------------
   Diagnostics, to the sigma channel only.
   ------------------------------------------------------------------;

procedure diag(msg);
   string msg;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, msg);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(stderrhandle, line, 0, linelen)
end diag;

comment ---------------------------------------------------------------
   Writing one NDJSON event line. Every emit procedure builds into
   outbuf, appends a trailing newline, and writes it out with a bounded
   deadline of its own, since a stalled controller must not be allowed
   to hang the adapter forever.
   ------------------------------------------------------------------;

integer procedure adapterwritedeadline;
begin
   adapterwritedeadline := cxnowms + 5000
end;

procedure flushline;
   comment writes outbuf, plus a trailing newline, to the controller.
   Reuses wswriteall from convex-ws.alg, which already implements a
   deadline-bounded write loop over a handle using cxpoll and cxwrite -
   the exact primitives this procedure would otherwise duplicate. A
   failed write is reported to the sigma channel rather than raised,
   because there is no command in flight left to report it to - a
   broken controller pipe surfaces at the next read instead;
begin
   integer array writeerrbuf[0:255];
   integer writeerrbuflen, writeerrkind, discard;
   discard := bufputbyte(outbuf, 65536, outlen, 10);
   writeerrbuflen := 0; writeerrkind := 0;
   wswriteall(stdouthandle, outbuf, outlen, adapterwritedeadline, writeerrbuf, writeerrbuflen, writeerrkind);
   if writeerrkind != 0 then diag("write to the controller failed")
end flushline;

procedure emitidfield(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   integer discard;
   if hasid != 0 then
      begin
      discard := bufputstr(outbuf, 65536, outlen, "\"id\":");
      discard := jsonwritestring(outbuf, 65536, outlen, idbuf, 0, idlen);
      discard := bufputbyte(outbuf, 65536, outlen, 44)
      end
end emitidfield;

procedure emitready(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   integer discard;
   outlen := 0;
   discard := bufputstr(outbuf, 65536, outlen, "{\"protocolVersion\":1,");
   emitidfield(hasid, idbuf, idlen);
   discard := bufputstr(outbuf, 65536, outlen,
      "\"type\":\"ready\",\"language\":\"algol60\",\"implementation\":\"native-algol60-0.1.0\",\"runtime\":");
   discard := jsonwritestring(outbuf, 65536, outlen, runtimename, 0, runtimenamelen);
   discard := bufputbyte(outbuf, 65536, outlen, 125);
   flushline
end emitready;

procedure emitresult(hasid, idbuf, idlen, valuebuf, valueoff, valuelen, haslogs, logsbuf, logsoff, logslen);
   value hasid, idlen, valueoff, valuelen, haslogs, logsoff, logslen;
   integer array idbuf, valuebuf, logsbuf;
   integer hasid, idlen, valueoff, valuelen, haslogs, logsoff, logslen;
begin
   integer discard;
   outlen := 0;
   discard := bufputbyte(outbuf, 65536, outlen, 123);
   emitidfield(hasid, idbuf, idlen);
   discard := bufputstr(outbuf, 65536, outlen, "\"type\":\"result\",\"value\":");
   discard := bufputbytes(outbuf, 65536, outlen, valuebuf, valueoff, valuelen);
   discard := bufputstr(outbuf, 65536, outlen, ",\"logs\":");
   if haslogs != 0 then
      discard := bufputbytes(outbuf, 65536, outlen, logsbuf, logsoff, logslen)
   else
      discard := bufputstr(outbuf, 65536, outlen, "[]");
   discard := bufputbyte(outbuf, 65536, outlen, 125);
   flushline
end emitresult;

procedure emitack(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   integer discard;
   outlen := 0;
   discard := bufputbyte(outbuf, 65536, outlen, 123);
   emitidfield(hasid, idbuf, idlen);
   discard := bufputstr(outbuf, 65536, outlen, "\"type\":\"ack\"}");
   flushline
end emitack;

procedure emitclosed(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   integer discard;
   outlen := 0;
   discard := bufputbyte(outbuf, 65536, outlen, 123);
   emitidfield(hasid, idbuf, idlen);
   discard := bufputstr(outbuf, 65536, outlen, "\"type\":\"closed\"}");
   flushline
end emitclosed;

comment errkindcode is 1 FunctionError, 2 ProtocolError, 3
   TransportError;
procedure writeerrorobject(errkindcode, msgbuf, msgoff, msglen, hasdata, databuf, dataoff, datalen);
   value errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
   integer array msgbuf, databuf;
   integer errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
begin
   integer discard;
   discard := bufputstr(outbuf, 65536, outlen, "\"error\":{\"name\":");
   if errkindcode = 1 then discard := bufputstr(outbuf, 65536, outlen, "\"FunctionError\"")
   else if errkindcode = 2 then discard := bufputstr(outbuf, 65536, outlen, "\"ProtocolError\"")
   else discard := bufputstr(outbuf, 65536, outlen, "\"TransportError\"");
   discard := bufputstr(outbuf, 65536, outlen, ",\"message\":");
   discard := jsonwritestring(outbuf, 65536, outlen, msgbuf, msgoff, msglen);
   if hasdata != 0 then
      begin
      discard := bufputstr(outbuf, 65536, outlen, ",\"data\":");
      discard := bufputbytes(outbuf, 65536, outlen, databuf, dataoff, datalen)
      end;
   discard := bufputbyte(outbuf, 65536, outlen, 125)
end writeerrorobject;

procedure emiterror(hasid, idbuf, idlen, errkindcode, msgbuf, msgoff, msglen, hasdata, databuf, dataoff, datalen);
   value hasid, idlen, errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
   integer array idbuf, msgbuf, databuf;
   integer hasid, idlen, errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
begin
   integer discard;
   outlen := 0;
   discard := bufputbyte(outbuf, 65536, outlen, 123);
   emitidfield(hasid, idbuf, idlen);
   discard := bufputstr(outbuf, 65536, outlen, "\"type\":\"error\",");
   writeerrorobject(errkindcode, msgbuf, msgoff, msglen, hasdata, databuf, dataoff, datalen);
   discard := bufputbyte(outbuf, 65536, outlen, 125);
   flushline
end emiterror;

procedure emitsubscriptionvalue(sub, valuebuf, valueoff, valuelen, haslogs, logsbuf, logsoff, logslen);
   value sub, valueoff, valuelen, haslogs, logsoff, logslen;
   integer array valuebuf, logsbuf;
   integer sub, valueoff, valuelen, haslogs, logsoff, logslen;
begin
   integer discard, i;
   integer array idcopy[0:127];
   outlen := 0;
   discard := bufputstr(outbuf, 65536, outlen, "{\"type\":\"subscription\",\"subscriptionId\":");
   for i := 0 step 1 until subidlen[sub] - 1 do idcopy[i] := subidbuf[sub, i];
   discard := jsonwritestring(outbuf, 65536, outlen, idcopy, 0, subidlen[sub]);
   discard := bufputstr(outbuf, 65536, outlen, ",\"value\":");
   discard := bufputbytes(outbuf, 65536, outlen, valuebuf, valueoff, valuelen);
   discard := bufputstr(outbuf, 65536, outlen, ",\"logs\":");
   if haslogs != 0 then
      discard := bufputbytes(outbuf, 65536, outlen, logsbuf, logsoff, logslen)
   else
      discard := bufputstr(outbuf, 65536, outlen, "[]");
   discard := bufputbyte(outbuf, 65536, outlen, 125);
   flushline
end emitsubscriptionvalue;

procedure emitsubscriptionerror(sub, errkindcode, msgbuf, msgoff, msglen, hasdata, databuf, dataoff, datalen);
   value sub, errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
   integer array msgbuf, databuf;
   integer sub, errkindcode, msgoff, msglen, hasdata, dataoff, datalen;
begin
   integer discard, i;
   integer array idcopy[0:127];
   outlen := 0;
   discard := bufputstr(outbuf, 65536, outlen, "{\"type\":\"subscription\",\"subscriptionId\":");
   for i := 0 step 1 until subidlen[sub] - 1 do idcopy[i] := subidbuf[sub, i];
   discard := jsonwritestring(outbuf, 65536, outlen, idcopy, 0, subidlen[sub]);
   discard := bufputbyte(outbuf, 65536, outlen, 44);
   writeerrorobject(errkindcode, msgbuf, msgoff, msglen, hasdata, databuf, dataoff, datalen);
   discard := bufputbyte(outbuf, 65536, outlen, 125);
   flushline
end emitsubscriptionerror;

comment ---------------------------------------------------------------
   Reading one command line, non-blocking friendly: most polls find
   nothing waiting, which is normal, not an error.
   ------------------------------------------------------------------;

procedure ctrlreadline(waitms, gotline, linebuf, linecap, linelen);
   value waitms, linecap;
   integer array linebuf;
   integer waitms, gotline, linecap, linelen;
begin
   integer avail, mask, alreadyhaveline, nlpos;
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   gotline := 0;
   alreadyhaveline := if bufindexof(ctrlrbuf, ctrlroff, ctrlrlen - ctrlroff, 10) >= 0 then 1 else 0;
   avail := if ctrlrlen > ctrlroff then 1 else 0;
   if alreadyhaveline = 0 & avail = 0 then
      begin
      mask := cxpoll(ctrlhandle, 0, -1, 0, -1, 0, waitms);
      if mask > 0 then avail := 1
      end;
   if alreadyhaveline != 0 | avail != 0 then
      begin
      errbuflen := 0; errkind := 0;
      linelen := 0;
      streamline(ctrlhandle, ctrlrbuf, 8192, ctrlrlen, ctrlroff, cxnowms + 60000, linebuf, linecap, linelen, errbuf,
         errbuflen, errkind);
      if errkind = 0 then
         gotline := 1
      else
         begin
         diag("controller stream failed");
         adapterrunning := 0
         end
      end
end ctrlreadline;

comment ---------------------------------------------------------------
   Command dispatch.
   ------------------------------------------------------------------;

integer procedure decodefield(line, linelen, key, decoded, decodedcap, decodedlen);
   comment finds a string field named key in the top-level object line
   and decodes its content into decoded. Returns 1 if found, 0 if
   absent - does not itself signal a protocol error, since not every
   field is required by every op;
   value linelen, decodedcap;
   integer array line, decoded;
   integer linelen, decodedcap, decodedlen;
   string key;
begin
   integer voff, vlen, found;
   integer array errbuf[0:255];
   integer errbuflen, errkind, discard;
   errbuflen := 0; errkind := 0;
   jsonfindfield(line, 0, linelen, key, voff, vlen, found, errbuf, errbuflen, errkind);
   decodedlen := 0;
   if errkind = 0 & found != 0 then
      begin
      discard := jsonstringcontent(line, voff, voff + vlen, decoded, decodedcap, decodedlen);
      decodefield := 1
      end
   else
      decodefield := 0
end decodefield;

integer procedure findsubidslot(idbuf, idlen);
   comment the active subscription slot whose external id matches, or
   negative one;
   value idlen;
   integer array idbuf;
   integer idlen;
begin
   integer i, j, same, found;
   found := -1;
   for i := 0 step 1 until 3 do
      if subactive[i] != 0 & found < 0 & subidlen[i] = idlen then
         begin
         same := 1;
         for j := 0 step 1 until idlen - 1 do
            if subidbuf[i, j] != idbuf[j] then same := 0;
         if same = 1 then found := i
         end;
   findsubidslot := found
end findsubidslot;

procedure handlehello(line, linelen, hasid, idbuf, idlen);
   value linelen, hasid, idlen;
   integer array line, idbuf;
   integer linelen, hasid, idlen;
begin
   integer voff, vlen, found, versionvalue, versionok;
   integer array errbuf[0:255];
   integer errbuflen, errkind, discard;
   errbuflen := 0; errkind := 0;
   jsonfindfield(line, 0, linelen, "protocolVersion", voff, vlen, found, errbuf, errbuflen, errkind);
   versionvalue := if errkind = 0 & found != 0 then jsonparseint(line, voff, vlen, versionok) else 0;
   if found = 0 | errkind != 0 | versionok = 0 | versionvalue != 1 then
      begin
      integer array msg[0:63];
      integer msglen;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "unsupported adapter protocol version");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
   else
      emitready(hasid, idbuf, idlen)
end handlehello;

procedure handlecall(opname, line, linelen, hasid, idbuf, idlen);
   value linelen, hasid, idlen;
   integer array line, idbuf;
   integer linelen, hasid, idlen;
   string opname;
begin
   integer array pathbuf[0:127];
   integer pathlen, pfound;
   integer argsoff, argslen, afound;
   integer array errbuf[0:255];
   integer errbuflen, errkind, discard;
   errbuflen := 0; errkind := 0;
   pfound := decodefield(line, linelen, "path", pathbuf, 128, pathlen);
   jsonfindfield(line, 0, linelen, "args", argsoff, argslen, afound, errbuf, errbuflen, errkind);
   if pfound = 0 | (errkind = 0 & afound = 0) | errkind != 0 then
      begin
      integer array msg[0:63];
      integer msglen;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "call command is missing path or args");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
   else
      begin
      integer array msgbuf[0:511];
      integer array bodybuf[0:8191];
      integer statuscode, kind, valoff, vallen, hasdata, dataoff, datalen, haslogs, logsoff, logslen, msglen;
      errbuflen := 0; errkind := 0;
      convexcall(opname, cfghost, cfghostlen, cfgport, cfgportlen, cfgtls, cfgauth, cfgauthlen,
         pathbuf, pathlen, line, argsoff, argslen, cxnowms + 10000,
         statuscode, kind, valoff, vallen, msgbuf, 512, msglen,
         hasdata, dataoff, datalen, haslogs, logsoff, logslen, bodybuf, 8192,
         errbuf, errbuflen, errkind);
      if errkind != 0 then
         emiterror(hasid, idbuf, idlen, errkind, errbuf, 0, errbuflen, 0, errbuf, 0, 0)
      else if kind = 1 then
         emiterror(hasid, idbuf, idlen, 1, msgbuf, 0, msglen, hasdata, bodybuf, dataoff, datalen)
      else
         emitresult(hasid, idbuf, idlen, bodybuf, valoff, vallen, haslogs, bodybuf, logsoff, logslen)
      end
end handlecall;

procedure handlesubscribe(line, linelen, hasid, idbuf, idlen);
   value linelen, hasid, idlen;
   integer array line, idbuf;
   integer linelen, hasid, idlen;
begin
   integer array subid[0:127];
   integer subidn, sidfound;
   integer array pathbuf[0:127];
   integer pathlen, pfound;
   integer argsoff, argslen, afound;
   integer array errbuf[0:255];
   integer errbuflen, errkind, discard;
   errbuflen := 0; errkind := 0;
   sidfound := decodefield(line, linelen, "subscriptionId", subid, 128, subidn);
   pfound := decodefield(line, linelen, "path", pathbuf, 128, pathlen);
   jsonfindfield(line, 0, linelen, "args", argsoff, argslen, afound, errbuf, errbuflen, errkind);
   if sidfound = 0 | pfound = 0 | (errkind = 0 & afound = 0) | errkind != 0 then
      begin
      integer array msg[0:63];
      integer msglen;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "subscribe command is missing a field");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
   else
      begin
      integer existing, sub;
      existing := findsubidslot(subid, subidn);
      if existing >= 0 then liveunsubscribe(existing, cxnowms + 5000);
      errbuflen := 0; errkind := 0;
      livesubscribe(cfghost, cfghostlen, cfgport, cfgportlen, cfgtls, pathbuf, pathlen,
         line, argsoff, argslen, cxnowms + 10000, sub, errbuf, errbuflen, errkind);
      if errkind != 0 then
         emiterror(hasid, idbuf, idlen, errkind, errbuf, 0, errbuflen, 0, errbuf, 0, 0)
      else
         begin
         integer i;
         subidlen[sub] := 0;
         for i := 0 step 1 until subidn - 1 do subidbuf[sub, i] := subid[i];
         subidlen[sub] := subidn;
         emitack(hasid, idbuf, idlen)
         end
      end
end handlesubscribe;

procedure handleunsubscribe(line, linelen, hasid, idbuf, idlen);
   value linelen, hasid, idlen;
   integer array line, idbuf;
   integer linelen, hasid, idlen;
begin
   integer array subid[0:127];
   integer subidn, sidfound, sub;
   if decodefield(line, linelen, "subscriptionId", subid, 128, subidn) = 0 then
      begin
      integer array msg[0:63];
      integer msglen, discard;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "unsubscribe command is missing subscriptionId");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
   else
      begin
      sub := findsubidslot(subid, subidn);
      if sub >= 0 then liveunsubscribe(sub, cxnowms + 5000);
      emitack(hasid, idbuf, idlen)
      end
end handleunsubscribe;

procedure handlesetauth(line, linelen, hasid, idbuf, idlen);
   value linelen, hasid, idlen;
   integer array line, idbuf;
   integer linelen, hasid, idlen;
begin
   integer tokenfound;
   tokenfound := decodefield(line, linelen, "token", cfgauth, 512, cfgauthlen);
   if tokenfound = 0 then cfgauthlen := 0;
   emitack(hasid, idbuf, idlen)
end handlesetauth;

procedure handledebugdisconnect(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   integer array errbuf[0:255];
   integer errbuflen, errkind, gen;
   errbuflen := 0; errkind := 0;
   gen := livedebugdisconnect(errbuf, errbuflen, errkind);
   if errkind != 0 then
      emiterror(hasid, idbuf, idlen, errkind, errbuf, 0, errbuflen, 0, errbuf, 0, 0)
   else
      emitack(hasid, idbuf, idlen)
end handledebugdisconnect;

procedure handleclose(hasid, idbuf, idlen);
   value hasid, idlen;
   integer array idbuf;
   integer hasid, idlen;
begin
   liveclose(cxnowms + 5000);
   adapterrunning := 0;
   emitclosed(hasid, idbuf, idlen)
end handleclose;

procedure handlecommand(line, linelen);
   value linelen;
   integer array line;
   integer linelen;
begin
   integer opoff, oplen, found, hasid;
   integer array idbuf[0:127];
   integer idlen;
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   errbuflen := 0; errkind := 0;
   hasid := decodefield(line, linelen, "id", idbuf, 128, idlen);
   jsonfindfield(line, 0, linelen, "op", opoff, oplen, found, errbuf, errbuflen, errkind);
   if errkind != 0 | found = 0 then
      begin
      integer array msg[0:63];
      integer msglen, discard;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "adapter command is missing op");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
   else if bufeqstr(line, opoff + 1, oplen - 2, "hello") then
      handlehello(line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "query") then
      handlecall("query", line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "mutation") then
      handlecall("mutation", line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "action") then
      handlecall("action", line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "subscribe") then
      handlesubscribe(line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "unsubscribe") then
      handleunsubscribe(line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "setAuth") then
      handlesetauth(line, linelen, hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "debugDisconnect") then
      handledebugdisconnect(hasid, idbuf, idlen)
   else if bufeqstr(line, opoff + 1, oplen - 2, "close") then
      handleclose(hasid, idbuf, idlen)
   else
      begin
      integer array msg[0:63];
      integer msglen, discard;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "unknown adapter operation");
      emiterror(hasid, idbuf, idlen, 2, msg, 0, msglen, 0, msg, 0, 0)
      end
end handlecommand;

comment ---------------------------------------------------------------
   Transport setup and the main loop.
   ------------------------------------------------------------------;

procedure adapterresolveconfig;
   comment reads CONVEX_URL, required. Diagnoses and exits with status
   1 if it is absent, matching every other native client in this
   project;
begin
   integer array namebuf[0:15];
   integer namelen, urllen, discard;
   integer array url[0:1023];
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "CONVEX_URL");
   urllen := cxgetenv(namebuf, namelen, url, 1024);
   if urllen < 0 then
      begin
      diag("CONVEX_URL is required");
      discard := cxexit(1)
      end
   else
      begin
      integer errbuflen, errkind;
      integer array errbuf[0:255];
      errbuflen := 0; errkind := 0;
      deploymentparse(url, urllen, cfgtls, cfghost, 256, cfghostlen, cfgport, 16, cfgportlen, errbuf, errbuflen,
         errkind);
      if errkind != 0 then
         begin
         diag("CONVEX_URL could not be parsed");
         discard := cxexit(1)
         end
      end
end adapterresolveconfig;

procedure adapterresolvetransport;
   comment listens on ADAPTER_LISTEN when set, accepting exactly one
   controller connection - otherwise adopts stdin and stdout;
begin
   integer array namebuf[0:31];
   integer namelen, listenlen, discard;
   integer array listenspec[0:127];
   integer colon, hostlen, portlen;
   integer array lhost[0:63];
   integer array lport[0:15];
   integer listener;
   namelen := 0;
   discard := bufputstr(namebuf, 32, namelen, "ADAPTER_LISTEN");
   listenlen := cxgetenv(namebuf, namelen, listenspec, 128);
   if listenlen > 0 then
      begin
      colon := bufindexof(listenspec, 0, listenlen, 58);
      if colon < 0 then
         begin
         diag("ADAPTER_LISTEN must be host:port");
         discard := cxexit(1)
         end
      else
         begin
         hostlen := 0;
         discard := bufputbytes(lhost, 64, hostlen, listenspec, 0, colon);
         portlen := 0;
         discard := bufputbytes(lport, 16, portlen, listenspec, colon + 1, listenlen - colon - 1);
         listener := cxlisten(lhost, hostlen, lport, portlen);
         if listener < 0 then
            begin
            diag("could not listen on ADAPTER_LISTEN");
            discard := cxexit(1)
            end
         else
            begin
            ctrlhandle := cxaccept(listener, 60000);
            if ctrlhandle < 0 then
               begin
               diag("no controller connected within the accept deadline");
               discard := cxexit(1)
               end
            else
               stdouthandle := ctrlhandle
            end
         end
      end
   else
      begin
      ctrlhandle := cxadopt(0);
      stdouthandle := cxadopt(1)
      end
end adapterresolvetransport;

comment ---------------------------------------------------------------
   Draining ready Live deliveries and turning them into subscription
   events. Runs once per main loop tick, across every active
   subscription, so no single subscription can starve another.
   ------------------------------------------------------------------;

procedure adapterdrainlive;
begin
   integer i, kind;
   for i := 0 step 1 until 3 do
      if subactive[i] != 0 then
         begin
         kind := livetakefor(i);
         if kind = 1 then
            begin
            integer array valuecopy[0:2047];
            integer valuelen;
            livetakencopyvalue(valuecopy, 2048, valuelen);
            emitsubscriptionvalue(i, valuecopy, 0, valuelen, 0, valuecopy, 0, 0);
            livereleasetaken
            end
         else if kind = 2 then
            begin
            integer array msgcopy[0:511];
            integer msglen, hasdata;
            integer array datacopy[0:1023];
            integer datalen;
            livetakencopymessage(msgcopy, 512, msglen);
            livetakencopydata(datacopy, 1024, datalen, hasdata);
            emitsubscriptionerror(i, livetakenerrkind, msgcopy, 0, msglen, hasdata, datacopy, 0, datalen);
            livereleasetaken
            end
         end
end adapterdrainlive;

comment ---------------------------------------------------------------
   Entry point.
   ------------------------------------------------------------------;

procedure adaptermain;
begin
   integer array marstversion[0:63];
   integer mvlen, gotline, dummy;
   integer array linebuf[0:65535];
   integer linelen;
   mvlen := 0;
   dummy := bufputstr(marstversion, 64, mvlen, "marst-2.7");
   runtimenamelen := 0;
   dummy := bufputbytes(runtimename, 64, runtimenamelen, marstversion, 0, mvlen);
   liveinit;
   cfgauthlen := 0;
   ctrlrlen := 0;
   ctrlroff := 0;
   adapterresolveconfig;
   adapterresolvetransport;
   stderrhandle := cxadopt(2);
   adapterrunning := 1;
   for dummy := 1 while adapterrunning != 0 do
      begin
      ctrlreadline(20, gotline, linebuf, 65536, linelen);
      if gotline != 0 & adapterrunning != 0 then
         handlecommand(linebuf, linelen);
      if adapterrunning != 0 then
         begin
         livepump(cxnowms + 20);
         adapterdrainlive
         end
      end
end adaptermain;
