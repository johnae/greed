local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")
local kubernetes = require("@kubernetes")

type Shell = typeof(shell.open())

test("a kubectl get line shows another resource or namespace", function()
	local function check(line: string, change: any, expected: string?)
		local got = kubernetes.retarget(line, change)
		assert(got == expected, `{line}: {tostring(got)}`)
	end
	check("kubectl get pods", { resource = "deployments" }, "kubectl get deployments")
	check(
		"watch -n 5 kubectl --context prod get po -n payments | where STATUS != Running",
		{ resource = "services" },
		"watch -n 5 kubectl --context prod get services -n payments | where STATUS != Running"
	)
	check(
		"kubectl get pods -n payments -w",
		{ namespace = "billing" },
		"kubectl get pods -n billing -w"
	)
	check("kubectl -n=payments get pods -o wide", { all = true }, "kubectl get pods -A -o wide")
	check("kubectl get pods -A", { namespace = "my ns" }, "kubectl get pods -n 'my ns'")
	check(
		"kubectl get pods --namespace payments",
		{ resource = "jobs", namespace = "batch" },
		"kubectl get jobs -n batch"
	)
	check("kubectl get pods", {}, "kubectl get pods")
	check("kubectl logs api", { resource = "jobs" }, nil)
	check("kubectl get", { resource = "jobs" }, nil)
	check("ls pods", { resource = "jobs" }, nil)
end)

-- A kubectl that prints a table for what it's asked to get.
local KUBECTL = [[#!/bin/sh
case "$1" in
  get) printf 'NAME  STATUS\n%s-one  Fine\n' "$2" ;;
  api-resources) printf 'pods\nwidgets.example.com\n' ;;
esac
]]

local function open(t: test.TestContext): Shell
	local dir = t:tempdir({ ["bin/kubectl"] = KUBECTL, ["kubeconfig"] = "" })
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/kubectl` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	sh.env.KUBECONFIG = `{dir}/kubeconfig`
	return sh
end

test("another resource runs a kubectl get block again in its place", function(t)
	local sh = open(t)
	local block = assert(shell.run(sh, "kubectl get pods", { view = greed.view() }))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	local object = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{block.number}`))
	local names: { [string]: boolean } = {}
	for _, action in core.objects.actions(object) do
		names[action.name] = true
	end
	assert(names["another resource"] and names["another namespace"], "offered")
	local count = #sh.blocks
	core.objects.act(object, "another resource")
	local listed = table.concat(t:floats(), "\n")
	assert(string.find(listed, "widgets.example.com", 1, true), listed)
	t:keys("w i d g e t s enter")
	t:wait_for(function()
		return block.command == "kubectl get widgets.example.com" and block.status ~= "running"
	end)
	assert(#sh.blocks == count, "in its place")
	assert(string.find(block.output, "widgets.example.com-one", 1, true), block.output)
	-- Other blocks don't offer it.
	local other = assert(shell.run(sh, "echo hi"))
	t:wait_for(function()
		return other.status ~= "running"
	end)
	local plain = assert(core.objects.get(`shell-block:{sh.buffer:id()}.{other.number}`))
	for _, action in core.objects.actions(plain) do
		assert(action.name ~= "another resource", "only for kubectl get")
	end
end)
