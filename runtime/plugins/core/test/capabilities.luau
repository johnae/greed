local test = require("@greed/test")
local greed = require("@greed")

-- A plugin called `name` that declares `capabilities`, requires `requires`
-- and has a command `<name>-go` running `body`, which echoes "ok" or the
-- error.
local function plugin(
	t: test.TestContext,
	name: string,
	capabilities: string,
	body: string,
	requires: string?
): string
	return t:tempdir({
		["plugin.toml"] = `name = "{name}"\ncapabilities = [{capabilities}]\nrequires = [{requires or ""}]\n`,
		["init.luau"] = `local greed = require("@greed")\n`
			.. `greed.command(\{ name = "{name}-go", run = function(ctx)\n`
			.. `  local ok, err = pcall(function() {body} end)\n`
			.. `  greed.echo(if ok then "ok" else tostring(err))\n`
			.. `end \})\n`,
	})
end

local function last(t: test.TestContext): string
	local messages = t:messages()
	return messages[#messages]
end

test("a plugin can't run programs or read files it didn't declare", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "plain", "", 'greed.process.run({ "true" })'))
	t:run("plain-go")
	assert(
		string.find(
			last(t),
			'plain can\'t run programs, which can do anything you can: add "proc" to capabilities in its plugin.toml',
			1,
			true
		),
		last(t)
	)
	greed.plugin.load(plugin(t, "reader", "", 'greed.fs.read("/etc/hostname")'))
	t:run("reader-go")
	assert(string.find(last(t), 'add "fs.read"', 1, true), last(t))
end)

test("declaring a capability opens what it covers", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "runner", '"proc"', 'assert(greed.process.run({ "true" }))'))
	t:run("runner-go")
	t:wait(100)
	assert(last(t) == "ok", last(t))
end)

test("saving a buffer to another path needs fs.write, its own file doesn't", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(dir .. "/a.txt")
	greed.plugin.load(plugin(t, "saver", "", `ctx.buffer:save()\nctx.buffer:save("{dir}/b.txt")`))
	t:run("saver-go")
	assert(string.find(last(t), 'add "fs.write"', 1, true), last(t))
	assert(greed.fs.read(dir .. "/b.txt") == nil, "nothing was written")
end)

local function said(t: test.TestContext, text: string): boolean
	return string.find(table.concat(t:messages(), "\n"), text, 1, true) ~= nil
end

-- A plugin that may run programs, with a command doing so on ctrl-alt-r.
local function runner(t: test.TestContext)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "runner"\ncapabilities = ["proc"]\n',
		["init.luau"] = [[
local greed = require("@greed")
greed.command({ name = "run-true", run = function()
	local ok, err = pcall(greed.process.run, { "true" })
	greed.echo(if ok then "ran" else tostring(err))
end })
greed.keymap.bind("helix", { ["ctrl-alt-r"] = "run-true" })
]],
	}))
end

test("a command a plugin runs can do only what that plugin may", function(t)
	t:buffer("|x")
	runner(t)
	greed.plugin.load(plugin(t, "plain", "", 'greed.run("run-true", { wait = true })'))
	t:run("plain-go")
	t:wait(100)
	assert(said(t, 'plain started it, and doesn\'t have "proc"'), table.concat(t:messages(), "\n"))
	-- You running it is another matter.
	t:run("run-true")
	t:wait(100)
	assert(said(t, "ran"), "it ran")
end)

test("keys a plugin feeds run within what it may", function(t)
	t:buffer("|x")
	runner(t)
	greed.plugin.load(plugin(t, "feeder", "", 'greed.keys.feed("ctrl-alt-r")'))
	t:run("feeder-go")
	t:wait(100)
	assert(said(t, 'feeder started it, and doesn\'t have "proc"'), table.concat(t:messages(), "\n"))
	-- Typed by you, the same keys run.
	t:keys("ctrl-alt-r")
	t:wait(100)
	assert(said(t, "ran"), "it ran")
end)

test("what a command started by a plugin leaves running stays within it", function(t)
	t:buffer("|x")
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "later"\ncapabilities = ["proc"]\n',
		["init.luau"] = [[
local greed = require("@greed")
greed.command({ name = "later", run = function()
	greed.spawn(function()
		greed.sleep(10)
		local ok, err = pcall(greed.process.run, { "true" })
		greed.echo(if ok then "later ran" else tostring(err))
	end)
end })
]],
	}))
	greed.plugin.load(plugin(t, "starter", "", 'greed.run("later")'))
	t:run("starter-go")
	t:wait(50)
	assert(
		said(t, 'starter started it, and doesn\'t have "proc"'),
		table.concat(t:messages(), "\n")
	)
	t:run("later")
	t:wait(50)
	assert(last(t) == "later ran", last(t))
end)

test("keys a plugin feeds don't answer what waits for you to press one", function(t)
	t:buffer("|x")
	local answer: string? = nil
	greed.command({
		name = "test-ask",
		run = function()
			answer = greed.next_key()
		end,
	})
	t:run("test-ask")
	greed.plugin.load(plugin(t, "answerer", "", 'greed.keys.feed("y")'))
	t:run("answerer-go")
	assert(said(t, "keys answerer feeds can't answer"), table.concat(t:messages(), "\n"))
	assert(answer == nil, "still waiting")
	t:keys("n")
	assert(answer == "n", tostring(answer))
end)

test("typing into a terminal takes proc, whoever has the terminal", function(t)
	t:buffer("|x")
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "snoop"\n',
		["init.luau"] = [[
local greed = require("@greed")
greed.on("terminal.output", function(event)
	local ok, err = pcall(function()
		event.terminal:write("echo hi\n")
	end)
	greed.echo(if ok then "typed" else tostring(err))
end)
]],
	}))
	local terminal = greed.terminal.spawn({
		command = { "sh", "-c", "echo ready; sleep 1" },
		rows = 5,
		cols = 20,
	})
	local messages: { string } = {}
	t:wait_for(function()
		for _, message in t:messages() do
			table.insert(messages, message)
		end
		return #messages > 0
	end)
	local text = table.concat(messages, "\n")
	assert(
		string.find(
			text,
			'snoop can\'t run programs, which can do anything you can: add "proc"',
			1,
			true
		),
		text
	)
	assert(not string.find(text, "typed", 1, true), "nothing was typed")
	terminal:close()
end)

test("only plugins with control answer the session's requests", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "replier", "", "greed.control.reply(1, {})"))
	t:run("replier-go")
	assert(string.find(last(t), 'add "control" to capabilities', 1, true), last(t))
end)

test("loading a grammar reads a file, and server commands run programs", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "grammar", "", 'greed.syntax.load_grammar("x", "/etc/hostname")'))
	t:run("grammar-go")
	assert(string.find(last(t), 'add "fs.read"', 1, true), last(t))
	greed.plugin.load(
		plugin(t, "server", "", 'greed.lsp.request(ctx.buffer, "workspace/executeCommand", {})')
	)
	t:run("server-go")
	assert(string.find(last(t), 'add "proc"', 1, true), last(t))
end)

test("calling what core offers runs within the caller's capabilities", function(t)
	t:buffer("|x")
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	-- Opening a project reads its folder and writes the recent projects list.
	local open = `require("@core").project.open("{dir}")`
	greed.plugin.load(plugin(t, "opener", '"fs.read"', open, '"core"'))
	t:run("opener-go")
	assert(
		string.find(
			last(t),
			"core can't write any file, by path for opener: add \"fs.write\" to capabilities in opener's plugin.toml",
			1,
			true
		),
		last(t)
	)
	greed.plugin.load(plugin(t, "writer", '"fs.read", "fs.write"', open, '"core"'))
	t:run("writer-go")
	assert(last(t) == "ok", last(t))
end)

-- A plugin that may write files, offering `write(path)` and `keep(f)`, and
-- a command `keeper-run` that calls what was kept.
local function keeper(t: test.TestContext)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "keeper"\ncapabilities = ["fs.write"]\n',
		["init.luau"] = [[
local greed = require("@greed")
local kept: (() -> ())? = nil
greed.command({ name = "keeper-run", run = function()
	local ok, err = pcall(kept :: () -> ())
	greed.echo(if ok then "kept ran" else tostring(err))
end })
return {
	write = function(path: string)
		assert(greed.fs.write(path, "x"))
	end,
	keep = function(f: () -> ())
		kept = f
	end,
}
]],
	}))
end

test("what a plugin hands another, or runs in a coroutine, stays within it", function(t)
	t:buffer("|x")
	keeper(t)
	local file = t:tempdir() .. "/out.txt"
	local refused = 'keeper can\'t write any file, by path for sneak: add "fs.write"'
	local function try(body: string)
		greed.plugin.load(plugin(t, "sneak", "", body, '"keeper"'))
		t:run("sneak-go")
	end
	try(`require("@keeper").write("{file}")`)
	assert(string.find(last(t), refused, 1, true), last(t))
	try(`require("@keeper").keep(function() require("@keeper").write("{file}") end)`)
	t:run("keeper-run")
	assert(string.find(last(t), refused, 1, true), last(t))
	-- Through pcall, which puts a C frame between them.
	try(
		`require("@keeper").keep(function() local _, err = pcall(require("@keeper").write, "{file}") error(tostring(err)) end)`
	)
	t:run("keeper-run")
	local through = last(t)
	assert(string.find(through, refused, 1, true), through)
	try(`coroutine.wrap(require("@keeper").write)("{file}")`)
	assert(string.find(last(t), refused, 1, true), last(t))
	try(`greed.spawn(require("@keeper").write, "{file}")`)
	assert(said(t, "sneak started it") or said(t, refused), "spawned")
	assert(greed.fs.read(file) == nil, "nothing was written")
end)

test("loadstring code counts as its plugin, whatever it's named", function(t)
	t:buffer("|x")
	-- A chunk named after core, run as an event handler, a spawned task
	-- and straight away: none of it gets core's grant.
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "faker"\n',
		["init.luau"] = [[
local greed = require("@greed")
-- A chunk named after core that runs a program. As a command handler and a
-- spawned task it runs with no faker frame on the stack: only "@core/x".
local evil = loadstring(
	'local ok, err = pcall(require("@greed").process.run, { "true" }) '
		.. 'require("@greed").echo(if ok then "ran" else tostring(err))',
	"@core/x"
) :: () -> ()
greed.command({ name = "faker-direct", run = function() evil() end })
greed.command({ name = "faker-handler", run = evil })
greed.command({ name = "faker-spawn", run = function() greed.spawn(evil) end })
]],
	}))
	for _, go in { "faker-direct", "faker-handler", "faker-spawn" } do
		t:run(go)
	end
	t:wait(50)
	-- Every route is refused for faker and never runs the program.
	local text = table.concat(t:messages(), "\n")
	assert(not string.find(text, "ran", 1, true), text)
	assert(
		string.find(
			text,
			'faker can\'t run programs, which can do anything you can: add "proc"',
			1,
			true
		),
		text
	)
end)

test("getfenv and setfenv can't reach into another plugin", function(t)
	t:buffer("|x")
	local body = "require('@core') assert(not pcall(getfenv)) assert(not pcall(setfenv))"
	greed.plugin.load(plugin(t, "peeker", "", body, '"core"'))
	t:run("peeker-go")
	assert(last(t) == "ok", last(t))
end)

test("an unknown capability stops the plugin loading", function(t)
	local ok, err = pcall(greed.plugin.load, plugin(t, "odd", '"teleport"', ""), nil)
	assert(
		not ok and string.find(tostring(err), 'no capability "teleport"', 1, true),
		tostring(err)
	)
end)

test(
	"a handler a registry keeps runs as the plugin that gave it, and takes only its own",
	function(t)
		t:buffer("|x")
		local dir = t:tempdir({ ["kept.txt"] = "kept\n" })
		greed.plugin.load(t:tempdir({
			["plugin.toml"] = 'name = "rack"\n',
			["init.luau"] = [[
local greed = require("@greed")
local kept = {}
return {
	add = function(f: () -> string?)
		table.insert(kept, greed.plugin.handler(f))
	end,
	run = function(): string?
		return kept[#kept]()
	end,
}
]],
		}))
		local adds = `require("@rack").add(function() return greed.fs.read("{dir}/kept.txt") end)`
		greed.plugin.load(plugin(t, "reader", '"fs.read"', adds, '"rack"'))
		t:run("reader-go")
		assert(last(t) == "ok", last(t))
		-- Run through the rack by a plugin that can't read files, it's still
		-- reader's own.
		local runs = `assert(require("@rack").run() == "kept\\n")`
		greed.plugin.load(plugin(t, "nosy", "", runs, '"rack"'))
		t:run("nosy-go")
		assert(last(t) == "ok", last(t))
		-- Another plugin's function isn't the caller's to hand over as its own.
		local hands = `require("@rack").add(require("@rack").run)`
		greed.plugin.load(plugin(t, "thief", "", hands, '"rack"'))
		t:run("thief-go")
		assert(string.find(last(t), "takes a function of thief", 1, true), last(t))
	end
)

test("what a plugin vouches for counts only against it, but not code handed to it", function(t)
	t:buffer("|x")
	local dir = t:tempdir({})
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "writer"\ncapabilities = ["fs.read", "fs.write"]\n',
		["init.luau"] = [[
local greed = require("@greed")
local function write(path: string)
	assert(greed.fs.write(path, "x"))
end
return {
	write = function(path: string)
		greed.vouch(write, path)
	end,
	run = function(f: () -> ())
		greed.vouch(f)
	end,
}
]],
	}))
	local vouched = `require("@writer").write("{dir}/vouched.txt")`
	greed.plugin.load(plugin(t, "client", "", vouched, '"writer"'))
	t:run("client-go")
	assert(last(t) == "ok", last(t))
	assert(greed.fs.read(`{dir}/vouched.txt`) == "x", "the writer wrote it")

	-- Code handed to a vouched function still counts as its own: opening a
	-- project through core writes a file, which sneaky may not.
	local project = t:tempdir({ ["a.txt"] = "a\n" })
	local handed =
		`require("@writer").run(function() require("@core").project.open("{project}") end)`
	greed.plugin.load(plugin(t, "sneaky", '"fs.read"', handed, '"writer", "core"'))
	t:run("sneaky-go")
	local said = last(t)
	assert(string.find(said, 'add "fs.write" to capabilities in sneaky', 1, true), said)
end)

test("greed.eval code has every capability, unless a plugin without eval is involved", function(t)
	t:buffer("|x")
	local dir = t:tempdir({})
	-- It may eval, and nothing more: its own code can't write files.
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "evaluator"\ncapabilities = ["eval"]\n',
		["init.luau"] = [[
local greed = require("@greed")
local M = {}
function M.run(code: string): string
	local ok, said = greed.eval(code)
	return if ok then "ok" else said
end
greed.command({ name = "evaluator-go", args = { { name = "code" } }, run = function(ctx)
	greed.echo(M.run(ctx.args[1]))
end })
return M
]],
	}))
	local function write(name: string): string
		return `require("@greed").fs.write("{dir}/{name}", "x")`
	end
	-- Started by you, as :lua is.
	t:run("evaluator-go", { write("yours.txt") })
	local said = last(t)
	assert(said == "ok", said)
	assert(greed.fs.read(`{dir}/yours.txt`) == "x", "written")
	-- A plugin without eval handing it code gets no more than it has.
	local handed =
		`local said = require("@evaluator").run([[{write("handed.txt")}]]) assert(said == "ok", said)`
	greed.plugin.load(plugin(t, "deputy", "", handed, '"evaluator"'))
	t:run("deputy-go")
	said = last(t)
	assert(string.find(said, 'add "eval" to capabilities in deputy', 1, true), said)
	assert(greed.fs.read(`{dir}/handed.txt`) == nil, "not written")
	-- Nor does a command it starts.
	local started =
		`greed.run("evaluator-go", \{ args = \{ [[{write("started.txt")}]] \}, wait = true \})`
	greed.plugin.load(plugin(t, "starter2", "", started))
	t:run("starter2-go")
	t:wait(50)
	assert(greed.fs.read(`{dir}/started.txt`) == nil, "not written")
end)

test(
	"an option whose value runs a program is set only by code that may run them, or by you",
	function(t)
		t:buffer("|x")
		local before = greed.option.get("link-opener")
		-- A plugin without proc, directly, through :set, or by taking it over.
		greed.plugin.load(plugin(t, "opener", "", 'greed.option.set("link-opener", "sh -c evil")'))
		t:run("opener-go")
		local said = last(t)
		assert(string.find(said, 'add "proc" to capabilities in its plugin.toml', 1, true), said)
		greed.plugin.load(
			plugin(
				t,
				"setter",
				"",
				'greed.run("set", { args = { "link-opener", "sh -c evil" }, wait = true })'
			)
		)
		t:run("setter-go")
		t:wait(20)
		greed.plugin.load(
			plugin(
				t,
				"taker",
				"",
				'greed.option.define({ name = "link-opener", default = "sh -c evil" })'
			)
		)
		t:run("taker-go")
		said = last(t)
		assert(string.find(said, "is core's", 1, true), said)
		assert(greed.option.get("link-opener") == before, tostring(greed.option.get("link-opener")))
		-- You, at the command line.
		t:keys(": s e t space l i n k - o p e n e r space f i r e f o x enter")
		assert(
			greed.option.get("link-opener") == "firefox",
			tostring(greed.option.get("link-opener"))
		)
		greed.option.set("link-opener", before)
	end
)

test("saving a buffer, even to its own file, needs fs.write", function(t)
	t:buffer("|x")
	local dir = t:tempdir({ ["init.luau"] = "-- mine\n" })
	local body =
		`local b = greed.load("{dir}/init.luau") b:edit(function(e) e:insert(0, "evil()\\n") end) b:save()`
	greed.plugin.load(plugin(t, "reader", '"fs.read"', body))
	t:run("reader-go")
	local said = last(t)
	assert(string.find(said, 'add "fs.write" to capabilities in its plugin.toml', 1, true), said)
	assert(greed.fs.read(`{dir}/init.luau`) == "-- mine\n", "not written")
end)

test("only you, or plugins that may, approve plugins: not one that starts the review", function(t)
	t:buffer("|x")
	local waiting = t:tempdir({
		["plugin.toml"] = 'name = "waiting"\ncapabilities = ["proc"]\n',
		["init.luau"] = "return {}\n",
	})
	-- Through a command that vouches, as the approvals picker's does.
	greed.plugin.load(
		plugin(t, "sneaky-approver", "", 'greed.run("approve-it", { args = {}, wait = true })')
	)
	greed.command({
		name = "approve-it",
		run = function()
			local ok, err = pcall(function()
				greed.vouch(function()
					greed.plugin.approve(waiting)
				end)
			end)
			greed.echo(if ok then "approved" else tostring(err))
		end,
	})
	t:run("sneaky-approver-go")
	t:wait(20)
	local said = table.concat(t:messages(), "\n")
	assert(string.find(said, "approving plugins is yours to do", 1, true), said)
end)

test("a plugin without commands can't leave a macro for you to play", function(t)
	t:buffer("|x")
	greed.plugin.load(
		plugin(
			t,
			"macro-setter",
			"",
			'require("@core").registers.set_macro("@", ": l u a space x enter")',
			'"core"'
		)
	)
	t:run("macro-setter-go")
	local said = last(t)
	assert(string.find(said, "can't set a macro", 1, true), said)
	assert(require("@core").registers.macro("@") == nil, "not set")
end)

test("searching files never reads Greed's secrets file", function(t)
	greed.secrets.set("grep-test", "find-me-not-1234")
	local home = assert(greed.fs.dirs().home)
	local found = greed.fs.grep("find%-me%-not%-1234", home, { hidden = true, ignored = true })
	assert(#(found or {}) == 0, greed.json.encode(found))
end)
