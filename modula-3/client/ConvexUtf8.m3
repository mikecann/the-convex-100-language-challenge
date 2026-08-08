MODULE ConvexUtf8;

IMPORT Text, Word;

PROCEDURE IsValid(s: TEXT): BOOLEAN =
  VAR n := Text.Length(s); i := 0; b, cont: INTEGER; extra, cp, minCp: INTEGER;
  BEGIN
    WHILE i < n DO
      b := ORD(Text.GetChar(s, i));
      IF b < 16_80 THEN
        INC(i);
      ELSE
        IF Word.And(b, 16_E0) = 16_C0 THEN
          extra := 1; cp := Word.And(b, 16_1F); minCp := 16_80;
        ELSIF Word.And(b, 16_F0) = 16_E0 THEN
          extra := 2; cp := Word.And(b, 16_0F); minCp := 16_800;
        ELSIF Word.And(b, 16_F8) = 16_F0 THEN
          extra := 3; cp := Word.And(b, 16_07); minCp := 16_10000;
        ELSE
          RETURN FALSE; (* stray continuation byte or invalid leading byte *)
        END;

        IF i + extra >= n THEN RETURN FALSE; END;
        FOR k := 1 TO extra DO
          cont := ORD(Text.GetChar(s, i + k));
          IF Word.And(cont, 16_C0) # 16_80 THEN RETURN FALSE; END;
          cp := cp * 64 + Word.And(cont, 16_3F);
        END;
        IF cp < minCp THEN RETURN FALSE; END; (* overlong encoding *)
        IF cp > 16_10FFFF THEN RETURN FALSE; END;
        IF cp >= 16_D800 AND cp <= 16_DFFF THEN RETURN FALSE; END; (* surrogate *)
        i := i + extra + 1;
      END;
    END;
    RETURN TRUE;
  END IsValid;

BEGIN
END ConvexUtf8.
