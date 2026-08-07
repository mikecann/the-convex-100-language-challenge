comment tls-test.alg - proof that TLS verification is really on.
   Certificate checking is the one thing a client can get wrong while
   every happy-path test still passes, so it needs a real peer rather
   than a loopback fixture this process writes to itself. The Docker
   test stage starts a local TLS server with a private CA and runs
   this program three times, once per TLS_MODE:
   trusted - the CA is trusted and the name matches, so the handshake,
   and a real request over the encrypted stream, must both succeed.
   untrusted - a different CA is trusted, so the handshake must fail.
   wronghost - the CA is trusted but the connection is made by address
   rather than by the name the certificate was issued for, so the
   handshake must still fail.
   Only trusted would pass on a client that quietly skipped
   verification, which is exactly why the other two matter;

begin
   integer array modebuf[0:15];
   integer array modename[0:15];
   integer modelen, namelen, discard;
   integer array port[0:15];
   integer portlen;
   integer array errbuf[0:255];
   integer errbuflen;
   integer handle, exitcode;
   integer array host[0:63];
   integer hostlen;
   exitcode := 1;

   namelen := 0;
   discard := bufputstr(modename, 16, namelen, "TLS_MODE");
   modelen := cxgetenv(modename, namelen, modebuf, 16);
   portlen := 0;
   discard := bufputstr(port, 16, portlen, "44300");

   if modelen > 0 & bufeqstr(modebuf, 0, modelen, "trusted") then
      begin
      hostlen := 0;
      discard := bufputstr(host, 64, hostlen, "localhost");
      handle := cxopen(host, hostlen, port, portlen, 1, cxnowms + 5000);
      if handle < 0 then
         begin
         integer array text[0:255];
         integer textlen;
         textlen := cxerrtext(text, 255);
         discard := cxwrite(2, text, 0, textlen)
         end
      else
         begin
         integer array reqbytes[0:63];
         integer reqlen, written, got, dummy;
         integer array rbuf[0:2047];
         integer array linebuf[0:1023];
         integer rlen, roff, linelen;
         reqlen := 0;
         discard := bufputstr(reqbytes, 64, reqlen, "GET / HTTP/1.0\r\n\r\n");
         written := 0;
         for dummy := 1 while written < reqlen do
            begin
            got := cxwrite(handle, reqbytes, written, reqlen - written);
            if got > 0 then written := written + got
            end;
         rlen := 0; roff := 0;
         linelen := 0;
         begin
            integer errkind2;
            errbuflen := 0; errkind2 := 0;
            streamline(handle, rbuf, 2048, rlen, roff, cxnowms + 5000, linebuf, 1024, linelen, errbuf, errbuflen,
               errkind2);
            if errkind2 = 0 & bufeqstr(linebuf, 0, 12, "HTTP/1.0 200") then
               exitcode := 0
         end;
         discard := cxclose(handle)
         end
      end
   else if modelen > 0 & bufeqstr(modebuf, 0, modelen, "untrusted") then
      begin
      hostlen := 0;
      discard := bufputstr(host, 64, hostlen, "localhost");
      handle := cxopen(host, hostlen, port, portlen, 1, cxnowms + 5000);
      if handle < 0 then exitcode := 0
      else discard := cxclose(handle)
      end
   else if modelen > 0 & bufeqstr(modebuf, 0, modelen, "wronghost") then
      begin
      hostlen := 0;
      discard := bufputstr(host, 64, hostlen, "127.0.0.1");
      handle := cxopen(host, hostlen, port, portlen, 1, cxnowms + 5000);
      if handle < 0 then exitcode := 0
      else discard := cxclose(handle)
      end
   else
      begin
      integer array msg[0:63];
      integer msglen;
      msglen := 0;
      discard := bufputstr(msg, 64, msglen, "TLS_MODE must be trusted, untrusted or wronghost\n");
      discard := cxwrite(2, msg, 0, msglen)
      end;
   discard := cxexit(exitcode)
end
