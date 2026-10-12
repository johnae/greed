local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local json = require("../json")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

-- 2026-10-11T12:00:00Z, the time the ages are from.
local NOW = 1791720000

local PODS = [==[
{"apiVersion": "v1", "kind": "List", "items": [
  {"kind": "Pod", "metadata": {"name": "api-7d9f8b6c5-2xkqz", "namespace": "shop", "creationTimestamp": "2026-10-08T00:00:00Z"},
   "status": {"phase": "Running", "containerStatuses": [
     {"name": "api", "ready": true, "restartCount": 0, "state": {"running": {}}},
     {"name": "proxy", "ready": true, "restartCount": 1, "state": {"running": {}}}]}},
  {"kind": "Pod", "metadata": {"name": "worker-5c6b7d8f9-abcde", "namespace": "shop", "creationTimestamp": "2026-10-11T10:00:00Z"},
   "status": {"phase": "Running", "containerStatuses": [
     {"name": "worker", "ready": false, "restartCount": 12, "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}}
]}
]==]

test("pods' JSON reads as the table kubectl prints", function()
	local made = assert(json.table(greed.json.decode(PODS), NOW))
	assert(
		table.concat(made.columns, ",") == "NAME,READY,STATUS,RESTARTS,AGE",
		table.concat(made.columns, ",")
	)
	local api, worker = made.rows[1], made.rows[2]
	assert(api.READY == "2/2" and api.STATUS == "Running" and api.RESTARTS == "1", api.READY)
	assert(api.AGE == "3d", api.AGE)
	assert(worker.READY == "0/1" and worker.STATUS == "CrashLoopBackOff", worker.STATUS)
	assert(worker.RESTARTS == "12" and worker.AGE == "2h", worker.AGE)
end)

test("objects in several namespaces get a NAMESPACE column; other kinds their own", function()
	local value = greed.json.decode([==[
{"items": [
  {"kind": "Deployment", "metadata": {"name": "api", "namespace": "shop"},
   "spec": {"replicas": 3}, "status": {"readyReplicas": 2, "updatedReplicas": 3, "availableReplicas": 2}},
  {"kind": "Deployment", "metadata": {"name": "pay", "namespace": "billing"},
   "spec": {"replicas": 1}, "status": {}}
]}
]==])
	local made = assert(json.table(value, NOW))
	assert(
		table.concat(made.columns, ",") == "NAMESPACE,NAME,READY,UP-TO-DATE,AVAILABLE,AGE",
		table.concat(made.columns, ",")
	)
	assert(made.rows[1].READY == "2/3" and made.rows[2].READY == "0/1", made.rows[2].READY)
	local nodes = assert(json.table(
		greed.json.decode([==[
{"items": [{"kind": "Node", "metadata": {"name": "n1"}, "status": {"conditions": [{"type": "Ready", "status": "False"}]}},
           {"kind": "ConfigMap", "metadata": {"name": "cm"}}]}
]==]),
		NOW
	))
	assert(nodes.rows[1].STATUS == "NotReady", nodes.rows[1].STATUS)
	assert(nodes.rows[2].NAME == "cm" and nodes.rows[2].AGE == "", nodes.rows[2].AGE)
	assert(json.table({ items = {} }) == nil, "nothing listed is no table")
	assert(json.table({ 1, 2 }) == nil, "not kubernetes objects")
end)

-- A shell whose `kubectl` prints `pods.json` for `-o json` and a table
-- otherwise, saying in `asked` what it was asked.
local function fake(t: test.TestContext): Shell
	local dir = t:tempdir({
		["bin/kubectl"] = '#!/bin/sh\necho "$*" >> "$(dirname "$0")/../asked"\ncase "$*" in *"-o json"*) cat "$(dirname "$0")/../pods.json" ;; *) printf "NAME   READY   STATUS    RESTARTS   AGE\\nweb    1/1     Running   0          1d\\n" ;; esac\n',
		["pods.json"] = PODS,
	})
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/kubectl` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	sh.env.KUBECONFIG = `{dir}/none`
	return sh
end

local function ran(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

test("kubectl get with stages after it asks for JSON and reads that", function(t)
	local sh = fake(t)
	local block = ran(t, sh, "kubectl get pods -n shop | where RESTARTS > 5")
	assert(block.status == "done", block.output)
	local asked = greed.fs.read(`{sh.cwd}/asked`) or ""
	assert(string.find(asked, "get pods -n shop -o json", 1, true), asked)
	assert(string.find(block.output, "CrashLoopBackOff", 1, true), block.output)
	assert(not string.find(block.output, "api-", 1, true), block.output)
	local chart = ran(t, sh, "kubectl get pods | chart RESTARTS")
	assert(chart.status == "done", chart.output)
	assert(string.find(chart.output, "worker", 1, true), chart.output)
end)

test("the rows kubectl get's stages keep are pods to act on", function(t)
	local sh = fake(t)
	local block = ran(t, sh, "kubectl get pods -n shop | where RESTARTS > 5")
	assert(block.called and block.called.one == "pod", "rows of pods")
	-- Taken from that block with $N, they're its pods still.
	local again = ran(t, sh, `${block.number} | where RESTARTS > 5`)
	assert(again.called and again.called.one == "pod", "pods from the block they came from")
end)

test("kubectl with its own output, a watch or no stages runs as typed", function(t)
	local sh = fake(t)
	ran(t, sh, "kubectl get pods -o wide | where NAME == web")
	ran(t, sh, "kubectl get pods")
	ran(t, sh, "kubectl describe pods | where x")
	local asked = greed.fs.read(`{sh.cwd}/asked`) or ""
	assert(not string.find(asked, "-o json", 1, true), asked)
end)
