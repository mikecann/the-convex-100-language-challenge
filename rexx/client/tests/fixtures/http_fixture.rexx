/* Loopback HTTP fixture for client/tests/http_test.rexx.
 *
 * Listens on 127.0.0.1:<port>, accepts exactly one connection, reads and
 * discards the request (up to the blank line that ends the headers, plus
 * any declared Content-Length body), then writes back the exact bytes
 * from <responseFile> verbatim. This is a real TCP peer, not a mock of
 * http_call: it exercises convex.rexx's actual RXCONNECT/RXSEND/RXRECV
 * transport and HTTP response parsing (Content-Length, chunked, and
 * close-terminated bodies) end to end.
 *
 * This is test-only infrastructure. It duplicates convex.rexx's small
 * shim-registration step because each program is its own OS process with
 * its own RXFUNCADD table; it does not duplicate any Convex protocol
 * logic.
 */
call rxfuncadd 'RXLISTEN', 'convexshim', 'RXLISTEN'
call rxfuncadd 'RXACCEPT', 'convexshim', 'RXACCEPT'
call rxfuncadd 'RXSEND', 'convexshim', 'RXSEND'
call rxfuncadd 'RXRECV', 'convexshim', 'RXRECV'
call rxfuncadd 'RXCLOSE', 'convexshim', 'RXCLOSE'

parse arg port responseFile

listenResult = RXLISTEN('127.0.0.1', port)
if left(listenResult, 1) <> 'K' then do
  call lineout 'stderr', 'http_fixture: listen failed:' substr(listenResult, 3)
  exit 1
end
listenHandle = substr(listenResult, 3)

/* Tell the test driver the fixture is actually listening before it tries
 * to connect, rather than relying on a fixed sleep. */
call lineout 'stdout', 'READY'
call stream 'stdout', 'c', 'flush'

acceptResult = RXACCEPT(listenHandle, 10000)
if left(acceptResult, 1) <> 'K' then do
  call lineout 'stderr', 'http_fixture: accept failed:' substr(acceptResult, 3)
  exit 1
end
handle = substr(acceptResult, 3)

/* Read until the request's blank line; a real client's exact byte count
 * does not matter to this fixture, only that it stops waiting once the
 * request looks complete enough to answer. */
buf = ''
do while pos('0d0a0d0a'x, buf) == 0
  chunk = RXRECV(handle, 65536, 5000)
  if left(chunk, 1) == 'D' then buf = buf || substr(chunk, 3)
  else leave
end

/* A raw byte read (not linein/lines) so the response file's own \r\n
 * bytes reach the socket exactly as written, with no EOL translation. */
responseSize = chars(responseFile)
responseText = charin(responseFile, 1, responseSize)
call stream responseFile, 'c', 'close'

call RXSEND handle, responseText
call RXCLOSE handle
call RXCLOSE listenHandle
exit 0
