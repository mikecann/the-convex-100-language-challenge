"""Adapter protocol v1 event serialization.

Kept apart from the adapter's own entry point so the exact wire shapes can be
asserted by a language-local test. The shared controller validates every event
against the adapter schema, and the rule that catches clients out is that an
absent field must be omitted rather than written as `null`.
"""

from convex import Update
from json import quote


fn ready_event(
    id: String, language: String, implementation: String, runtime: String
) -> String:
    var out = String('{"protocolVersion":1,"id":')
    out += quote(id)
    out += ',"type":"ready","language":'
    out += quote(language)
    out += ',"implementation":'
    out += quote(implementation)
    out += ',"runtime":'
    out += quote(runtime)
    out += "}"
    return out


fn result_event(id: String, value_json: String, logs_json: String) -> String:
    var out = String('{"id":')
    out += quote(id)
    out += ',"type":"result","value":'
    out += value_json if value_json else String("null")
    if logs_json:
        out += ',"logs":'
        out += logs_json
    out += "}"
    return out


fn error_event(
    id: String,
    subscription_id: String,
    name: String,
    message: String,
    data_json: String,
    logs_json: String,
) -> String:
    """A failure, as either a command error or a subscription delivery."""
    var out = String("{")
    if subscription_id:
        out += '"type":"subscription","subscriptionId":'
        out += quote(subscription_id)
    else:
        out += '"type":"error"'
        if id:
            out += ',"id":'
            out += quote(id)
    out += ',"error":{"name":'
    out += quote(name)
    out += ',"message":'
    out += quote(message)
    if data_json:
        out += ',"data":'
        out += data_json
    out += "}"
    if logs_json:
        out += ',"logs":'
        out += logs_json
    out += "}"
    return out


fn simple_event(id: String, kind: String) -> String:
    var out = String('{"id":')
    out += quote(id)
    out += ',"type":'
    out += quote(kind)
    out += "}"
    return out


fn subscription_event(subscription_id: String, update: Update) -> String:
    if update.failed:
        return error_event(
            String(),
            subscription_id,
            update.error_name,
            update.error_message,
            update.error_data_json,
            update.logs_json,
        )
    var out = String('{"type":"subscription","subscriptionId":')
    out += quote(subscription_id)
    out += ',"value":'
    out += update.value_json if update.value_json else String("null")
    if update.logs_json:
        out += ',"logs":'
        out += update.logs_json
    out += "}"
    return out
