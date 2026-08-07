// Adapter protocol v1 event constructors.
//
// Test-only infrastructure, kept apart from the adapter's dispatch loop so the
// exact serialised shape can be asserted directly. The shared controller
// validates every line against _shared/schemas/adapter.schema.json, and that
// schema has no room for invented nulls: an absent id, value, error, or log
// list must simply not appear.
#ifndef CONVEX_ADAPTER_EVENTS_PIKE
#define CONVEX_ADAPTER_EVENTS_PIKE

mapping ready_event(string id, string language, string implementation,
                    string runtime)
{
  return ([
    "protocolVersion": 1,
    "id": id,
    "type": "ready",
    "language": language,
    "implementation": implementation,
    "runtime": runtime,
  ]);
}

mapping ack_event(string id)
{
  return ([ "id": id, "type": "ack" ]);
}

mapping closed_event(string id)
{
  return ([ "id": id, "type": "closed" ]);
}

// A result always carries its value, including an explicit JSON null, because
// "the function returned null" and "the adapter forgot the value" are different
// answers. Empty log lists are omitted rather than sent as [].
mapping result_event(string id, mixed value, array(string) logs)
{
  mapping event = ([ "id": id, "type": "result", "value": value ]);
  if (logs && sizeof(logs))
    event->logs = logs;
  return event;
}

// `failure` is already the exact error object to publish: name and message
// always, data only when Convex actually supplied it.
mapping error_event(string id, mapping failure, void|array(string) logs)
{
  mapping event = ([ "type": "error", "error": failure ]);
  if (id && sizeof(id))
    event->id = id;
  if (logs && sizeof(logs))
    event->logs = logs;
  return event;
}

mapping subscription_value_event(string subscription_id, mixed value,
                                 array(string) logs)
{
  mapping event = ([
    "type": "subscription",
    "subscriptionId": subscription_id,
    "value": value,
  ]);
  if (logs && sizeof(logs))
    event->logs = logs;
  return event;
}

// A failing subscription publishes an error instead of a value. Sending both,
// or sending a null value alongside the error, would let a consumer read a
// failure as data.
mapping subscription_error_event(string subscription_id, mapping failure,
                                 void|array(string) logs)
{
  mapping event = ([
    "type": "subscription",
    "subscriptionId": subscription_id,
    "error": failure,
  ]);
  if (logs && sizeof(logs))
    event->logs = logs;
  return event;
}

mapping failure_object(string name, string message, int carries_data,
                       mixed data)
{
  mapping failure = ([ "name": name, "message": message ]);
  if (carries_data)
    failure->data = data;
  return failure;
}

#endif
