-- Exact adapter protocol v1 event constructors, kept separate for shape tests.
local Events = {}

function Events.error(id, err)
	local event = { type = "error", error = { name = err.name or "Error", message = err.message or tostring(err) } }
	if id and id ~= "" then
		event.id = id
	end
	if err.data ~= nil then
		event.error.data = err.data
	end
	if err.logs and #err.logs > 0 then
		event.logs = err.logs
	end
	return event
end

function Events.result(id, result)
	local event = { id = id, type = "result", value = result.value }
	if result.logs and #result.logs > 0 then
		event.logs = result.logs
	end
	return event
end

function Events.subscription(subscription_id, update)
	local event = { type = "subscription", subscriptionId = subscription_id, value = update.value }
	if update.logs and #update.logs > 0 then
		event.logs = update.logs
	end
	return event
end

-- Relays can yield while writing. Rechecking the exact entry after dequeue
-- prevents an old subscription from crossing an unsubscribe or replacement
-- acknowledgement if the controller changed that id in the meantime.
function Events.relay_is_current(subscriptions, subscription_id, entry)
	return subscriptions[subscription_id] == entry
end

function Events.deliver_if_current(subscriptions, subscription_id, entry, update, deliver, before_check)
	if before_check then
		before_check() -- deterministic fixture pause after dequeue
	end
	if not Events.relay_is_current(subscriptions, subscription_id, entry) then
		return false
	end
	deliver(update)
	return true
end

return Events
