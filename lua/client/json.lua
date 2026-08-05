local dkjson = require("dkjson")

local Json = {
	null = dkjson.null,
	array_mt = { __jsontype = "array" },
	object_mt = { __jsontype = "object" },
}

function Json.encode(value)
	local ok, encoded = pcall(dkjson.encode, value)
	if not ok then
		return nil, encoded
	end
	return encoded
end

function Json.decode(text)
	local ok, value, position, decode_error = pcall(dkjson.decode, text, 1, dkjson.null, Json.object_mt, Json.array_mt)
	if not ok then
		return nil, value
	end
	if value == nil then
		return nil, decode_error
	end
	if text:sub(position):match("%S") then
		return nil, "trailing data after JSON value"
	end
	return value
end

function Json.object(value)
	value = value or {}
	setmetatable(value, Json.object_mt)
	return value
end

function Json.array(value)
	value = value or {}
	setmetatable(value, Json.array_mt)
	return value
end

return Json
