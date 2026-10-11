local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local kubernetes = require("@kubernetes")

type Shell = typeof(shell.open())

local CONFIG = [[
apiVersion: v1
kind: Config
current-context: staging
contexts:
- name: prod-eu
  context:
    cluster: eu
    user: me
    namespace: payments
- name: staging
  context:
    cluster: st
    user: me
]]

-- A kubectl that switches the context and namespace in the first file
-- KUBECONFIG names, and lists two namespaces.
local KUBECTL = [[#!/bin/sh
file=${KUBECONFIG%%:*}
case "$1 $2" in
  "config use-context") sed "s/^current-context: .*/current-context: $3/" "$file" > "$file.new" && mv "$file.new" "$file" ;;
  "config set-context") ns=${4#--namespace=}; printf '%s\n' "$ns" > "$file.namespace" ;;
  "get namespaces") printf 'namespace/default\nnamespace/billing\n' ;;
esac
]]

-- A shell whose kubectl is the one above, reading `config`.
local function open(t: test.TestContext): (Shell, string)
	local dir = t:tempdir({ ["bin/kubectl"] = KUBECTL, ["kubeconfig"] = CONFIG })
	assert(greed.process.run({ "chmod", "+x", `{dir}/bin/kubectl` }))
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = dir
	local path = assert(greed.process.run({ "printenv", "PATH" })).stdout
	sh.env.PATH = `{dir}/bin:{string.gsub(path, "\n$", "")}`
	sh.env.KUBECONFIG = `{dir}/kubeconfig`
	return sh, dir
end

test("the contexts a kubeconfig defines, and the current one", function(t)
	local sh = open(t)
	local contexts, current = kubernetes.context.contexts(sh)
	assert(current == "staging", tostring(current))
	assert(#contexts == 2 and contexts[1].name == "prod-eu" and contexts[1].namespace == "payments")
	assert(contexts[1].cluster == "eu" and contexts[1].user == "me")
end)

test("switching everywhere goes through kubectl, the prompt following", function(t)
	local sh, dir = open(t)
	kubernetes.context.use("prod-eu", sh)
	assert(
		(string.find(greed.fs.read(`{dir}/kubeconfig`) or "", "current-context: prod-eu", 1, true))
	)
	assert(kubernetes.current(sh) == "prod-eu")
	kubernetes.context.use_namespace("billing", sh)
	assert(greed.fs.read(`{dir}/kubeconfig.namespace`) == "billing\n")
end)

test("switching in one shell leaves the kubeconfig and other shells as they were", function(t)
	local sh, dir = open(t)
	local other = assert(shell.open({ show = false }))
	other.env.KUBECONFIG = `{dir}/kubeconfig`
	kubernetes.context.use("prod-eu", sh, true)
	local context, namespace = kubernetes.current(sh)
	assert(context == "prod-eu" and namespace == "payments", tostring(context))
	assert(kubernetes.current(other) == "staging", "the other shell keeps its own")
	assert(
		(string.find(greed.fs.read(`{dir}/kubeconfig`) or "", "current-context: staging", 1, true))
	)
	-- Its own kubeconfig comes first, with yours after it for the rest.
	local list = sh.env.KUBECONFIG :: string
	local yours = `:{dir}/kubeconfig`
	assert(string.sub(list, -#yours) == yours, list)
	kubernetes.context.use_namespace("billing", sh, true)
	local _, now = kubernetes.current(sh)
	assert(now == "billing", tostring(now))
	-- Switching everywhere from it lets its own go.
	kubernetes.context.use("staging", sh)
	assert(sh.env.KUBECONFIG == `{dir}/kubeconfig`, tostring(sh.env.KUBECONFIG))
	assert(kubernetes.current(sh) == "staging")
end)

test(
	"space o k picks a context, marking the current and production ones; ctrl-s in this shell",
	function(t)
		local sh = open(t)
		t:keys("esc space o k")
		local listed = table.concat(t:floats(), "\n")
		assert(string.find(listed, "prod-eu  payments  (PRODUCTION)", 1, true), listed)
		assert(string.find(listed, "staging  default  (current)", 1, true), listed)
		t:keys("p r o d ctrl-s")
		assert(kubernetes.current(sh) == "prod-eu", "switched in this shell")
		-- The prompt's context opens the picker when clicked.
		local action: string? = nil
		for _, mark in sh.buffer:decorations("shell.prompt") do
			if mark.text and string.find(mark.text, "prod-eu", 1, true) then
				action = mark.action
			end
		end
		assert(action == "kube-context", tostring(action))
	end
)
