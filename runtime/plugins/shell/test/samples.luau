-- The rows of the commands people run most, as each system prints them:
-- GNU and macOS (BSD) `ls -l` and `ps`, `lsof`, `docker ps`, `kubectl get`.
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
		name = "docker ps",
		program = "docker",
		line = "docker ps",
		output = [[
CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS        PORTS                  NAMES
3f2a1b4c5d6e   nginx:latest   "/docker-entrypoint.…"   2 hours ago    Up 2 hours    0.0.0.0:8080->80/tcp   web
9a8b7c6d5e4f   postgres:16    "docker-entrypoint.s…"   3 days ago     Up 3 days     5432/tcp               db
]],
		many = "containers",
		rows = { { id = "container:web", label = "web" }, { id = "container:db" } },
	},
	{
		name = "kubectl get pods -o wide",
		program = "kubectl",
		line = "kubectl get pods -o wide --context prod -n team",
		output = [[
NAME                  READY   STATUS    RESTARTS      AGE   IP          NODE     NOMINATED NODE   READINESS GATES
api-7d9f8b6c5-2xkqz   1/1     Running   0             3d    10.0.1.12   node-1   <none>           <none>
worker-5c6b7-abcde    0/1     Error     3 (2m ago)    1h    10.0.1.13   node-2   <none>           <none>
]],
		many = "pods",
		rows = {
			{ id = "pod:prod/team/api-7d9f8b6c5-2xkqz" },
			{ id = "pod:prod/team/worker-5c6b7-abcde" },
		},
	},
	{
		name = "kubectl get deployments",
		program = "kubectl",
		line = "kubectl get deploy --context prod -n team",
		output = [[
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
api      3/3     3            3           12d
worker   0/1     1            0           12d
]],
		many = "deployments",
		rows = { { id = "deployment:prod/team/api" }, { id = "deployment:prod/team/worker" } },
	},
	{
		name = "kubectl get nodes",
		program = "kubectl",
		line = "kubectl get nodes --context prod",
		output = [[
NAME     STATUS   ROLES           AGE   VERSION
node-1   Ready    control-plane   40d   v1.31.2
]],
		many = "nodes",
		rows = { { id = "kubernetes:prod//nodes/node-1" } },
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

test("a pod's node and namespace are objects, with the actions kubernetes objects have", function(t)
	local sh = printing(
		t,
		"kubectl",
		"NAMESPACE   NAME    READY   STATUS    RESTARTS   AGE   IP          NODE     NOMINATED NODE   READINESS GATES\n"
			.. "billing     pay-0   1/1     Running   0          1d    10.0.1.12   node-1   <none>           <none>\n"
	)
	local block = ran(t, sh, "kubectl get pods -A -o wide --context prod")
	local pod = assert(core.objects.get("pod:prod/billing/pay-0"))
	local related = core.objects.related(pod)
	local node = assert(related.node)[1]
	assert(node.id == "kubernetes:prod//nodes/node-1", node.id)
	assert(assert(related.namespace)[1].id == "kubernetes:prod//namespaces/billing")
	-- Found again by id, its row and block related.
	local found = assert(core.objects.get(node.id))
	assert(assert(core.objects.related(found).row)[1].id == pod.id)
	assert(core.objects.inspect(found).row == nil, "a node's state isn't the pod's row")
	local described = act(t, sh, found, "describe")
	assert(described == "kubectl describe nodes node-1 --context prod", described)
	-- Under the cursor on its cell, the node comes before the pod.
	local from = shell.log.output_range(sh, block)
	assert(from, "a block with output")
	local at = assert(string.find(sh.buffer:text(), "node-1", from + 1, true), "node-1")
	greed.view():set_cursor(at - 1)
	local here = core.objects.at(greed.view())
	assert(here[1].id == node.id and here[2].id == pod.id, here[1].id)
end)

test("a container's image is an object", function(t)
	local sh = printing(
		t,
		"docker",
		"CONTAINER ID   IMAGE          COMMAND   CREATED       STATUS       PORTS   NAMES\n"
			.. '3f2a1b4c5d6e   nginx:latest   "nginx"   2 hours ago   Up 2 hours           web\n'
	)
	ran(t, sh, "docker ps")
	local image =
		assert(assert(core.objects.related(assert(core.objects.get("container:web")))).image)[1]
	assert(image.id == "image:nginx:latest", image.id)
	local inspected = act(t, sh, assert(core.objects.get(image.id)), "inspect")
	assert(inspected == "docker image inspect nginx:latest", inspected)
end)
