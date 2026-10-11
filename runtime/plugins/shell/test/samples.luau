-- The rows of the commands people run most, as each system prints them:
-- GNU and macOS (BSD) `ls -l` and `ps`, and `lsof`.
-- Each sample is printed by a stand-in for its program and run as typed,
-- so a change in how they're read shows here first. The last test runs
-- the real `ls` and `ps` of the machine the tests run on.

local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- A sample: the program printing it, the line run, what it printed, what
-- its rows are called, and the id (with the label, when given) of each
-- row that's an object, in order.
type Sample = {
	name: string,
	program: string,
	line: string,
	output: string,
	many: string,
	rows: { { id: string, label: string? } },
}

local SAMPLES: { Sample } = {
	{
		name = "GNU ls -l",
		program = "ls",
		line = "ls -l",
		output = [[
total 12
-rw-r--r-- 1 me users 2209 Oct 10 10:18 Cargo.toml
drwxr-xr-x 4 me users 4096 Oct  9 21:02 src
lrwxrwxrwx 1 me users    9 Oct  1  2025 latest -> src
]],
		many = "files",
		rows = {
			{ id = "file:DIR/Cargo.toml" },
			{ id = "folder:DIR/src" },
			{ id = "file:DIR/latest", label = "latest" },
		},
	},
	{
		name = "macOS ls -l",
		program = "ls",
		line = "ls -l",
		output = [[
total 16
-rw-r--r--@  1 me  staff  2209 Oct 10 10:18 Cargo.toml
drwxr-xr-x   4 me  staff   128 Oct  9 21:02 src
-rw-r--r--   1 me  staff     0 Oct  1  2025 with space.txt
]],
		many = "files",
		rows = {
			{ id = "file:DIR/Cargo.toml" },
			{ id = "folder:DIR/src" },
			{ id = "file:DIR/with space.txt", label = "with space.txt" },
		},
	},
	{
		name = "GNU ps aux",
		program = "ps",
		line = "ps aux",
		output = [[
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.2  0.0  20696 15628 ?        Ss   16:40   0:26 /sbin/init splash
me          4711  1.5  2.0 912345 81234 pts/1    Sl+  18:02   1:02 greed notes.md
]],
		many = "processes",
		rows = {
			{ id = "process:1", label = "1 /sbin/init splash" },
			{ id = "process:4711", label = "4711 greed notes.md" },
		},
	},
	{
		name = "macOS ps aux",
		program = "ps",
		line = "ps aux",
		output = [[
USER               PID  %CPU %MEM      VSZ    RSS   TT  STAT STARTED      TIME COMMAND
me                4711   1.5  2.0 34512345  12345   ??  S    10:18AM   0:01.23 /Applications/Greed.app/Contents/MacOS/greed
root                 1   0.0  0.1 33722312  14096   ??  Ss    9:02AM   1:23.45 /sbin/launchd
]],
		many = "processes",
		rows = {
			{ id = "process:4711", label = "4711 /Applications/Greed.app/Contents/MacOS/greed" },
			{ id = "process:1", label = "1 /sbin/launchd" },
		},
	},
	{
		name = "GNU ps",
		program = "ps",
		line = "ps",
		output = [[
    PID TTY          TIME CMD
   3622 pts/1    00:00:00 bash
   4712 pts/1    00:00:00 ps
]],
		many = "processes",
		rows = { { id = "process:3622", label = "3622 bash" }, { id = "process:4712" } },
	},
	{
		name = "macOS ps",
		program = "ps",
		line = "ps",
		output = [[
  PID TTY           TIME CMD
 3622 ttys000    0:00.05 -zsh
 4712 ttys000    0:00.01 greed
]],
		many = "processes",
		rows = { { id = "process:3622", label = "3622 -zsh" }, { id = "process:4712" } },
	},
	{
		name = "ps -ef",
		program = "ps",
		line = "ps -ef",
		output = [[
UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 16:40 ?        00:00:26 /sbin/init
me          4711    3622  1 18:02 pts/1    00:01:02 greed notes.md
]],
		many = "processes",
		rows = { { id = "process:1" }, { id = "process:4711", label = "4711 greed notes.md" } },
	},
	{
		name = "lsof",
		program = "lsof",
		line = "lsof -i",
		output = [[
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
nginx     812 root    6u  IPv4  23456      0t0  TCP *:http (LISTEN)
sshd      977 root    3u  IPv4  23999      0t0  TCP *:ssh (LISTEN)
]],
		many = "processes",
		rows = { { id = "process:812", label = "812 nginx" }, { id = "process:977" } },
	},
}

-- A shell in a folder whose `bin` comes first on PATH, the folder given.
local function open(t: test.TestContext, files: { [string]: string }): (Shell, string)
	local dir = t:tempdir(files)
	greed.option.set("shell-fallback", "sh")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	return sh, dir
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- The objects `block`'s rows are.
local function rows_of(sh: Shell, block: Block): { core.Object }
	local here = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{block.number}`))
	return core.objects.related(here).rows or {}
end

for _, sample in SAMPLES do
	test(`{sample.name}: rows are {sample.many}`, function(t)
		local sh, dir = open(t, {
			[`bin/{sample.program}`] = `#!/bin/sh\ncat "$(dirname "$0")/output"\n`,
			["bin/output"] = sample.output,
		})
		assert(greed.process.run({ "chmod", "+x", `{dir}/bin/{sample.program}` }))
		local block = ran(t, sh, sample.line)
		assert(block.table, `no table in: {block.output}`)
		local many = if block.called then block.called.many else "nothing"
		assert(many == sample.many, `{sample.many} expected, got {many}`)
		local found = rows_of(sh, block)
		assert(#found == #sample.rows, `{#sample.rows} rows expected, got {#found}`)
		for i, want in sample.rows do
			local id = string.gsub(want.id, "DIR", dir)
			assert(found[i].id == id, `row {i}: {id} expected, got {found[i].id}`)
			assert(want.label == nil or found[i].label == want.label, found[i].label)
		end
	end)
end

test("this machine's ls -l and ps are read as files and processes", function(t)
	local sh, dir = open(t, { ["notes.txt"] = "hello\n", ["src/main.rs"] = "" })
	local listing = ran(t, sh, "ls -l")
	assert(listing.called and listing.called.many == "files", listing.output)
	local ids: { [string]: boolean } = {}
	for _, object in rows_of(sh, listing) do
		ids[object.id] = true
	end
	assert(ids[`file:{dir}/notes.txt`] and ids[`folder:{dir}/src`], listing.output)
	local processes = ran(t, sh, "ps aux")
	assert(processes.called and processes.called.many == "processes", processes.output)
	local first = rows_of(sh, processes)[1]
	assert(first and string.match(first.id, "^process:%d+$"), processes.output)
end)
