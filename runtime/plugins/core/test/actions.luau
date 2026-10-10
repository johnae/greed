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

-- The actions of `kind` itself, without those for every kind.
local function own(kind: string): { any }
	local out = {}
	for _, action in actions.for_kind(kind) do
		if action.kind == kind then
			table.insert(out, action)
		end
	end
	return out
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
core.style.typing_kind("tickets")
return {}
]],
	})
	greed.plugin.load(dir .. "/jira")
	-- Loading it again replaces what it added.
	greed.plugin.load(dir .. "/jira")
	t:wait(0)
	assert(string.find(kinds(), "ticket:ABC-12", 1, true), kinds())
	assert(#own("ticket") == 1)
	local core = require("@core")
	local features = table.concat(core.features.of(greed.view():buffer()), " ")
	assert(features == "tickets", features)
	assert(core.style.typing_kinds.tickets)
	greed.plugin.unload("jira")
	t:wait(0)
	assert(not string.find(kinds(), "ticket", 1, true), kinds())
	assert(#own("ticket") == 0)
	assert(#core.features.of(greed.view():buffer()) == 0)
	assert(core.style.typing_kinds.tickets == nil)
end)

-- Runs the action `name` of `kind` on `value`, as space . would.
local function run(kind: string, name: string, value: any)
	for _, action in actions.for_kind(kind) do
		if action.name == name then
			greed.spawn(function()
				actions.run(action, { kind = kind, label = tostring(value), value = value })
			end)
			return
		end
	end
	error(`no action {name} for a {kind}`)
end

test("a file renames in its folder or to a path, and deletes after y", function(t)
	local dir = t:tempdir({ ["a.txt"] = "aaa", ["keep.txt"] = "keep" })
	greed.open(dir .. "/a.txt")
	local buffer = greed.view():buffer()
	run("file", "rename", dir .. "/a.txt")
	t:keys("ctrl-u b . t x t enter")
	assert(greed.fs.stat(dir .. "/b.txt") and not greed.fs.stat(dir .. "/a.txt"), "renamed")
	assert(buffer:path() == dir .. "/b.txt", "the open file went along")
	run("file", "delete", dir .. "/keep.txt")
	t:keys("n")
	assert(greed.fs.stat(dir .. "/keep.txt"), "n keeps it")
	run("folder", "delete", dir)
	t:keys("esc")
	run("file", "delete", dir .. "/keep.txt")
	t:keys("y")
	assert(greed.fs.stat(dir .. "/keep.txt") == nil, "y deletes it")
end)

test("actions run through actions.run are kept as what was done, newest first", function(t)
	actions.action({ kind = "test-done", name = "poke", run = function() end })
	actions.action({
		kind = "test-done",
		name = "make",
		run = function()
			return "buffer:1"
		end,
	})
	local function named(name: string): any
		for _, action in actions.for_kind("test-done") do
			if action.name == name then
				return action
			end
		end
		error(name)
	end
	local target = { kind = "test-done", label = "it", value = "it" }
	actions.run(named("poke"), target)
	actions.run(named("make"), target, "agent")
	local done = actions.history("test-done:it")
	assert(#done == 2, tostring(#done))
	assert(done[1].action == "make" and done[1].by == "agent" and done[1].made == "buffer:1")
	assert(done[2].action == "poke" and done[2].by == "you" and done[2].made == nil)
	assert(#actions.history("test-done:other") == 0)
	-- One that only looks isn't kept.
	actions.run({ kind = "test-done", name = "look", quiet = true, run = function() end }, target)
	assert(#actions.history("test-done:it") == 2, "quiet")
end)

test("an action that destroys several, or an agent's, is reviewed together first", function(t)
	local ran: { string } = {}
	actions.action({
		kind = "test-risky",
		name = "wipe",
		danger = true,
		says = function(target)
			return `wipe --hard {target.value}`
		end,
		warns = function(target)
			return if target.value == "prod" then "in PRODUCTION (prod)" else nil
		end,
		run = function(target)
			table.insert(ran, target.value)
		end,
	})
	local wipe = actions.for_kind("test-risky")[1]
	local function targets(...: string): { any }
		local out = {}
		for _, value in { ... } do
			table.insert(out, { kind = "test-risky", label = value, value = value })
		end
		return out
	end
	t:buffer("|x")
	local chosen: { any }? = nil
	greed.spawn(function()
		chosen = actions.run_all(wipe, targets("dev", "prod"))
	end)
	local review = table.concat(t:floats(), "\n")
	assert(string.find(review, "[x] wipe  dev   wipe --hard dev", 1, true), review)
	assert(string.find(review, "(in PRODUCTION (prod))", 1, true), review)
	-- Untick prod, then run what's ticked.
	t:keys("j space enter")
	t:wait_for(function()
		return chosen ~= nil
	end)
	assert(#ran == 1 and ran[1] == "dev", table.concat(ran, ","))
	-- An agent's, even of one, is reviewed; esc runs none.
	chosen = nil
	greed.spawn(function()
		chosen = actions.run_all(wipe, targets("stage"), "agent")
	end)
	local spec = assert(greed.view():float_spec())
	assert(spec.title == "An agent asks to wipe 1", tostring(spec.title))
	t:keys("esc")
	t:wait_for(function()
		return chosen ~= nil
	end)
	assert(#ran == 1 and #assert(chosen) == 0, "none ran")
end)
