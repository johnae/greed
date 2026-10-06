local test = require("@greed/test")
local greed = require("@greed")
local terminal = require("@terminal")

-- Takes `name` out of `map`, which doesn't allow nil values.
local function forget<V>(map: { [string]: V }, name: string)
	map[name] = nil
end

local function shows(t: test.TestContext, buffer: greed.Buffer, wanted: string)
	t:wait_for(function()
		return string.find(buffer:text(), wanted, 1, true) ~= nil
	end)
end

test("a task runs in a terminal below that stays open when it's done", function(t)
	terminal.tasks.hello = { command = "echo hello from a task" }
	t:run("task", { "hello" })
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "terminal")
	shows(t, buffer, "hello from a task")
	t:wait_for(function()
		return #buffer:decorations("terminal.exit") > 0
	end)
	local lines = buffer:decorations("terminal.exit")[1].lines
	assert(lines and lines[1] == "[done]", "it says it's done")
	assert(greed.view():buffer():id() == buffer:id(), "and stays open")
	forget(terminal.tasks, "hello")
end)

test("running a task again replaces its last run", function(t)
	terminal.tasks.count = { command = "echo run; sleep 5" }
	t:run("task", { "count" })
	local first = greed.view():buffer()
	shows(t, first, "run")
	t:run("task", { "count" })
	local second = greed.view():buffer()
	assert(second:id() ~= first:id(), "a new terminal")
	shows(t, second, "run")
	local open = 0
	for _, b in greed.buffers() do
		if b:kind() == "terminal" then
			open += 1
		end
	end
	assert(open == 1, `the first one went: {open}`)
	forget(terminal.tasks, "count")
end)

test("tasks come from the project's files, and space r picks one, the last run first", function(t)
	local dir = t:tempdir({
		["package.json"] = '{ "scripts": { "lint": "eslint ." } }',
		["Makefile"] = "all: build\nbuild:\n\techo building\nVAR := 1\n.PHONY: all\n",
	})
	greed.project.open(dir)
	local all = terminal.all_tasks(dir)
	assert(all.lint and all.build and all.all, "npm scripts and make targets")
	assert(all.VAR == nil and all[".PHONY"] == nil, "not variables or special targets")
	t:keys("space r")
	local floats = table.concat(t:floats(), "\n")
	assert(string.find(floats, "lint  npm run lint", 1, true), floats)
end)

test("an unknown task says so", function(t)
	t:run("task", { "nope" })
	local messages = t:messages()
	assert(messages[#messages] == "there's no task called nope", messages[#messages])
end)

test("a task runs in the folder it names", function(t)
	local dir = t:tempdir({ ["marker.txt"] = "" })
	terminal.tasks.where = { command = "pwd; ls; sleep 5", cwd = dir }
	t:run("task", { "where" })
	local buffer = greed.view():buffer()
	shows(t, buffer, "marker.txt")
	forget(terminal.tasks, "where")
end)

test("make targets right after one another, and on the last line, count too", function(t)
	local dir = t:tempdir({ ["Makefile"] = "build:\ntest:\nVAR:=1\nlast:" })
	local all = terminal.all_tasks(dir)
	assert(all.build and all.test and all.last, "every target")
	assert(all.VAR == nil, "not a variable")
end)
