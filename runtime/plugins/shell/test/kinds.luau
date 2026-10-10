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

-- A shell whose `kubectl`, `docker` and `ps` print tables for `get` and `ps` and
-- say what they were asked otherwise, with kubectl's config in `context`.
local function fake(t: test.TestContext, context: string): (Shell, string)
	local dir = t:tempdir({
		["bin/kubectl"] = '#!/bin/sh\nif [ "$1 $2" = "get pods" ]; then\n  case "$*" in *-w*) cat "$(dirname "$0")/pods"; sleep 0.3; printf "worker-5c6b7d8f9-abcde   0/1   CrashLoopBackOff   13 (5s ago)   2h\\n" ;; *-A*) cat "$(dirname "$0")/all" ;; *) cat "$(dirname "$0")/pods" ;; esac\nelse\n  echo "kubectl $*"\nfi\n',
		["bin/docker"] = '#!/bin/sh\nif [ "$1" = "ps" ]; then\n  printf "CONTAINER ID   IMAGE      NAMES\\n3f2a1b4c5d6e   nginx      web\\n"\nelse\n  echo "docker $*"\nfi\n',
		-- The same ps everywhere: macOS's prints other columns than Linux's.
		["bin/ps"] = '#!/bin/sh\nprintf "USER         PID %%CPU %%MEM COMMAND\\nroot           1  0.0  0.1 /sbin/init\\nme          4711  1.5  2.0 greed\\n"\n',
		["bin/pods"] = PODS,
		["bin/all"] = ALL,
		["kubeconfig"] = (string.gsub(CONFIG, "CONTEXT", context)),
	})
	assert(
		greed.process.run({ "chmod", "+x", `{dir}/bin/kubectl`, `{dir}/bin/docker`, `{dir}/bin/ps` })
	)
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
				action.run(pod)
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

test("ls -l's rows are files and folders; enter opens one and goes into the other", function(t)
	local sh = fake(t, "staging")
	greed.fs.write(`{sh.cwd}/notes.txt`, "hello\n")
	local listing = ran(t, sh, "ls -l")
	assert(listing.called and listing.called.many == "files")
	on(sh, listing, "notes.txt")
	local file = assert(thing_here("file"))
	assert(file.value == `{sh.cwd}/notes.txt`, tostring(file.value))
	t:keys("esc")
	on(sh, listing, "notes.txt")
	t:keys("enter")
	assert(greed.view():buffer():path() == `{sh.cwd}/notes.txt`, "opened")
end)

test("ps's rows are processes and docker ps's containers", function(t)
	local sh = fake(t, "staging")
	local listed = ran(t, sh, "ps aux")
	assert(listed.called and listed.called.many == "processes")
	local containers = ran(t, sh, "docker ps")
	assert(containers.called and containers.called.many == "containers")
	on(sh, containers, "nginx")
	local web = assert(thing_here("container"))
	assert(web.label == "web")
	local logs = act(t, sh, web, "logs")
	assert(logs.command == "docker logs --tail 200 web", logs.command)
	assert(string.find(logs.output, "docker logs --tail 200 web", 1, true), logs.output)
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
	-- Processes for kill, containers for docker logs.
	local listed = ran(t, sh, "ps aux")
	local kill = offered(t, sh, "kill ")
	assert(kill[1] and string.match(kill[1].label, "^%d+$"), labels(kill))
	assert(string.find(kill[1].detail or "", `${listed.number}`, 1, true), tostring(kill[1].detail))
	ran(t, sh, "docker ps")
	assert(offered(t, sh, "docker logs --tail 50 ")[1].label == "web")
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

test("process rows are process:PID and container rows container:NAME", function(t)
	local sh = fake(t, "staging")
	ran(t, sh, "ps aux")
	local process = assert(core.objects.get("process:4711"))
	assert(process.label == "4711 greed", process.label)
	assert(core.objects.inspect(process).row["%CPU"] == "1.5")
	ran(t, sh, "docker ps")
	local web = assert(core.objects.get("container:web"))
	assert(core.objects.inspect(web).row.IMAGE == "nginx")
end)

test("the rows of a table no kind reads are plain rows of their block", function(t)
	local sh = fake(t, "staging")
	greed.fs.write(`{sh.cwd}/fruit.txt`, "NAME    COLOR\napple   red\npear    green\n")
	local fruit = ran(t, sh, "cat fruit.txt")
	local block = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{fruit.number}`))
	local rows = assert(core.objects.related(block).rows)
	local prefix = `row:{sh.buffer:id()}.{fruit.number}`
	assert(ids(rows) == `{prefix}.1,{prefix}.2`, ids(rows))
	local pear = assert(core.objects.get(`{prefix}.2`))
	assert(pear.kind == "row" and pear.label == "pear", pear.label)
	assert(core.objects.inspect(pear).COLOR == "green")
	assert(assert(core.objects.related(pear).block)[1].id == block.id)
	on(sh, fruit, "pear")
	assert(string.find(ids(core.objects.at(greed.view())), `{prefix}.2`, 1, true) ~= nil)
	-- A filter shows fewer rows; the objects stay where they are.
	shell.rows.set(sh, fruit, "pear")
	local still = assert(core.objects.get(`{prefix}.2`))
	local from = assert(still.from)
	assert(string.sub(sh.buffer:text(), from + 1, from + 4) == "pear", "on its line")
	assert(assert(core.objects.get(`{prefix}.1`)).from == nil, "apple isn't shown")
	on(sh, fruit, "pear")
	assert(string.find(ids(core.objects.at(greed.view())), `{prefix}.2`, 1, true) ~= nil)
end)

test("a PID column makes rows processes, whatever printed them", function(t)
	local sh = fake(t, "staging")
	greed.fs.write(
		`{sh.cwd}/open.txt`,
		"COMMAND    PID USER   FD   TYPE NAME\nnginx     812 root    6u  IPv4 *:http\nsshd      977 root    3u  IPv4 *:ssh\n"
	)
	local open = ran(t, sh, "cat open.txt")
	assert(open.called and open.called.many == "processes", "read by its columns")
	local nginx = assert(core.objects.get("process:812"))
	assert(nginx.label == "812 nginx" and core.objects.inspect(nginx).row.FD == "6u", nginx.label)
	-- nu's ps names its columns in lower case.
	greed.fs.write(`{sh.cwd}/ps.json`, '[{"pid": 42, "ppid": 1, "name": "fish", "cpu": 0.1}]')
	ran(t, sh, "cat ps.json")
	assert(assert(core.objects.get("process:42")).label == "42 fish")
end)

test("name and type columns of files and folders make rows files, as nu's ls prints", function(t)
	local sh = fake(t, "staging")
	greed.fs.write(
		`{sh.cwd}/ls.json`,
		'[{"name": "notes.txt", "type": "file", "size": 6}, {"name": "src", "type": "dir", "size": 0}]'
	)
	local listing = ran(t, sh, "cat ls.json")
	assert(listing.called and listing.called.many == "files")
	local ids_of = ids(
		core.objects.related(
			assert(core.objects.get(`shell-block:{sh.buffer:id()}.{listing.number}`))
		).rows or {}
	)
	assert(ids_of == `file:{sh.cwd}/notes.txt,folder:{sh.cwd}/src`, ids_of)
	-- A type that isn't a file's (lsblk's disks) isn't read as files.
	greed.fs.write(`{sh.cwd}/disks.txt`, "NAME   TYPE  SIZE\nsda    disk  1T\nsda1   part  512M\n")
	assert(ran(t, sh, "cat disks.txt").called == nil, "not files")
end)

test("a cell is an object to copy or filter by, and a plain row copies as text or JSON", function(t)
	local sh = fake(t, "staging")
	greed.fs.write(`{sh.cwd}/fruit.txt`, "NAME    COLOR\napple   red\npear    green\n")
	local fruit = ran(t, sh, "cat fruit.txt")
	on(sh, fruit, "green")
	local here = core.objects.at(greed.view())
	local cell = `cell:{sh.buffer:id()}.{fruit.number}.2.COLOR`
	assert(here[1].id == cell and here[1].label == "COLOR: green", ids(here))
	assert(here[2].id == `row:{sh.buffer:id()}.{fruit.number}.2`, ids(here))
	local found = assert(core.objects.get(cell))
	assert(assert(core.objects.related(found).row)[1].label == "pear")
	assert(core.objects.act(found, "copy"))
	assert(assert(greed.clipboard.get())[1] == "green")
	assert(core.objects.act(found, "filter by this"))
	assert(fruit.shown and fruit.shown.filter == "COLOR=green", "filtered")
	assert(#fruit.shown.rows == 1 and fruit.shown.rows[1] == 2)
	-- The row, as text and as JSON.
	local row = here[2]
	assert(core.objects.act(row, "copy"))
	assert(assert(greed.clipboard.get())[1] == "pear\tgreen")
	assert(core.objects.act(row, "copy as JSON"))
	local copied = greed.json.decode(assert(greed.clipboard.get())[1])
	assert(copied.NAME == "pear" and copied.COLOR == "green")
end)

test("filtering by a cell with spaces keeps the rows with its words", function(t)
	local sh = fake(t, "staging")
	ran(t, sh, "docker ps")
	local status = ran(t, sh, "docker ps")
	local cell = assert(core.objects.get(`cell:{sh.buffer:id()}.{status.number}.1.CONTAINER ID`))
	assert(core.objects.act(cell, "filter by this"))
	assert(
		status.shown and status.shown.filter == "3f2a1b4c5d6e",
		tostring(status.shown and status.shown.filter)
	)
end)
