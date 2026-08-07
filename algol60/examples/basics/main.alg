comment Convex from ALGOL 60: read a shared counter over HTTP, watch it
   over Live, and prove a mutation arrives on both. Against a fresh
   room the journey is 0 to 1.
   This file is the canonical example projected into the README and
   the website, so every step below is commented for a reader meeting
   Convex, and ALGOL 60, for the first time. It is assembled together
   with convex-native.alg, convex-buffer.alg, convex-json.alg,
   convex-http.alg, convex-ws.alg and convex-live.alg by the Docker
   build - see the Dockerfile for the exact command;

comment ---------------------------------------------------------------
   Reads count from a Convex demo record - {"count": N, ...} - and
   insists on a whole number. Convex may encode an integral count in
   decimal form, as 0 or as 0.0, and jsonparseint accepts both while
   rejecting a fractional, quoted or out of range value;
integer procedure examplecount(buf, off, limit, ok);
   value off, limit;
   integer array buf;
   integer off, limit, ok;
begin
   integer voff, vlen, found;
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   errbuflen := 0; errkind := 0;
   jsonfindfield(buf, off, limit, "count", voff, vlen, found, errbuf, errbuflen,
      errkind);
   if errkind != 0 | found = 0 then
      ok := 0
   else
      examplecount := jsonparseint(buf, voff, vlen, ok)
end examplecount;

comment prints a caption, a nonnegative integer, and a newline, built
   as bytes and written with cxwrite rather than with ALGOL 60's own
   outinteger, which pads every number with a trailing separator space
   that would break the byte-for-byte match this example's stdout
   owes the canonical transcript. Every printed line in this example
   goes through this one procedure or printplain below, so stdout is
   never a mix of buffered ALGOL 60 output and raw written bytes,
   which this client's own tests found can interleave unpredictably;
procedure printline(caption, num);
   value num;
   string caption;
   integer num;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, caption);
   discard := bufputint(line, 256, linelen, num);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printline;

comment prints one literal line with no number in it;
procedure printplain(text);
   string text;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, text);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestdout, line, 0, linelen)
end printplain;

comment writes a diagnostic to stderr, ALGOL 60's sigma channel, and
   exits with status 1. A missing value or a disagreement between
   HTTP and Live is a failed demonstration, not something to retry;
procedure givingup(msg);
   string msg;
begin
   integer array line[0:255];
   integer linelen, discard;
   linelen := 0;
   discard := bufputstr(line, 256, linelen, msg);
   discard := bufputbyte(line, 256, linelen, 10);
   discard := cxwrite(examplestderr, line, 0, linelen);
   discard := cxexit(1)
end givingup;

comment ---------------------------------------------------------------
   Example-wide state. One client, one deployment, exactly like every
   procedure in convex-http.alg and convex-live.alg expects to be
   handed explicitly, since ALGOL 60 has no way to share it silently.
   ------------------------------------------------------------------;

integer examplestderr;
integer examplestdout;
integer discard;
integer array examplehost[0:255];
integer examplehostlen;
integer array exampleport[0:15];
integer exampleportlen;
integer exampletls;
integer array exampleauth[0:1];
integer exampleroom;
integer array exampleroombuf[0:63];
integer exampleroomlen;

comment ---------------------------------------------------------------
   Building this example's arguments. Every Convex function below
   takes room, the shared counter's identity, so this is written once
   and reused for the query, the subscribe, and the mutation.
   ------------------------------------------------------------------;
procedure examplebuildargs(argsbuf, argscap, argslen, includemutationfields,
   runidbuf, runidlen);
   value argscap, includemutationfields, runidlen;
   integer array argsbuf, runidbuf;
   integer argscap, argslen, includemutationfields, runidlen;
begin
   integer discard;
   argslen := 0;
   discard := bufputbyte(argsbuf, argscap, argslen, 123);
   discard := bufputstr(argsbuf, argscap, argslen, "\"room\":");
   discard := jsonwritestring(argsbuf, argscap, argslen, exampleroombuf, 0,
      exampleroomlen);
   if includemutationfields != 0 then
      begin
      discard := bufputstr(argsbuf, argscap, argslen,
         ",\"language\":\"algol60\",\"runId\":");
      discard := jsonwritestring(argsbuf, argscap, argslen, runidbuf, 0,
         runidlen)
      end;
   discard := bufputbyte(argsbuf, argscap, argslen, 125)
end examplebuildargs;

comment ---------------------------------------------------------------
   The example itself.
   ------------------------------------------------------------------;

procedure examplerun;
begin
   integer array urlbuf[0:1023];
   integer urllen, discard;
   integer array namebuf[0:15];
   integer namelen;
   integer array errbuf[0:255];
   integer errbuflen, errkind;

   comment Configuration: every native client in this project reads
      its deployment from CONVEX_URL, and ALGOL 60 has no environment
      access of its own, so this is the one place the example calls
      the shim's cxgetenv rather than a pure ALGOL 60 procedure;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "CONVEX_URL");
   urllen := cxgetenv(namebuf, namelen, urlbuf, 1024);
   if urllen < 0 then givingup("CONVEX_URL is required");

   comment client creation: parse the deployment URL once into a host,
      a port and a scheme, exactly as convex-http.alg's HTTP calls and
      convex-live.alg's WebSocket connect both need them;
   errbuflen := 0; errkind := 0;
   deploymentparse(urlbuf, urllen, exampletls, examplehost, 256, examplehostlen,
      exampleport, 16, exampleportlen, errbuf, errbuflen, errkind);
   if errkind != 0 then givingup("CONVEX_URL could not be parsed");

   comment the verifier passes a unique room as this container's
      first argument, forwarded here as EXAMPLE_ROOM by the Docker
      image's entry script, and running the image by hand without one
      still works;
   namelen := 0;
   discard := bufputstr(namebuf, 16, namelen, "EXAMPLE_ROOM");
   exampleroomlen := cxgetenv(namebuf, namelen, exampleroombuf, 64);
   if exampleroomlen < 0 then
      begin
      exampleroomlen := 0;
      discard := bufputstr(exampleroombuf, 64, exampleroomlen,
         "algol60-example")
      end;

   liveinit;

   begin
      integer array pathbuf[0:31];
      integer pathlen;
      integer array argsbuf[0:511];
      integer argslen;
      integer array msgbuf[0:511];
      integer array bodybuf[0:8191];
      integer statuscode, kind, valoff, vallen, msglen;
      integer hasdata, dataoff, datalen, haslogs, logsoff, logslen;
      integer current, currentok;

      comment the HTTP query: ask Convex for the room's current state
         through its documented JSON HTTP endpoint, /api/query;
      pathlen := 0;
      discard := bufputstr(pathbuf, 32, pathlen, "demo:state");
      examplebuildargs(argsbuf, 512, argslen, 0, argsbuf, 0);
      errbuflen := 0; errkind := 0;
      convexcall("query", examplehost, examplehostlen, exampleport,
         exampleportlen, exampletls,
         exampleauth, 0, pathbuf, pathlen, argsbuf, 0, argslen, cxnowms + 10000,
         statuscode, kind, valoff, vallen, msgbuf, 512, msglen,
         hasdata, dataoff, datalen, haslogs, logsoff, logslen, bodybuf, 8192,
         errbuf, errbuflen, errkind);
      if errkind != 0 then givingup("the HTTP query failed");
      if kind = 1 then
         givingup("the HTTP query returned a Convex function error");

      comment decoding into an idiomatic value: Convex's JSON is
         parsed only as far as the one field this example promises;
      current := examplecount(bodybuf, valoff, valoff + vallen, currentok);
      if currentok = 0 then givingup("the HTTP query did not return a count");
      printline("current count: ", current);

      begin
         integer sub;

         comment starting Live before the mutation: subscribing first
            means no reactive update, including the one the mutation
            below is about to cause, can fall into the gap between
            reading and watching;
         examplebuildargs(argsbuf, 512, argslen, 0, argsbuf, 0);
         errbuflen := 0; errkind := 0;
         livesubscribe(examplehost, examplehostlen, exampleport, exampleportlen,
            exampletls,
            pathbuf, pathlen, argsbuf, 0, argslen, cxnowms + 10000, sub, errbuf,
               errbuflen, errkind);
         if errkind != 0 then givingup("the Live subscribe failed");

         begin
            integer initialkind, initial, initialok;
            integer array valuecopy[0:2047];
            integer valuelen;

            comment the initial Live value: the first delivery on a
               fresh subscription hydrates the same state the HTTP
               query above just read, over the WebSocket sync
               protocol rather than a second HTTP request;
            initialkind := livenext(sub, 10000);
            if initialkind = 0 then
               givingup("the initial Live value did not arrive "
                  "before the deadline");
            if initialkind = 2 then
               givingup("the initial Live value was a Convex "
                  "function error");
            valuelen := 0;
            livetakencopyvalue(valuecopy, 2048, valuelen);
            livereleasetaken;
            initial := examplecount(valuecopy, 0, valuelen, initialok);
            if initialok = 0 | initial != current then
               givingup("the initial Live count disagreed with HTTP");
            printline("live initial count: ", initial);

            begin
               integer array runid[0:31];
               integer runidlen;
               integer expected, appliedoff, appliedlen, afound, applied,
                  countoff, countlen, cfound, count, countok;
               integer array mutationpath[0:31];
               integer mutationpathlen;

               comment the mutation and its idempotency key: runId is
                  fresh random bytes on every run, and Convex uses it
                  to replay the earlier result rather than counting
                  twice if the same key ever arrived again;
               runidlen := 0;
               begin
                  integer array randbytes[0:15];
                  discard := cxrandom(randbytes, 16);
                  discard := hexencode(randbytes, 0, 16, runid, 32, runidlen)
               end;
               mutationpathlen := 0;
               discard := bufputstr(mutationpath, 32, mutationpathlen,
                  "demo:increment");
               examplebuildargs(argsbuf, 512, argslen, 1, runid, runidlen);
               errbuflen := 0; errkind := 0;
               convexcall("mutation", examplehost, examplehostlen, exampleport,
                  exampleportlen, exampletls,
                  exampleauth, 0, mutationpath, mutationpathlen, argsbuf, 0,
                     argslen, cxnowms + 10000,
                  statuscode, kind, valoff, vallen, msgbuf, 512, msglen,
                  hasdata, dataoff, datalen, haslogs, logsoff, logslen, bodybuf,
                     8192,
                  errbuf, errbuflen, errkind);
               if errkind != 0 then givingup("the mutation failed");
               if kind = 1 then
                  givingup("the mutation returned a Convex function error");
               expected := current + 1;
               jsonfindfield(bodybuf, valoff, valoff + vallen, "applied",
                  appliedoff, appliedlen, afound, errbuf, errbuflen, errkind);
               applied := if afound != 0 & bufeqstr(bodybuf, appliedoff,
                  appliedlen, "true") then 1 else 0;
               if applied = 0 then givingup("the mutation was not applied");
               jsonfindfield(bodybuf, valoff, valoff + vallen, "state",
                  countoff, countlen, cfound, errbuf, errbuflen, errkind);
               count := if cfound != 0 then examplecount(bodybuf, countoff,
                  countoff + countlen, countok) else 0;
               if cfound = 0 | countok = 0 | count != expected then
                  givingup("the mutation returned an unexpected count");
               comment printline always prints a trailing integer, and
                  this narration line has none, so it is written
                  directly with ALGOL 60's own outstring instead;
               printplain("mutation applied: true");
               printline("mutation count: ", count);

               begin
                  integer updatedkind, updated, updatedok;
                  integer array updatedcopy[0:2047];
                  integer updatedlen;

                  comment receiving the same change reactively: the
                     Live subscription delivers the mutation's result
                     with no second HTTP request at all;
                  updatedkind := livenext(sub, 10000);
                  if updatedkind = 0 then
                     givingup("the updated Live value did not arrive "
                        "before the deadline");
                  if updatedkind = 2 then
                     givingup("the updated Live value was a Convex "
                        "function error");
                  updatedlen := 0;
                  livetakencopyvalue(updatedcopy, 2048, updatedlen);
                  livereleasetaken;
                  updated := examplecount(updatedcopy, 0, updatedlen,
                     updatedok);
                  if updatedok = 0 | updated != expected then
                     givingup("the updated Live count disagreed "
                        "with the mutation");
                  printline("live updated count: ", updated);

                  comment only now, with the HTTP query, the initial
                     Live value, the mutation and the updated Live
                     value all agreeing, print the proof line;
                  begin
                     integer array line[0:255];
                     integer linelen, discard2;
                     linelen := 0;
                     discard2 := bufputstr(line, 256, linelen,
                        "verified count: ");
                     discard2 := bufputint(line, 256, linelen, current);
                     discard2 := bufputstr(line, 256, linelen, " -> ");
                     discard2 := bufputint(line, 256, linelen, updated);
                     discard2 := bufputbyte(line, 256, linelen, 10);
                     discard2 := cxwrite(examplestdout, line, 0, linelen)
                  end
               end
            end
         end;

         comment cleanup: unsubscribe and close use the client's own
            bounded deadlines rather than waiting on a peer that may
            never answer;
         liveunsubscribe(sub, cxnowms + 5000)
      end
   end;
   liveclose(cxnowms + 5000)
end examplerun;

examplestdout := cxadopt(1);
examplestderr := cxadopt(2);
examplerun;
discard := cxexit(0)
