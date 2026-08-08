use "../../../../client"

// Serialisation of NDJSON adapter protocol v1 events.
//
// The shared controller validates every emitted line against
// `_shared/schemas/adapter.schema.json`, and the rule that catches clients out
// is that an absent optional field must be omitted rather than serialised as
// null. That is why every event here is assembled field by field: there is no
// struct with nullable members that could quietly emit `"id":null` or
// `"subscriptionId":null`.
//
// This is test infrastructure. It is not part of the client the demonstration
// teaches, and nothing under `client/` depends on it.

primitive AdapterEvents
  fun protocol_version(): I64 => 1

  fun ready(id: String, language: String, implementation: String,
    runtime: String): String ?
  =>
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](6)
      out.push(("protocolVersion",
        JsonNumber.from_i64(AdapterEvents.protocol_version())))
      out.push(("id", id))
      out.push(("type", "ready"))
      out.push(("language", language))
      out.push(("implementation", implementation))
      out.push(("runtime", runtime))
      out
    end)?

  fun result(id: String, value: JsonValue, logs: Array[String] val): String ? =>
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](4)
      out.push(("id", id))
      out.push(("type", "result"))
      out.push(("value", value))
      out.push(("logs", AdapterEvents.log_lines(logs)))
      out
    end)?

  fun ack(id: String): String ? =>
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](2)
      out.push(("id", id))
      out.push(("type", "ack"))
      out
    end)?

  fun closed(id: String): String ? =>
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](2)
      out.push(("id", id))
      out.push(("type", "closed"))
      out
    end)?

  fun failure(id: String, error': ConvexError): String ? =>
    """
    A command failure. `id` is omitted entirely when the failing line had no
    usable identifier, because the schema requires a non-empty string.
    """
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](3)
      if id.size() > 0 then out.push(("id", id)) end
      out.push(("type", "error"))
      out.push(("error", AdapterEvents.error_object(error')))
      if error'.logs.size() > 0 then
        out.push(("logs", AdapterEvents.log_lines(error'.logs)))
      end
      out
    end)?

  fun subscription_value(
    subscription_id: String,
    value: JsonValue,
    logs: Array[String] val)
    : String ?
  =>
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](4)
      out.push(("type", "subscription"))
      out.push(("subscriptionId", subscription_id))
      out.push(("value", value))
      out.push(("logs", AdapterEvents.log_lines(logs)))
      out
    end)?

  fun subscription_failure(
    subscription_id: String,
    error': ConvexError)
    : String ?
  =>
    """
    A subscription failure carries no `id`: it is not the answer to a command.
    """
    AdapterEvents._encode(recover val
      let out = Array[(String, JsonValue)](4)
      out.push(("type", "subscription"))
      out.push(("subscriptionId", subscription_id))
      out.push(("error", AdapterEvents.error_object(error')))
      if error'.logs.size() > 0 then
        out.push(("logs", AdapterEvents.log_lines(error'.logs)))
      end
      out
    end)?

  fun error_object(error': ConvexError): JsonObject =>
    JsonObject(recover val
      let out = Array[(String, JsonValue)](3)
      out.push(("name", error'.name()))
      out.push(("message", error'.message))
      // Structured application data only exists for a Convex function error,
      // and an absent payload is absent rather than null.
      if error'.has_data then out.push(("data", error'.data)) end
      out
    end)

  fun log_lines(logs: Array[String] val): JsonArray =>
    JsonArray(recover val
      let out = Array[JsonValue](logs.size())
      for line in logs.values() do
        out.push(line)
      end
      out
    end)

  fun _encode(entries: Array[(String, JsonValue)] val): String ? =>
    JsonEncode(JsonObject(entries))?
