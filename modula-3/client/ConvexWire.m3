MODULE ConvexWire;

IMPORT Text, Time, ConvexTransport;

PROCEDURE Find(s: TEXT; needle: TEXT; from: CARDINAL): INTEGER =
  VAR sLen := Text.Length(s); nLen := Text.Length(needle);
  BEGIN
    IF nLen = 0 THEN RETURN from; END;
    IF from + nLen > sLen THEN RETURN -1; END;
    FOR i := from TO sLen - nLen DO
      VAR ok := TRUE;
      BEGIN
        FOR j := 0 TO nLen - 1 DO
          IF Text.GetChar(s, i + j) # Text.GetChar(needle, j) THEN ok := FALSE; EXIT; END;
        END;
        IF ok THEN RETURN i; END;
      END;
    END;
    RETURN -1;
  END Find;

PROCEDURE ReadHeaderBlock(t: ConvexTransport.T; deadline: LONGREAL; maxBytes: INTEGER): HeaderBlock
  RAISES {Error} =
  VAR
    whole := "";
    chunk: TEXT;
    headerText, statusLine, leftover: TEXT;
    blankAt: INTEGER;
    sawAnyByte: BOOLEAN;
  BEGIN
    LOOP
      blankAt := Find(whole, "\r\n\r\n", 0);
      IF blankAt >= 0 THEN
        headerText := Text.Sub(whole, 0, blankAt + 2);
        leftover := Text.Sub(whole, blankAt + 4, LAST(CARDINAL));
        VAR lineEnd := Find(headerText, "\r\n", 0);
        BEGIN
          IF lineEnd < 0 THEN statusLine := headerText;
          ELSE statusLine := Text.Sub(headerText, 0, lineEnd);
          END;
        END;
        RETURN HeaderBlock{statusLine := statusLine, headerText := headerText, leftover := leftover};
      END;
      IF Text.Length(whole) > maxBytes THEN RAISE Error("header block exceeded budget"); END;

      VAR remainMs: INTEGER;
      BEGIN
        remainMs := ROUND((deadline - Time.Now()) * 1000.0d0);
        IF remainMs <= 0 THEN RAISE Error("timed out reading headers"); END;
        IF remainMs > 2000 THEN remainMs := 2000; END;
        TRY
          chunk := ConvexTransport.Read(t, 65536, remainMs);
          sawAnyByte := TRUE;
        EXCEPT
        | ConvexTransport.Error(msg) =>
            IF Find(msg, "timeout:", 0) = 0 THEN
              (* transient: loop back and re-check the deadline *)
              chunk := NIL;
              sawAnyByte := FALSE;
            ELSE
              RAISE Error(msg);
            END;
        END;
      END;

      IF sawAnyByte THEN
        IF Text.Equal(chunk, "") THEN RAISE Error("connection closed while reading headers"); END;
        whole := whole & chunk;
      END;
    END;
  END ReadHeaderBlock;

PROCEDURE LowerChar(c: CHAR): CHAR =
  BEGIN
    IF c >= 'A' AND c <= 'Z' THEN RETURN VAL(ORD(c) + 32, CHAR); END;
    RETURN c;
  END LowerChar;

PROCEDURE LowerEqual(a: TEXT; b: TEXT): BOOLEAN =
  BEGIN
    IF Text.Length(a) # Text.Length(b) THEN RETURN FALSE; END;
    FOR i := 0 TO Text.Length(a) - 1 DO
      IF LowerChar(Text.GetChar(a, i)) # LowerChar(Text.GetChar(b, i)) THEN RETURN FALSE; END;
    END;
    RETURN TRUE;
  END LowerEqual;

PROCEDURE Trim(s: TEXT): TEXT =
  VAR n := Text.Length(s); start := 0; stop := n;
  BEGIN
    WHILE start < stop AND (Text.GetChar(s, start) = ' ' OR Text.GetChar(s, start) = '\t') DO
      INC(start);
    END;
    WHILE stop > start AND (Text.GetChar(s, stop - 1) = ' ' OR Text.GetChar(s, stop - 1) = '\t') DO
      DEC(stop);
    END;
    RETURN Text.Sub(s, start, stop - start);
  END Trim;

PROCEDURE HeaderValue(headerText: TEXT; name: TEXT): TEXT =
  VAR
    pos := 0;
    n := Text.Length(headerText);
  BEGIN
    (* headerText is "Status-Line\r\nName: value\r\n...\r\n"; skip the
       status line, then walk header lines one at a time. *)
    VAR firstEol := Find(headerText, "\r\n", 0);
    BEGIN
      IF firstEol < 0 THEN RETURN NIL; END;
      pos := firstEol + 2;
    END;
    WHILE pos < n DO
      VAR eol := Find(headerText, "\r\n", pos);
      BEGIN
        IF eol < 0 THEN eol := n; END;
        IF eol > pos THEN
          VAR line := Text.Sub(headerText, pos, eol - pos);
              colon := Find(line, ":", 0);
          BEGIN
            IF colon >= 0 THEN
              VAR hname := Text.Sub(line, 0, colon);
                  hvalue := Trim(Text.Sub(line, colon + 1, LAST(CARDINAL)));
              BEGIN
                IF LowerEqual(hname, name) THEN RETURN hvalue; END;
              END;
            END;
          END;
        END;
        pos := eol + 2;
      END;
    END;
    RETURN NIL;
  END HeaderValue;

BEGIN
END ConvexWire.
