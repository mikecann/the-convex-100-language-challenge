module: convex

// -------------------------------------------------------------------------
// Convex from Dylan: the canonical basics example.
//
// Demonstrates the shared counter's 0 -> 1 journey: an initial HTTP
// query, an initial Live value over WebSocket, an idempotent mutation,
// and the resulting Live update -- verifying every step before printing
// the final confirmation line. Stdout here is a universal happy-path
// transcript compared byte-for-byte against
// _shared/examples/basics.expected.txt, so every diagnostic goes to
// stderr instead.
// -------------------------------------------------------------------------

define function die (message :: <byte-string>) => ()
  format-err(message);
  format-err("\n");
  force-err();
  c-exit(1);
end function;

// Convex's "json" HTTP format may render a whole count as either 0 or
// 0.0; this accepts both without silently truncating a genuinely
// fractional value (see convex-json.dylan's header comment on why floats
// and integers are distinct Dylan types here).
define function count-of (value :: <object>)
 => (count :: false-or(<integer>))
  let count-value = json-object-ref(value, "count");
  if (instance?(count-value, <integer>))
    count-value
  elseif (instance?(count-value, <float>))
    let whole = truncate(count-value);
    if (as(<double-float>, whole) = count-value) whole else #f end if
  else
    #f
  end if
end function;

// Blocks (via the same reactor step the adapter uses) until the next
// value or error arrives for query-id, or the overall deadline passes.
define function await-update
    (mgr :: <sync-manager>, query-id :: <integer>, deadline-ms :: <integer>)
 => (update :: false-or(<sync-update>))
  block (done)
    while (#t)
      let update = sync-poll-update(mgr, query-id);
      if (update)
        done(update);
      end if;
      if (cx-now-ms() > deadline-ms)
        done(#f);
      end if;
      sync-pump(mgr, 50);
    end while;
    #f
  end block
end function;

define function main () => ()
  // Configuration: the deployment URL comes from the environment, and
  // the verifier passes a unique room as this container's first
  // argument, forwarded here as EXAMPLE_ROOM by the Docker entrypoint
  // wrapper so a human running the image directly can also just set it.
  let url-text = cx-getenv("CONVEX_URL");
  if (~url-text)
    die("CONVEX_URL is required");
  end if;
  let base-url = parse-convex-url(url-text);
  if (~base-url)
    die("CONVEX_URL is not a valid http(s) URL");
  end if;
  let room = cx-getenv("EXAMPLE_ROOM") | "dylan-basic-example";

  let query-args = make-json-object();
  json-object-set!(query-args, "room", room);

  // The HTTP query: ask Convex for the room's current state.
  let (initial-value, query-err, _query-logs) =
    convex-http-call(base-url, "query", "demo:state", query-args, #f,
                      cx-now-ms() + 15000);
  if (query-err | count-of(initial-value) ~= 0)
    die("unexpected initial query value");
  end if;
  format-out("current count: 0\n");

  // Start Live before the mutation so no reactive update can be missed.
  let mgr = sync-manager-new(base-url);
  let query-id =
    sync-subscribe(mgr, "demo:state", query-args, cx-now-ms() + 8000);
  let initial-live = await-update(mgr, query-id, cx-now-ms() + 10000);
  if (~initial-live | initial-live.upd-kind ~= #"value"
        | count-of(initial-live.upd-value) ~= 0)
    die("unexpected initial Live value");
  end if;
  format-out("live initial count: 0\n");

  // The run ID makes the mutation safe to retry without incrementing
  // twice.
  let mutation-args = make-json-object();
  json-object-set!(mutation-args, "room", room);
  json-object-set!(mutation-args, "language", "Dylan");
  json-object-set!(mutation-args, "runId", concatenate(room, "-once"));
  let (mutation-value, mutation-err, _mutation-logs) =
    convex-http-call(base-url, "mutation", "demo:increment", mutation-args,
                      #f, cx-now-ms() + 15000);
  if (mutation-err)
    die("mutation failed");
  end if;
  let applied = json-object-ref(mutation-value, "applied");
  let state = json-object-ref(mutation-value, "state");
  if (applied ~= #t | count-of(state) ~= 1)
    die("unexpected mutation result");
  end if;
  format-out("mutation applied: true\n");
  format-out("mutation count: 1\n");

  // Decode the resulting Live update, then cleanly remove the
  // subscription.
  let updated-live = await-update(mgr, query-id, cx-now-ms() + 10000);
  if (~updated-live | updated-live.upd-kind ~= #"value"
        | count-of(updated-live.upd-value) ~= 1)
    die("unexpected updated Live value");
  end if;
  format-out("live updated count: 1\n");
  sync-unsubscribe(mgr, query-id, cx-now-ms() + 5000);

  // Print verification only after HTTP and Live agree on the 0 -> 1
  // journey.
  format-out("verified count: 0 -> 1\n");
  force-out();
end function;

main();
