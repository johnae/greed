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

-- What `docker ps` prints with a long PORTS column, NAMES last as docker
-- puts it.
local WIDE_PS = [[
CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS        PORTS                                       NAMES
3f2a1b4c5d6e   nginx:latest   "/docker-entrypoint.…"   2 hours ago    Up 2 hours    0.0.0.0:8080->80/tcp, [::]:8080->80/tcp     web-frontend
9a8b7c6d5e4f   postgres:16    "docker-entrypoint.s…"   3 days ago     Up 3 days     5432/tcp                                    db
]]

test("docker ps shows NAMES first, so a narrow pane cuts COMMAND and PORTS instead", function(t)
	local sh = printing(t, WIDE_PS)
	local block = ran(t, sh, "docker ps")
	local tbl = assert(block.table)
	assert(tbl.columns[1] == "NAMES" and tbl.columns[2] == "IMAGE", table.concat(tbl.columns, ","))
	local screen = table.concat(t:draw(40, 20), "\n")
	assert(string.find(screen, "\nNAMES ", 1, true), screen)
	assert(string.find(screen, "\nweb-frontend ", 1, true), screen)
	assert(string.find(screen, "\ndb ", 1, true), screen)
	-- The rows are still the containers, and a cell is still in its column.
	assert(row_ids(sh, block) == "container:web-frontend,container:db", row_ids(sh, block))
	assert(tbl.rows[2].PORTS == "5432/tcp", tbl.rows[2].PORTS)
	-- What it printed is kept as it came.
	assert(string.find(block.stdout, "^CONTAINER ID"), block.stdout)
end)

test("columns picked with select keep the order they were picked in", function(t)
	local sh = printing(t, WIDE_PS)
	local block = ran(t, sh, "docker ps | select IMAGE,NAMES")
	local tbl = assert(block.table, block.output)
	assert(table.concat(tbl.columns, ",") == "IMAGE,NAMES", table.concat(tbl.columns, ","))
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
