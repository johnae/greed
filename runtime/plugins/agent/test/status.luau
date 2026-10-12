local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

local function status(): any
	for _, tool in agent.tools() do
		if tool.name == "status" then
			return tool.run({}, agent.caller())
		end
	end
	error("no status tool")
end

test("the status says which machine it's on, with an id that stays", function()
	local first, again = status().host, status().host
	assert(type(first.id) == "string" and #first.id == 16, tostring(first.id))
	assert(first.id == again.id, "the same id each time")
	assert(first.name == (greed.hostname() or "this machine"), first.name)
end)
