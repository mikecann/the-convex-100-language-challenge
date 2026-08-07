// json.b -- a bounded JSON reader and writer.
//
// Numbers are kept as their literal text rather than converted to a machine
// number. That is not laziness: a Convex document can carry a number too big
// for even this system's 64-bit words, such as a value close to IEEE double
// precision's range. Holding the lexeme means every value survives a round
// trip exactly as Convex sent it, and a caller that genuinely wants an
// integer asks for one through jsWholeNumber, which accepts Convex's
// integral 0 or 0.0 forms and refuses anything fractional or out of range.

LET jsNew(type) = VALOF
{ LET node = getvec(Js_upb)
  UNLESS node RESULTIS 0
  node!Js_type := type
  node!Js_a := 0
  node!Js_b := 0
  RESULTIS node
}

AND jsFree(node) BE
{ UNLESS node RETURN
  SWITCHON node!Js_type INTO
  { CASE Jt_number:
    CASE Jt_string:
      bbFree(node!Js_a)
      ENDCASE
    CASE Jt_array:
      jsFreeList(node!Js_a)
      ENDCASE
    CASE Jt_object:
      IF node!Js_a DO
      { FOR index = 0 TO (node!Js_a)!Vl_len - 1 DO
          bbFree(vlGet(node!Js_a, index))
        vlFree(node!Js_a)
      }
      jsFreeList(node!Js_b)
      ENDCASE
    DEFAULT:
      ENDCASE
  }
  freevec(node)
}

AND jsFreeList(list) BE
{ UNLESS list RETURN
  FOR index = 0 TO list!Vl_len - 1 DO jsFree(vlGet(list, index))
  vlFree(list)
}

AND jsType(node) = (node = 0) -> Jt_null, node!Js_type

AND jsNull() = jsNew(Jt_null)

AND jsNumberFromInt(value) = VALOF
{ LET node = jsNew(Jt_number)
  UNLESS node RESULTIS 0
  node!Js_a := bbNew(16)
  UNLESS node!Js_a DO { jsFree(node); RESULTIS 0 }
  UNLESS bbPushNum(node!Js_a, value) DO { jsFree(node); RESULTIS 0 }
  RESULTIS node
}

// Takes ownership of the buffer. A caller that hands over a buffer it failed to
// allocate gets nothing back rather than a string node with no bytes: every
// writer here dereferences Js_a, so an empty string node would be a fault
// waiting for the first serialisation.
AND jsStringFromBuffer(buffer) = VALOF
{ LET node = 0
  UNLESS buffer RESULTIS 0
  node := jsNew(Jt_string)
  UNLESS node DO { bbFree(buffer); RESULTIS 0 }
  node!Js_a := buffer
  RESULTIS node
}

AND jsStringFromStr(text) = jsStringFromBuffer(bbFromStr(text))

AND jsArray() = VALOF
{ LET node = jsNew(Jt_array)
  UNLESS node RESULTIS 0
  node!Js_a := vlNew(8)
  UNLESS node!Js_a DO { jsFree(node); RESULTIS 0 }
  RESULTIS node
}

AND jsObject() = VALOF
{ LET node = jsNew(Jt_object)
  UNLESS node RESULTIS 0
  node!Js_a := vlNew(8)
  node!Js_b := vlNew(8)
  IF node!Js_a = 0 DO { jsFree(node); RESULTIS 0 }
  IF node!Js_b = 0 DO { jsFree(node); RESULTIS 0 }
  RESULTIS node
}

// Takes ownership of the child.
AND jsArrayPush(array, child) = VALOF
{ UNLESS child RESULTIS FALSE
  UNLESS vlPush(array!Js_a, child) DO { jsFree(child); RESULTIS FALSE }
  RESULTIS TRUE
}

// Takes ownership of both the key buffer and the child.
AND jsObjectPut(object, key, child) = VALOF
{ IF key = 0 DO { jsFree(child); RESULTIS FALSE }
  IF child = 0 DO { bbFree(key); RESULTIS FALSE }
  UNLESS vlPush(object!Js_a, key) DO
  { bbFree(key); jsFree(child); RESULTIS FALSE }
  UNLESS vlPush(object!Js_b, child) DO
  { // Keep the two lists the same length so freeing stays correct.
    (object!Js_a)!Vl_len := (object!Js_a)!Vl_len - 1
    bbFree(key)
    jsFree(child)
    RESULTIS FALSE
  }
  RESULTIS TRUE
}

AND jsObjectPutStr(object, key, child) =
      jsObjectPut(object, bbFromStr(key), child)

// Borrowed reference, or 0.
AND jsObjectGet(object, key) = VALOF
{ IF object = 0 RESULTIS 0
  UNLESS object!Js_type = Jt_object RESULTIS 0
  FOR index = 0 TO (object!Js_a)!Vl_len - 1 DO
    IF bbEqualStr(vlGet(object!Js_a, index), key) DO
      RESULTIS vlGet(object!Js_b, index)
  RESULTIS 0
}

AND jsArrayGet(array, index) = VALOF
{ IF array = 0 RESULTIS 0
  UNLESS array!Js_type = Jt_array RESULTIS 0
  IF index < 0 RESULTIS 0
  IF index >= (array!Js_a)!Vl_len RESULTIS 0
  RESULTIS vlGet(array!Js_a, index)
}

AND jsCount(node) = VALOF
{ IF node = 0 RESULTIS 0
  IF node!Js_type = Jt_array RESULTIS (node!Js_a)!Vl_len
  IF node!Js_type = Jt_object RESULTIS (node!Js_a)!Vl_len
  RESULTIS 0
}

AND jsStringEqualsStr(node, text) = VALOF
{ IF node = 0 RESULTIS FALSE
  UNLESS node!Js_type = Jt_string RESULTIS FALSE
  RESULTIS bbEqualStr(node!Js_a, text)
}

AND jsClone(node) = VALOF
{ LET copy = 0
  IF node = 0 RESULTIS 0
  SWITCHON node!Js_type INTO
  { CASE Jt_null:
    CASE Jt_true:
    CASE Jt_false:
      RESULTIS jsNew(node!Js_type)

    CASE Jt_number:
    CASE Jt_string:
      copy := jsNew(node!Js_type)
      UNLESS copy RESULTIS 0
      copy!Js_a := bbCopy(node!Js_a)
      UNLESS copy!Js_a DO { jsFree(copy); RESULTIS 0 }
      RESULTIS copy

    CASE Jt_array:
      copy := jsArray()
      UNLESS copy RESULTIS 0
      FOR index = 0 TO (node!Js_a)!Vl_len - 1 DO
        UNLESS jsArrayPush(copy, jsClone(vlGet(node!Js_a, index))) DO
        { jsFree(copy); RESULTIS 0 }
      RESULTIS copy

    DEFAULT:
      copy := jsObject()
      UNLESS copy RESULTIS 0
      FOR index = 0 TO (node!Js_a)!Vl_len - 1 DO
        UNLESS jsObjectPut(copy, bbCopy(vlGet(node!Js_a, index)),
                           jsClone(vlGet(node!Js_b, index))) DO
        { jsFree(copy); RESULTIS 0 }
      RESULTIS copy
  }
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

AND jsWriteStringInto(buffer, out) = VALOF
{ UNLESS bbPush(out, '"') RESULTIS FALSE
  FOR index = 0 TO buffer!Bb_len - 1 DO
  { LET byte = bbGet(buffer, index)
    SWITCHON byte INTO
    { CASE '"':  bbPushStr(out, "\*""); ENDCASE
      CASE '\': bbPushStr(out, "\\"); ENDCASE
      CASE 8:    bbPushStr(out, "\b"); ENDCASE
      CASE 12:   bbPushStr(out, "\f"); ENDCASE
      CASE 10:   bbPushStr(out, "\n"); ENDCASE
      CASE 13:   bbPushStr(out, "\r"); ENDCASE
      CASE 9:    bbPushStr(out, "\t"); ENDCASE
      DEFAULT:
        TEST byte < 32
        THEN { bbPushStr(out, "\u00")
               bbPushHexDigit(out, shr32(byte, 4))
               bbPushHexDigit(out, byte)
             }
        ELSE bbPush(out, byte)
        ENDCASE
    }
  }
  RESULTIS bbPush(out, '"')
}

AND jsWrite(node, out) = VALOF
{ IF node = 0 RESULTIS bbPushStr(out, "null")
  SWITCHON node!Js_type INTO
  { CASE Jt_null:   RESULTIS bbPushStr(out, "null")
    CASE Jt_true:   RESULTIS bbPushStr(out, "true")
    CASE Jt_false:  RESULTIS bbPushStr(out, "false")
    CASE Jt_number: RESULTIS bbPushBuffer(out, node!Js_a)
    CASE Jt_string: RESULTIS jsWriteStringInto(node!Js_a, out)

    CASE Jt_array:
      UNLESS bbPush(out, '[') RESULTIS FALSE
      FOR index = 0 TO (node!Js_a)!Vl_len - 1 DO
      { IF index > 0 DO UNLESS bbPush(out, ',') RESULTIS FALSE
        UNLESS jsWrite(vlGet(node!Js_a, index), out) RESULTIS FALSE
      }
      RESULTIS bbPush(out, ']')

    DEFAULT:
      UNLESS bbPush(out, '{') RESULTIS FALSE
      FOR index = 0 TO (node!Js_a)!Vl_len - 1 DO
      { IF index > 0 DO UNLESS bbPush(out, ',') RESULTIS FALSE
        UNLESS jsWriteStringInto(vlGet(node!Js_a, index), out) RESULTIS FALSE
        UNLESS bbPush(out, ':') RESULTIS FALSE
        UNLESS jsWrite(vlGet(node!Js_b, index), out) RESULTIS FALSE
      }
      RESULTIS bbPush(out, '}')
  }
}

AND jsSerialise(node) = VALOF
{ LET out = bbNew(128)
  UNLESS out RESULTIS 0
  UNLESS jsWrite(node, out) DO { bbFree(out); RESULTIS 0 }
  RESULTIS out
}

// ---------------------------------------------------------------------------
// Reading
//
// The parser is bounded in both directions: Maxjsondepth stops a nest of
// brackets from exhausting the Cintcode stack, and Maxjsonnodes stops a long
// but shallow value from exhausting the heap. Both are hostile-peer defences,
// not tidiness.
// ---------------------------------------------------------------------------

AND jpFail(reason) BE
{ UNLESS jsParseError DO jsParseError := bbFromStr(reason)
}

AND jpSkipSpace() BE
  UNTIL jpPos >= jpEnd DO
  { LET byte = jpSource%jpPos
    UNLESS byte = 32 | byte = 9 | byte = 10 | byte = 13 RETURN
    jpPos := jpPos + 1
  }

AND jpLiteral(text, type) = VALOF
{ FOR index = 1 TO text%0 DO
  { IF jpPos + index - 1 >= jpEnd DO { jpFail("truncated JSON literal")
                                       RESULTIS 0
                                     }
    UNLESS jpSource%(jpPos + index - 1) = text%index DO
    { jpFail("unknown JSON literal"); RESULTIS 0 }
  }
  jpPos := jpPos + text%0
  RESULTIS jsNew(type)
}

AND jpHex4() = VALOF
{ LET value = 0
  IF jpPos + 4 > jpEnd RESULTIS -1
  FOR index = 1 TO 4 DO
  { LET byte = jpSource%jpPos
    LET digit = -1
    IF '0' <= byte <= '9' DO digit := byte - '0'
    IF 'a' <= byte <= 'f' DO digit := byte - 'a' + 10
    IF 'A' <= byte <= 'F' DO digit := byte - 'A' + 10
    IF digit < 0 RESULTIS -1
    value := value * 16 + digit
    jpPos := jpPos + 1
  }
  RESULTIS value
}

AND jpUtf8Push(out, point) BE
  TEST point < #x80
  THEN bbPush(out, point)
  ELSE TEST point < #x800
  THEN { bbPush(out, #xC0 | shr32(point, 6))
         bbPush(out, #x80 | (point & #x3F))
       }
  ELSE TEST point < #x10000
  THEN { bbPush(out, #xE0 | shr32(point, 12))
         bbPush(out, #x80 | (shr32(point, 6) & #x3F))
         bbPush(out, #x80 | (point & #x3F))
       }
  ELSE { bbPush(out, #xF0 | shr32(point, 18))
         bbPush(out, #x80 | (shr32(point, 12) & #x3F))
         bbPush(out, #x80 | (shr32(point, 6) & #x3F))
         bbPush(out, #x80 | (point & #x3F))
       }

// Reads a quoted string, returning the decoded UTF-8 bytes.
AND jpString() = VALOF
{ LET out = bbNew(32)
  UNLESS out RESULTIS 0
  IF jpPos >= jpEnd DO { jpFail("truncated JSON string")
                         bbFree(out)
                         RESULTIS 0
                       }
  UNLESS jpSource%jpPos = '"' DO { jpFail("expected a JSON string")
                                   bbFree(out)
                                   RESULTIS 0
                                 }
  jpPos := jpPos + 1
  UNTIL jpPos >= jpEnd DO
  { LET byte = jpSource%jpPos
    jpPos := jpPos + 1
    IF byte = '"' DO
    { UNLESS utf8Valid(out!Bb_vec, 0, out!Bb_len) DO
      { jpFail("JSON string was not valid UTF-8")
        bbFree(out)
        RESULTIS 0
      }
      RESULTIS out
    }
    TEST byte = '\'
    THEN
    { LET escape = 0
      IF jpPos >= jpEnd DO { jpFail("truncated JSON escape")
                             bbFree(out)
                             RESULTIS 0
                           }
      escape := jpSource%jpPos
      jpPos := jpPos + 1
      SWITCHON escape INTO
      { CASE '"':  bbPush(out, '"');  ENDCASE
        CASE '\': bbPush(out, '\'); ENDCASE
        CASE '/':  bbPush(out, '/');  ENDCASE
        CASE 'b':  bbPush(out, 8);    ENDCASE
        CASE 'f':  bbPush(out, 12);   ENDCASE
        CASE 'n':  bbPush(out, 10);   ENDCASE
        CASE 'r':  bbPush(out, 13);   ENDCASE
        CASE 't':  bbPush(out, 9);    ENDCASE
        CASE 'u':
        { LET point = jpHex4()
          IF point < 0 DO { jpFail("bad JSON \u escape")
                            bbFree(out)
                            RESULTIS 0
                          }
          // A high surrogate must be followed by its low partner; anything
          // else would produce ill-formed UTF-8 on the way out.
          IF #xD800 <= point <= #xDBFF DO
          { LET low = 0
            IF jpPos + 1 >= jpEnd DO { jpFail("unpaired JSON surrogate")
                                       bbFree(out)
                                       RESULTIS 0
                                     }
            UNLESS jpSource%jpPos = '\' DO
            { jpFail("unpaired JSON surrogate"); bbFree(out); RESULTIS 0 }
            UNLESS jpSource%(jpPos + 1) = 'u' DO
            { jpFail("unpaired JSON surrogate"); bbFree(out); RESULTIS 0 }
            jpPos := jpPos + 2
            low := jpHex4()
            UNLESS #xDC00 <= low <= #xDFFF DO
            { jpFail("unpaired JSON surrogate"); bbFree(out); RESULTIS 0 }
            point := #x10000 + ((point - #xD800) << 10) + (low - #xDC00)
          }
          IF #xDC00 <= point <= #xDFFF DO
          { jpFail("unpaired JSON surrogate"); bbFree(out); RESULTIS 0 }
          jpUtf8Push(out, point)
          ENDCASE
        }
        DEFAULT:
          jpFail("unknown JSON escape")
          bbFree(out)
          RESULTIS 0
      }
    }
    ELSE
    { IF byte < 32 DO { jpFail("raw control character in a JSON string")
                        bbFree(out)
                        RESULTIS 0
                      }
      bbPush(out, byte)
    }
    IF out!Bb_len > Maxbufferbytes - 8 DO
    { jpFail("JSON string exceeded the buffer bound")
      bbFree(out)
      RESULTIS 0
    }
  }
  jpFail("unterminated JSON string")
  bbFree(out)
  RESULTIS 0
}

// Captures a number's literal text after validating the JSON grammar.
AND jpNumber() = VALOF
{ LET start = jpPos
  LET node = 0
  LET digits = 0
  IF jpPos < jpEnd DO IF jpSource%jpPos = '-' DO jpPos := jpPos + 1
  UNTIL jpPos >= jpEnd DO
  { UNLESS '0' <= jpSource%jpPos <= '9' DO BREAK
    digits := digits + 1
    jpPos := jpPos + 1
  }
  IF digits = 0 DO { jpFail("JSON number has no digits"); RESULTIS 0 }
  // JSON forbids a leading zero in a multi-digit integer part.
  IF digits > 1 DO
    IF jpSource%(jpPos - digits) = '0' DO
    { jpFail("JSON number has a leading zero"); RESULTIS 0 }
  IF jpPos < jpEnd DO IF jpSource%jpPos = '.' DO
  { LET fraction = 0
    jpPos := jpPos + 1
    UNTIL jpPos >= jpEnd DO
    { UNLESS '0' <= jpSource%jpPos <= '9' DO BREAK
      fraction := fraction + 1
      jpPos := jpPos + 1
    }
    IF fraction = 0 DO { jpFail("JSON number has an empty fraction")
                         RESULTIS 0
                       }
  }
  IF jpPos < jpEnd DO
    IF jpSource%jpPos = 'e' | jpSource%jpPos = 'E' DO
    { LET exponent = 0
      jpPos := jpPos + 1
      IF jpPos < jpEnd DO
        IF jpSource%jpPos = '+' | jpSource%jpPos = '-' DO
          jpPos := jpPos + 1
      UNTIL jpPos >= jpEnd DO
      { UNLESS '0' <= jpSource%jpPos <= '9' DO BREAK
        exponent := exponent + 1
        jpPos := jpPos + 1
      }
      IF exponent = 0 DO { jpFail("JSON number has an empty exponent")
                           RESULTIS 0
                         }
    }
  node := jsNew(Jt_number)
  UNLESS node RESULTIS 0
  node!Js_a := bbNew(jpPos - start + 1)
  UNLESS node!Js_a DO { jsFree(node); RESULTIS 0 }
  bbPushBytes(node!Js_a, jpSource, start, jpPos - start)
  RESULTIS node
}

AND jpValue() = VALOF
{ LET byte = 0
  LET node = 0
  jpNodes := jpNodes + 1
  IF jpNodes > Maxjsonnodes DO { jpFail("JSON value exceeded the node bound")
                                 RESULTIS 0
                               }
  jpDepth := jpDepth + 1
  IF jpDepth > Maxjsondepth DO { jpFail("JSON value exceeded the depth bound")
                                 jpDepth := jpDepth - 1
                                 RESULTIS 0
                               }
  jpSkipSpace()
  IF jpPos >= jpEnd DO { jpFail("truncated JSON value")
                         jpDepth := jpDepth - 1
                         RESULTIS 0
                       }
  byte := jpSource%jpPos

  IF byte = '"' DO
  { LET text = jpString()
    jpDepth := jpDepth - 1
    UNLESS text RESULTIS 0
    RESULTIS jsStringFromBuffer(text)
  }

  IF byte = 't' DO { node := jpLiteral("true", Jt_true)
                     jpDepth := jpDepth - 1
                     RESULTIS node
                   }
  IF byte = 'f' DO { node := jpLiteral("false", Jt_false)
                     jpDepth := jpDepth - 1
                     RESULTIS node
                   }
  IF byte = 'n' DO { node := jpLiteral("null", Jt_null)
                     jpDepth := jpDepth - 1
                     RESULTIS node
                   }

  IF byte = '[' DO
  { jpPos := jpPos + 1
    node := jsArray()
    UNLESS node DO { jpDepth := jpDepth - 1; RESULTIS 0 }
    jpSkipSpace()
    IF jpPos < jpEnd DO IF jpSource%jpPos = ']' DO
    { jpPos := jpPos + 1
      jpDepth := jpDepth - 1
      RESULTIS node
    }
    { LET child = jpValue()
      UNLESS child DO { jsFree(node); jpDepth := jpDepth - 1; RESULTIS 0 }
      UNLESS jsArrayPush(node, child) DO
      { jsFree(node); jpDepth := jpDepth - 1; RESULTIS 0 }
      jpSkipSpace()
      IF jpPos >= jpEnd DO { jpFail("truncated JSON array")
                             jsFree(node)
                             jpDepth := jpDepth - 1
                             RESULTIS 0
                           }
      IF jpSource%jpPos = ',' DO { jpPos := jpPos + 1; LOOP }
      IF jpSource%jpPos = ']' DO
      { jpPos := jpPos + 1
        jpDepth := jpDepth - 1
        RESULTIS node
      }
      jpFail("expected a comma or a closing bracket")
      jsFree(node)
      jpDepth := jpDepth - 1
      RESULTIS 0
    } REPEAT
  }

  IF byte = '{' DO
  { jpPos := jpPos + 1
    node := jsObject()
    UNLESS node DO { jpDepth := jpDepth - 1; RESULTIS 0 }
    jpSkipSpace()
    IF jpPos < jpEnd DO IF jpSource%jpPos = '}' DO
    { jpPos := jpPos + 1
      jpDepth := jpDepth - 1
      RESULTIS node
    }
    { LET key = 0
      LET child = 0
      jpSkipSpace()
      key := jpString()
      UNLESS key DO { jsFree(node); jpDepth := jpDepth - 1; RESULTIS 0 }
      jpSkipSpace()
      UNLESS jpPos < jpEnd DO { jpFail("truncated JSON object")
                                bbFree(key)
                                jsFree(node)
                                jpDepth := jpDepth - 1
                                RESULTIS 0
                              }
      UNLESS jpSource%jpPos = ':' DO { jpFail("expected a colon")
                                       bbFree(key)
                                       jsFree(node)
                                       jpDepth := jpDepth - 1
                                       RESULTIS 0
                                     }
      jpPos := jpPos + 1
      child := jpValue()
      UNLESS child DO { bbFree(key)
                        jsFree(node)
                        jpDepth := jpDepth - 1
                        RESULTIS 0
                      }
      UNLESS jsObjectPut(node, key, child) DO
      { jsFree(node); jpDepth := jpDepth - 1; RESULTIS 0 }
      jpSkipSpace()
      IF jpPos >= jpEnd DO { jpFail("truncated JSON object")
                             jsFree(node)
                             jpDepth := jpDepth - 1
                             RESULTIS 0
                           }
      IF jpSource%jpPos = ',' DO { jpPos := jpPos + 1; LOOP }
      IF jpSource%jpPos = '}' DO
      { jpPos := jpPos + 1
        jpDepth := jpDepth - 1
        RESULTIS node
      }
      jpFail("expected a comma or a closing brace")
      jsFree(node)
      jpDepth := jpDepth - 1
      RESULTIS 0
    } REPEAT
  }

  node := jpNumber()
  jpDepth := jpDepth - 1
  RESULTIS node
}

AND jsParse(source, offset, count) = VALOF
{ LET node = 0
  IF jsParseError DO { bbFree(jsParseError); jsParseError := 0 }
  jpSource := source
  jpPos := offset
  jpEnd := offset + count
  jpDepth := 0
  jpNodes := 0
  node := jpValue()
  UNLESS node RESULTIS 0
  jpSkipSpace()
  UNLESS jpPos = jpEnd DO
  { jpFail("trailing data after the JSON value")
    jsFree(node)
    RESULTIS 0
  }
  RESULTIS node
}

AND jsParseBuffer(buffer) = jsParse(buffer!Bb_vec, 0, buffer!Bb_len)

// ---------------------------------------------------------------------------
// Integral decoding
//
// Convex encodes a whole count as 0 or 0.0 depending on the path it took, so
// both must decode to the same integer. Everything else -- a real fraction, a
// quoted digit string, or a value outside the 32-bit range this system can
// represent -- must be refused rather than truncated.
// ---------------------------------------------------------------------------

AND jsWholeNumber(node, target) = VALOF
{ LET text = 0
  LET length = 0
  LET position = 0
  LET negative = FALSE
  LET digits = 0
  LET pointat = -1
  LET exponent = 0
  LET exponentsign = 1
  LET scale = 0
  LET value = 0
  LET used = 0

  IF node = 0 RESULTIS FALSE
  UNLESS node!Js_type = Jt_number RESULTIS FALSE
  text := node!Js_a
  length := text!Bb_len
  IF length = 0 RESULTIS FALSE

  IF bbGet(text, 0) = '-' DO { negative := TRUE; position := 1 }

  // Split the lexeme into its digit run and its decimal point position.
  { LET index = position
    UNTIL index >= length DO
    { LET byte = bbGet(text, index)
      IF byte = '.' DO
      { IF pointat >= 0 RESULTIS FALSE
        pointat := digits
        index := index + 1
        LOOP
      }
      IF byte = 'e' | byte = 'E' DO BREAK
      UNLESS '0' <= byte <= '9' RESULTIS FALSE
      digits := digits + 1
      index := index + 1
    }
    // Anything left must be a well-formed exponent.
    IF index < length DO
    { index := index + 1
      IF index < length DO
      { IF bbGet(text, index) = '-' DO { exponentsign := -1
                                         index := index + 1
                                       }
        IF index < length DO
          IF bbGet(text, index) = '+' DO index := index + 1
      }
      IF index >= length RESULTIS FALSE
      UNTIL index >= length DO
      { LET byte = bbGet(text, index)
        UNLESS '0' <= byte <= '9' RESULTIS FALSE
        IF exponent > 100 RESULTIS FALSE
        exponent := exponent * 10 + byte - '0'
        index := index + 1
      }
    }
  }

  IF digits = 0 RESULTIS FALSE
  IF pointat < 0 DO pointat := digits

  // scale is where the decimal point ends up once the exponent is applied.
  // maxint on this 64-bit build is 9223372036854775807, a 19 digit number,
  // so a value needing a 20th integer digit cannot be a whole number here
  // regardless of what its leading digits are; reject it before the digit
  // loop below ever risks reading past what "used" can count against scale.
  scale := pointat + exponent * exponentsign
  IF scale < 0 RESULTIS FALSE
  IF scale > 19 RESULTIS FALSE

  // Every digit beyond the point must be zero, or the value is fractional.
  { LET index = position
    LET seen = 0
    UNTIL index >= length DO
    { LET byte = bbGet(text, index)
      IF byte = '.' DO { index := index + 1; LOOP }
      IF byte = 'e' | byte = 'E' DO BREAK
      TEST seen < scale
      THEN
      { IF value > (maxint - (byte - '0')) / 10 RESULTIS FALSE
        value := value * 10 + byte - '0'
        used := used + 1
      }
      ELSE UNLESS byte = '0' RESULTIS FALSE
      seen := seen + 1
      index := index + 1
    }
    // A value such as 1e3 has fewer digits than the scale demands, so the
    // remaining places are implicit zeros.
    UNTIL used >= scale DO
    { IF value > maxint / 10 RESULTIS FALSE
      value := value * 10
      used := used + 1
    }
  }

  IF negative DO value := -value
  !target := value
  RESULTIS TRUE
}
