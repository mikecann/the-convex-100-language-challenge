MODULE ConvexUrl;

IMPORT Text;

(* Index of the first occurrence of "needle" in "s" at or after "from",
   or -1. Small and linear -- these URLs are a handful of bytes. *)
PROCEDURE FindFrom(s: TEXT; needle: TEXT; from: CARDINAL): INTEGER =
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
  END FindFrom;

PROCEDURE ParseInt(s: TEXT): INTEGER =
  VAR n := 0;
  BEGIN
    FOR i := 0 TO Text.Length(s) - 1 DO
      n := n * 10 + (ORD(Text.GetChar(s, i)) - ORD('0'));
    END;
    RETURN n;
  END ParseInt;

PROCEDURE Parse(url: TEXT; defaultPath: TEXT): T =
  VAR
    schemeEnd := FindFrom(url, "://", 0);
    scheme, rest, hostAndMore, path, host: TEXT;
    colon, slash: INTEGER;
    port: INTEGER;
    useTls: BOOLEAN;
  BEGIN
    scheme := Text.Sub(url, 0, schemeEnd);
    rest := Text.Sub(url, schemeEnd + 3, LAST(CARDINAL));
    useTls := Text.Equal(scheme, "https") OR Text.Equal(scheme, "wss");

    slash := FindFrom(rest, "/", 0);
    IF slash >= 0 THEN
      hostAndMore := Text.Sub(rest, 0, slash);
      path := Text.Sub(rest, slash, LAST(CARDINAL));
    ELSE
      hostAndMore := rest;
      path := defaultPath;
    END;

    colon := FindFrom(hostAndMore, ":", 0);
    IF colon >= 0 THEN
      host := Text.Sub(hostAndMore, 0, colon);
      port := ParseInt(Text.Sub(hostAndMore, colon + 1, LAST(CARDINAL)));
    ELSE
      host := hostAndMore;
      IF useTls THEN port := 443; ELSE port := 80; END;
    END;

    RETURN T{scheme := scheme, host := host, port := port, useTls := useTls, path := path};
  END Parse;

BEGIN
END ConvexUrl.
