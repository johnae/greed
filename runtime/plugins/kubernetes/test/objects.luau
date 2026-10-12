local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local PODS = [[
NAME                     READY   STATUS             RESTARTS   AGE
api-7d9f8b6c5-2xkqz      1/1     Running            0          3d16h
worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   12         2h
]]

local ALL = [[
NAMESPACE   NAME      READY   STATUS    RESTARTS   AGE
billing     pay-0     1/1     Running   0          1d
]]

local CONFIG = [[
apiVersion: v1
current-context: CONTEXT
contexts:
- name: prod-eu
  context:
    cluster: eu
    namespace: payments
- name: staging
  context:
    cluster: st
]]

-- A shell whose `kubectl` prints tables for `get pods` and says what it was
-- asked otherwise, with kubectl's config in `context`.
local function fake(t: test.TestContext, context: string): (Shell, string)
	local dir = t:tempdir({
		["bin/kubectl"] = '#!/bin/sh\nif [ "$1 $2" = "get pods" ]; then\n  case "$*" in *-w*) cat "$(dirname "$0")/pods"; sleep 0.3; printf "worker-5c6b7d8f9-abcde   0/1   CrashLoopBackOff   13 (5s ago)   2h\\n" ;; *-A*) cat "$(dirname "$0")/all" ;; *) cat "$(dirname "$0")/pods" ;; esac\nelif [ "$1 $2" = "logs -f" ]; then\n  i=0; while :; do i=$((i+1)); echo "log $i"; sleep 0.1; done\nelse\n  echo "kubectl $*"\nfi\n',
		["bin/pods"] = PODS,
		["bin/all"] = ALL,
		["kubeconfig"] = (string.gsub(CONFIG, "CONTEXT", context)),
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/kubectl` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	sh.env.KUBECONFIG = `{dir}/kubeconfig`
	return sh, dir
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
	local from = shell.log.output_range(sh, block)
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

test("kubectl get's rows are pods, in the context and namespace it ran against", function(t)
	local sh, dir = fake(t, "prod-eu")
	local pods = ran(t, sh, "kubectl get pods")
	assert(pods.called and pods.called.many == "pods" and pods.called.one == "pod")
	on(sh, pods, "worker-5c6b7d8f9-abcde")
	local pod = assert(thing_here("pod"), "a pod at the cursor")
	assert(pod.label == "worker-5c6b7d8f9-abcde")
	assert(pod.value.context == "prod-eu" and pod.value.namespace == "payments", pod.value.context)
	-- Switching context after doesn't move where the row is.
	greed.fs.write(`{dir}/kubeconfig`, (string.gsub(CONFIG, "CONTEXT", "staging")))
	local logs = act(t, sh, pod, "logs")
	assert(
		logs.command
			== "kubectl logs worker-5c6b7d8f9-abcde --tail 200 --context prod-eu -n payments",
		logs.command
	)
	-- What was done to the pod is kept, with the block it ran.
	local object = assert(core.objects.from(pod))
	assert(core.objects.act(object, "events"))
	local done = core.actions.history(object.id)
	assert(done[1].action == "events" and done[1].made, "kept")
	assert((string.find(assert(core.objects.get(assert(done[1].made))).label, "events", 1, true)))
	-- With every namespace, each row says its own.
	local all = ran(t, sh, "kubectl get pods -A --context prod-eu")
	on(sh, all, "pay-0")
	local paying = assert(thing_here("pod"))
	assert(paying.value.namespace == "billing" and paying.value.context == "prod-eu")
	local status = ""
	for _, mark in sh.buffer:decorations(`shell.block.{all.uid}`) do
		status = if mark.eol then mark.text or "" else status
	end
	assert(string.find(status, "table · 1 pod", 1, true), "one is a pod: " .. status)
	-- Flags run together count as theirs, and JSON isn't a table of pods.
	local joined = ran(t, sh, "kubectl get pods -nteam")
	on(sh, joined, "api-7d9f8b6c5-2xkqz")
	assert(assert(thing_here("pod")).value.namespace == "team")
	assert(ran(t, sh, "kubectl get pods -ojson").called == nil, "not rows of pods")
	-- enter on a pod describes it.
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	local count = #sh.blocks
	t:keys("esc")
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	t:keys("enter")
	t:wait_for(function()
		return #sh.blocks > count and sh.blocks[#sh.blocks].status ~= "running"
	end)
	local described = sh.blocks[#sh.blocks].command
	assert(string.find(described, "kubectl describe pods api-7d9f8b6c5-2xkqz", 1, true), described)
end)

test("an action that destroys asks first, and says when it's production", function(t)
	local sh = fake(t, "prod-eu")
	local pods = ran(t, sh, "kubectl get pods")
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	local pod = assert(thing_here("pod"))
	local count = #sh.blocks
	greed.spawn(function()
		for _, action in core.actions.for_kind("pod") do
			if action.name == "delete" then
				core.actions.run(action, pod)
			end
		end
	end)
	local asked = ""
	t:wait_for(function()
		for _, message in t:messages() do
			if string.find(message, "y/n", 1, true) then
				asked = message
			end
		end
		return asked ~= ""
	end)
	assert(string.find(asked, "PRODUCTION (prod-eu)", 1, true), asked)
	t:keys("n")
	assert(#sh.blocks == count, "nothing ran")
end)

test("watching a pod gets just it again with kubectl and says how it changed", function(t)
	local sh, dir = fake(t, "staging")
	-- `kubectl get pods NAME` lists that one, from a file the test changes.
	greed.fs.write(
		`{dir}/bin/kubectl`,
		'#!/bin/sh\nif [ "$1 $2" = "get pods" ]; then\n  case "$3" in ""|-*) cat "$(dirname "$0")/pods" ;; *) cat "$(dirname "$0")/one" ;; esac\nfi\n'
	)
	local header = "NAME                     READY   STATUS             RESTARTS   AGE\n"
	local function one(restarts: string)
		greed.fs.write(
			`{dir}/bin/one`,
			header .. `worker-5c6b7d8f9-abcde   0/1     CrashLoopBackOff   {restarts}         2h\n`
		)
	end
	one("12")
	local pods = ran(t, sh, "kubectl get pods")
	on(sh, pods, "worker-5c6b7d8f9-abcde")
	local pod = assert(core.objects.from(assert(thing_here("pod"))))
	greed.option.set("watch-interval", 1)
	local watching = core.watch.toggle(pod)
	assert(watching, table.concat(t:messages(), "|"))
	one("13")
	-- The watch sleeps its interval (time passes at once here), then runs
	-- kubectl for real.
	t:wait(1100)
	local said = ""
	t:wait_for(function()
		said ..= table.concat(t:messages(), "|")
		return string.find(said, "RESTARTS 12 → 13", 1, true) ~= nil
	end)
	assert(string.find(said, "worker-5c6b7d8f9-abcde: RESTARTS 12 → 13", 1, true), said)
	assert(not core.watch.toggle(pod), "stopped")
	greed.option.set("watch-interval", 10)
end)

test("a selection over several rows acts on each of them", function(t)
	local sh = fake(t, "staging")
	local pods = ran(t, sh, "kubectl get pods")
	local from = assert((string.find(sh.buffer:text(), "api-7d9f8b6c5-2xkqz", 1, true)))
	local to = assert((string.find(sh.buffer:text(), "worker-5c6b7d8f9-abcde", 1, true)))
	greed.view():set_selection({ ranges = { { anchor = from - 1, head = to } }, primary = 1 })
	local here = core.actions.at(greed.view())
	local found: { core.Target } = {}
	for _, target in here do
		if target.kind == "pod" then
			table.insert(found, target)
		end
	end
	assert(#found == 2 and found[1].group and found[1].group == found[2].group, "found together")
	local count = #sh.blocks
	require("@picker").act(here)
	local menu = table.concat(t:floats(), "\n")
	assert(string.find(menu, "2 × pod", 1, true), menu)
	t:keys("d e s c r i b e enter")
	t:wait_for(function()
		return #sh.blocks == count + 2 and sh.blocks[#sh.blocks].status ~= "running"
	end)
	assert((string.find(sh.blocks[count + 1].command, "describe pods api", 1, true)))
	assert((string.find(sh.blocks[count + 2].command, "describe pods worker", 1, true)))
	assert(pods.called, "still pods")
end)

test("follow logs opens in a float on its last line; again goes to it, not a second", function(t)
	local sh = fake(t, "staging")
	local pods = ran(t, sh, "kubectl get pods")
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	local pod = assert(thing_here("pod"))
	local function follow()
		for _, action in core.actions.for_kind("pod") do
			if action.name == "follow logs" then
				action.run(pod)
			end
		end
	end
	local count = #sh.blocks
	follow()
	assert(#sh.blocks == count + 1, "it ran")
	local logs = sh.blocks[#sh.blocks]
	local float = greed.view()
	assert(shell.peek.of(float) == logs, "in a float")
	-- It stays on the last line as lines come.
	t:wait_for(function()
		local _, to = shell.log.range(logs)
		return string.find(sh.buffer:slice(0, assert(to)), "log 5\n", 1, true) ~= nil
	end)
	local function on_last(): boolean
		local _, to = shell.log.range(logs)
		local buffer = sh.buffer
		return buffer:line_of(float:cursor()) == buffer:line_of(assert(to) - 1)
	end
	assert(on_last(), "on the last line")
	-- Moved up, it stays put.
	t:keys("k")
	local here = float:cursor()
	greed.sleep(300)
	t:wait(50)
	assert(not on_last() and float:cursor() == here, "stays where moved")
	t:keys("esc")
	-- Again while it runs goes to it.
	follow()
	assert(#sh.blocks == count + 1, "not a second one")
	assert(shell.peek.of(greed.view()) == logs, "its float again")
	local said = table.concat(t:messages(), "|")
	assert(string.find(said, `already running as ${logs.number}`, 1, true), said)
	t:keys("esc")
	shell.interrupt(logs)
end)

-- What completion offers with `text` at `sh`'s prompt, in order.
local function offered(
	t: test.TestContext,
	sh: Shell,
	text: string
): { { label: string, detail: string? } }
	shell.log.set_prompt(sh, text, { greed.view() })
	local found: { any }? = nil
	greed.spawn(function()
		found = shell.completion.items(greed.view(), { explicit = true }) or {}
	end)
	t:wait_for(function()
		return found ~= nil
	end, 10000)
	return assert(found)
end

local function labels(items: { { label: string, detail: string? } }): string
	local out = {}
	for _, item in items do
		table.insert(out, item.label)
	end
	return table.concat(out, ",")
end

test("completion offers the rows of blocks above, where the command goes", function(t)
	local sh = fake(t, "prod-eu")
	local pods = ran(t, sh, "kubectl get pods")
	local logs = offered(t, sh, "kubectl logs ")
	assert(logs[1] and logs[1].label == "api-7d9f8b6c5-2xkqz", labels(logs))
	assert(logs[2] and logs[2].label == "worker-5c6b7d8f9-abcde", labels(logs))
	assert(logs[1].detail == `pod · ${pods.number}`, tostring(logs[1].detail))
	-- Named the same way after describe and the resource.
	assert(offered(t, sh, "kubectl describe po ")[1].label == "api-7d9f8b6c5-2xkqz")
	-- Not for another context, another namespace, another resource or a flag.
	local function none(line: string)
		for _, item in offered(t, sh, line) do
			assert(
				not string.find(item.label, "api-7d9f", 1, true),
				`{line}: {labels(offered(t, sh, line))}`
			)
		end
	end
	none("kubectl logs --context staging ")
	none("kubectl logs -n other ")
	none("kubectl describe deploy ")
	none("kubectl logs -")
	-- A one-word alias or a path to the program counts as it.
	shell.aliases.use({ k = "kubectl" })
	assert(offered(t, sh, "k logs ")[1].label == "api-7d9f8b6c5-2xkqz")
	assert(offered(t, sh, `{sh.cwd}/bin/kubectl logs `)[1].label == "api-7d9f8b6c5-2xkqz")
	shell.aliases.use(nil)
end)

test("kubectl get -w shows each pod in place, the ones that changed marked", function(t)
	local sh = fake(t, "prod-eu")
	local block = ran(t, sh, "kubectl get pods -w")
	assert(block.watching == "kubectl get pods -w", tostring(block.watching))
	local tbl = assert(block.table, "a table")
	assert(#tbl.rows == 2, "one row a pod: " .. block.output)
	assert(tbl.rows[2].RESTARTS == "13 (5s ago)", tostring(tbl.rows[2].RESTARTS))
	local _, count = string.gsub(block.output, "worker%-5c6b7d8f9%-abcde", "")
	assert(count == 1, "shown once: " .. block.output)
	local changed = {}
	for _, mark in sh.buffer:decorations(`shell.out.{block.uid}`) do
		if mark.style == "shell.changed" then
			table.insert(changed, sh.buffer:slice(mark.from, mark.to))
		end
	end
	assert(#changed == 1 and string.find(changed[1], "worker", 1, true), table.concat(changed, "|"))
	on(sh, block, "worker-5c6b7d8f9-abcde")
	local pod = assert(thing_here("pod"))
	assert(pod.value.context == "prod-eu", tostring(pod.value.context))
end)

-- The ids of `objects`, in order.
local function ids(objects: { core.Object }): string
	local out = {}
	for _, object in objects do
		table.insert(out, object.id)
	end
	return table.concat(out, ",")
end

test(
	"a pod row is an object by its context, namespace and name, acted on from anywhere",
	function(t)
		local sh = fake(t, "prod-eu")
		local pods = ran(t, sh, "kubectl get pods")
		local id = "pod:prod-eu/payments/api-7d9f8b6c5-2xkqz"
		local pod = assert(core.objects.get(id), "found by id")
		assert(pod.label == "api-7d9f8b6c5-2xkqz" and pod.buffer == sh.buffer)
		local state = core.objects.inspect(pod)
		assert(
			state.namespace == "payments" and state.row.STATUS == "Running",
			greed.json.encode(state)
		)
		local block = core.objects.related(pod).block
		assert(block and block[1].id == `shell-block:{sh.buffer:id()}.{pods.number}`)
		local listed = ids(core.objects.list("pod"))
		assert(listed == `{id},pod:prod-eu/payments/worker-5c6b7d8f9-abcde`, listed)
		-- The block's rows are the pods.
		local rows = assert(core.objects.related(block[1]).rows)
		assert(ids(rows) == listed, ids(rows))
		-- Under the cursor it's the same object.
		on(sh, pods, "worker-5c6b7d8f9-abcde")
		local here = ids(core.objects.at(greed.view()))
		assert(string.find(here, "pod:prod-eu/payments/worker-5c6b7d8f9-abcde", 1, true), here)
		-- From a float, as the inspector or an agent would.
		greed.float(greed.create_buffer("elsewhere", "elsewhere"))
		local count = #sh.blocks
		assert(core.objects.act(pod, "logs"))
		t:wait_for(function()
			return #sh.blocks > count and sh.blocks[#sh.blocks].status ~= "running"
		end)
		local logs = sh.blocks[#sh.blocks].command
		assert(
			logs == "kubectl logs api-7d9f8b6c5-2xkqz --tail 200 --context prod-eu -n payments",
			logs
		)
		-- The newest row of a pod is the one found.
		local again = ran(t, sh, "kubectl get pods")
		local newest = assert(core.objects.related(assert(core.objects.get(id))).block)
		assert(newest[1].id == `shell-block:{sh.buffer:id()}.{again.number}`, newest[1].id)
	end
)

test("in blocks mode down goes onto the pods, each one a pod to act on", function(t)
	local sh = fake(t, "prod-eu")
	ran(t, sh, "kubectl get pods -A")
	shell.log.set_prompt(sh, "", { greed.view() })
	greed.view():set_cursor(sh.buffer:len())
	t:keys("esc down")
	local pod = assert(thing_here("pod"), "a pod under the cursor")
	assert(pod.value.namespace ~= nil, "with its namespace")
	local names: { string } = {}
	for _, action in core.actions.for_kind("pod") do
		table.insert(names, action.name)
	end
	assert(table.find(names, "logs"), table.concat(names, ", "))
end)

test("enter on a pod shows what it ran where you are, and esc goes back to the pod", function(t)
	local sh = fake(t, "prod-eu")
	local pods = ran(t, sh, "kubectl get pods")
	local main = greed.view()
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	t:keys("esc")
	on(sh, pods, "api-7d9f8b6c5-2xkqz")
	local line = sh.buffer:line_of(main:cursor())
	t:keys("enter")
	t:wait_for(function()
		return greed.view() ~= main
	end)
	local float = greed.view()
	local spec = assert(float:float_spec(), "a float")
	assert(
		string.find(spec.title or "", "pods › api-7d9f8b6c5-2xkqz › describe", 1, true),
		spec.title
	)
	t:wait_for(function()
		return sh.blocks[#sh.blocks].status ~= "running"
	end)
	t:keys("esc")
	assert(not float:valid(), "closed")
	assert(greed.view() == main, "back in the shell")
	assert(sh.buffer:line_of(main:cursor()) == line, "on the pod again")
end)
