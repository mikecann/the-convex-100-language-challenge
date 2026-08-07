comment convex-live.alg - Convex Live over the pinned sync profile, in
   ALGOL 60.
   Ownership: exactly one worker may touch the WebSocket, change the
   query-set version, or decide to reconnect. This client is single
   threaded by construction - ALGOL 60 has no concurrency primitives at
   all - so that worker is simply whichever procedure the caller is
   currently inside. The public API never blocks waiting for a server
   message on its own, and the caller drives livepump in a loop and
   reads the result afterward, exactly matching this project's other
   bounded, single-threaded native clients.
   State: since ALGOL 60 has no record or struct type, the subscription
   table and the delivery queue are each a bank of parallel arrays,
   indexed by slot number, with a fixed maximum size. Text fields that
   belong to one slot live in a two-dimensional array, one row per slot.
   Barriers: every delivery carries the subscription slot it belongs to
   and that subscription's epoch at the moment it was queued.
   Unsubscribing, or subscribing again with the same caller-visible id
   before the adapter has released the old slot, bumps the epoch and
   purges queued deliveries for that slot before the caller can observe
   the acknowledgement, so a value produced for a retired subscription
   can never be handed back. Retiring a connection bumps the manager
   generation and purges the whole queue, so nothing the old socket
   produced can survive either;

comment ---------------------------------------------------------------
   Bounds. Chosen deliberately and documented in the manifest rather
   than left implicit, matching this project's buffering policy for
   every other Live-capable client.
   ------------------------------------------------------------------;

integer procedure livemaxsubs; begin livemaxsubs := 4 end;
integer procedure livemaxdeliveries; begin livemaxdeliveries := 8 end;
integer procedure livedeliveryoverhead; begin livedeliveryoverhead := 256 end;
integer procedure livemaxdeliverybytes; begin livemaxdeliverybytes := 262144 end;
integer procedure livemaxsubbytes; begin livemaxsubbytes := 65536 end;
integer procedure liveinitialbackoff; begin liveinitialbackoff := 100 end;
integer procedure livemaxbackoff; begin livemaxbackoff := 8000 end;
integer procedure liveconnectbudget; begin liveconnectbudget := 8000 end;

comment ---------------------------------------------------------------
   Version timestamps: a uint64 in little-endian byte order, base 64
   encoded into exactly twelve characters with one padding character.
   Represented as its eight raw bytes, index 0 the least significant
   and index 7 the most significant, rather than as a real. An earlier
   version of this client held it as a non-negative real, reasoning
   that a real holds every integer exactly up to 2^53, a ceiling wrong
   for this field. A real Convex deployment's logical timestamp is
   nanosecond scale, routinely above 10^18, over two orders of
   magnitude past 2^53, so accumulating it into a real silently
   rounded the value, and the canonical-form check below then rejected
   every genuine timestamp as malformed - the exact defect that made
   the pilot's first Live delivery come back as a reported function
   error instead of the room's state. Kept as bytes, compared byte by
   byte through timestampcompare, the value is never rounded at all.
   ------------------------------------------------------------------;

procedure timestampencode(srcbytes, srcoff, buf, cap, len);
   comment appends the twelve character base 64 encoding of the eight
   bytes at srcbytes from srcoff to buf at len;
   value srcoff, cap;
   integer array srcbytes, buf;
   integer srcoff, cap, len;
begin
   integer discard;
   discard := b64encode(srcbytes, srcoff, 8, buf, cap, len)
end timestampencode;

procedure timestampdecode(buf, off, blen, outbytes, outoff, ok);
   comment decodes a canonical twelve character base 64 uint64 at buf
   from off for blen bytes into the eight bytes of outbytes starting
   at outoff. Sets ok to 1 on success, 0 if the text is not exactly
   twelve characters, does not end with the base 64 padding character,
   or does not re-encode to the same text - the same canonical-form
   check convex-live.fth uses;
   value off, blen, outoff;
   integer array buf, outbytes;
   integer off, blen, outoff, ok;
begin
   integer array bytes[0:7];
   integer array reencoded[0:15];
   integer bytelen, relen, i, discard;
   ok := 0;
   if blen = 12 & buf[off + 11] = 61 then
      begin
      bytelen := 0;
      discard := b64decode(buf, off, 4, bytes, 8, bytelen);
      if discard = 0 then discard := b64decode(buf, off + 4, 4, bytes, 8, bytelen);
      if discard = 0 then discard := b64decode(buf, off + 8, 4, bytes, 8, bytelen);
      if discard = 0 then
         begin
         relen := 0;
         timestampencode(bytes, 0, reencoded, 16, relen);
         if relen = blen then
            begin
            integer same, j;
            same := 1;
            for j := 0 step 1 until blen - 1 do
               if reencoded[j] != buf[off + j] then same := 0;
            if same = 1 then
               begin
               for i := 0 step 1 until 7 do outbytes[outoff + i] := bytes[i];
               ok := 1
               end
            end
         end
      end
end timestampdecode;

integer procedure timestampcompare(a, aoff, b, boff);
   comment compares two eight byte little-endian timestamps, most
   significant byte first, returning negative one, zero or one exactly
   as an ordinary numeric comparison of a against b would;
   value aoff, boff;
   integer array a, b;
   integer aoff, boff;
begin
   integer i, result, done;
   result := 0;
   done := 0;
   for i := 7 step -1 until 0 do
      if done = 0 then
         if a[aoff + i] != b[boff + i] then
            begin
            result := if a[aoff + i] < b[boff + i] then -1 else 1;
            done := 1
            end;
   timestampcompare := result
end timestampcompare;

procedure timestampzero(dst, dstoff);
   comment sets the eight bytes of dst starting at dstoff to zero;
   value dstoff;
   integer array dst;
   integer dstoff;
begin
   integer i;
   for i := 0 step 1 until 7 do dst[dstoff + i] := 0
end timestampzero;

procedure timestampcopy(dst, dstoff, src, srcoff);
   comment copies eight timestamp bytes from src at srcoff to dst at
   dstoff;
   value srcoff, dstoff;
   integer array dst, src;
   integer dstoff, srcoff;
begin
   integer i;
   for i := 0 step 1 until 7 do dst[dstoff + i] := src[srcoff + i]
end timestampcopy;

integer procedure liveuint32(buf, off, blen, ok);
   comment parses a JSON integer field that must fit a uint32, used for
   querySet and identity;
   value off, blen;
   integer array buf;
   integer off, blen, ok;
begin
   integer v;
   v := jsonparseint(buf, off, blen, ok);
   if ok = 1 & v < 0 then ok := 0;
   liveuint32 := v
end liveuint32;

comment ---------------------------------------------------------------
   The subscription table.
   ------------------------------------------------------------------;

integer array subactive[0:3];
integer array subqueryid[0:3];
integer array subpathbuf[0:3, 0:127];
integer array subpathlen[0:3];
integer array subargsbuf[0:3, 0:1023];
integer array subargslen[0:3];
integer array subcharge[0:3];
integer array subepoch[0:3];
integer array subhavelast[0:3];
integer array sublastbuf[0:3, 0:2047];
integer array sublastlen[0:3];

comment ---------------------------------------------------------------
   The bounded delivery queue.
   ------------------------------------------------------------------;

integer array dlused[0:7];
integer array dlseq[0:7];
integer array dlsub[0:7];
integer array dlepoch[0:7];
integer array dlgeneration[0:7];
integer array dlkind[0:7];
integer array dlvaluebuf[0:7, 0:2047];
integer array dlvaluelen[0:7];
integer array dlerrkind[0:7];
integer array dlmsgbuf[0:7, 0:511];
integer array dlmsglen[0:7];
integer array dldatabuf[0:7, 0:1023];
integer array dldatalen[0:7];
integer array dlhasdata[0:7];
integer array dllogsbuf[0:7, 0:1023];
integer array dllogslen[0:7];
integer array dlhaslogs[0:7];
integer array dlbytes[0:7];

comment ---------------------------------------------------------------
   Manager state - one client, one Live manager, matching every other
   file in this client, which passes state explicitly rather than
   relying on a record this language cannot express.
   ------------------------------------------------------------------;

integer livewshandle;
integer array liversbuf[0:8191];
integer liversrlen;
integer liversroff;
integer array livehostbuf[0:255];
integer livehostlen;
integer array liveportbuf[0:15];
integer liveportlen;
integer livetls;
integer array livesessionbuf[0:31];
integer livesessionlen;
integer liveconnectioncount;
integer array liveclosereasonbuf[0:63];
integer liveclosereasonlen;
integer livequerysetversion;
integer liveremotequeryset;
integer liveremoteidentity;
integer array liveremotetsbytes[0:7];
integer array livemaxtsbytes[0:7];
integer livehavemaxts;
integer livegeneration;
integer livebackoff;
integer livenextconnect;
integer livenextqueryid;
integer livesubbytes;
integer livequeuecount;
integer livequeuebytes;
integer liveseq;
integer liveclosed;
integer livedrops;
integer array livesendbuf[0:4095];
integer liveoutlen;

procedure liveinit;
   comment initialises every table and manager field. Called once
   before the manager is used;
begin
   integer i, discard;
   for i := 0 step 1 until 3 do
      begin
      subactive[i] := 0;
      subqueryid[i] := 0;
      subpathlen[i] := 0;
      subargslen[i] := 0;
      subcharge[i] := 0;
      subepoch[i] := 0;
      subhavelast[i] := 0;
      sublastlen[i] := 0
      end;
   for i := 0 step 1 until 7 do
      begin
      dlused[i] := 0;
      dlseq[i] := 0;
      dlsub[i] := -1;
      dlepoch[i] := 0;
      dlgeneration[i] := 0;
      dlkind[i] := 0;
      dlvaluelen[i] := 0;
      dlerrkind[i] := 0;
      dlmsglen[i] := 0;
      dldatalen[i] := 0;
      dlhasdata[i] := 0;
      dllogslen[i] := 0;
      dlhaslogs[i] := 0;
      dlbytes[i] := 0
      end;
   livewshandle := -1;
   liversrlen := 0;
   liversroff := 0;
   livesessionlen := 0;
   discard := hexencode(liversbuf, 0, 0, livesessionbuf, 32, livesessionlen);
   begin
      integer array randbytes[0:15];
      discard := cxrandom(randbytes, 16);
      livesessionlen := 0;
      discard := hexencode(randbytes, 0, 16, livesessionbuf, 32, livesessionlen)
   end;
   liveconnectioncount := 0;
   liveclosereasonlen := 0;
   discard := bufputstr(liveclosereasonbuf, 64, liveclosereasonlen, "InitialConnect");
   livequerysetversion := 0;
   liveremotequeryset := 0;
   liveremoteidentity := 0;
   timestampzero(liveremotetsbytes, 0);
   timestampzero(livemaxtsbytes, 0);
   livehavemaxts := 0;
   livegeneration := 0;
   livebackoff := liveinitialbackoff;
   livenextconnect := 0;
   livenextqueryid := 0;
   livesubbytes := 0;
   livequeuecount := 0;
   livequeuebytes := 0;
   liveseq := 0;
   liveclosed := 0;
   livedrops := 0
end liveinit;

comment ---------------------------------------------------------------
   The bounded delivery queue - make room, commit, release, find.
   ------------------------------------------------------------------;

integer procedure deliverycharge(index);
   value index;
   integer index;
begin
   deliverycharge := dlvaluelen[index] + dlmsglen[index]
      + dldatalen[index] + dllogslen[index] + livedeliveryoverhead
end deliverycharge;

procedure deliveryrelease(index);
   value index;
   integer index;
begin
   if dlused[index] != 0 then
      begin
      dlused[index] := 0;
      livequeuebytes := livequeuebytes - dlbytes[index];
      livequeuecount := livequeuecount - 1
      end
end deliveryrelease;

integer procedure deliveryoldest;
   comment the slot with the smallest sequence number among used
   slots, or negative one when the queue is empty;
begin
   integer i, best, bestseq;
   best := -1;
   bestseq := 0;
   for i := 0 step 1 until 7 do
      if dlused[i] != 0 then
         if best < 0 | dlseq[i] < bestseq then
            begin best := i; bestseq := dlseq[i] end;
   deliveryoldest := best
end deliveryoldest;

integer procedure deliveryoldestfor(sub);
   value sub;
   integer sub;
begin
   integer i, best, bestseq;
   best := -1;
   bestseq := 0;
   for i := 0 step 1 until 7 do
      if dlused[i] != 0 & dlsub[i] = sub then
         if best < 0 | dlseq[i] < bestseq then
            begin best := i; bestseq := dlseq[i] end;
   deliveryoldestfor := best
end deliveryoldestfor;

integer procedure deliveryfreeslot;
begin
   integer i, found;
   found := -1;
   for i := 0 step 1 until 7 do
      if dlused[i] = 0 & found < 0 then found := i;
   deliveryfreeslot := found
end deliveryfreeslot;

comment makes room for one more delivery of the given charge, dropping
   the oldest queued delivery when the count or byte budget would
   otherwise be exceeded. A stopped consumer therefore costs bounded
   memory rather than unbounded growth, and every drop is counted;
procedure deliverymakeroom(charge);
   value charge;
   integer charge;
begin
   integer oldest, dummy, done;
   done := 0;
   for dummy := 1 while done = 0 do
      begin
      if livequeuecount < livemaxdeliveries & livequeuebytes + charge <= livemaxdeliverybytes then
         done := 1
      else if livequeuecount = 0 then
         done := 1
      else
         begin
         oldest := deliveryoldest;
         if oldest < 0 then done := 1
         else
            begin
            deliveryrelease(oldest);
            livedrops := livedrops + 1
            end
         end
      end
end deliverymakeroom;

procedure deliverycommit(index, charge);
   value index, charge;
   integer index, charge;
begin
   dlused[index] := 1;
   dlbytes[index] := charge;
   liveseq := liveseq + 1;
   dlseq[index] := liveseq;
   livequeuebytes := livequeuebytes + charge;
   livequeuecount := livequeuecount + 1
end deliverycommit;

procedure livestamp(index, sub);
   value index, sub;
   integer index, sub;
begin
   dlsub[index] := sub;
   dlepoch[index] := subepoch[sub];
   dlgeneration[index] := livegeneration
end livestamp;

comment publishes one value for sub, suppressing an unchanged
   rehydration so a reconnect that resends the same value does not
   turn one logical update into two;
procedure livepublishvalue(sub, valbuf, valoff, vallen);
   value sub, valoff, vallen;
   integer array valbuf;
   integer sub, valoff, vallen;
begin
   integer index, charge, unchanged, i, discard;
   unchanged := 0;
   if subhavelast[sub] != 0 & sublastlen[sub] = vallen then
      begin
      unchanged := 1;
      for i := 0 step 1 until vallen - 1 do
         if sublastbuf[sub, i] != valbuf[valoff + i] then unchanged := 0
      end;
   if unchanged = 0 then
      begin
      sublastlen[sub] := 0;
      for i := 0 step 1 until vallen - 1 do sublastbuf[sub, i] := valbuf[valoff + i];
      sublastlen[sub] := vallen;
      subhavelast[sub] := 1;
      charge := vallen + livedeliveryoverhead;
      deliverymakeroom(charge);
      index := deliveryfreeslot;
      if index >= 0 then
         begin
         dlkind[index] := 1;
         dlvaluelen[index] := 0;
         for i := 0 step 1 until vallen - 1 do dlvaluebuf[index, i] := valbuf[valoff + i];
         dlvaluelen[index] := vallen;
         dlmsglen[index] := 0;
         dlhasdata[index] := 0;
         dlhaslogs[index] := 0;
         livestamp(index, sub);
         deliverycommit(index, charge)
         end
      end
end livepublishvalue;

integer procedure livepublisherror(sub, errkindcode, msgbuf, msgoff, msglen);
   comment errkindcode is 1 for FunctionError, 2 for ProtocolError, or
   3 for TransportError - the adapter maps this back to the literal
   name string it emits, since a two-dimensional array cannot itself be
   sliced into the one-dimensional array a text-buffer procedure
   expects;
   value sub, errkindcode, msgoff, msglen;
   integer array msgbuf;
   integer sub, errkindcode, msgoff, msglen;
begin
   integer index, charge, i;
   subhavelast[sub] := 0;
   charge := msglen + 64 + livedeliveryoverhead;
   deliverymakeroom(charge);
   index := deliveryfreeslot;
   if index < 0 then livepublisherror := -1
   else
      begin
      dlkind[index] := 2;
      dlvaluelen[index] := 0;
      dlerrkind[index] := errkindcode;
      dlmsglen[index] := 0;
      for i := 0 step 1 until msglen - 1 do dlmsgbuf[index, i] := msgbuf[msgoff + i];
      dlmsglen[index] := msglen;
      dldatalen[index] := 0;
      dlhasdata[index] := 0;
      dllogslen[index] := 0;
      dlhaslogs[index] := 0;
      livestamp(index, sub);
      deliverycommit(index, charge);
      livepublisherror := index
      end
end livepublisherror;

comment ---------------------------------------------------------------
   Purging - unsubscribe and connection retirement both need to clear
   queued deliveries without losing the suppression memory in a way
   that would hide a real rehydration after reconnect.
   ------------------------------------------------------------------;

procedure livepurgesubscription(sub);
   value sub;
   integer sub;
begin
   integer i;
   for i := 0 step 1 until 7 do
      if dlused[i] != 0 & dlsub[i] = sub then deliveryrelease(i)
end livepurgesubscription;

comment dropping an unconsumed value must also forget it was
   published, otherwise the rehydration that follows a reconnect would
   be suppressed as unchanged and the caller would never see it at
   all;
procedure livepurgeall;
begin
   integer i, sub;
   for i := 0 step 1 until 7 do
      begin
      if dlused[i] != 0 then
         begin
         sub := dlsub[i];
         if sub >= 0 & dlkind[i] = 1 then subhavelast[sub] := 0
         end;
      deliveryrelease(i)
      end;
   livequeuecount := 0;
   livequeuebytes := 0
end livepurgeall;

procedure livepublishtoall(errkindcode, msgbuf, msgoff, msglen);
   value errkindcode, msgoff, msglen;
   integer array msgbuf;
   integer errkindcode, msgoff, msglen;
begin
   integer i, discard;
   for i := 0 step 1 until 3 do
      if subactive[i] != 0 then
         discard := livepublisherror(i, errkindcode, msgbuf, msgoff, msglen)
end livepublishtoall;

comment ---------------------------------------------------------------
   Outgoing sync messages.
   ------------------------------------------------------------------;

procedure livesend(deadlinems, errbuf, errbuflen, errkind);
   value deadlinems;
   integer array errbuf;
   integer deadlinems, errbuflen, errkind;
begin
   integer discard;
   if livewshandle < 0 then
      begin
      errbuflen := 0;
      errkind := 3;
      discard := bufputstr(errbuf, 256, errbuflen, "Live WebSocket is not connected")
      end
   else
      wssendtext(livewshandle, livesendbuf, 0, liveoutlen, deadlinems, errbuf, errbuflen, errkind)
end livesend;

procedure livewritemodification(sub, isadd);
   value sub, isadd;
   integer sub, isadd;
begin
   integer discard, i;
   discard := bufputbyte(livesendbuf, 4096, liveoutlen, 123);
   if isadd != 0 then
      begin
      discard := bufputstr(livesendbuf, 4096, liveoutlen, "\"type\":\"Add\",\"queryId\":");
      discard := bufputint(livesendbuf, 4096, liveoutlen, subqueryid[sub]);
      discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"udfPath\":");
      begin
         integer array pathcopy[0:127];
         integer pathcopylen, j;
         pathcopylen := 0;
         for j := 0 step 1 until subpathlen[sub] - 1 do pathcopy[j] := subpathbuf[sub, j];
         discard := jsonwritestring(livesendbuf, 4096, liveoutlen, pathcopy, 0, subpathlen[sub])
      end;
      discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"args\":[");
      begin
         integer k;
         for k := 0 step 1 until subargslen[sub] - 1 do
            discard := bufputbyte(livesendbuf, 4096, liveoutlen, subargsbuf[sub, k])
      end;
      discard := bufputbyte(livesendbuf, 4096, liveoutlen, 93)
      end
   else
      begin
      discard := bufputstr(livesendbuf, 4096, liveoutlen, "\"type\":\"Remove\",\"queryId\":");
      discard := bufputint(livesendbuf, 4096, liveoutlen, subqueryid[sub])
      end;
   discard := bufputbyte(livesendbuf, 4096, liveoutlen, 125)
end livewritemodification;

procedure livesendconnect(deadlinems, errbuf, errbuflen, errkind);
   value deadlinems;
   integer array errbuf;
   integer deadlinems, errbuflen, errkind;
begin
   integer discard;
   liveoutlen := 0;
   discard := bufputstr(livesendbuf, 4096, liveoutlen, "{\"type\":\"Connect\",\"sessionId\":");
   begin
      integer array sidcopy[0:31];
      integer j;
      for j := 0 step 1 until livesessionlen - 1 do sidcopy[j] := livesessionbuf[j];
      discard := jsonwritestring(livesendbuf, 4096, liveoutlen, sidcopy, 0, livesessionlen)
   end;
   discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"connectionCount\":");
   discard := bufputint(livesendbuf, 4096, liveoutlen, liveconnectioncount);
   discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"lastCloseReason\":");
   begin
      integer array reasoncopy[0:63];
      integer j;
      for j := 0 step 1 until liveclosereasonlen - 1 do reasoncopy[j] := liveclosereasonbuf[j];
      discard := jsonwritestring(livesendbuf, 4096, liveoutlen, reasoncopy, 0, liveclosereasonlen)
   end;
   discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"clientTs\":0");
   if livehavemaxts != 0 then
      begin
      integer array tsbuf[0:15];
      integer tslen;
      tslen := 0;
      timestampencode(livemaxtsbytes, 0, tsbuf, 16, tslen);
      discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"maxObservedTimestamp\":\"");
      discard := bufputbytes(livesendbuf, 4096, liveoutlen, tsbuf, 0, tslen);
      discard := bufputbyte(livesendbuf, 4096, liveoutlen, 34)
      end;
   discard := bufputbyte(livesendbuf, 4096, liveoutlen, 125);
   livesend(deadlinems, errbuf, errbuflen, errkind)
end livesendconnect;

comment resends every active subscription's Add on a fresh connection,
   which is what makes reconnect evidence meaningful;
procedure livesendfullqueryset(deadlinems, errbuf, errbuflen, errkind);
   value deadlinems;
   integer array errbuf;
   integer deadlinems, errbuflen, errkind;
begin
   integer any, i, discard;
   any := 0;
   for i := 0 step 1 until 3 do if subactive[i] != 0 then any := 1;
   if any = 0 then
      livequerysetversion := 0
   else
      begin
      liveoutlen := 0;
      discard := bufputstr(livesendbuf, 4096, liveoutlen,
         "{\"type\":\"ModifyQuerySet\",\"baseVersion\":0,\"newVersion\":1,\"modifications\":[");
      begin
         integer first, i2;
         first := 1;
         for i2 := 0 step 1 until 3 do
            if subactive[i2] != 0 then
               begin
               if first = 0 then discard := bufputbyte(livesendbuf, 4096, liveoutlen, 44);
               livewritemodification(i2, 1);
               first := 0
               end
      end;
      discard := bufputstr(livesendbuf, 4096, liveoutlen, "]}");
      livesend(deadlinems, errbuf, errbuflen, errkind);
      if errkind = 0 then livequerysetversion := 1
      end
end livesendfullqueryset;

procedure livesendmodification(sub, isadd, deadlinems, errbuf, errbuflen, errkind);
   value sub, isadd, deadlinems;
   integer array errbuf;
   integer sub, isadd, deadlinems, errbuflen, errkind;
begin
   integer version, discard;
   version := livequerysetversion;
   liveoutlen := 0;
   discard := bufputstr(livesendbuf, 4096, liveoutlen, "{\"type\":\"ModifyQuerySet\",\"baseVersion\":");
   discard := bufputint(livesendbuf, 4096, liveoutlen, version);
   discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"newVersion\":");
   discard := bufputint(livesendbuf, 4096, liveoutlen, version + 1);
   discard := bufputstr(livesendbuf, 4096, liveoutlen, ",\"modifications\":[");
   livewritemodification(sub, isadd);
   discard := bufputstr(livesendbuf, 4096, liveoutlen, "]}");
   livesend(deadlinems, errbuf, errbuflen, errkind);
   if errkind = 0 then livequerysetversion := version + 1
end livesendmodification;

comment ---------------------------------------------------------------
   Retiring a connection. The generation moves first, so anything the
   old connection queued is already stale by the time a caller can
   observe the failure, and no later acknowledgement can be crossed by
   an old event.
   ------------------------------------------------------------------;

procedure liveretire(reasonbuf, reasonoff, reasonlen);
   comment the core retirement step. reasonbuf holds the close reason
   as bytes rather than a string literal, because a transport failure's
   reason is discovered at run time, not fixed at compile time;
   value reasonoff, reasonlen;
   integer array reasonbuf;
   integer reasonoff, reasonlen;
begin
   integer discard;
   livegeneration := livegeneration + 1;
   if livewshandle >= 0 then
      begin
      discard := cxclose(livewshandle);
      livewshandle := -1
      end;
   liveclosereasonlen := 0;
   discard := bufputbytes(liveclosereasonbuf, 64, liveclosereasonlen, reasonbuf, reasonoff, reasonlen);
   livequerysetversion := 0;
   liveremotequeryset := 0;
   liveremoteidentity := 0;
   timestampzero(liveremotetsbytes, 0)
end liveretire;

procedure liveretireliteral(reasonstr);
   comment retires the connection with a fixed, compile-time reason;
   string reasonstr;
begin
   integer array scratch[0:63];
   integer scratchlen, discard;
   scratchlen := 0;
   discard := bufputstr(scratch, 64, scratchlen, reasonstr);
   liveretire(scratch, 0, scratchlen)
end liveretireliteral;

procedure liveschedulereconnect;
begin
   integer backoff;
   backoff := livebackoff;
   livenextconnect := cxnowms + backoff;
   livebackoff := if backoff * 2 > livemaxbackoff then livemaxbackoff else backoff * 2
end liveschedulereconnect;

comment ---------------------------------------------------------------
   Incoming sync messages.
   ------------------------------------------------------------------;

integer procedure livefindquery(queryid);
   value queryid;
   integer queryid;
begin
   integer i, found;
   found := -1;
   for i := 0 step 1 until 3 do
      if subactive[i] != 0 & subqueryid[i] = queryid & found < 0 then found := i;
   livefindquery := found
end livefindquery;

procedure livecheckstartversion(msgbuf, startoff, startlen, errbuf, errbuflen, errkind);
   value startoff, startlen;
   integer array msgbuf, errbuf;
   integer startoff, startlen, errbuflen, errkind;
begin
   integer qsoff, qslen, idoff, idlen, tsoff, tslen, f1, f2, f3;
   integer newqs, newid, ok1, ok2, endok, mismatch;
   integer array startts[0:7];
   jsonfindfield(msgbuf, startoff, startoff + startlen, "querySet", qsoff, qslen, f1, errbuf, errbuflen, errkind);
   if errkind = 0 then
      jsonfindfield(msgbuf, startoff, startoff + startlen, "identity", idoff, idlen, f2, errbuf, errbuflen, errkind);
   if errkind = 0 then
      jsonfindfield(msgbuf, startoff, startoff + startlen, "ts", tsoff, tslen, f3, errbuf, errbuflen, errkind);
   if errkind = 0 & (f1 = 0 | f2 = 0 | f3 = 0) then
      begin
      integer discard;
      errbuflen := 0; errkind := 2;
      discard := bufputstr(errbuf, 256, errbuflen, "Live state version is missing a field")
      end;
   if errkind = 0 then
      begin
      newqs := liveuint32(msgbuf, qsoff, qslen, ok1);
      newid := liveuint32(msgbuf, idoff, idlen, ok2);
      timestampdecode(msgbuf, tsoff + 1, tslen - 2, startts, 0, endok);
      if ok1 = 0 | ok2 = 0 | endok = 0 then
         begin
         integer discard;
         errbuflen := 0; errkind := 2;
         discard := bufputstr(errbuf, 256, errbuflen, "Live state version field is invalid")
         end
      else
         begin
         mismatch := if newqs != liveremotequeryset then 1 else 0;
         if newid != liveremoteidentity then mismatch := 1;
         if timestampcompare(startts, 0, liveremotetsbytes, 0) != 0 then mismatch := 1;
         if mismatch != 0 then
            begin
            integer discard;
            errbuflen := 0; errkind := 2;
            discard := bufputstr(errbuf, 256, errbuflen, "Live transition start version did not match local state")
            end
         end
      end
end livecheckstartversion;

procedure livehandletransition(msgbuf, msglen, errbuf, errbuflen, errkind);
   value msglen;
   integer array msgbuf, errbuf;
   integer msglen, errbuflen, errkind;
begin
   integer startoff, startlen, endoff, endlen, modsoff, modslen, f1, f2, f3;
   integer array pendingkind[0:3];
   integer array pendingvaloff[0:3];
   integer array pendingvallen[0:3];
   integer array pendingmsgoff[0:3];
   integer array pendingmsglen[0:3];
   integer array pendingdataoff[0:3];
   integer array pendingdatalen[0:3];
   integer array pendinghasdata[0:3];
   integer i, newqs, newid, ok1, ok2, endok, discard;
   integer array endts[0:7];
   for i := 0 step 1 until 3 do pendingkind[i] := 0;
   jsonfindfield(msgbuf, 0, msglen, "startVersion", startoff, startlen, f1, errbuf, errbuflen, errkind);
   if errkind = 0 then
      jsonfindfield(msgbuf, 0, msglen, "endVersion", endoff, endlen, f2, errbuf, errbuflen, errkind);
   if errkind = 0 then
      jsonfindfield(msgbuf, 0, msglen, "modifications", modsoff, modslen, f3, errbuf, errbuflen, errkind);
   if errkind = 0 & (f1 = 0 | f2 = 0 | f3 = 0) then
      begin
      errbuflen := 0; errkind := 2;
      discard := bufputstr(errbuf, 256, errbuflen, "Live transition is missing a field")
      end;
   if errkind = 0 then
      livecheckstartversion(msgbuf, startoff, startlen, errbuf, errbuflen, errkind);
   if errkind = 0 then
      begin
      integer qsoff, qslen, idoff, idlen, tsoff, tslen, g1, g2, g3;
      jsonfindfield(msgbuf, endoff, endoff + endlen, "querySet", qsoff, qslen, g1, errbuf, errbuflen, errkind);
      if errkind = 0 then
         jsonfindfield(msgbuf, endoff, endoff + endlen, "identity", idoff, idlen, g2, errbuf, errbuflen, errkind);
      if errkind = 0 then
         jsonfindfield(msgbuf, endoff, endoff + endlen, "ts", tsoff, tslen, g3, errbuf, errbuflen, errkind);
      if errkind = 0 & (g1 = 0 | g2 = 0 | g3 = 0) then
         begin
         errbuflen := 0; errkind := 2;
         discard := bufputstr(errbuf, 256, errbuflen, "Live end version is missing a field")
         end;
      if errkind = 0 then
         begin
         newqs := liveuint32(msgbuf, qsoff, qslen, ok1);
         newid := liveuint32(msgbuf, idoff, idlen, ok2);
         timestampdecode(msgbuf, tsoff + 1, tslen - 2, endts, 0, endok);
         if ok1 = 0 | ok2 = 0 | endok = 0 then
            begin
            errbuflen := 0; errkind := 2;
            discard := bufputstr(errbuf, 256, errbuflen, "Live end version field is invalid")
            end
         else if timestampcompare(endts, 0, liveremotetsbytes, 0) < 0 then
            begin
            errbuflen := 0; errkind := 2;
            discard := bufputstr(errbuf, 256, errbuflen, "Live timestamp moved backwards")
            end
         end
      end;
   if errkind = 0 then
      begin
      integer idx, elemoff, elemlen, hasmore, dummy;
      idx := 0;
      hasmore := 1;
      for dummy := 1 while hasmore != 0 & errkind = 0 do
         begin
         jsonarrayelementat(msgbuf, modsoff, modsoff + modslen, idx, elemoff, elemlen, hasmore, errbuf, errbuflen,
            errkind);
         if errkind = 0 & hasmore != 0 then
            begin
            integer typeoff, typelen, qidoff, qidlen, tf, qf, queryid, qok, sub;
            jsonfindfield(msgbuf, elemoff, elemoff + elemlen, "type", typeoff, typelen, tf, errbuf, errbuflen, errkind);
            if errkind = 0 then
               jsonfindfield(msgbuf, elemoff, elemoff + elemlen, "queryId", qidoff, qidlen, qf, errbuf, errbuflen,
                  errkind);
            if errkind = 0 & (tf = 0 | qf = 0) then
               begin
               errbuflen := 0; errkind := 2;
               discard := bufputstr(errbuf, 256, errbuflen, "Live modification is missing a field")
               end;
            if errkind = 0 then
               begin
               queryid := liveuint32(msgbuf, qidoff, qidlen, qok);
               if qok = 0 then
                  begin
                  errbuflen := 0; errkind := 2;
                  discard := bufputstr(errbuf, 256, errbuflen, "Live modification queryId is invalid")
                  end
               else
                  begin
                  sub := livefindquery(queryid);
                  if sub >= 0 then
                     begin
                     if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "QueryUpdated") then
                        begin
                        integer valoff, vallen, vf;
                        jsonfindfield(msgbuf, elemoff, elemoff + elemlen, "value", valoff, vallen, vf, errbuf,
                           errbuflen, errkind);
                        if errkind = 0 & vf = 0 then
                           begin
                           errbuflen := 0; errkind := 2;
                           discard := bufputstr(errbuf, 256, errbuflen, "QueryUpdated is missing value")
                           end
                        else if errkind = 0 then
                           begin
                           pendingkind[sub] := 1;
                           pendingvaloff[sub] := valoff;
                           pendingvallen[sub] := vallen
                           end
                        end
                     else if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "QueryFailed") then
                        begin
                        integer msgoff2, msglen2, mf, dataoff2, datalen2, dfound;
                        jsonfindfield(msgbuf, elemoff, elemoff + elemlen, "errorMessage", msgoff2, msglen2, mf, errbuf,
                           errbuflen, errkind);
                        if errkind = 0 & mf = 0 then
                           begin
                           errbuflen := 0; errkind := 2;
                           discard := bufputstr(errbuf, 256, errbuflen, "QueryFailed is missing errorMessage")
                           end
                        else if errkind = 0 then
                           begin
                           pendingkind[sub] := 2;
                           pendingmsgoff[sub] := msgoff2;
                           pendingmsglen[sub] := msglen2;
                           jsonfindfield(msgbuf, elemoff, elemoff + elemlen, "errorData", dataoff2, datalen2, dfound,
                              errbuf, errbuflen, errkind);
                           pendinghasdata[sub] := if errkind = 0 then dfound else 0;
                           pendingdataoff[sub] := dataoff2;
                           pendingdatalen[sub] := datalen2
                           end
                        end
                     else if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "QueryRemoved") then
                        pendingkind[sub] := 0
                     else
                        begin
                        errbuflen := 0; errkind := 2;
                        discard := bufputstr(errbuf, 256, errbuflen, "unsupported Live modification")
                        end
                     end
                  end
               end;
            idx := idx + 1
            end
         end
      end;
   if errkind = 0 then
      begin
      liveremotequeryset := newqs;
      liveremoteidentity := newid;
      timestampcopy(liveremotetsbytes, 0, endts, 0);
      if livehavemaxts = 0 | timestampcompare(endts, 0, livemaxtsbytes, 0) > 0 then
         begin
         timestampcopy(livemaxtsbytes, 0, endts, 0);
         livehavemaxts := 1
         end;
      for i := 0 step 1 until 3 do
         begin
         if pendingkind[i] = 1 then
            livepublishvalue(i, msgbuf, pendingvaloff[i], pendingvallen[i]);
         if pendingkind[i] = 2 then
            begin
            integer array decodedmsg[0:511];
            integer decodedlen, dwr, index2, k;
            decodedlen := 0;
            dwr := jsonstringcontent(msgbuf, pendingmsgoff[i], pendingmsgoff[i] + pendingmsglen[i], decodedmsg, 512,
               decodedlen);
            index2 := livepublisherror(i, 1, decodedmsg, 0, decodedlen);
            if index2 >= 0 & pendinghasdata[i] != 0 then
               begin
               integer copylen;
               copylen := pendingdatalen[i];
               if copylen > 1024 then copylen := 1024;
               for k := 0 step 1 until copylen - 1 do
                  dldatabuf[index2, k] := msgbuf[pendingdataoff[i] + k];
               dldatalen[index2] := copylen;
               dlhasdata[index2] := 1
               end
            end
         end;
      livebackoff := liveinitialbackoff;
      livenextconnect := 0
      end
end livehandletransition;

procedure livehandlemessage(msgbuf, msglen, errbuf, errbuflen, errkind);
   value msglen;
   integer array msgbuf, errbuf;
   integer msglen, errbuflen, errkind;
begin
   integer typeoff, typelen, found, discard;
   if msglen > wsmaxmessage then
      begin
      errbuflen := 0; errkind := 2;
      discard := bufputstr(errbuf, 256, errbuflen, "Live message exceeds the message limit")
      end
   else
      begin
      jsonfindfield(msgbuf, 0, msglen, "type", typeoff, typelen, found, errbuf, errbuflen, errkind);
      if errkind = 0 & found = 0 then
         begin
         errbuflen := 0; errkind := 2;
         discard := bufputstr(errbuf, 256, errbuflen, "Live message type is missing")
         end
      else if errkind = 0 then
         begin
         if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "Transition") then
            livehandletransition(msgbuf, msglen, errbuf, errbuflen, errkind)
         else if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "Ping") then
            errkind := 0
         else if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "MutationResponse") then
            errkind := 0
         else if bufeqstr(msgbuf, typeoff + 1, typelen - 2, "ActionResponse") then
            errkind := 0
         else
            begin
            errbuflen := 0; errkind := 2;
            discard := bufputstr(errbuf, 256, errbuflen, "unsupported Live server message")
            end
         end
      end
end livehandlemessage;

comment ---------------------------------------------------------------
   The owner loop.
   ------------------------------------------------------------------;

procedure liveconnectnow(errbuf, errbuflen, errkind);
   comment opens the transport, performs the WebSocket handshake to
   the pinned sync endpoint, and sends Connect followed by a full
   resend of every active subscription. Gets its own full connect
   budget rather than the caller's remaining slice, because a real TCP
   connect plus TLS handshake routinely needs more than one short poll
   slice, even though steady-state servicing is polled in small steps;
   integer array errbuf;
   integer errbuflen, errkind;
begin
   integer array syncpath[0:15];
   integer syncpathlen, connectdeadline, discard;
   connectdeadline := cxnowms + liveconnectbudget;
   syncpathlen := 0;
   discard := bufputstr(syncpath, 16, syncpathlen, "/api/sync");
   livewshandle := cxopen(livehostbuf, livehostlen, liveportbuf, liveportlen, livetls, connectdeadline);
   if livewshandle < 0 then
      begin
      errbuflen := 0; errkind := 3;
      discard := bufputstr(errbuf, 256, errbuflen, "could not connect to the Convex deployment")
      end
   else
      begin
      liversrlen := 0;
      liversroff := 0;
      wshandshake(livewshandle, livehostbuf, livehostlen, liveportbuf, liveportlen, syncpath, syncpathlen,
         liversbuf, 8192, liversrlen, liversroff, connectdeadline, errbuf, errbuflen, errkind);
      if errkind = 0 then
         livesendconnect(connectdeadline, errbuf, errbuflen, errkind);
      if errkind = 0 then
         livesendfullqueryset(connectdeadline, errbuf, errbuflen, errkind);
      if errkind != 0 & livewshandle >= 0 then
         begin
         discard := cxclose(livewshandle);
         livewshandle := -1
         end;
      if errkind = 0 then
         begin
         liveremotequeryset := 0;
         liveremoteidentity := 0;
         timestampzero(liveremotetsbytes, 0);
         livenextconnect := 0;
         livebackoff := liveinitialbackoff;
         liveconnectioncount := liveconnectioncount + 1
         end
      end
end liveconnectnow;

integer procedure livereadbudget;
   comment once bytes are known to be available - already buffered, or
   the socket reported readable - this is how long a single message is
   given to finish arriving before a stalled peer is treated as a
   transport failure. Deliberately longer than one owner-loop tick,
   because livepump itself is normally called with a short slice so
   that a slow Convex socket never starves the adapter's controller
   stream, or vice versa;
begin
   livereadbudget := 5000
end;

comment services the live connection for up to calldeadline. Most
   calls find nothing ready in their short slice, which is completely
   normal, not a failure - only a genuine socket error, an already
   started frame that then stalls, or a message that fails to parse
   sets errkind;
procedure liveservice(calldeadline, errbuf, errbuflen, errkind);
   value calldeadline;
   integer array errbuf;
   integer calldeadline, errbuflen, errkind;
begin
   integer array msgbuf[0:65535];
   integer msgtype, msglen, discard, avail, mask, remaining;
   avail := if liversrlen > liversroff then 1 else 0;
   if avail = 0 then
      begin
      remaining := calldeadline - cxnowms;
      if remaining < 0 then remaining := 0;
      mask := cxpoll(livewshandle, 0, -1, 0, -1, 0, remaining);
      if mask < 0 then
         begin
         errbuflen := 0; errkind := 3;
         discard := bufputstr(errbuf, 256, errbuflen, "Live connection failed while waiting")
         end
      else if mask > 0 then avail := 1
      end;
   if errkind = 0 & avail != 0 then
      begin
      wsreadmessage(livewshandle, liversbuf, 8192, liversrlen, liversroff, cxnowms + livereadbudget, msgtype, msgbuf,
         65536, msglen, errbuf, errbuflen, errkind);
      if errkind = 0 then
         begin
         if msgtype = wsopcodeclose then
            begin
            errbuflen := 0; errkind := 3;
            discard := bufputstr(errbuf, 256, errbuflen, "Live server closed the WebSocket")
            end
         else if msgtype = wsopcodetext | msgtype = wsopcodebinary then
            livehandlemessage(msgbuf, msglen, errbuf, errbuflen, errkind);
         comment ping and pong frames need no response from a client
            that only reads - a real deployment's server keeps the
            connection alive on its own timers;
         end
      end
end liveservice;

comment one bounded slice of owner work. Failures retire the
   connection, publish a structured TransportError to every active
   subscription, and schedule a reconnect, and they never strand a
   subscription, because the next connection resends its Add;
procedure livepump(calldeadline);
   value calldeadline;
   integer calldeadline;
begin
   integer array errbuf[0:255];
   integer errbuflen, errkind, discard;
   if liveclosed = 0 then
      begin
      if livewshandle < 0 then
         begin
         if livenextconnect > cxnowms then
            begin
            integer waitms, remaining;
            waitms := livenextconnect - cxnowms;
            remaining := calldeadline - cxnowms;
            if remaining < waitms then waitms := remaining;
            if waitms > 0 then discard := cxpoll(-1, 0, -1, 0, -1, 0, waitms)
            end
         else
            begin
            errbuflen := 0; errkind := 0;
            liveconnectnow(errbuf, errbuflen, errkind);
            if errkind != 0 then
               begin
               liveretire(errbuf, 0, errbuflen);
               liveschedulereconnect;
               livepublishtoall(3, errbuf, 0, errbuflen)
               end
            end
         end
      else
         begin
         errbuflen := 0; errkind := 0;
         liveservice(calldeadline, errbuf, errbuflen, errkind);
         if errkind != 0 then
            begin
            liveretire(errbuf, 0, errbuflen);
            liveschedulereconnect;
            livepublishtoall(errkind, errbuf, 0, errbuflen)
            end
         end
      end
end livepump;

comment ---------------------------------------------------------------
   Public Live API.
   ------------------------------------------------------------------;

integer procedure livefreesubscription;
begin
   integer i, found;
   found := -1;
   for i := 0 step 1 until 3 do
      if subactive[i] = 0 & found < 0 then found := i;
   livefreesubscription := found
end livefreesubscription;

procedure livesubscribe(host, hostlen, port, portlen, tls, pathbuf, pathlen,
      argsbuf, argsoff, argslen, deadlinems, sub, errbuf, errbuflen, errkind);
   value hostlen, portlen, tls, pathlen, argsoff, argslen, deadlinems;
   integer array host, port, pathbuf, argsbuf, errbuf;
   integer hostlen, portlen, tls, pathlen, argsoff, argslen, deadlinems,
      sub, errbuflen, errkind;
begin
   integer charge, i, discard;
   errkind := 0;
   if httpvalidpath(pathbuf, pathlen) = 0 then
      begin
      errbuflen := 0; errkind := 2;
      discard := bufputstr(errbuf, 256, errbuflen, "function path must be module:function")
      end;
   if errkind = 0 then
      begin
      livehostlen := 0;
      discard := bufputbytes(livehostbuf, 256, livehostlen, host, 0, hostlen);
      liveportlen := 0;
      discard := bufputbytes(liveportbuf, 16, liveportlen, port, 0, portlen);
      livetls := tls;
      charge := pathlen + argslen + 512;
      if livesubbytes + charge > livemaxsubbytes then
         begin
         errbuflen := 0; errkind := 2;
         discard := bufputstr(errbuf, 256, errbuflen, "Live subscription capacity exceeded")
         end
      else
         begin
         sub := livefreesubscription;
         if sub < 0 then
            begin
            errbuflen := 0; errkind := 2;
            discard := bufputstr(errbuf, 256, errbuflen, "Live subscription capacity exceeded")
            end
         end
      end;
   if errkind = 0 then
      begin
      subpathlen[sub] := 0;
      for i := 0 step 1 until pathlen - 1 do subpathbuf[sub, i] := pathbuf[i];
      subpathlen[sub] := pathlen;
      subargslen[sub] := 0;
      for i := 0 step 1 until argslen - 1 do subargsbuf[sub, i] := argsbuf[argsoff + i];
      subargslen[sub] := argslen;
      subqueryid[sub] := livenextqueryid;
      livenextqueryid := livenextqueryid + 1;
      subcharge[sub] := charge;
      livesubbytes := livesubbytes + charge;
      subhavelast[sub] := 0;
      subepoch[sub] := subepoch[sub] + 1;
      subactive[sub] := 1;
      if livewshandle < 0 then
         begin
         livenextconnect := 0;
         livepump(deadlinems);
         if livewshandle < 0 then
            begin
            subactive[sub] := 0;
            livesubbytes := livesubbytes - charge;
            errbuflen := 0; errkind := 3;
            discard := bufputstr(errbuf, 256, errbuflen, "Live connection failed")
            end
         end
      else
         begin
         livesendmodification(sub, 1, deadlinems, errbuf, errbuflen, errkind);
         if errkind != 0 then
            begin
            subactive[sub] := 0;
            livesubbytes := livesubbytes - charge;
            liveretireliteral("SubscribeFailed");
            liveschedulereconnect
            end
         end
      end
end livesubscribe;

procedure liveunsubscribe(sub, deadlinems);
   value sub, deadlinems;
   integer sub, deadlinems;
begin
   integer array errbuf[0:255];
   integer errbuflen, errkind;
   if subactive[sub] != 0 then
      begin
      subepoch[sub] := subepoch[sub] + 1;
      subactive[sub] := 0;
      subhavelast[sub] := 0;
      livesubbytes := livesubbytes - subcharge[sub];
      livepurgesubscription(sub);
      if livewshandle >= 0 then
         begin
         errbuflen := 0; errkind := 0;
         livesendmodification(sub, 0, deadlinems, errbuf, errbuflen, errkind);
         if errkind != 0 then
            begin
            liveretireliteral("UnsubscribeFailed");
            liveschedulereconnect
            end
         end
      end
end liveunsubscribe;

comment fault injection for the conformance adapter only - forces the
   live connection closed so the shared controller can prove real
   reconnects. Refuses, rather than faking success, when there is no
   live connection;
integer procedure livedebugdisconnect(errbuf, errbuflen, errkind);
   integer array errbuf;
   integer errbuflen, errkind;
begin
   if livewshandle < 0 then
      begin
      errbuflen := 0; errkind := 3;
      begin integer discard; discard := bufputstr(errbuf, 256, errbuflen, "Live WebSocket is not connected") end;
      livedebugdisconnect := livegeneration
      end
   else
      begin
      errkind := 0;
      liveretireliteral("DebugDisconnect");
      livepurgeall;
      livenextconnect := cxnowms + liveinitialbackoff;
      livebackoff := liveinitialbackoff * 2;
      livedebugdisconnect := livegeneration
      end
end livedebugdisconnect;

procedure liveclose(deadlinems);
   value deadlinems;
   integer deadlinems;
begin
   integer i;
   if liveclosed = 0 then
      begin
      liveclosed := 1;
      for i := 0 step 1 until 3 do
         begin
         subactive[i] := 0;
         subepoch[i] := subepoch[i] + 1
         end;
      livesubbytes := 0;
      livepurgeall;
      if livewshandle >= 0 then
         begin
         integer array errbuf[0:255];
         integer errbuflen, errkind, discard;
         integer array empty[0:0];
         errbuflen := 0; errkind := 0;
         wssendcontrol(livewshandle, wsopcodeclose, empty, 0, 0, deadlinems, errbuf, errbuflen, errkind)
         end;
      liveretireliteral("ClientClosed")
      end
end liveclose;

comment ---------------------------------------------------------------
   Consuming deliveries.
   ------------------------------------------------------------------;

integer livetaken;

integer procedure liveaccept(index);
   comment a delivery is only acceptable if it still belongs to the
   current epoch of the subscription it was queued for - the barrier
   that keeps a value produced for a removed or replaced subscription
   from ever being handed back;
   value index;
   integer index;
begin
   integer sub;
   sub := dlsub[index];
   liveaccept := if sub < 0 then 0 else if dlepoch[index] = subepoch[sub] then 1 else 0
end liveaccept;

integer procedure livetakefor(sub);
   comment returns 0 for none, 1 for value, 2 for error;
   value sub;
   integer sub;
begin
   integer index, dummy, done, kind;
   done := 0;
   kind := 0;
   for dummy := 1 while done = 0 do
      begin
      index := deliveryoldestfor(sub);
      if index < 0 then done := 1
      else if liveaccept(index) = 0 then
         deliveryrelease(index)
      else
         begin
         livetaken := index;
         kind := dlkind[index];
         done := 1
         end
      end;
   livetakefor := kind
end livetakefor;

procedure livereleasetaken;
begin
   deliveryrelease(livetaken)
end livereleasetaken;

comment waits for the next delivery on one subscription, pumping the
   owner loop while waiting, bounded by an absolute deadline;
integer procedure livenext(sub, timeoutms);
   value sub, timeoutms;
   integer sub, timeoutms;
begin
   integer deadline, kind, dummy, sleepms, remaining, timedout;
   deadline := cxnowms + timeoutms;
   kind := 0;
   timedout := 0;
   for dummy := 1 while kind = 0 & timedout = 0 do
      begin
      kind := livetakefor(sub);
      if kind = 0 then
         begin
         if cxnowms >= deadline then timedout := 1
         else
            begin
            remaining := deadline - cxnowms;
            sleepms := 50;
            if sleepms > remaining then sleepms := remaining;
            livepump(cxnowms + sleepms)
            end
         end
      end;
   livenext := kind
end livenext;

integer procedure liveconnected;
begin
   liveconnected := if livewshandle >= 0 then 1 else 0
end liveconnected;

comment ---------------------------------------------------------------
   Reading the fields of the delivery most recently taken. These copy
   out of the two-dimensional per-slot arrays, because a row of a
   two-dimensional array cannot itself be passed where a
   one-dimensional array formal parameter is expected.
   ------------------------------------------------------------------;

integer procedure livetakenkind;
begin
   livetakenkind := dlkind[livetaken]
end livetakenkind;

integer procedure livetakenerrkind;
begin
   livetakenerrkind := dlerrkind[livetaken]
end livetakenerrkind;

procedure livetakencopyvalue(dst, dstcap, dstlen);
   value dstcap;
   integer array dst;
   integer dstcap, dstlen;
begin
   integer i, n;
   n := dlvaluelen[livetaken];
   if n > dstcap then n := dstcap;
   for i := 0 step 1 until n - 1 do dst[i] := dlvaluebuf[livetaken, i];
   dstlen := n
end livetakencopyvalue;

procedure livetakencopymessage(dst, dstcap, dstlen);
   value dstcap;
   integer array dst;
   integer dstcap, dstlen;
begin
   integer i, n;
   n := dlmsglen[livetaken];
   if n > dstcap then n := dstcap;
   for i := 0 step 1 until n - 1 do dst[i] := dlmsgbuf[livetaken, i];
   dstlen := n
end livetakencopymessage;

procedure livetakencopydata(dst, dstcap, dstlen, hasdata);
   value dstcap;
   integer array dst;
   integer dstcap, dstlen, hasdata;
begin
   integer i, n;
   hasdata := dlhasdata[livetaken];
   n := dldatalen[livetaken];
   if n > dstcap then n := dstcap;
   for i := 0 step 1 until n - 1 do dst[i] := dldatabuf[livetaken, i];
   dstlen := n
end livetakencopydata;
