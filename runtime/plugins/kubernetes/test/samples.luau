-- The rows of `kubectl get`, as kubectl prints them. Each sample is
-- printed by a stand-in for kubectl and run as typed, so a change in how
-- they're read shows here first.

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
	-- Under the cursor on its cell, the pod comes first, then the node, then the cell.
	local from = shell.log.output_range(sh, block)
	assert(from, "a block with output")
	local at = assert(string.find(sh.buffer:text(), "node-1", from + 1, true), "node-1")
	greed.view():set_cursor(at - 1)
	local here = core.objects.at(greed.view())
	assert(here[1].id == pod.id and here[2].id == node.id and here[3].kind == "cell", here[1].id)
end)
