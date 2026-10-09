local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local envs = shell.envs

-- A provider standing in for devenv: a folder with `test.env` brings the
-- NAME=VALUE lines in it. A load started after `hold()` waits for
-- `release()`, a line `fail` fails it, and a folder with `test.denied`
-- isn't allowed.
local slow: { gate: greed.Signal?, loads: number } = { gate = nil, loads = 0 }

local function hold()
	slow.gate = greed.signal()
end

local function release()
	local gate = assert(slow.gate)
	slow.gate = nil
	gate:send(true)
end

local function nearest(dir: string, file: string): string?
	local at: string? = dir
	while at and at ~= "" do
		if greed.fs.stat(`{at}/{file}`) then
			return at
		end
		at = string.match(at, "^(.*)/[^/]*$")
	end
	return nil
end

local function provide(t: test.TestContext)
	slow.gate, slow.loads = nil, 0
	shell.environment("test", {
		root = function(dir: string): (string?, string?)
			if nearest(dir, "test.denied") then
				return nil, "not allowed"
			end
			return nearest(dir, "test.env"), nil
		end,
		load = function(root: string): shell.LoadedEnvironment
			slow.loads += 1
			local gate = slow.gate
			if gate then
				gate:wait()
			end
			local vars: { [string]: string | false } = {}
			for _, line in string.split(greed.fs.read(`{root}/test.env`) or "", "\n") do
				assert(line ~= "fail", "the environment failed to build")
				local name, value = string.match(line, "^([%w_]+)=(.*)$")
				if name and value then
					vars[name] = value
				end
			end
			return { vars = vars, watch = { `{root}/test.env` }, output = "" }
		end,
	})
	greed.option.set("shell-environments", "test")
end

-- Runs `line` in `sh` in the background, as it waits for the environment,
-- and gives back its block once it's there.
local function started(t: test.TestContext, sh: Shell, line: string): Block
	local count = #sh.blocks
	greed.spawn(function()
		shell.run(sh, line, { runner = "pipe" })
	end)
	t:wait_for(function()
		return #sh.blocks > count
	end)
	return sh.blocks[#sh.blocks]
end

local function open(t: test.TestContext, dir: string): Shell
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	envs.refresh(sh)
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string, by: string?): Block
	local block = assert(shell.run(sh, line, { by = by, runner = "pipe" }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

local function prompt_text(sh: Shell): string
	local parts: { string } = {}
	for _, mark in sh.buffer:decorations("shell.prompt") do
		if mark.text and mark.lines == nil then
			table.insert(parts, mark.text)
		end
	end
	return table.concat(parts)
end

local function shows(t: test.TestContext, sh: Shell, text: string)
	t:wait_for(function()
		return string.find(prompt_text(sh), text, 1, true) ~= nil
	end)
end

test("a folder's environment is there for its commands, and goes on leaving it", function(t)
	provide(t)
	local dir = t:tempdir({ ["test.env"] = "GREED_T=one\n", ["sub/x"] = "", ["other/x"] = "" })
	local outside = t:tempdir()
	local sh = open(t, dir .. "/sub")
	shows(t, sh, "❄ test")
	assert(ran(t, sh, "printenv GREED_T").stdout == "one\n")
	-- What you export wins over it.
	ran(t, sh, "export GREED_T=mine")
	assert(ran(t, sh, "printenv GREED_T").stdout == "mine\n")
	ran(t, sh, "unset GREED_T")
	assert(ran(t, sh, "printenv GREED_T || echo none").stdout == "none\n")
	table.clear(sh.env)
	ran(t, sh, `cd {outside}`)
	t:wait_for(function()
		return sh.environment == nil
	end)
	assert(ran(t, sh, "printenv GREED_T || echo none").stdout == "none\n")
	assert(not string.find(prompt_text(sh), "❄", 1, true), prompt_text(sh))
	-- Coming back loads nothing again: the shells share one load.
	ran(t, sh, `cd {dir}/other`)
	assert(ran(t, sh, "printenv GREED_T").stdout == "one\n")
	assert(slow.loads == 1, tostring(slow.loads))
end)

test("a command waits for the environment to load, or runs without when interrupted", function(t)
	provide(t)
	local dir = t:tempdir({ ["test.env"] = "GREED_T=one\n" })
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	hold()
	greed.spawn(function()
		envs.refresh(sh)
	end)
	shows(t, sh, "❄ test…")
	local block = started(t, sh, "printenv GREED_T")
	t:wait_for(function()
		return block.note == "waiting for test"
	end)
	assert(block.status == "running")
	release()
	t:wait_for(function()
		return block.status ~= "running"
	end)
	assert(block.stdout == "one\n", block.stdout)
	-- Interrupting one that waits runs it without.
	hold()
	greed.spawn(function()
		envs.reload(sh)
	end)
	local waiting = started(t, sh, "printenv GREED_T || echo none")
	t:wait_for(function()
		return waiting.note == "waiting for test"
	end)
	assert(shell.interrupt(waiting))
	t:wait_for(function()
		return waiting.status ~= "running"
	end)
	assert(waiting.stdout == "none\n", waiting.stdout)
	release()
end)

test("changing what it comes from loads it again; env reload does too", function(t)
	provide(t)
	local dir = t:tempdir({ ["test.env"] = "GREED_T=one\n" })
	local sh = open(t, dir)
	greed.fs.write(`{dir}/test.env`, "GREED_T=two\n")
	t:wait_for(function()
		return sh.provided.GREED_T == "two"
	end)
	assert(ran(t, sh, "printenv GREED_T").stdout == "two\n")
	local loads = slow.loads
	local listed = ran(t, sh, "env reload")
	assert(slow.loads == loads + 1, tostring(slow.loads))
	assert(string.find(listed.stdout, "test for .*: 1 variable, loaded"), listed.stdout)
end)

test("a failed or refused environment says so, and commands run without it", function(t)
	provide(t)
	local broken = t:tempdir({ ["test.env"] = "GREED_T=one\nfail\n" })
	local sh = open(t, broken)
	shows(t, sh, "❄ test failed")
	assert(ran(t, sh, "printenv GREED_T || echo none").stdout == "none\n")
	local said = ran(t, sh, "env")
	assert(string.find(said.stdout, "failed to build", 1, true), said.stdout)
	assert(ran(t, sh, "env reload").code == 1)
	local denied = t:tempdir({ ["test.env"] = "GREED_T=one\n", ["test.denied"] = "" })
	ran(t, sh, `cd {denied}`)
	t:wait_for(function()
		return sh.environment == nil
	end)
	shows(t, sh, "❄ test: not allowed")
	assert(ran(t, sh, "printenv GREED_T || echo none").stdout == "none\n")
end)

test("an agent's commands get it too, without it in what the agent reads", function(t)
	provide(t)
	local dir = t:tempdir({ ["test.env"] = "GREED_T=one\n" })
	local sh = open(t, dir)
	local block = ran(t, sh, "printenv GREED_T", "agent")
	assert(block.stdout == "one\n", block.stdout)
	assert(shell.record(block).env.GREED_T == nil, "not in its record's variables")
end)

test("direnv's variables are read with the ones it takes away", function()
	local vars =
		envs.direnv_vars('{\n  "GREED_A": "1",\n  "GREED_B": null,\n  "GREED_C": "x: null"\n}')
	assert(vars.GREED_A == "1" and vars.GREED_B == false, greed.json.encode(vars))
	assert(vars.GREED_C == "x: null", "a value that says null stays")
	assert(next(envs.direnv_vars("")) == nil, "nothing to load")
end)
