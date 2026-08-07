NB. Convex from J: the shared counter journey.
NB.
NB. The program reads a room's counter over Convex's documented HTTP API,
NB. starts a Live subscription, increments the counter once, and proves
NB. that the Live subscription reported the same change without polling.
NB.
NB. Run it with:  CONVEX_URL=https://<deployment>.convex.cloud convex-example <room>

load '/project/client/live.ijs'

NB. Convex returns the room state as a JSON object. This narrows it to the
NB. non-negative integer the output contract needs, and refuses anything
NB. else -- including a fractional or out-of-range count that happened to
NB. arrive as valid JSON.
example_count=: 3 : 0
  'value operation'=. y
  'pok root'=. cx_unpack2 cx_json_parse value
  if. -. pok do. example_fail operation,' did not return a Convex object' return. end.
  if. -. 'o' -: jtag root do. example_fail operation,' did not return a Convex object' return. end.
  node=. root jfind 'count'
  if. node = _1 do. example_fail operation,' returned no count' return. end.
  if. -. 'n' -: jtag > node do. example_fail operation,' returned no count' return. end.
  literal=. jpay > node
  NB. Convex JSON may encode an integral number as 0 or as 0.0. Both are
  NB. accepted; fractional, non-finite, and out-of-range values are not.
  if. -. convex_integral literal do.
    example_fail operation,' returned a non-integral or negative count' return.
  end.
  count=. ". literal
  if. count < 0 do.
    example_fail operation,' returned a non-integral or negative count' return.
  end.
  count
)

NB. One failure channel. Diagnostics belong on stderr so that stdout stays
NB. the exact shared transcript.
example_fail=: 3 : 0
  EXAMPLE_FAILED=: 1
  msg=. 'J example failed: ', y, LF
  write_J 2;msg;(# msg)
  _1
)

NB. Wait for the next value this subscription publishes, and surface a
NB. reactive query failure as a failure rather than as a missing value.
example_next=: 3 : 0
  'tag operation deadline'=. y
  while. 1 do.
    cx_live_pump 200
    'ok utag value logs errname errmsg errdata'=. cx_live_next_update ''
    if. ok do.
      if. utag -: tag do.
        if. 0 < # errname do.
          example_fail operation,': ',errmsg return.
        end.
        example_count value;operation return.
      end.
    end.
    if. (tx_remaining deadline) = 0 do.
      example_fail operation,': timed out waiting for a Live update' return.
    end.
  end.
)

NB. Close the Live socket and drop every subscription within a bounded
NB. budget, so a stalled deployment cannot keep the example running.
example_shutdown=: 3 : 0
  status=. y
  cx_live_close 2000
  if. status < 0 do. 1 return. end.
  status
)

example_main=: 3 : 0
  EXAMPLE_FAILED=: 0
  cx_live_reset ''
  url=. tx_getenv 'CONVEX_URL'
  if. 0 = # url do. example_fail 'CONVEX_URL is required' return. end.

  NB. The verifier passes a unique room as the first argument; the literal
  NB. default only makes a hand run convenient.
  room=. 'j-example'
  argv=. ARGV
  if. 2 < # argv do. room=. > 2 { argv end.

  if. -. convex_open url;'j-0.1.0' do.
    example_shutdown example_fail convex_error_message ''
    return.
  end.
  args=. '{"room":',(jw_quote room),'}'

  NB. Read the current value through Convex's documented HTTP query
  NB. endpoint.
  'qok qvalue qlogs'=. convex_query 'demo:state';args
  if. -. qok do.
    example_shutdown example_fail 'query: ', convex_error_message ''
    return.
  end.
  current=. example_count qvalue;'current query'
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  echo 'current count: ', ": current

  NB. Start Live before mutating. Subscribing first is what makes the
  NB. update below an observation rather than a race.
  sok=. cx_live_subscribe (<'counter'),(<'demo:state'),(<args)
  if. -. sok do.
    example_shutdown example_fail 'subscribe: ', convex_error_message ''
    return.
  end.

  NB. The first Live value hydrates the same state the HTTP query
  NB. returned.
  initial=. example_next 'counter';'initial Live value';(tx_now_ms '')+15000
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  if. initial ~: current do.
    example_shutdown example_fail 'the initial Live count disagreed with HTTP'
    return.
  end.
  echo 'live initial count: ', ": initial

  NB. runId is the mutation's idempotency key. Convex records it, so a
  NB. repeated run of the same key returns the previous result instead of
  NB. incrementing twice. A fresh random key means this run really applies
  NB. its increment.
  runid=. tx_uuid ''
  mutargs=. '{"room":',(jw_quote room),',"language":"j","runId":',(jw_quote runid),'}'
  'mok mvalue mlogs'=. convex_mutation 'demo:increment';mutargs
  if. -. mok do.
    example_shutdown example_fail 'mutation: ', convex_error_message ''
    return.
  end.

  'pok mroot'=. cx_unpack2 cx_json_parse mvalue
  applied=. 0
  statecount=. _1
  if. pok do.
    if. 'o' -: jtag mroot do.
      appliednode=. mroot jfind 'applied'
      if. appliednode ~: _1 do.
        if. 't' -: jtag > appliednode do. applied=. 1 end.
      end.
      statenode=. mroot jfind 'state'
      if. statenode ~: _1 do.
        statecount=. example_count (cx_json_encode > statenode);'mutation'
      end.
    end.
  end.
  if. -. applied do.
    example_shutdown example_fail 'the mutation was not applied'
    return.
  end.
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.

  expected=. current + 1
  if. statecount ~: expected do.
    example_shutdown example_fail 'the mutation returned an unexpected count'
    return.
  end.
  echo 'mutation applied: true'
  echo 'mutation count: ', ": statecount

  NB. Receive the same change over Live, without polling HTTP again.
  updated=. example_next 'counter';'updated Live value';(tx_now_ms '')+15000
  if. EXAMPLE_FAILED do. example_shutdown _1 return. end.
  if. updated ~: expected do.
    example_shutdown example_fail 'the updated Live count disagreed with the mutation'
    return.
  end.
  echo 'live updated count: ', ": updated

  NB. Every operation agreed before this proof line is printed.
  echo 'verified count: ', (": current), ' -> ', ": updated
  example_shutdown 0
)

exit example_main ''
