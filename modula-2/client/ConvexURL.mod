IMPLEMENTATION MODULE ConvexURL;

(* gm2's ISO Strings.Length crashes when called on an array whose declared
   capacity is roughly 2 MiB or more (confirmed empirically: it is fine on
   a 1 MiB array and segfaults on a 2 MiB one, with no application code on
   the stack between the call and the crash). Several buffers in this
   client are exactly that large, so every module scans for the NUL
   terminator itself instead of trusting Strings.Length. *)
PROCEDURE TextLength (VAR s: ARRAY OF CHAR) : INTEGER;
VAR i, cap: INTEGER;
BEGIN
  cap := INTEGER(HIGH(s));
  i := 0;
  WHILE (i <= cap) AND (s[i] <> 0C) DO INC(i) END;
  RETURN i;
END TextLength;


PROCEDURE HasPrefix (text: ARRAY OF CHAR; prefix: ARRAY OF CHAR; VAR prefixLength: INTEGER) : BOOLEAN;
VAR
  textLength, i: INTEGER;
BEGIN
  prefixLength := INTEGER(TextLength(prefix));
  textLength := INTEGER(TextLength(text));
  IF textLength < prefixLength THEN RETURN FALSE END;
  FOR i := 0 TO prefixLength - 1 DO
    IF text[i] <> prefix[i] THEN RETURN FALSE END;
  END;
  RETURN TRUE;
END HasPrefix;

PROCEDURE IsDigit (ch: CHAR) : BOOLEAN;
BEGIN
  RETURN (ch >= "0") AND (ch <= "9");
END IsDigit;

PROCEDURE Parse (url: ARRAY OF CHAR;
                  VAR secure: BOOLEAN;
                  VAR host: ARRAY OF CHAR;
                  VAR port: INTEGER;
                  VAR path: ARRAY OF CHAR) : BOOLEAN;
VAR
  prefixLength, urlLength, pos, hostStart, i: INTEGER;
  defaultPort: INTEGER;
BEGIN
  host[0] := 0C;
  path[0] := 0C;
  port := 0;
  secure := FALSE;
  urlLength := INTEGER(TextLength(url));

  IF HasPrefix(url, "https://", prefixLength) THEN
    secure := TRUE;
    defaultPort := 443;
  ELSIF HasPrefix(url, "http://", prefixLength) THEN
    secure := FALSE;
    defaultPort := 80;
  ELSIF HasPrefix(url, "wss://", prefixLength) THEN
    secure := TRUE;
    defaultPort := 443;
  ELSIF HasPrefix(url, "ws://", prefixLength) THEN
    secure := FALSE;
    defaultPort := 80;
  ELSE
    RETURN FALSE;
  END;

  hostStart := prefixLength;
  pos := hostStart;
  WHILE (pos < urlLength) AND (url[pos] <> '/') AND (url[pos] <> ':') DO
    INC(pos);
  END;
  IF pos = hostStart THEN RETURN FALSE END;
  IF pos - hostStart > INTEGER(HIGH(host)) THEN RETURN FALSE END;
  FOR i := 0 TO pos - hostStart - 1 DO
    host[i] := url[hostStart + i];
  END;
  host[pos - hostStart] := 0C;

  IF (pos < urlLength) AND (url[pos] = ':') THEN
    INC(pos);
    port := 0;
    IF (pos >= urlLength) OR NOT IsDigit(url[pos]) THEN RETURN FALSE END;
    WHILE (pos < urlLength) AND IsDigit(url[pos]) DO
      port := port * 10 + (INTEGER(ORD(url[pos])) - INTEGER(ORD('0')));
      INC(pos);
    END;
  ELSE
    port := defaultPort;
  END;

  IF pos >= urlLength THEN
    path[0] := '/';
    path[1] := 0C;
    RETURN TRUE;
  END;
  IF url[pos] <> '/' THEN RETURN FALSE END;
  IF urlLength - pos > INTEGER(HIGH(path)) THEN RETURN FALSE END;
  FOR i := 0 TO urlLength - pos - 1 DO
    path[i] := url[pos + i];
  END;
  path[urlLength - pos] := 0C;
  RETURN TRUE;
END Parse;

END ConvexURL.
