-- The rows of the commands people run most, as each system prints them:
-- GNU and macOS (BSD) `ls -l` and `ps`, `lsof`, `git status`, `git log`,
-- `jj st` and `jj log`.
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
	{
		name = "git status -s",
		program = "git",
		line = "git status -s",
		output = " M a.txt\n D c.txt\nRM b.txt -> moved.txt\n?? new.txt\n",
		many = "changed files",
		rows = {
			{ id = "changed-file:DIR/a.txt", label = "a.txt" },
			{ id = "changed-file:DIR/c.txt" },
			{ id = "changed-file:DIR/moved.txt", label = "moved.txt" },
			{ id = "changed-file:DIR/new.txt" },
		},
	},
	{
		name = "git status",
		program = "git",
		line = "git status",
		output = [[
On branch main
Changes to be committed:
  (use "git restore --staged <file>..." to unstage)
	modified:   a.txt
	renamed:    b.txt -> moved.txt

Changes not staged for commit:
  (use "git add/rm <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	deleted:    c.txt

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	new.txt

]],
		many = "changed files",
		rows = {
			{ id = "changed-file:DIR/a.txt" },
			{ id = "changed-file:DIR/moved.txt" },
			{ id = "changed-file:DIR/c.txt" },
			{ id = "changed-file:DIR/new.txt" },
		},
	},
	{
		name = "git log --oneline",
		program = "git",
		line = "git log --oneline",
		output = "8c16b60 second (wip)\nb84a092 first commit\n",
		many = "commits",
		rows = {
			{ id = "commit:8c16b60", label = "8c16b60 second (wip)" },
			{ id = "commit:b84a092" },
		},
	},
	{
		name = "git log --oneline --graph",
		program = "git",
		line = "git log --oneline --graph",
		output = "*   d4e5f6a Merge branch 'topic'\n|\\  \n| * 8c16b60 second (wip)\n|/  \n* b84a092 first commit\n",
		many = "commits",
		rows = { { id = "commit:d4e5f6a" }, { id = "commit:8c16b60" }, { id = "commit:b84a092" } },
	},
	{
		name = "git log",
		program = "git",
		line = "git log -2",
		output = [[
commit 8c16b60bf9b582865f56f13a745300eee4ca98fe
Author: t <a@b>
Date:   Sat Oct 10 20:32:27 2026 +0200

    second (wip)

commit b84a0926491ee1c7d27222fa19ab4742a99f0879
Author: t <a@b>
Date:   Sat Oct 10 20:32:27 2026 +0200

    first commit
]],
		many = "commits",
		rows = {
			{ id = "commit:8c16b60bf9b5", label = "8c16b60bf9b5 second (wip)" },
			{ id = "commit:b84a0926491e", label = "b84a0926491e first commit" },
		},
	},
	{
		name = "jj st",
		program = "jj",
		line = "jj st",
		output = [[
Working copy changes:
M a.txt
A d/x.txt
R {b.txt => moved.txt}
Working copy  (@) : kpvxkwkw fa988274 (no description set)
Parent commit (@-): zuzlzyzv 52511424 first
]],
		many = "changed files",
		rows = {
			{ id = "changed-file:DIR/a.txt" },
			{ id = "changed-file:DIR/d/x.txt" },
			{ id = "changed-file:DIR/moved.txt" },
		},
	},
	{
		name = "jj log",
		program = "jj",
		line = "jj log",
		output = [[
@  kpvxkwkw me@example.com 2026-10-10 20:32:27 fa988274
│  (no description set)
○  zuzlzyzv me@example.com 2026-10-10 20:32:27 main 52511424
│  first
│ ○  rstuvwxy me@example.com 2026-10-09 18:01:02 0a1b2c3d
├─╯  rust stuff
◆  zzzzzzzz root() 00000000
]],
		many = "revisions",
		rows = {
			{ id = "revision:kpvxkwkw", label = "kpvxkwkw (no description set)" },
			{ id = "revision:zuzlzyzv", label = "zuzlzyzv first" },
			{ id = "revision:rstuvwxy", label = "rstuvwxy rust stuff" },
			{ id = "revision:zzzzzzzz" },
		},
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
		-- In a repository of both kinds, for git's and jj's.
		local sh, dir = open(t, {
			[`bin/{sample.program}`] = `#!/bin/sh\ncat "$(dirname "$0")/output"\n`,
			["bin/output"] = sample.output,
			[".git/HEAD"] = "",
			[".jj/repo"] = "",
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

-- A shell whose `program` prints `output`, whatever it's asked.
local function printing(t: test.TestContext, program: string, output: string): Shell
	local sh, dir = open(t, {
		[`bin/{program}`] = `#!/bin/sh\ncat "$(dirname "$0")/output"\n`,
		["bin/output"] = output,
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/{program}` }))
	return sh
end

-- Runs `object`'s action `name` and gives back the command it ran.
local function act(t: test.TestContext, sh: Shell, object: core.Object, name: string): string
	local count = #sh.blocks
	assert(core.objects.act(object, name), name)
	t:wait_for(function()
		return #sh.blocks > count and sh.blocks[#sh.blocks].status ~= "running"
	end)
	return sh.blocks[#sh.blocks].command
end

test("changed files, commits and changes run git and jj in their repository", function(t)
	local sh = printing(t, "git", " M a.txt\n")
	local dir = sh.cwd
	greed.fs.write(`{dir}/.git/HEAD`, "")
	ran(t, sh, "git status -s")
	local file = assert(core.objects.get(`changed-file:{dir}/a.txt`))
	local diffed = act(t, sh, file, "diff")
	assert(diffed == `git -C {dir} diff HEAD -- {dir}/a.txt`, diffed)
	assert(act(t, sh, file, "stage") == `git -C {dir} add -- {dir}/a.txt`)
	assert(assert(core.objects.related(file).path)[1].id == `file:{dir}/a.txt`)

	local jj = printing(t, "jj", "Working copy changes:\nM sub/a b.txt\n")
	local root = jj.cwd
	greed.fs.write(`{root}/.jj/repo`, "")
	ran(t, jj, "jj st")
	local changed = assert(core.objects.get(`changed-file:{root}/sub/a b.txt`))
	local jj_diff = act(t, jj, changed, "diff")
	assert(jj_diff == `jj -R {root} diff 'root:"sub/a b.txt"'`, jj_diff)
	-- jj has no staging: nothing runs, and it says so.
	local count = #jj.blocks
	assert(core.objects.act(changed, "stage"))
	assert(#jj.blocks == count, "nothing ran")
end)

test("this machine's git status lists changed files that stage for real", function(t)
	if greed.which("git") == nil then
		return
	end
	local sh, dir = open(t, { ["notes.txt"] = "hello\n" })
	ran(t, sh, "git init -q")
	local status = ran(t, sh, "git status -s")
	assert(status.called and status.called.many == "changed files", status.output)
	local notes = assert(core.objects.get(`changed-file:{dir}/notes.txt`), status.output)
	assert(core.objects.inspect(notes).status == "untracked")
	act(t, sh, notes, "stage")
	ran(t, sh, "git status -s")
	local staged = assert(core.objects.get(`changed-file:{dir}/notes.txt`))
	local state = core.objects.inspect(staged)
	assert(state.status == "added" and state.staged == "yes", state.status)
end)
