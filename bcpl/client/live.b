// live.b -- the Convex sync protocol: reactive subscriptions over WebSocket.
//
// Ownership. BCPL has no threads, so exclusive ownership of the socket is
// structural rather than enforced by a lock: exactly one record, the Live
// manager, holds the connection, the query-set version and every reconnect
// decision, and it is only ever advanced from lvStep. Subscribing,
// unsubscribing and the adapter's debugDisconnect all record their intent on
// that record; none of them touches the socket concurrently, because there is
// no concurrency to protect against. What that buys is the same guarantee a
// locked owner gives: no two pieces of code can interleave a write, a
// reconnect and a query-set version bump.
//
// Atomicity. A Transition is applied in three passes. The first validates
// every modification and stages the delivery it would produce, allocating
// everything it needs; the second commits the query-set version and the
// timestamp; the third publishes. A Transition that turns out to be malformed
// halfway through, or that this client cannot hold in memory, therefore
// publishes nothing at all and leaves the version where it was, instead of
// delivering its first half and then reporting drift.
//
// Delivery. Each subscription owns a bounded queue, and the manager owns the
// bound that actually holds: sixteen subscriptions at most, one megabyte of
// queued updates across all of them together, and 256 KiB in any one of them.
// A value too large to hold inside that budget is reported as an error, not
// queued past the bound and not silently dropped.
//
// Generations. Unsubscribing, or replacing a subscription with the same
// identifier, bumps a generation counter. A relay that was already dequeued
// carries the old generation and is discarded on the way out, so no stale
// value can cross the acknowledgement that retired it.
//
// Failure. Nothing here turns an allocation this client could not satisfy into
// a successful empty value. Every staging step that fails refuses the whole
// Transition, which the caller reports as drift and recovers from by
// reconnecting.

LET upNew() = VALOF
{ LET update = getvec(Up_upb)
  UNLESS update RESULTIS 0
  FOR field = 0 TO Up_upb DO update!field := 0
  RESULTIS update
}

AND upFree(update) BE
{ UNLESS update RETURN
  IF update!Up_value DO jsFree(update!Up_value)
  IF update!Up_errname DO bbFree(update!Up_errname)
  IF update!Up_errmsg DO bbFree(update!Up_errmsg)
  IF update!Up_errdata DO jsFree(update!Up_errdata)
  IF update!Up_logs DO
  { FOR index = 0 TO (update!Up_logs)!Vl_len - 1 DO
      bbFree(vlGet(update!Up_logs, index))
    vlFree(update!Up_logs)
  }
  freevec(update)
}

// A staged delivery: the subscription it belongs to, the update it will
// publish, and the serialised text a later reconnect compares against.
// Takes ownership of `update` and `text` on every path.
AND pnNew(subscription, update, text) = VALOF
{ LET pending = getvec(Pn_upb)
  UNLESS pending DO { upFree(update); bbFree(text); RESULTIS 0 }
  pending!Pn_sub := subscription
  pending!Pn_update := update
  pending!Pn_text := text
  RESULTIS pending
}

AND lvFreePending(pending) BE
{ UNLESS pending RETURN
  IF pending!Pn_update DO upFree(pending!Pn_update)
  IF pending!Pn_text DO bbFree(pending!Pn_text)
  freevec(pending)
}

AND lvFreeStaged(staged) BE
{ UNLESS staged RETURN
  FOR index = 0 TO staged!Vl_len - 1 DO lvFreePending(vlGet(staged, index))
  vlFree(staged)
}

// The aggregate queued-byte count, kept on the manager because a per
// subscription bound multiplied by an unbounded number of subscriptions is not
// a bound at all.
AND lvAccount(manager, delta) BE
{ UNLESS manager RETURN
  manager!Lv_queuebytes := manager!Lv_queuebytes + delta
  IF manager!Lv_queuebytes < 0 DO manager!Lv_queuebytes := 0
}

// Make room for `needed` bytes across every subscription, always at the
// expense of the queue holding the most, and always the oldest value in it.
AND lvReclaim(manager, needed) BE
{ UNLESS manager RETURN
  UNTIL manager!Lv_queuebytes + needed <= Maxlivequeuebytes DO
  { LET victim = 0
    LET most = 0
    LET oldest = 0
    FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
    { LET candidate = vlGet(manager!Lv_subs, index)
      IF (candidate!Sb_queue)!Vl_len > 0 DO
        IF candidate!Sb_queuebytes >= most DO
        { most := candidate!Sb_queuebytes
          victim := candidate
        }
    }
    IF victim = 0 DO BREAK
    oldest := vlShift(victim!Sb_queue)
    victim!Sb_queuebytes := victim!Sb_queuebytes - oldest!Up_bytes
    lvAccount(manager, -(oldest!Up_bytes))
    upFree(oldest)
  }
}

AND sbSetLastText(subscription, text) BE
{ IF subscription!Sb_lasttext DO bbFree(subscription!Sb_lasttext)
  subscription!Sb_lasttext := text
}

AND sbFree(manager, subscription) BE
{ UNLESS subscription RETURN
  bbFree(subscription!Sb_subid)
  bbFree(subscription!Sb_path)
  IF subscription!Sb_args DO jsFree(subscription!Sb_args)
  IF subscription!Sb_lasttext DO bbFree(subscription!Sb_lasttext)
  IF subscription!Sb_queue DO
  { FOR index = 0 TO (subscription!Sb_queue)!Vl_len - 1 DO
      upFree(vlGet(subscription!Sb_queue, index))
    vlFree(subscription!Sb_queue)
  }
  lvAccount(manager, -(subscription!Sb_queuebytes))
  freevec(subscription)
}

// Queue an update, dropping the oldest when any of the three bounds -- this
// subscription's count, this subscription's bytes, or the manager's aggregate
// -- would otherwise be exceeded.
AND sbDeliver(manager, subscription, update) BE
{ LET queue = subscription!Sb_queue
  UNTIL queue!Vl_len < Maxqueueupdates DO
  { LET oldest = vlShift(queue)
    subscription!Sb_queuebytes := subscription!Sb_queuebytes - oldest!Up_bytes
    lvAccount(manager, -(oldest!Up_bytes))
    upFree(oldest)
  }
  UNTIL subscription!Sb_queuebytes + update!Up_bytes <= Maxqueuebytes DO
  { LET oldest = 0
    IF queue!Vl_len = 0 DO BREAK
    oldest := vlShift(queue)
    subscription!Sb_queuebytes := subscription!Sb_queuebytes - oldest!Up_bytes
    lvAccount(manager, -(oldest!Up_bytes))
    upFree(oldest)
  }
  lvReclaim(manager, update!Up_bytes)
  UNLESS vlPush(queue, update) DO { upFree(update); RETURN }
  subscription!Sb_queuebytes := subscription!Sb_queuebytes + update!Up_bytes
  lvAccount(manager, update!Up_bytes)
}

// Hand the next live update to the consumer, discarding anything left over
// from a retired generation.
AND sbTake(manager, subscription) = VALOF
{ LET queue = subscription!Sb_queue
  UNTIL queue!Vl_len = 0 DO
  { LET update = vlShift(queue)
    subscription!Sb_queuebytes := subscription!Sb_queuebytes - update!Up_bytes
    lvAccount(manager, -(update!Up_bytes))
    IF update!Up_generation = subscription!Sb_generation RESULTIS update
    upFree(update)
  }
  RESULTIS 0
}

AND lvNew(endpoint, version) = VALOF
{ LET manager = getvec(Lv_upb)
  LET session = VEC 3
  UNLESS manager RESULTIS 0
  FOR field = 0 TO Lv_upb DO manager!field := 0
  manager!Lv_ep := endpoint
  manager!Lv_version := version
  manager!Lv_subs := vlNew(8)
  manager!Lv_lastclose := bbFromStr("InitialConnect")
  manager!Lv_maxts := bbFromStr("AAAAAAAAAAA=")
  manager!Lv_remotets := bbFromStr("AAAAAAAAAAA=")
  manager!Lv_sessionid := bbNew(40)
  manager!Lv_backoff := Backoffbasems
  manager!Lv_nextattempt := 0
  manager!Lv_nextqueryid := 0
  IF manager!Lv_subs = 0 DO { lvFree(manager); RESULTIS 0 }
  IF manager!Lv_lastclose = 0 DO { lvFree(manager); RESULTIS 0 }
  IF manager!Lv_maxts = 0 DO { lvFree(manager); RESULTIS 0 }
  IF manager!Lv_remotets = 0 DO { lvFree(manager); RESULTIS 0 }
  IF manager!Lv_sessionid = 0 DO { lvFree(manager); RESULTIS 0 }
  // A session identifier is 16 random bytes rendered as hexadecimal.
  UNLESS cxRandomBytes(session, 0, 16) DO { lvFree(manager); RESULTIS 0 }
  FOR index = 0 TO 15 DO
  { bbPushHexDigit(manager!Lv_sessionid, shr32(session%index, 4))
    bbPushHexDigit(manager!Lv_sessionid, session%index)
  }
  RESULTIS manager
}

AND lvFree(manager) BE
{ UNLESS manager RETURN
  IF manager!Lv_ws DO wsFree(manager!Lv_ws)
  IF manager!Lv_subs DO
  { FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
      sbFree(manager, vlGet(manager!Lv_subs, index))
    vlFree(manager!Lv_subs)
  }
  bbFree(manager!Lv_lastclose)
  bbFree(manager!Lv_maxts)
  bbFree(manager!Lv_remotets)
  bbFree(manager!Lv_sessionid)
  freevec(manager)
}

AND lvFindSub(manager, subid) = VALOF
{ FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
  { LET subscription = vlGet(manager!Lv_subs, index)
    IF bbEqual(subscription!Sb_subid, subid) RESULTIS subscription
  }
  RESULTIS 0
}

AND lvFindByQueryId(manager, queryid) = VALOF
{ FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
  { LET subscription = vlGet(manager!Lv_subs, index)
    IF subscription!Sb_queryid = queryid RESULTIS subscription
  }
  RESULTIS 0
}

AND lvResetVersions(manager) BE
{ LET fresh = bbFromStr("AAAAAAAAAAA=")
  manager!Lv_queryversion := 0
  manager!Lv_remotequery := 0
  manager!Lv_remoteident := 0
  IF fresh ~= 0 DO
  { bbFree(manager!Lv_remotets)
    manager!Lv_remotets := fresh
  }
}

// Retire the current connection. `reason` becomes lastCloseReason, which the
// next Connect reports back to the server, and the connection count advances
// so the server can tell a genuine reconnect from a duplicate session.
//
// Every retirement goes through here so the three pieces of bookkeeping can
// never drift apart. `graceful` decides between the RFC 6455 closing
// handshake, used when the client is finished with a healthy connection, and
// an immediate teardown, used when the connection has already failed or is
// being deliberately broken. Both are bounded: the handshake by
// Closetimeoutms, the teardown by nothing at all.
AND lvRetire(manager, reason, graceful) BE
{ LET connection = manager!Lv_ws
  LET recorded = 0
  UNLESS connection RETURN
  // Clear the field first, so nothing reached from the close path can find a
  // connection that is already being torn down.
  manager!Lv_ws := 0
  TEST graceful
  THEN wsCloseGracefully(connection, cxDeadline(Closetimeoutms))
  ELSE wsFree(connection)
  manager!Lv_conncount := manager!Lv_conncount + 1
  // Keep the old reason rather than losing both if the new one cannot be
  // allocated: the next Connect has to carry something the server can read.
  recorded := bbFromStr(reason)
  IF recorded ~= 0 DO
  { bbFree(manager!Lv_lastclose)
    manager!Lv_lastclose := recorded
  }
  lvResetVersions(manager)
}

AND lvDropConnection(manager, reason) BE lvRetire(manager, reason, FALSE)

AND lvBackoffAfterFailure(manager) BE
{ manager!Lv_backoff := manager!Lv_backoff * 2
  IF manager!Lv_backoff > Backoffmaxms DO
    manager!Lv_backoff := Backoffmaxms
  IF manager!Lv_backoff < Backoffbasems DO
    manager!Lv_backoff := Backoffbasems
  manager!Lv_nextattempt := cxNow() + manager!Lv_backoff
}

// Every put here is checked. jsObjectPut frees the child it could not store,
// so the arguments array is built immediately before its own put rather than
// up front: that is what keeps an earlier failure from leaking it and a later
// one from freeing it twice.
AND lvMakeAdd(subscription) = VALOF
{ LET modification = jsObject()
  LET ok = TRUE
  UNLESS modification RESULTIS 0
  ok := jsObjectPutStr(modification, "type", jsStringFromStr("Add"))
  IF ok DO ok := jsObjectPutStr(modification, "queryId",
                                jsNumberFromInt(subscription!Sb_queryid))
  IF ok DO ok := jsObjectPutStr(modification, "udfPath",
                                jsStringFromBuffer(
                                  bbCopy(subscription!Sb_path)))
  IF ok DO
  { LET arguments = jsArray()
    TEST arguments = 0
    THEN ok := FALSE
    ELSE
    { UNLESS jsArrayPush(arguments, jsClone(subscription!Sb_args)) DO
      { jsFree(arguments); ok := FALSE }
      IF ok DO ok := jsObjectPutStr(modification, "args", arguments)
    }
  }
  UNLESS ok DO { jsFree(modification); RESULTIS 0 }
  RESULTIS modification
}

AND lvMakeRemove(queryid) = VALOF
{ LET modification = jsObject()
  LET ok = TRUE
  UNLESS modification RESULTIS 0
  ok := jsObjectPutStr(modification, "type", jsStringFromStr("Remove"))
  IF ok DO ok := jsObjectPutStr(modification, "queryId",
                                jsNumberFromInt(queryid))
  UNLESS ok DO { jsFree(modification); RESULTIS 0 }
  RESULTIS modification
}

// Send one ModifyQuerySet carrying `modifications` (ownership passes here) and
// advance the local query-set version. Every version change goes through this
// one place, so base and new versions can never drift apart.
AND lvSendModifications(manager, modifications, deadline) = VALOF
{ LET envelope = jsObject()
  LET text = 0
  LET sent = FALSE
  LET ok = TRUE
  IF modifications = 0 RESULTIS FALSE
  IF jsCount(modifications) = 0 DO { jsFree(modifications); RESULTIS TRUE }
  UNLESS envelope DO { jsFree(modifications); RESULTIS FALSE }
  ok := jsObjectPutStr(envelope, "type", jsStringFromStr("ModifyQuerySet"))
  IF ok DO ok := jsObjectPutStr(envelope, "baseVersion",
                                jsNumberFromInt(manager!Lv_queryversion))
  IF ok DO ok := jsObjectPutStr(envelope, "newVersion",
                                jsNumberFromInt(manager!Lv_queryversion + 1))
  TEST ok
  THEN ok := jsObjectPutStr(envelope, "modifications", modifications)
  ELSE jsFree(modifications)
  UNLESS ok DO { jsFree(envelope); RESULTIS FALSE }
  text := jsSerialise(envelope)
  jsFree(envelope)
  UNLESS text RESULTIS FALSE
  sent := wsSendText(manager!Lv_ws, text, deadline)
  bbFree(text)
  IF sent DO manager!Lv_queryversion := manager!Lv_queryversion + 1
  RESULTIS sent
}

// Announce a freshly established connection and re-establish every active
// subscription on it. Split out from lvOpen so a test can drive it over a
// socket pair and read exactly what goes on the wire.
AND lvAnnounce(manager, deadline) = VALOF
{ LET envelope = jsObject()
  LET text = 0
  LET modifications = 0
  LET ok = TRUE
  UNLESS envelope RESULTIS FALSE
  ok := jsObjectPutStr(envelope, "type", jsStringFromStr("Connect"))
  IF ok DO ok := jsObjectPutStr(envelope, "sessionId",
                                jsStringFromBuffer(
                                  bbCopy(manager!Lv_sessionid)))
  IF ok DO ok := jsObjectPutStr(envelope, "connectionCount",
                                jsNumberFromInt(manager!Lv_conncount))
  IF ok DO ok := jsObjectPutStr(envelope, "lastCloseReason",
                                jsStringFromBuffer(
                                  bbCopy(manager!Lv_lastclose)))
  // Reporting the highest timestamp already seen lets the server resume rather
  // than replay, which is what keeps a reconnect from looking like a change.
  // On a first connection there is nothing to report, and the reference
  // clients omit the field rather than announcing the zero timestamp, so this
  // one does too.
  IF ok DO
    UNLESS bbEqualStr(manager!Lv_maxts, "AAAAAAAAAAA=") DO
      ok := jsObjectPutStr(envelope, "maxObservedTimestamp",
                           jsStringFromBuffer(bbCopy(manager!Lv_maxts)))
  IF ok DO ok := jsObjectPutStr(envelope, "clientTs", jsNumberFromInt(0))
  UNLESS ok DO { jsFree(envelope); RESULTIS FALSE }
  text := jsSerialise(envelope)
  jsFree(envelope)
  UNLESS text RESULTIS FALSE
  UNLESS wsSendText(manager!Lv_ws, text, deadline) DO
  { bbFree(text); RESULTIS FALSE }
  bbFree(text)

  modifications := jsArray()
  UNLESS modifications RESULTIS FALSE
  FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
  { LET subscription = vlGet(manager!Lv_subs, index)
    IF subscription!Sb_active DO
    { // An Add this client could not build must not be quietly missing from
      // the replayed query set: the connection would then be watching fewer
      // queries than the consumer believes it is.
      UNLESS jsArrayPush(modifications, lvMakeAdd(subscription)) DO
      { jsFree(modifications); RESULTIS FALSE }
      // The first value after a reconnect is usually the same value the
      // consumer already has; mark it so an unchanged rehydration is dropped.
      subscription!Sb_rehydrate := TRUE
    }
  }
  RESULTIS lvSendModifications(manager, modifications, deadline)
}

// Open a connection, announce it, and re-establish every active subscription.
//
// Connecting gets its own budget rather than the caller's slice. lvStep is
// normally driven with a few milliseconds at a time so that controller traffic
// stays responsive, and a handshake cannot happen inside that; clamping to the
// slice would mean the connection never completed at all.
AND lvOpen(manager, deadline) BE
{ LET connectdeadline = cxDeadline(Connecttimeoutms)
  LET connection = 0

  connection := wsConnect(manager!Lv_ep, "/api/sync", manager!Lv_version,
                          connectdeadline)
  UNLESS connection DO { lvBackoffAfterFailure(manager); RETURN }
  manager!Lv_ws := connection
  lvResetVersions(manager)

  UNLESS lvAnnounce(manager, connectdeadline) DO
  { lvDropConnection(manager, "TransportError")
    lvBackoffAfterFailure(manager)
    RETURN
  }

  // A completed handshake means the network is healthy again, so a later
  // failure starts from the base interval instead of inheriting an old
  // maximum delay.
  manager!Lv_backoff := Backoffbasems
  manager!Lv_nextattempt := 0
}

// Retire one subscription without deciding anything about the connection. The
// generation bump happens before anything else, so a value already dequeued
// for this subscription can no longer be published.
AND lvRetireSubscription(manager, subscription) BE
{ LET position = -1
  UNLESS subscription RETURN
  subscription!Sb_generation := subscription!Sb_generation + 1
  subscription!Sb_active := FALSE
  FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
    IF vlGet(manager!Lv_subs, index) = subscription DO
    { position := index; BREAK }
  IF manager!Lv_ws DO
  { LET modifications = jsArray()
    IF modifications ~= 0 DO
    { UNLESS jsArrayPush(modifications, lvMakeRemove(subscription!Sb_queryid))
      DO { jsFree(modifications)
           lvDropConnection(manager, "TransportError")
           modifications := 0
         }
      IF modifications ~= 0 DO
        UNLESS lvSendModifications(manager, modifications,
                                   cxDeadline(Closetimeoutms)) DO
          lvDropConnection(manager, "TransportError")
    }
  }
  IF position >= 0 DO vlRemoveAt(manager!Lv_subs, position)
  sbFree(manager, subscription)
}

// Takes ownership of `subid`, `path` and `args` on every path, including the
// failing ones. Split ownership is how a caller ends up either leaking a
// subscription identifier or freeing one the manager still holds.
AND lvSubscribe(manager, subid, path, args) = VALOF
{ LET subscription = 0
  LET existing = 0
  IF subid = 0 DO { bbFree(path); jsFree(args); RESULTIS 0 }

  // Replacing a live subscription with the same identifier retires the old one
  // first -- generation bump, Remove on the wire, queue discarded -- so no
  // value from the previous query can ever be published under the new one.
  // The barrier lives here rather than in the conformance adapter, because a
  // rule that only the test harness applies is not a rule the client has.
  existing := lvFindSub(manager, subid)
  IF existing ~= 0 DO lvRetireSubscription(manager, existing)

  IF (manager!Lv_subs)!Vl_len >= Maxsubscriptions DO
  { errSetStr(Ek_protocol, "ProtocolError",
              "this client holds as many subscriptions as its budget bounds")
    bbFree(subid)
    bbFree(path)
    jsFree(args)
    RESULTIS 0
  }

  subscription := getvec(Sb_upb)
  UNLESS subscription DO
  { errSetStr(Ek_internal, "InternalError",
              "the Convex subscription could not be allocated")
    bbFree(subid); bbFree(path); jsFree(args); RESULTIS 0 }
  FOR field = 0 TO Sb_upb DO subscription!field := 0
  subscription!Sb_queryid := manager!Lv_nextqueryid
  manager!Lv_nextqueryid := manager!Lv_nextqueryid + 1
  subscription!Sb_subid := subid
  subscription!Sb_path := path
  subscription!Sb_args := args
  subscription!Sb_generation := 1
  subscription!Sb_queue := vlNew(8)
  subscription!Sb_active := TRUE
  UNLESS subscription!Sb_queue DO
  { errSetStr(Ek_internal, "InternalError",
              "the Convex subscription queue could not be allocated")
    sbFree(0, subscription)
    RESULTIS 0
  }
  UNLESS vlPush(manager!Lv_subs, subscription) DO
  { errSetStr(Ek_internal, "InternalError",
              "the Convex subscription could not be recorded")
    sbFree(0, subscription)
    RESULTIS 0
  }
  IF manager!Lv_ws DO
  { LET modifications = jsArray()
    IF modifications ~= 0 DO
    { UNLESS jsArrayPush(modifications, lvMakeAdd(subscription)) DO
      { jsFree(modifications)
        lvDropConnection(manager, "TransportError")
        modifications := 0
      }
      IF modifications ~= 0 DO
        UNLESS lvSendModifications(manager, modifications,
                                   cxDeadline(Closetimeoutms)) DO
          lvDropConnection(manager, "TransportError")
    }
  }
  RESULTIS subscription
}

// Retire a subscription and, when it was the last one, the connection too.
AND lvUnsubscribe(manager, subscription) BE
{ UNLESS subscription RETURN
  lvRetireSubscription(manager, subscription)
  // With nothing left to watch there is no reason to hold a socket open. The
  // connection is still healthy here, so it earns a real closing handshake
  // rather than a dropped TCP connection the deployment has to time out.
  IF (manager!Lv_subs)!Vl_len = 0 DO
    lvRetire(manager, "NoSubscriptions", TRUE)
}

// The adapter-only hook. The acknowledgement it enables must not be sent until
// the old connection is retired and the reconnect is scheduled, which is
// exactly the state this leaves behind.
AND lvDisconnectForAdapter(manager) = VALOF
{ UNLESS manager!Lv_ws RESULTIS FALSE
  lvDropConnection(manager, "DebugDisconnect")
  FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
    (vlGet(manager!Lv_subs, index))!Sb_rehydrate := TRUE
  manager!Lv_backoff := Backoffbasems
  manager!Lv_nextattempt := cxNow()
  RESULTIS TRUE
}

AND lvClose(manager) BE
{ UNLESS manager RETURN
  lvRetire(manager, "ClientClosed", TRUE)
  lvFree(manager)
}

// ---------------------------------------------------------------------------
// Timestamps
//
// The protocol's ts field is a base64 little-endian unsigned 64-bit value.
// Comparing the encoded strings, or the raw bytes left to right, would order
// them wrongly, so both sides are decoded and compared from the most
// significant byte down. Anything that is not exactly eight decoded bytes is
// not a timestamp at all and is refused rather than compared as if it were.
// ---------------------------------------------------------------------------

AND lvDecodeTimestamp(buffer, out) = VALOF
{ UNLESS buffer RESULTIS FALSE
  UNLESS out RESULTIS FALSE
  bbClear(out)
  UNLESS base64Decode(buffer!Bb_vec, 0, buffer!Bb_len, out) RESULTIS FALSE
  RESULTIS out!Bb_len = 8
}

AND lvTimestampValid(buffer) = VALOF
{ LET raw = bbNew(16)
  LET ok = FALSE
  UNLESS raw RESULTIS FALSE
  ok := lvDecodeTimestamp(buffer, raw)
  bbFree(raw)
  RESULTIS ok
}

// Returns 1, 0 or -1 for two decodable timestamps, and Tsinvalid when either
// side is not one. Tsinvalid is deliberately not an ordering: a caller that
// treats it as "less than" would accept a malformed timestamp as older.
AND lvCompareTimestamps(left, right) = VALOF
{ LET leftbytes = bbNew(16)
  LET rightbytes = bbNew(16)
  LET result = 0
  LET decoded = FALSE
  IF leftbytes = 0 DO { bbFree(rightbytes); RESULTIS Tsinvalid }
  IF rightbytes = 0 DO { bbFree(leftbytes); RESULTIS Tsinvalid }
  decoded := lvDecodeTimestamp(left, leftbytes)
  IF decoded DO decoded := lvDecodeTimestamp(right, rightbytes)
  TEST decoded
  THEN FOR index = 7 TO 0 BY -1 DO
       { LET a = bbGet(leftbytes, index)
         LET b = bbGet(rightbytes, index)
         IF a > b DO { result := 1; BREAK }
         IF a < b DO { result := -1; BREAK }
       }
  ELSE result := Tsinvalid
  bbFree(leftbytes)
  bbFree(rightbytes)
  RESULTIS result
}

AND lvNoteTimestamp(manager, timestamp) BE
{ UNLESS timestamp RETURN
  IF lvCompareTimestamps(timestamp, manager!Lv_maxts) > 0 DO
  { LET copy = bbCopy(timestamp)
    IF copy ~= 0 DO
    { bbFree(manager!Lv_maxts)
      manager!Lv_maxts := copy
    }
  }
}

AND lvVersionMatches(manager, version) = VALOF
{ LET queryset = 0
  LET identity = 0
  LET timestamp = 0
  IF version = 0 RESULTIS FALSE
  UNLESS jsWholeNumber(jsObjectGet(version, "querySet"), @queryset) DO
    RESULTIS FALSE
  UNLESS jsWholeNumber(jsObjectGet(version, "identity"), @identity) DO
    RESULTIS FALSE
  timestamp := jsObjectGet(version, "ts")
  IF timestamp = 0 RESULTIS FALSE
  UNLESS timestamp!Js_type = Jt_string RESULTIS FALSE
  UNLESS lvTimestampValid(timestamp!Js_a) RESULTIS FALSE
  UNLESS queryset = manager!Lv_remotequery RESULTIS FALSE
  UNLESS identity = manager!Lv_remoteident RESULTIS FALSE
  RESULTIS lvCompareTimestamps(timestamp!Js_a, manager!Lv_remotets) = 0
}

// ---------------------------------------------------------------------------
// Staging and delivery
// ---------------------------------------------------------------------------

AND lvFreeLogs(logs) BE
{ UNLESS logs RETURN
  FOR index = 0 TO logs!Vl_len - 1 DO bbFree(vlGet(logs, index))
  vlFree(logs)
}

// Takes ownership of `message`, `data` and `logs`. Returns 0 when the delivery
// could not be built, which is a refusal, never an empty success.
AND lvStageError(manager, subscription, name, message, data, logs) = VALOF
{ LET update = upNew()
  IF update = 0 DO
  { bbFree(message); jsFree(data); lvFreeLogs(logs); RESULTIS 0 }
  update!Up_generation := subscription!Sb_generation
  update!Up_errname := bbFromStr(name)
  update!Up_errmsg := message
  update!Up_errdata := data
  update!Up_logs := logs
  update!Up_bytes := 512
  IF message DO update!Up_bytes := update!Up_bytes + message!Bb_len
  IF update!Up_errname = 0 DO { upFree(update); RESULTIS 0 }
  IF update!Up_errmsg = 0 DO { upFree(update); RESULTIS 0 }
  RESULTIS pnNew(subscription, update, 0)
}

// Builds what a QueryUpdated will publish without publishing it. `value` stays
// with the caller's parsed message; `logs` is taken over on every path.
AND lvStageValue(manager, subscription, value, logs) = VALOF
{ LET text = 0
  LET clone = 0
  LET update = 0
  IF value = 0 DO { lvFreeLogs(logs); RESULTIS 0 }
  text := jsSerialise(value)
  IF text = 0 DO { lvFreeLogs(logs); RESULTIS 0 }
  // A value too large to hold inside the per-subscription byte budget is
  // reported as an error rather than queued past the bound this client
  // documents. Dropping it silently would look exactly like a query that
  // never updated.
  IF text!Bb_len + 128 > Maxqueuebytes DO
  { LET detail =
      bbFromStr("a Convex value exceeded this client's live retention budget")
    bbFree(text)
    RESULTIS lvStageError(manager, subscription, "ProtocolError", detail, 0,
                          logs)
  }
  clone := jsClone(value)
  IF clone = 0 DO { bbFree(text); lvFreeLogs(logs); RESULTIS 0 }
  update := upNew()
  IF update = 0 DO
  { jsFree(clone); bbFree(text); lvFreeLogs(logs); RESULTIS 0 }
  update!Up_generation := subscription!Sb_generation
  update!Up_value := clone
  update!Up_logs := logs
  update!Up_bytes := text!Bb_len + 128
  RESULTIS pnNew(subscription, update, text)
}

// Publish one staged delivery. This is the only place a value reaches a
// consumer, and for a Transition it runs only after every modification has
// been validated and the version committed.
AND lvCommitPending(manager, pending) BE
{ LET subscription = pending!Pn_sub
  LET update = pending!Pn_update
  LET text = pending!Pn_text
  pending!Pn_update := 0
  pending!Pn_text := 0
  TEST text = 0
  THEN
  { // A failed query invalidates the remembered value, so the repair that
    // follows is published even if it equals what was held before the failure.
    subscription!Sb_rehydrate := FALSE
    sbSetLastText(subscription, 0)
  }
  ELSE
  { IF subscription!Sb_rehydrate DO
    { subscription!Sb_rehydrate := FALSE
      IF subscription!Sb_lasttext ~= 0 DO
        IF bbEqual(text, subscription!Sb_lasttext) DO
        { // The reconnect produced the value the consumer already holds, so
          // publishing it would invent a change that never happened.
          bbFree(text)
          upFree(update)
          RETURN
        }
    }
    sbSetLastText(subscription, text)
  }
  sbDeliver(manager, subscription, update)
}

// Takes ownership of `message`, `data` and `logs`.
AND lvDeliverError(manager, subscription, name, message, data, logs) BE
{ LET pending = lvStageError(manager, subscription, name, message, data, logs)
  UNLESS pending RETURN
  lvCommitPending(manager, pending)
  lvFreePending(pending)
}

AND lvBroadcastProtocolError(manager, detail) BE
  FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
  { LET subscription = vlGet(manager!Lv_subs, index)
    lvDeliverError(manager, subscription, "ProtocolError",
                   bbFromStr(detail), 0, 0)
  }

// Collects a modification's logLines into a fresh list of buffers. `failed` is
// an out-parameter because 0 otherwise means two different things -- there were
// no log lines, and there were log lines this client could not copy -- and a
// caller that cannot tell them apart would silently publish a function's output
// as empty.
AND lvCopyLogs(node, failed) = VALOF
{ LET lines = jsObjectGet(node, "logLines")
  LET logs = 0
  !failed := FALSE
  IF lines = 0 RESULTIS 0
  UNLESS lines!Js_type = Jt_array RESULTIS 0
  logs := vlNew(4)
  UNLESS logs DO { !failed := TRUE; RESULTIS 0 }
  FOR index = 0 TO (lines!Js_a)!Vl_len - 1 DO
  { LET line = vlGet(lines!Js_a, index)
    IF line!Js_type = Jt_string DO
    { LET copy = bbCopy(line!Js_a)
      // A log line that could not be copied must not become a null entry in
      // the list: every reader here dereferences it.
      IF copy = 0 DO { lvFreeLogs(logs); !failed := TRUE; RESULTIS 0 }
      UNLESS vlPush(logs, copy) DO
      { bbFree(copy); lvFreeLogs(logs); !failed := TRUE; RESULTIS 0 }
    }
  }
  RESULTIS logs
}

// Apply a whole Transition atomically: validate and stage every modification,
// then commit the version, then publish. Returns FALSE with `detail` set, in
// which case nothing was published and the version did not move.
AND lvApplyTransition(manager, node, detail) = VALOF
{ LET modifications = jsObjectGet(node, "modifications")
  LET endversion = jsObjectGet(node, "endVersion")
  LET staged = 0
  LET queryset = 0
  LET identity = 0
  LET timestamp = 0
  LET failed = FALSE

  UNLESS lvVersionMatches(manager, jsObjectGet(node, "startVersion")) DO
  { !detail := "a Transition did not continue from the version this client holds"
    RESULTIS FALSE
  }
  IF endversion = 0 DO
  { !detail := "a Transition carried no endVersion"
    RESULTIS FALSE
  }
  UNLESS jsWholeNumber(jsObjectGet(endversion, "querySet"), @queryset) DO
  { !detail := "a Transition endVersion had an unusable querySet"
    RESULTIS FALSE
  }
  UNLESS jsWholeNumber(jsObjectGet(endversion, "identity"), @identity) DO
  { !detail := "a Transition endVersion had an unusable identity"
    RESULTIS FALSE
  }
  timestamp := jsObjectGet(endversion, "ts")
  IF timestamp = 0 DO
  { !detail := "a Transition endVersion had no timestamp"
    RESULTIS FALSE
  }
  UNLESS timestamp!Js_type = Jt_string DO
  { !detail := "a Transition endVersion timestamp was not a string"
    RESULTIS FALSE
  }
  UNLESS lvTimestampValid(timestamp!Js_a) DO
  { !detail := "a Transition endVersion timestamp was not eight base64 bytes"
    RESULTIS FALSE
  }

  staged := vlNew(8)
  UNLESS staged DO
  { !detail := "this client could not stage a Transition"
    RESULTIS FALSE
  }

  // Pass one: validate every modification and build every delivery. Nothing
  // reaches a consumer until the whole message has survived this.
  IF modifications ~= 0 DO
  { UNLESS modifications!Js_type = Jt_array DO
    { !detail := "a Transition carried malformed modifications"
      lvFreeStaged(staged)
      RESULTIS FALSE
    }
    FOR index = 0 TO (modifications!Js_a)!Vl_len - 1 DO
    { LET modification = vlGet(modifications!Js_a, index)
      LET kind = jsObjectGet(modification, "type")
      LET queryid = 0
      LET subscription = 0
      LET pending = 0
      LET logs = 0
      LET logsfailed = FALSE
      IF failed DO BREAK
      UNLESS jsWholeNumber(jsObjectGet(modification, "queryId"), @queryid) DO
      { !detail := "a Transition modification had an unusable queryId"
        failed := TRUE
        BREAK
      }
      subscription := lvFindByQueryId(manager, queryid)

      TEST jsStringEqualsStr(kind, "QueryUpdated")
      THEN
      { LET value = jsObjectGet(modification, "value")
        IF value = 0 DO
        { !detail := "a Transition QueryUpdated carried no value"
          failed := TRUE
          BREAK
        }
        IF subscription ~= 0 DO
        { logs := lvCopyLogs(modification, @logsfailed)
          IF logsfailed DO
          { !detail := "this client could not retain Convex log lines"
            failed := TRUE
            BREAK
          }
          pending := lvStageValue(manager, subscription, value, logs)
          IF pending = 0 DO
          { !detail := "this client could not retain a Convex value"
            failed := TRUE
            BREAK
          }
        }
      }
      ELSE TEST jsStringEqualsStr(kind, "QueryFailed")
      THEN
      { IF subscription ~= 0 DO
        { LET message = jsObjectGet(modification, "errorMessage")
          LET data = jsObjectGet(modification, "errorData")
          LET text = 0
          LET clone = 0
          TEST message = 0
          THEN text := bbFromStr("the Convex query failed")
          ELSE TEST message!Js_type = Jt_string
          THEN text := bbCopy(message!Js_a)
          ELSE text := bbFromStr("the Convex query failed")
          // A refused clone must not become an error with its data missing,
          // so the absent and the unallocatable cases are kept apart.
          IF data ~= 0 DO
          { clone := jsClone(data)
            IF clone = 0 DO
            { bbFree(text)
              !detail := "this client could not retain a Convex error"
              failed := TRUE
              BREAK
            }
          }
          logs := lvCopyLogs(modification, @logsfailed)
          IF logsfailed DO
          { bbFree(text)
            jsFree(clone)
            !detail := "this client could not retain Convex log lines"
            failed := TRUE
            BREAK
          }
          pending := lvStageError(manager, subscription, "FunctionError", text,
                                  clone, logs)
          IF pending = 0 DO
          { !detail := "this client could not retain a Convex error"
            failed := TRUE
            BREAK
          }
        }
      }
      ELSE TEST jsStringEqualsStr(kind, "QueryRemoved")
      THEN
      { // Nothing to publish: the server is confirming a Remove we sent.
      }
      ELSE
      { !detail := "a Transition carried an unknown modification"
        failed := TRUE
        BREAK
      }

      IF pending ~= 0 DO
        UNLESS vlPush(staged, pending) DO
        { lvFreePending(pending)
          !detail := "this client could not stage a Transition"
          failed := TRUE
          BREAK
        }
    }
  }

  IF failed DO { lvFreeStaged(staged); RESULTIS FALSE }

  // Pass two: commit the version. Only now is the client's idea of where the
  // stream is allowed to move.
  { LET committed = bbCopy(timestamp!Js_a)
    UNLESS committed DO
    { !detail := "this client could not record a Transition timestamp"
      lvFreeStaged(staged)
      RESULTIS FALSE
    }
    manager!Lv_remotequery := queryset
    manager!Lv_remoteident := identity
    bbFree(manager!Lv_remotets)
    manager!Lv_remotets := committed
    lvNoteTimestamp(manager, committed)
  }

  // Pass three: publish. Every allocation these need was made in pass one.
  FOR index = 0 TO staged!Vl_len - 1 DO
    lvCommitPending(manager, vlGet(staged, index))
  lvFreeStaged(staged)
  RESULTIS TRUE
}

// Prove a quiet connection is still there, or give up on it. A dead TCP
// connection is indistinguishable from an idle one until something is sent, and
// the sync protocol is quiet by design, so silence alone is never taken as
// health. Returns FALSE when the connection has been retired.
AND lvKeepalive(manager) = VALOF
{ LET connection = manager!Lv_ws
  LET idle = 0
  UNLESS connection RESULTIS FALSE
  idle := cxNow() - connection!Ws_lastrx
  IF idle >= Liveinactivityms DO
  { lvDropConnection(manager, "InactivityTimeout")
    lvBackoffAfterFailure(manager)
    RESULTIS FALSE
  }
  IF idle >= Livekeepalivems DO
    UNLESS connection!Ws_pingsent DO
    { connection!Ws_pingsent := TRUE
      UNLESS wsSendControl(connection, Op_ping, 0,
                           cxDeadline(Closetimeoutms)) DO
      { lvDropConnection(manager, "TransportError")
        lvBackoffAfterFailure(manager)
        RESULTIS FALSE
      }
    }
  RESULTIS TRUE
}

// One slice of owner work, bounded by the caller's absolute deadline.
AND lvStep(manager, deadline) BE
{ LET message = 0
  LET node = 0
  LET kind = 0
  LET detail = "the Convex sync stream drifted from the pinned profile"

  UNLESS manager RETURN

  IF (manager!Lv_subs)!Vl_len = 0 DO
  { lvRetire(manager, "NoSubscriptions", TRUE)
    RETURN
  }

  IF manager!Lv_ws = 0 DO
  { IF cxNow() < manager!Lv_nextattempt DO
    { LET wake = manager!Lv_nextattempt
      IF wake > deadline DO wake := deadline
      // Sleeping out the backoff rather than returning at once is what keeps a
      // caller's poll loop from spinning at the speed of the interpreter for
      // the whole of a reconnect delay.
      cxSleepUntil(wake)
      RETURN
    }
    lvOpen(manager, deadline)
    RETURN
  }

  UNLESS lvKeepalive(manager) RETURN

  message := wsNextMessage(manager!Lv_ws, deadline)
  IF message = 0 DO
  { IF wsStatus = Wss_none RETURN
    IF wsStatus = Wss_protocol DO
      lvBroadcastProtocolError(manager,
        "the Convex sync connection violated the WebSocket protocol")
    lvDropConnection(manager,
      (wsStatus = Wss_eof -> "PeerClosed", "TransportError"))
    lvBackoffAfterFailure(manager)
    RETURN
  }

  node := jsParseBuffer(message)
  UNLESS node DO
  { lvBroadcastProtocolError(manager, "a Convex sync message was not JSON")
    lvDropConnection(manager, "ProtocolError")
    lvBackoffAfterFailure(manager)
    RETURN
  }

  kind := jsObjectGet(node, "type")

  IF jsStringEqualsStr(kind, "Transition") DO
  { LET ok = lvApplyTransition(manager, node, @detail)
    jsFree(node)
    TEST ok
    THEN
    { // A well-formed server transition is as good a health signal as a
      // handshake, so the transport backoff starts again from the base.
      manager!Lv_backoff := Backoffbasems
      manager!Lv_nextattempt := 0
    }
    ELSE
    { lvBroadcastProtocolError(manager, detail)
      lvDropConnection(manager, "ProtocolError")
      lvBackoffAfterFailure(manager)
    }
    RETURN
  }

  // Ping keeps the connection warm; mutation and action responses belong to
  // WebSocket call paths this client deliberately does not use.
  IF jsStringEqualsStr(kind, "Ping") DO { jsFree(node); RETURN }
  IF jsStringEqualsStr(kind, "MutationResponse") DO { jsFree(node); RETURN }
  IF jsStringEqualsStr(kind, "ActionResponse") DO { jsFree(node); RETURN }

  IF jsStringEqualsStr(kind, "TransitionChunk") DO
    detail := "chunked Transition assembly is deferred by this client"
  IF jsStringEqualsStr(kind, "AuthError") DO
    detail := "the Convex sync connection reported an authentication error"
  IF jsStringEqualsStr(kind, "FatalError") DO
    detail := "the Convex sync connection reported a fatal server error"

  jsFree(node)
  lvBroadcastProtocolError(manager, detail)
  lvDropConnection(manager, "ProtocolError")
  lvBackoffAfterFailure(manager)
}
