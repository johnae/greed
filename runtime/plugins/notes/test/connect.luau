local test = require("@greed/test")
local models: any = require("@models")

test("notes-connect starts Greed's agent on the inbox with the notes tools on", function(t)
	local asked: { any } = {}
	models.turn = function(_role, request)
		table.insert(asked, table.clone(request))
		return { text = "Connected.", calls = {}, stop = "done" }, nil
	end
	t:buffer("|x")
	t:run("notes-connect")
	t:wait(10)
	local request = asked[1]
	assert(request, "the model was asked")
	assert(string.find(request.said[1].text, "my inbox note", 1, true), request.said[1].text)
	assert(string.find(request.said[1].text, "only with the propose tool", 1, true) ~= nil)
	local names: { [string]: boolean } = {}
	for _, tool in request.tools do
		names[tool.name] = true
	end
	assert(names["notes_search"] and names["notes_add_thought"], "the notes tools are on")
end)
