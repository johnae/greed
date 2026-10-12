local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A shell whose `docker` prints a table for `ps` and says what it was
-- asked otherwise.
local function fake(t: test.TestContext): Shell
	local dir = t:tempdir({
		["bin/docker"] = '#!/bin/sh\nif [ "$1" = "ps" ]; then\n  printf "CONTAINER ID   IMAGE      NAMES\\n3f2a1b4c5d6e   nginx      web\\n"\nelse\n  echo "docker $*"\nfi\n',
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/docker` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- Puts the cursor on the line of `block`'s output holding `text`.
local function on(sh: Shell, block: Block, text: string)
	local from = shell.output(sh, block)
	assert(from, "a block with output")
	local at = assert(string.find(sh.buffer:text(), text, from + 1, true), text)
	greed.view():set_cursor(at - 1)
end

-- The thing of `kind` at the cursor, as `space .` finds it.
local function thing_here(kind: string): core.Target?
	for _, target in core.actions.at(greed.view()) do
		if target.kind == kind then
			return target
		end
	end
	return nil
end

-- Runs action `name` on `target` and gives back the block it ran.
local function act(t: test.TestContext, sh: Shell, target: any, name: string): Block
	local count = #sh.blocks
	for _, action in core.actions.for_kind(target.kind) do
		if action.name == name then
			action.run(target)
		end
	end
	t:wait_for(function()
		local last = sh.blocks[#sh.blocks]
		return #sh.blocks > count and last.status ~= "running"
	end)
	return sh.blocks[#sh.blocks]
end

-- What completion offers with `text` at `sh`'s prompt, in order.
local function offered(t: test.TestContext, sh: Shell, text: string): { { label: string } }
	shell.set_prompt(sh, text, { greed.view() })
	local found: { any }? = nil
	greed.spawn(function()
		found = shell.completions(greed.view(), { explicit = true }) or {}
	end)
	t:wait_for(function()
		return found ~= nil
	end, 10000)
	return assert(found)
end

test("docker ps's rows are containers, whose logs run docker logs", function(t)
	local sh = fake(t)
	local containers = ran(t, sh, "docker ps")
	assert(containers.called and containers.called.many == "containers")
	on(sh, containers, "nginx")
	local web = assert(thing_here("container"))
	assert(web.label == "web")
	local logs = act(t, sh, web, "logs")
	assert(logs.command == "docker logs --tail 200 web", logs.command)
	assert(string.find(logs.output, "docker logs --tail 200 web", 1, true), logs.output)
end)

test("completion offers containers for docker, from blocks above", function(t)
	local sh = fake(t)
	ran(t, sh, "docker ps")
	assert(offered(t, sh, "docker logs --tail 50 ")[1].label == "web")
	-- A one-word alias or a path to the program counts as it.
	shell.use_aliases({ d = "docker" })
	assert(offered(t, sh, "d logs ")[1].label == "web")
	assert(offered(t, sh, `{sh.cwd}/bin/docker logs `)[1].label == "web")
	shell.use_aliases(nil)
end)

test("container rows are container:NAME", function(t)
	local sh = fake(t)
	ran(t, sh, "docker ps")
	local web = assert(core.objects.get("container:web"))
	assert(core.objects.inspect(web).row.IMAGE == "nginx")
end)

test("docker that changes containers is risky for an agent; looking isn't", function()
	local risk = core.risk
	for _, line in { "docker ps -a", "docker logs web", "docker compose ps", "docker image ls" } do
		assert(risk.of(line) == nil, line)
	end
	local cases: { [string]: string } = {
		["docker rm -f web"] = "(docker rm)",
		["docker compose down"] = "(docker down)",
		["docker exec -it web sh"] = "in a container",
	}
	for line, says in cases do
		local why = risk.of(line)
		assert(why and string.find(why, says, 1, true), `{line}: {why}`)
	end
end)
