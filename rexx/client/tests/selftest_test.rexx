/* Runs convex.rexx's own selftest operation, which exercises the JSON
 * codec, crypto, WebSocket framing, HTTP response classification, and
 * Live state-surgery helpers directly -- see the "Self-test" section at
 * the bottom of client/convex.rexx for why this lives inside the client
 * file itself rather than duplicating that logic here. */
call '/opt/convex/client/convex.rexx' 'selftest'
say 'convex.rexx selftest:' result
if result <> 'PASS' then exit 1
exit 0
