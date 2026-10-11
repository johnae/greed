-- The rows of `docker ps`, as docker prints them, printed by a stand-in
-- for docker and run as typed, so a change in how they're read shows here
-- first.

local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A shell whose `docker` prints `output`, whatever it's asked.
local function printing(t: test.TestContext, output: string): Shell
	local dir = t:tempdir({
		["bin/docker"] = '#!/bin/sh\ncat "$(dirname "$0")/output"\n',
		["bin/output"] = output,
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/docker` }))
	greed.option.set("shell-fallback", "sh")
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

-- The ids of the objects `block`'s rows are, in order.
local function row_ids(sh: Shell, block: Block): string
	local here = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{block.number}`))
	local rows: { core.Object } = core.objects.related(here).rows or {}
	local out = {}
	for _, object in rows do
		table.insert(out, object.id)
	end
	return table.concat(out, ",")
end

test("docker ps: rows are containers", function(t)
	local sh = printing(
		t,
		[[
CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS        PORTS                  NAMES
3f2a1b4c5d6e   nginx:latest   "/docker-entrypoint.…"   2 hours ago    Up 2 hours    0.0.0.0:8080->80/tcp   web
9a8b7c6d5e4f   postgres:16    "docker-entrypoint.s…"   3 days ago     Up 3 days     5432/tcp               db
]]
	)
	local block = ran(t, sh, "docker ps")
	assert(block.table, `no table in: {block.output}`)
	assert(block.called and block.called.many == "containers")
	local ids = row_ids(sh, block)
	assert(ids == "container:web,container:db", ids)
	assert(assert(core.objects.get("container:web")).label == "web")
end)

test("a container's image is an object", function(t)
	local sh = printing(
		t,
		"CONTAINER ID   IMAGE          COMMAND   CREATED       STATUS       PORTS   NAMES\n"
			.. '3f2a1b4c5d6e   nginx:latest   "nginx"   2 hours ago   Up 2 hours           web\n'
	)
	ran(t, sh, "docker ps")
	local image =
		assert(assert(core.objects.related(assert(core.objects.get("container:web")))).image)[1]
	assert(image.id == "image:nginx:latest", image.id)
	local count = #sh.blocks
	assert(core.objects.act(assert(core.objects.get(image.id)), "inspect"))
	t:wait_for(function()
		return #sh.blocks > count and sh.blocks[#sh.blocks].status ~= "running"
	end)
	local inspected = sh.blocks[#sh.blocks].command
	assert(inspected == "docker image inspect nginx:latest", inspected)
end)
