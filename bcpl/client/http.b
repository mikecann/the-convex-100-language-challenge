// http.b -- HTTP/1.1 over the native byte transport.
//
// Convex's query, mutation and action endpoints are ordinary HTTP POSTs of a
// JSON body, so this is where the client speaks HTTP itself rather than
// delegating. Every read carries the caller's absolute deadline, and every
// accumulation is bounded, because the peer on the other end of a conformance
// run is deliberately not always friendly.

LET epNew(tls, host, port, path) = VALOF
{ LET endpoint = getvec(Ep_upb)
  UNLESS endpoint RESULTIS 0
  endpoint!Ep_tls := tls
  endpoint!Ep_host := host
  endpoint!Ep_port := port
  endpoint!Ep_path := path
  RESULTIS endpoint
}

AND epFree(endpoint) BE
{ UNLESS endpoint RETURN
  bbFree(endpoint!Ep_host)
  bbFree(endpoint!Ep_path)
  freevec(endpoint)
}

// Accepts http:// and https:// deployment URLs. A URL carrying userinfo is
// refused rather than quietly ignored, so a credential can never be smuggled
// into a request line.
AND epParseUrl(url) = VALOF
{ LET tls = FALSE
  LET position = 0
  LET host = 0
  LET path = 0
  LET port = 0
  LET length = url!Bb_len

  TEST bbMatchStrAt(url, 0, "https://")
  THEN { tls := TRUE; position := 8 }
  ELSE TEST bbMatchStrAt(url, 0, "http://")
  THEN { tls := FALSE; position := 7 }
  ELSE { errSetStr(Ek_protocol, "ConfigurationError",
                   "the Convex deployment URL must start with http:// or https://")
         RESULTIS 0
       }

  host := bbNew(64)
  path := bbNew(32)
  IF host = 0 DO { bbFree(path); RESULTIS 0 }
  IF path = 0 DO { bbFree(host); RESULTIS 0 }

  UNTIL position >= length DO
  { LET byte = bbGet(url, position)
    IF byte = '/' DO BREAK
    IF byte = '@' DO
    { errSetStr(Ek_protocol, "ConfigurationError",
                "the Convex deployment URL must not carry userinfo")
      bbFree(host)
      bbFree(path)
      RESULTIS 0
    }
    IF byte = ':' DO
    { position := position + 1
      UNTIL position >= length DO
      { LET digit = bbGet(url, position)
        IF digit = '/' DO BREAK
        UNLESS '0' <= digit <= '9' DO
        { errSetStr(Ek_protocol, "ConfigurationError",
                    "the Convex deployment URL has a malformed port")
          bbFree(host)
          bbFree(path)
          RESULTIS 0
        }
        port := port * 10 + digit - '0'
        position := position + 1
      }
      BREAK
    }
    bbPush(host, byte)
    position := position + 1
  }

  // Any remaining path is a deployment prefix; trailing slashes are dropped so
  // that appending /api/query cannot produce a doubled separator.
  UNTIL position >= length DO
  { bbPush(path, bbGet(url, position))
    position := position + 1
  }
  UNTIL path!Bb_len = 0 DO
  { UNLESS bbGet(path, path!Bb_len - 1) = '/' DO BREAK
    path!Bb_len := path!Bb_len - 1
  }

  IF host!Bb_len = 0 DO
  { errSetStr(Ek_protocol, "ConfigurationError",
              "the Convex deployment URL has no host")
    bbFree(host)
    bbFree(path)
    RESULTIS 0
  }
  IF port = 0 DO port := tls -> 443, 80
  RESULTIS epNew(tls, host, port, path)
}

// Reads bytes until the blank line that ends an HTTP header block. Returns the
// offset just past it, or a negative value. The whole block is bounded, so a
// peer that never stops sending headers cannot exhaust memory.
AND httpReadHeaders(handle, rx, deadline) = VALOF
{ LET scanfrom = 0
  { LET got = 0
    LET limit = rx!Bb_len - 3
    FOR index = scanfrom TO limit - 1 DO
      IF bbGet(rx, index) = 13 DO
        IF bbGet(rx, index + 1) = 10 DO
          IF bbGet(rx, index + 2) = 13 DO
            IF bbGet(rx, index + 3) = 10 DO RESULTIS index + 4
    IF limit > 0 DO scanfrom := limit
    IF rx!Bb_len > Maxheaderbytes DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the HTTP header block exceeded its bound")
      RESULTIS -1
    }
    got := bbReadInto(rx, handle, 4096, deadline)
    IF got = Cx_eof DO
    { errSetStr(Ek_transport, "TransportError",
                "the peer closed before the HTTP headers were complete")
      RESULTIS -1
    }
    IF got = Cx_timeout DO
    { errSetStr(Ek_transport, "TransportError",
                "the deadline expired while reading HTTP headers")
      RESULTIS -1
    }
    IF got < 0 DO
    { errFromNative(Ek_transport, "TransportError", "HTTP header read failed")
      RESULTIS -1
    }
  } REPEAT
}

// Copies the value of the named header out of a header block, or returns 0.
AND httpHeaderValue(rx, headerend, name) = VALOF
{ LET position = 0
  // Skip the status line.
  UNTIL position >= headerend - 1 DO
  { IF bbGet(rx, position) = 13 DO
      IF bbGet(rx, position + 1) = 10 DO { position := position + 2; BREAK }
    position := position + 1
  }
  UNTIL position >= headerend - 1 DO
  { LET lineend = position
    LET colon = -1
    LET start = 0
    LET stop = 0
    LET value = 0
    UNTIL lineend >= headerend - 1 DO
    { IF bbGet(rx, lineend) = 13 DO
        IF bbGet(rx, lineend + 1) = 10 DO BREAK
      lineend := lineend + 1
    }
    IF lineend = position RESULTIS 0
    FOR index = position TO lineend - 1 DO
      IF bbGet(rx, index) = ':' DO { colon := index; BREAK }
    IF colon >= 0 DO
      IF bbEqualFoldStr(rx, position, colon - position, name) DO
      { start := colon + 1
        UNTIL start >= lineend DO
        { UNLESS bbGet(rx, start) = 32 | bbGet(rx, start) = 9 DO BREAK
          start := start + 1
        }
        stop := lineend
        UNTIL stop <= start DO
        { UNLESS bbGet(rx, stop - 1) = 32 | bbGet(rx, stop - 1) = 9 DO BREAK
          stop := stop - 1
        }
        value := bbSlice(rx, start, stop - start)
        RESULTIS value
      }
    position := lineend + 2
  }
  RESULTIS 0
}

AND httpFree(response) BE
{ UNLESS response RETURN
  bbFree(response!Hr_body)
  freevec(response)
}

// Build and send the request line, headers and body.
//
// The whole message is assembled in one buffer before anything is written, so
// a refused append would produce a request whose Content-Length no longer
// described its body. The two appends that carry caller-sized data are
// therefore checked, and an oversized body is refused before the connection is
// used at all.
AND httpSendRequest(handle, endpoint, method, target, body, token, version,
                    deadline) = VALOF
{ LET request = 0
  LET sent = 0
  IF body ~= 0 DO
    IF body!Bb_len > Maxrequestbytes DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the Convex request body exceeded its bound")
      RESULTIS FALSE
    }
  request := bbNew(512)
  UNLESS request RESULTIS FALSE
  bbPushStr(request, method)
  bbPush(request, ' ')
  bbPushBuffer(request, endpoint!Ep_path)
  bbPushStr(request, target)
  bbPushStr(request, " HTTP/1.1*c*n")
  bbPushStr(request, "Host: ")
  bbPushBuffer(request, endpoint!Ep_host)
  // The default port is implicit in the Host header; a non-default one is not.
  UNLESS endpoint!Ep_port = (endpoint!Ep_tls -> 443, 80) DO
  { bbPush(request, ':')
    bbPushNum(request, endpoint!Ep_port)
  }
  bbPushStr(request, "*c*n")
  bbPushStr(request, "User-Agent: ")
  bbPushBuffer(request, version)
  bbPushStr(request, "*c*n")
  bbPushStr(request, "Convex-Client: ")
  bbPushBuffer(request, version)
  bbPushStr(request, "*c*n")
  bbPushStr(request, "Accept: application/json*c*n")
  bbPushStr(request, "Content-Type: application/json*c*n")
  // This client implements no content coding, so it asks for none. Announcing
  // identity explicitly is what makes a Content-Encoding in the answer a
  // protocol violation rather than a feature this client quietly mishandles.
  bbPushStr(request, "Accept-Encoding: identity*c*n")
  // No keep-alive: one request per connection keeps the state machine small
  // and makes a half-closed peer impossible to mistake for a slow one.
  bbPushStr(request, "Connection: close*c*n")
  IF token ~= 0 DO
    IF token!Bb_len > 0 DO
    { bbPushStr(request, "Authorization: Bearer ")
      UNLESS bbPushBuffer(request, token) DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "the Convex bearer token exceeded its bound")
        bbFree(request)
        RESULTIS FALSE
      }
      bbPushStr(request, "*c*n")
    }
  bbPushStr(request, "Content-Length: ")
  bbPushNum(request, (body = 0 -> 0, body!Bb_len))
  bbPushStr(request, "*c*n*c*n")
  IF body ~= 0 DO
    UNLESS bbPushBuffer(request, body) DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the Convex request could not be assembled within its bound")
      bbFree(request)
      RESULTIS FALSE
    }

  sent := cxWriteBuffer(handle, request, deadline)
  bbFree(request)
  IF sent < 0 DO
  { errFromNative(Ek_transport, "TransportError", "HTTP request write failed")
    RESULTIS FALSE
  }
  RESULTIS TRUE
}

// One complete HTTP exchange. `target` is appended to the deployment's base
// path, for example "/api/query".
AND httpRequest(endpoint, method, target, body, token, version, deadline) =
VALOF
{ LET hostname = VEC 64
  LET handle = 0
  LET rx = 0
  LET headerend = 0
  LET response = 0
  LET status = 0
  LET lengthheader = 0
  LET encodingheader = 0
  LET chunked = FALSE
  LET expected = -1

  bbToStr(endpoint!Ep_host, hostname, 250)
  handle := cxConnect(hostname, endpoint!Ep_port, endpoint!Ep_tls, deadline)
  IF handle < 0 DO
  { errFromNative(Ek_transport, "TransportError",
                  "could not reach the Convex deployment")
    RESULTIS 0
  }

  UNLESS httpSendRequest(handle, endpoint, method, target, body, token,
                         version, deadline) DO
  { cxCloseHandle(handle); RESULTIS 0 }

  rx := bbNew(4096)
  UNLESS rx DO { cxCloseHandle(handle); RESULTIS 0 }

  headerend := httpReadHeaders(handle, rx, deadline)
  IF headerend < 0 DO { bbFree(rx); cxCloseHandle(handle); RESULTIS 0 }

  // Status line: HTTP/1.<digit> SP <three digits> SP reason. Every fixed
  // position is checked, because a status read out of a line this client never
  // validated would be a number it invented rather than one the peer sent.
  IF rx!Bb_len < 12 DO
  { errSetStr(Ek_protocol, "ProtocolError", "the HTTP response was truncated")
    bbFree(rx)
    cxCloseHandle(handle)
    RESULTIS 0
  }
  { LET wellformed = bbMatchStrAt(rx, 0, "HTTP/1.")
    IF wellformed DO wellformed := '0' <= bbGet(rx, 7) <= '9'
    IF wellformed DO wellformed := bbGet(rx, 8) = 32
    UNLESS wellformed DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the HTTP status line was not HTTP/1.x")
      bbFree(rx)
      cxCloseHandle(handle)
      RESULTIS 0
    }
  }
  FOR index = 9 TO 11 DO
  { LET digit = bbGet(rx, index)
    UNLESS '0' <= digit <= '9' DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the HTTP status line was malformed")
      bbFree(rx)
      cxCloseHandle(handle)
      RESULTIS 0
    }
    status := status * 10 + digit - '0'
  }

  // The request asked for identity, so anything else here is a body this
  // client would have to decode and cannot. Refuse it rather than hand a
  // compressed byte stream to the JSON parser and report the resulting mess as
  // protocol drift from the deployment.
  { LET contentencoding = httpHeaderValue(rx, headerend, "content-encoding")
    IF contentencoding ~= 0 DO
    { LET identity = bbEqualFoldStr(contentencoding, 0,
                                    contentencoding!Bb_len, "identity")
      bbFree(contentencoding)
      UNLESS identity DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "the HTTP response used an unsupported content encoding")
        bbFree(rx)
        cxCloseHandle(handle)
        RESULTIS 0
      }
    }
  }

  encodingheader := httpHeaderValue(rx, headerend, "transfer-encoding")
  lengthheader := httpHeaderValue(rx, headerend, "content-length")
  IF encodingheader ~= 0 DO
  { chunked := bbEqualFoldStr(encodingheader, 0, encodingheader!Bb_len,
                              "chunked")
    bbFree(encodingheader)
    // Two disagreeing framings in one response is the classic request
    // smuggling shape. Refuse rather than pick a winner.
    UNLESS chunked DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the HTTP response used an unsupported transfer encoding")
      bbFree(lengthheader)
      bbFree(rx)
      cxCloseHandle(handle)
      RESULTIS 0
    }
    IF lengthheader ~= 0 DO
    { errSetStr(Ek_protocol, "ProtocolError",
                "the HTTP response declared two conflicting body framings")
      bbFree(lengthheader)
      bbFree(rx)
      cxCloseHandle(handle)
      RESULTIS 0
    }
  }
  IF lengthheader ~= 0 DO
  { LET value = 0
    LET valid = lengthheader!Bb_len > 0
    FOR index = 0 TO lengthheader!Bb_len - 1 DO
    { LET digit = bbGet(lengthheader, index)
      UNLESS '0' <= digit <= '9' DO { valid := FALSE; BREAK }
      IF value > Maxbodybytes DO { valid := FALSE; BREAK }
      value := value * 10 + digit - '0'
    }
    IF value > Maxbodybytes DO valid := FALSE
    bbFree(lengthheader)
    TEST valid
    THEN expected := value
    ELSE { errSetStr(Ek_protocol, "ProtocolError",
                     "the HTTP Content-Length was unusable")
           bbFree(rx)
           cxCloseHandle(handle)
           RESULTIS 0
         }
  }

  response := getvec(Hr_upb)
  UNLESS response DO { bbFree(rx); cxCloseHandle(handle); RESULTIS 0 }
  response!Hr_status := status
  response!Hr_body := bbNew(1024)
  UNLESS response!Hr_body DO
  { freevec(response); bbFree(rx); cxCloseHandle(handle); RESULTIS 0 }

  // Whatever arrived alongside the headers is the start of the body.
  bbPushBytes(response!Hr_body, rx!Bb_vec, headerend, rx!Bb_len - headerend)
  bbFree(rx)

  TEST chunked
  THEN
  // `pending` holds the still-unparsed raw stream and `assembled` the decoded
  // body. Every consumed chunk is trimmed off the front of `pending`, so the
  // raw encoding never has to fit in memory beside the body it decodes to.
  { LET assembled = bbNew(1024)
    LET pending = response!Hr_body
    UNLESS assembled DO
    { httpFree(response); cxCloseHandle(handle); RESULTIS 0 }
    { LET size = -1
      LET digits = 0
      LET lineend = -1
      // Find the chunk-size line, reading more only when it is incomplete.
      FOR index = 0 TO pending!Bb_len - 2 DO
        IF bbGet(pending, index) = 13 DO
          IF bbGet(pending, index + 1) = 10 DO { lineend := index; BREAK }
      IF lineend >= 0 DO
      { size := 0
        FOR index = 0 TO lineend - 1 DO
        { LET digit = bbGet(pending, index)
          LET value = -1
          IF digit = ';' DO BREAK
          IF '0' <= digit <= '9' DO value := digit - '0'
          IF 'a' <= digit <= 'f' DO value := digit - 'a' + 10
          IF 'A' <= digit <= 'F' DO value := digit - 'A' + 10
          IF value < 0 DO { size := -2; BREAK }
          size := size * 16 + value
          digits := digits + 1
          IF size > Maxbodybytes DO { size := -2; BREAK }
        }
        IF digits = 0 DO size := -2
      }
      IF size = -2 DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "a chunked HTTP body had a malformed chunk size")
        bbFree(assembled)
        httpFree(response)
        cxCloseHandle(handle)
        RESULTIS 0
      }
      IF size > 0 DO
        IF assembled!Bb_len + size > Maxbodybytes DO
        { errSetStr(Ek_protocol, "ProtocolError",
                    "the HTTP response body exceeded its bound")
          bbFree(assembled)
          httpFree(response)
          cxCloseHandle(handle)
          RESULTIS 0
        }
      IF size >= 0 DO
        IF pending!Bb_len >= lineend + 2 + size + 2 DO
        { IF size = 0 DO BREAK
          UNLESS bbPushBytes(assembled, pending!Bb_vec, lineend + 2, size) DO
          { errSetStr(Ek_protocol, "ProtocolError",
                      "the HTTP response body exceeded its bound")
            bbFree(assembled)
            httpFree(response)
            cxCloseHandle(handle)
            RESULTIS 0
          }
          bbTrimFront(pending, lineend + 2 + size + 2)
          LOOP
        }
      IF pending!Bb_len > Maxheaderbytes + Maxbodybytes DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "a chunked HTTP body exceeded its bound")
        bbFree(assembled)
        httpFree(response)
        cxCloseHandle(handle)
        RESULTIS 0
      }
      { LET got = bbReadInto(pending, handle, 4096, deadline)
        IF got <= 0 DO
        { errSetStr(Ek_transport, "TransportError",
                    "the chunked HTTP body ended early")
          bbFree(assembled)
          httpFree(response)
          cxCloseHandle(handle)
          RESULTIS 0
        }
      }
    } REPEAT
    bbFree(response!Hr_body)
    response!Hr_body := assembled
  }
  ELSE
  { // Content-Length when present, otherwise read to a clean close.
    { LET got = 0
      IF expected >= 0 DO
        IF response!Hr_body!Bb_len >= expected DO
        { response!Hr_body!Bb_len := expected; BREAK }
      IF response!Hr_body!Bb_len > Maxbodybytes DO
      { errSetStr(Ek_protocol, "ProtocolError",
                  "the HTTP response body exceeded its bound")
        httpFree(response)
        cxCloseHandle(handle)
        RESULTIS 0
      }
      got := bbReadInto(response!Hr_body, handle, 8192, deadline)
      IF got = Cx_eof DO
      { IF expected < 0 DO BREAK
        errSetStr(Ek_transport, "TransportError",
                  "the HTTP response body ended early")
        httpFree(response)
        cxCloseHandle(handle)
        RESULTIS 0
      }
      IF got < 0 DO
      { errSetStr(Ek_transport, "TransportError",
                  "the deadline expired while reading the HTTP response body")
        httpFree(response)
        cxCloseHandle(handle)
        RESULTIS 0
      }
    } REPEAT
  }

  cxCloseHandle(handle)
  RESULTIS response
}
