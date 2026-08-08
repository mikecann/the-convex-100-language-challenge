UNSAFE MODULE ConvexTransport;

IMPORT IP, TCP, TCPPosix, TlsShim, Thread, Rd, M3toC, ConnFD, Text;

REVEAL
  T = ROOT BRANDED "ConvexTransport.T" OBJECT
        isTls: BOOLEAN;
        plain: TCP.T;
        tls: ADDRESS;
      END;

PROCEDURE Connect(host: TEXT; port: INTEGER; useTls: BOOLEAN): T RAISES {Error} =
  VAR
    addr: IP.Address;
    conn: TCP.T;
    pub: TCPPosix.Public;
    t := NEW(T);
  BEGIN
    TRY
      IF NOT IP.GetHostByName(host, addr) THEN
        RAISE Error("DNS lookup failed for " & host);
      END;
      conn := TCP.Connect(IP.Endpoint{addr := addr, port := port});
    EXCEPT
    | IP.Error(ec) => RAISE Error("connect failed: " & host);
    | Thread.Alerted => RAISE Error("connect alerted: " & host);
    END;

    t.isTls := useTls;
    t.plain := conn;
    t.tls := NIL;

    IF useTls THEN
      pub := conn;
      VAR hostC := M3toC.CopyTtoS(host);
      BEGIN
        t.tls := TlsShim.Connect(pub.fd, hostC);
        M3toC.FreeCopiedS(hostC);
      END;
      IF t.tls = NIL THEN
        RAISE Error("TLS handshake or certificate/hostname verification failed for " & host);
      END;
    END;
    RETURN t;
  END Connect;

PROCEDURE Read(t: T; maxBytes: INTEGER; timeoutMs: INTEGER): TEXT RAISES {Error} =
  VAR n: INTEGER; buf: REF ARRAY OF CHAR := NEW(REF ARRAY OF CHAR, maxBytes);
  BEGIN
    IF t.isTls THEN
      n := TlsShim.Read(t.tls, ADR(buf[0]), maxBytes, timeoutMs);
      IF n = -1 THEN RAISE Error("timeout: reading TLS data"); END;
      IF n = -2 THEN RAISE Error("TLS read failed"); END;
      IF n = 0 THEN RETURN ""; END;
      RETURN Text.FromChars(SUBARRAY(buf^, 0, n));
    ELSE
      TRY
        n := t.plain.get(buf^, FLOAT(timeoutMs, LONGREAL) / 1000.0d0);
        IF n = 0 THEN RETURN ""; END;
        RETURN Text.FromChars(SUBARRAY(buf^, 0, n));
      EXCEPT
      | ConnFD.TimedOut => RAISE Error("timeout: reading plain data");
      | Rd.Failure => RAISE Error("plain read failed");
      | Thread.Alerted => RAISE Error("plain read alerted");
      END;
    END;
  END Read;

PROCEDURE Write(t: T; data: TEXT) RAISES {Error} =
  VAR n := Text.Length(data); buf: REF ARRAY OF CHAR;
  BEGIN
    IF n = 0 THEN RETURN; END;
    buf := NEW(REF ARRAY OF CHAR, n);
    Text.SetChars(buf^, data);
    IF t.isTls THEN
      IF TlsShim.Write(t.tls, ADR(buf[0]), n) # n THEN RAISE Error("TLS write failed"); END;
    ELSE
      TRY
        t.plain.put(buf^);
      EXCEPT
      | Thread.Alerted => RAISE Error("plain write alerted");
      ELSE RAISE Error("plain write failed");
      END;
    END;
  END Write;

PROCEDURE Close(t: T) =
  BEGIN
    IF t.isTls THEN
      IF t.tls # NIL THEN TlsShim.Close(t.tls); t.tls := NIL; END;
    ELSE
      IF t.plain # NIL THEN t.plain.close(); END;
    END;
  END Close;

BEGIN
END ConvexTransport.
