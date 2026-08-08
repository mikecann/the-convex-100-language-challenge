/* Convex from XPL: the canonical counter walk.
 *
 * This program is the exact source shown in the README and on the
 * website. It proves the same 0 -> 1 journey over both transports:
 * an HTTP query for the current count, a Live subscription started
 * before the mutation so no update can be missed, the mutation
 * itself, and the resulting Live update.
 */

/* Convex renders a whole count as either "0" or "0.0"; this decodes
 * both to a plain integer and rejects anything that is not actually a
 * non-negative whole number (a quoted string, a fractional value, or
 * something too large to be a real count in this demonstration).
 */
decode_count: procedure(s, start, fin) fixed;
    declare s character, start fixed, fin fixed, i fixed, v fixed, digits fixed;
    i = start;
    v = 0;
    digits = 0;
    do while i < fin & byte(s, i) >= 48 & byte(s, i) <= 57;
        if v > 100000000 then return -1;
        v = v * 10 + (byte(s, i) - 48);
        digits = digits + 1;
        i = i + 1;
    end;
    if digits = 0 then return -1;
    if i < fin & byte(s, i) = 46 then do;
        i = i + 1;
        if i >= fin then return -1;
        do while i < fin & byte(s, i) >= 48 & byte(s, i) <= 57;
            if byte(s, i) ~= 48 then return -1;
            i = i + 1;
        end;
    end;
    if i ~= fin then return -1;
    return v;
end decode_count;

/* Reads the "count" member of a demo:state result value (query
   result, mutation's nested "state", or a Live update) and returns
   its decoded value, or -1 if "count" is missing or not a whole
   number. */
count_of: procedure(value_json) fixed;
    declare value_json character, found fixed;
    found = json_find_member(value_json, 1, 'count');
    if found = 0 then return -1;
    return decode_count(value_json, g_span_start, g_span_end);
end count_of;

die: procedure(message);
    declare message character;
    output(1) = message;
    call exit(1);
end die;

declare room character, args character, run_id character;
declare count fixed;

/* Configure the deployment from the environment and create the client. */
if convex_init = 0 then call die(g_error_message);
if argc > 1 then room = argv(1);
else room = 'xpl-basic-example';

/* Query the current counter over HTTP and decode its JSON object. */
args = '{"room":' || json_encode_string('', room) || '}';
if convex_call('query', 'demo:state', args) = 0 then
    call die('unexpected initial query value: ' || g_error_message);
count = count_of(g_value_json);
if count ~= 0 then call die('unexpected initial query value');
output = 'current count: 0';

/* Start Live before the mutation so no reactive update can be missed. */
if convex_subscribe('demo:state', args) = 0 then
    call die('could not subscribe: ' || g_error_message);
if convex_subscription_next = 0 then
    call die('unexpected initial Live value: ' || g_error_message);
if g_sub_pending_is_error = 1 then
    call die('unexpected initial Live value: ' || g_sub_pending_error_message);
count = count_of(g_sub_pending_value);
if count ~= 0 then call die('unexpected initial Live value');
output = 'live initial count: 0';

/* The run ID makes the mutation safe to retry without incrementing twice. */
run_id = room || '-once';
args = '{"room":' || json_encode_string('', room) ||
    ',"language":' || json_encode_string('', 'XPL') ||
    ',"runId":' || json_encode_string('', run_id) || '}';
if convex_call('mutation', 'demo:increment', args) = 0 then
    call die('mutation failed: ' || g_error_message);
if json_find_member(g_value_json, 1, 'applied') = 0 |
        raw_eq(g_value_json, g_span_start, g_span_end - g_span_start, 'true') = 0 then
    call die('unexpected mutation result');
if json_find_member(g_value_json, 1, 'state') = 0 then
    call die('unexpected mutation result');
count = count_of(substr(g_value_json, g_span_start, g_span_end - g_span_start));
if count ~= 1 then call die('unexpected mutation result');
output = 'mutation applied: true';
output = 'mutation count: 1';

/* Decode the resulting Live update, then cleanly remove the subscription. */
if convex_subscription_next = 0 then
    call die('unexpected updated Live value: ' || g_error_message);
if g_sub_pending_is_error = 1 then
    call die('unexpected updated Live value: ' || g_sub_pending_error_message);
count = count_of(g_sub_pending_value);
if count ~= 1 then call die('unexpected updated Live value');
output = 'live updated count: 1';
call convex_unsubscribe;

/* Print verification only after HTTP and Live agree on the 0 -> 1 journey. */
output = 'verified count: 0 -> 1';
eof
