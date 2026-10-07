local test = require("@greed/test")
local greed = require("@greed")
local actions = require("@core").actions

local function kinds(): string
	local out = {}
	for _, target in actions.at(greed.view()) do
		table.insert(out, `{target.kind}:{target.label}`)
	end
	return table.concat(out, " ")
end

test("a path under the cursor that exists is a file to act on", function(t)
	local dir = t:tempdir({ ["notes.txt"] = "hi" })
	t:buffer(`see {dir}/no|tes.txt and more`)
	assert(kinds() == `file:{dir}/notes.txt`, kinds())
	t:buffer("see |nothing.txt here")
	assert(kinds() == "", kinds())
end)

test("a selection is text to act on, and a button under the cursor is one too", function(t)
	t:buffer("^some text| here")
	assert(string.find(kinds(), "text:some text", 1, true), kinds())
	t:buffer("|[x]")
	greed
		.view()
		:buffer()
		:decorate("test", { { from = 0, to = 3, style = "ui.text", action = "goto-end" } })
	assert(string.find(kinds(), "button:[x]", 1, true), kinds())
end)

test("plugins add finders and actions, and they go with the plugin", function(t)
	t:buffer("|ABC-12")
	local dir = t:tempdir({
		["jira/plugin.toml"] = 'name = "jira"\nrequires = ["core"]\n',
		["jira/init.luau"] = [[
local core = require("@core")
core.actions.finder({ name = "ticket", find = function(view, range)
	return { { kind = "ticket", label = "ABC-12", value = "ABC-12" } }
end })
core.actions.action({ kind = "ticket", name = "open", run = function() end })
core.features.add("tickets", function() return true end)
core.style.kind_mode("tickets", "helix-insert")
return {}
]],
	})
	greed.plugin.load(dir .. "/jira")
	-- Loading it again replaces what it added.
	greed.plugin.load(dir .. "/jira")
	t:wait(0)
	assert(string.find(kinds(), "ticket:ABC-12", 1, true), kinds())
	assert(#actions.for_kind("ticket") == 1)
	local core = require("@core")
	local features = table.concat(core.features.of(greed.view():buffer()), " ")
	assert(features == "tickets", features)
	assert(core.style.kind_modes.tickets == "helix-insert")
	greed.plugin.unload("jira")
	t:wait(0)
	assert(not string.find(kinds(), "ticket", 1, true), kinds())
	assert(#actions.for_kind("ticket") == 0)
	assert(#core.features.of(greed.view():buffer()) == 0)
	assert(core.style.kind_modes.tickets == nil)
end)
