/* Language-local unit tests for the XPL Convex client's JSON scanner,
   URL parser, and small string helpers. This exercises pure logic that
   does not need a network connection; the HTTP and TLS paths are
   proved separately by Docker's example and conformance stages
   against the approved backend. */

declare failures fixed;

check_str: procedure(name, actual, expected);
    declare name character, actual character, expected character;
    if raw_eq(actual, 0, length(actual), expected) = 1 then
        output = 'ok   ' || name;
    else do;
        output = 'FAIL ' || name || ': got [' || actual || '] want [' ||
            expected || ']';
        failures = failures + 1;
    end;
end check_str;

check_int: procedure(name, actual, expected);
    declare name character, actual fixed, expected fixed;
    if actual = expected then output = 'ok   ' || name;
    else do;
        output = 'FAIL ' || name || ': got ' || actual || ' want ' ||
            expected;
        failures = failures + 1;
    end;
end check_int;

declare doc character, endpos fixed, found fixed;

failures = 0;
byte(CRLF, 0) = 13;
byte(CRLF, 1) = 10;

/* --- json_skip_value / json_skip_string ------------------------- */

doc = '  "hello" , 1';
endpos = json_skip_value(doc, 0);
call check_int('skip_value trims leading whitespace', endpos, 9);

doc = '"a\"b\\c" tail';
endpos = json_skip_value(doc, 0);
call check_int('skip_value respects escaped quote and backslash', endpos, 9);

doc = '{"a":1,"b":[1,2,{"c":"}"}],"d":true} tail';
endpos = json_skip_value(doc, 0);
call check_int('skip_value balances nested braces past a literal } in a string',
    endpos, 36);

doc = '-12.5e+3, next';
endpos = json_skip_value(doc, 0);
call check_int('skip_value stops a number at the comma', endpos, 8);

doc = 'null}';
endpos = json_skip_value(doc, 0);
call check_int('skip_value stops a literal at the closing brace', endpos, 4);

/* --- json_decode_string ------------------------------------------ */

doc = '"plain"';
call check_str('decode_string plain text',
    json_decode_string(doc, 0, length(doc)), 'plain');

doc = '"a\"b\\c\/d"';
call check_str('decode_string handles quote, backslash, and slash escapes',
    json_decode_string(doc, 0, length(doc)), 'a"b\c/d');

declare tab_expect character(8);
call zero_mem(addr(tab_expect), 8);
byte(tab_expect, 0) = 116; /* t */
byte(tab_expect, 1) = 97;  /* a */
byte(tab_expect, 2) = 98;  /* b */
byte(tab_expect, 3) = 9;   /* the tab character \t decodes to */
byte(tab_expect, 4) = 104; /* h */
doc = '"tab\there"';
call check_str('decode_string handles a \t escape',
    substr(json_decode_string(doc, 0, length(doc)), 0, 5), tab_expect);

/* é is the JSON escape for U+00E9 (e-acute), which UTF-8 encodes
   as the two bytes 0xC3 0xA9. */
declare eacute_expect character(8);
call zero_mem(addr(eacute_expect), 8);
byte(eacute_expect, 0) = 65;  /* A */
byte(eacute_expect, 1) = 195; /* first byte of UTF-8 e-acute */
byte(eacute_expect, 2) = 169; /* second byte of UTF-8 e-acute */
doc = '"A\u00e9"';
call check_str('decode_string encodes a BMP \u escape as 2 UTF-8 bytes',
    json_decode_string(doc, 0, length(doc)), eacute_expect);

/* 😀 is a UTF-16 surrogate pair for U+1F600 (an emoji outside
   the BMP), which UTF-8 encodes as 4 bytes. */
doc = '"\ud83d\ude00"';
endpos = length(json_decode_string(doc, 0, length(doc)));
call check_int(
    'decode_string combines a surrogate pair into a 4 byte UTF-8 code point',
    endpos, 4);

/* JSON text may also carry non-ASCII bytes literally, with no \u
   escape at all; those must be relayed unchanged too. */
declare literal_utf8 character(8);
call zero_mem(addr(literal_utf8), 8);
byte(literal_utf8, 0) = 34;  /* opening quote */
byte(literal_utf8, 1) = 65;  /* A */
byte(literal_utf8, 2) = 195; /* literal UTF-8 e-acute, unescaped */
byte(literal_utf8, 3) = 169;
byte(literal_utf8, 4) = 34;  /* closing quote */
doc = substr(literal_utf8, 0, 5);
call check_int('decode_string passes literal (non-escaped) UTF-8 through',
    length(json_decode_string(doc, 0, length(doc))), 3);

/* --- json_encode_string ------------------------------------------ */

call check_str('encode_string escapes quotes and backslashes',
    json_encode_string('', 'a"b\c'), '"a\"b\\c"');

call check_str('encode_string passes ordinary text through unescaped',
    json_encode_string('', 'counter:get'), '"counter:get"');

/* --- json_find_member --------------------------------------------- */

doc = '{"status":"success","value":{"n":1},"logLines":["a","b"]}';
found = json_find_member(doc, 1, 'value');
call check_int('find_member locates a nested object member', found, 1);
call check_str('find_member returns the exact source span for the value',
    substr(doc, g_span_start, g_span_end - g_span_start), '{"n":1}');

found = json_find_member(doc, 1, 'logLines');
call check_str('find_member locates a later member after a nested one',
    substr(doc, g_span_start, g_span_end - g_span_start), '["a","b"]');

found = json_find_member(doc, 1, 'missing');
call check_int('find_member reports a missing key as not found', found, 0);

/* --- convex_configure --------------------------------------------- */

found = convex_configure('https://api.example.com/deployment');
call check_int('configure accepts https', found, 1);
call check_int('configure defaults https to port 443', g_convex_port, 443);
call check_str('configure captures the host', g_convex_host,
    'api.example.com');
call check_str('configure captures the path prefix', g_convex_prefix,
    '/deployment');

found = convex_configure('http://127.0.0.1:3210');
call check_int('configure accepts an explicit port', found, 1);
call check_int('configure parses the explicit port', g_convex_port, 3210);
call check_str('configure defaults the prefix to empty', g_convex_prefix, '');

found = convex_configure('ftp://nope');
call check_int('configure rejects an unsupported scheme', found, 0);

/* --- parse_uint ----------------------------------------------------- */

doc = '2097152';
call check_int('parse_uint reads a plain decimal integer',
    parse_uint(doc, 0, length(doc)), 2097152);

doc = '12x';
call check_int('parse_uint rejects a non-digit byte', parse_uint(doc, 0, 3), -1);

/* --- find_header_end / extract_content_length ----------------------- */

doc = 'HTTP/1.1 200 OK' || CRLF || 'content-length: 11' || CRLF || CRLF ||
    'hello world';
endpos = find_header_end(doc);
call check_int('find_header_end locates the blank line', endpos,
    length(doc) - 11);
found = extract_content_length(doc, endpos);
call check_int('extract_content_length is case-insensitive', found, 1);
call check_int('extract_content_length parses the byte count',
    g_response_content_length, 11);

if failures = 0 then do;
    output = 'all client tests passed';
end;
else do;
    output = failures || ' client test(s) failed';
    call exit(1);
end;
eof
