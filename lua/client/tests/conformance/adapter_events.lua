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

return Events
