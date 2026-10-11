local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A shell whose `docker` prints JSON lines for `--format json` (one with a
-- space in a name, which a table on screen splits on) and its tables
-- otherwise; `old` makes it an old docker that prints `json` as text.
local function fake(t: test.TestContext, old: boolean?): Shell
	local ps = '{"ID":"3f2a1b4c5d6e","Image":"nginx","Names":"web","Status":"Up 2 hours","Ports":"","RunningFor":"2 hours ago","Command":"\\"nginx -g\\""}\n'
		.. '{"ID":"9a8b7c6d5e4f","Image":"postgres:16","Names":"db","Status":"Exited (1) 3 minutes ago","Ports":"5432/tcp","RunningFor":"3 days ago","Command":"\\"docker-entrypoint\\""}\n'
	local stats = '{"ID":"3f2a1b4c5d6e","Name":"web","CPUPerc":"12.50%","MemUsage":"20MiB / 1GiB","MemPerc":"1.95%","NetIO":"1kB / 2kB","BlockIO":"0B / 0B","PIDs":"3"}\n'
		.. '{"ID":"9a8b7c6d5e4f","Name":"db","CPUPerc":"40.00%","MemUsage":"200MiB / 1GiB","MemPerc":"19.53%","NetIO":"0B / 0B","BlockIO":"1MB / 0B","PIDs":"12"}\n'
	local script = if old
		then '#!/bin/sh\necho "$*" >> "$(dirname "$0")/../asked"\ncase "$*" in *"--format json"*) echo json; echo json ;; *) printf "CONTAINER ID   IMAGE   NAMES\\n3f2a1b4c5d6e   nginx   web\\n" ;; esac\n'
		else '#!/bin/sh\necho "$*" >> "$(dirname "$0")/../asked"\ncase "$*" in\n  *stats*) cat "$(dirname "$0")/../stats" ;;\n  *) cat "$(dirname "$0")/../ps" ;;\nesac\n'
	local dir = t:tempdir({ ["bin/docker"] = script, ps = ps, stats = stats })
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

local function asked(sh: Shell): string
	return greed.fs.read(`{sh.cwd}/asked`) or ""
end

test("docker ps with stages after it is read from its JSON", function(t)
	local sh = fake(t)
	local block = ran(t, sh, "docker ps -a | where STATUS ~ Exited")
	assert(block.status == "done", block.output)
	assert(string.find(asked(sh), "ps -a --format json", 1, true), asked(sh))
	assert(string.find(block.output, "db", 1, true), block.output)
	assert(not string.find(block.output, "web", 1, true), block.output)
	assert(string.find(block.output, "postgres:16", 1, true), block.output)
	assert(string.find(block.note or "", "read as data", 1, true), tostring(block.note))
end)

test("docker stats --no-stream charts its CPU from the JSON", function(t)
	local sh = fake(t)
	local block = ran(t, sh, "docker stats --no-stream | sort CPU -r")
	assert(block.status == "done", block.output)
	assert(string.find(asked(sh), "stats --no-stream --format json", 1, true), asked(sh))
	local db = assert(string.find(block.output, "db", 1, true), block.output)
	local web = assert(string.find(block.output, "web", 1, true), block.output)
	assert(db < web, block.output)
	local chart = ran(t, sh, "docker stats --no-stream | chart CPU")
	assert(chart.status == "done", chart.output)
	assert(string.find(chart.output, "█", 1, true), chart.output)
end)

test("a command asking its own format, or with no stages, runs as typed", function(t)
	local sh = fake(t)
	ran(t, sh, "docker ps --format '{{.Names}}' | where x")
	ran(t, sh, "docker ps")
	ran(t, sh, "docker stats | where NAME = web")
	local said = asked(sh)
	assert(not string.find(said, "--format json", 1, true), said)
end)

test("an old docker that can't print JSON is read from its table", function(t)
	local sh = fake(t, true)
	local block = ran(t, sh, "docker ps | where NAMES = web")
	assert(block.status == "done", block.output)
	assert(string.find(asked(sh), "--format json", 1, true), asked(sh))
	assert(string.find(block.output, "nginx", 1, true), block.output)
	assert(block.note == nil or not string.find(block.note, "read as data", 1, true), block.note)
end)
