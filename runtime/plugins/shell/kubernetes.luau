-- `kubectl get`'s rows as kubernetes objects: a pod, a deployment, a
-- service, in the context and namespace the command ran against. Those are
-- taken when the block finishes, from its flags or else from kubectl's
-- config, so acting on an old block after `kubectl config use-context`
-- still goes where the row was, and every action spells them out.

local greed = require("@greed")
local state = require("./state")
local parse = require("./parse")
local segments = require("./segments")
local kinds = require("./kinds")

type Block = state.Block
type Shell = state.Shell

-- kubectl's short names for the resources people get most.
local SHORT: { [string]: string } = {
	po = "pods",
	pod = "pods",
	deploy = "deployments",
	deployment = "deployments",
	svc = "services",
	service = "services",
	ns = "namespaces",
	namespace = "namespaces",
	no = "nodes",
	node = "nodes",
	cm = "configmaps",
	configmap = "configmaps",
	secret = "secrets",
	sts = "statefulsets",
	statefulset = "statefulsets",
	ds = "daemonsets",
	daemonset = "daemonsets",
	rs = "replicasets",
	replicaset = "replicasets",
	ing = "ingresses",
	ingress = "ingresses",
	pvc = "persistentvolumeclaims",
	pv = "persistentvolumes",
	sa = "serviceaccounts",
	job = "jobs",
	cj = "cronjobs",
	cronjob = "cronjobs",
	ev = "events",
	hpa = "horizontalpodautoscalers",
}

-- The kind names events give the resources people get most.
local KIND: { [string]: string } = {
	pods = "Pod",
	deployments = "Deployment",
	services = "Service",
	nodes = "Node",
	statefulsets = "StatefulSet",
	daemonsets = "DaemonSet",
	replicasets = "ReplicaSet",
	jobs = "Job",
	cronjobs = "CronJob",
	persistentvolumeclaims = "PersistentVolumeClaim",
	ingresses = "Ingress",
	configmaps = "ConfigMap",
	secrets = "Secret",
}

-- One of `resource`, as its plural is: "pods" is "pod", "ingresses"
-- "ingress", "policies" "policy".
local function singular(resource: string): string
	if string.match(resource, "ies$") then
		return string.sub(resource, 1, -4) .. "y"
	elseif string.match(resource, "sses$") or string.match(resource, "[xz]es$") then
		return string.sub(resource, 1, -3)
	elseif string.match(resource, "s$") and not string.match(resource, "ss$") then
		return string.sub(resource, 1, -2)
	end
	return resource
end

-- Resources that belong to no namespace.
local CLUSTER: { [string]: boolean } = {
	namespaces = true,
	nodes = true,
	persistentvolumes = true,
	clusterroles = true,
	clusterrolebindings = true,
	storageclasses = true,
	customresourcedefinitions = true,
}

-- What things of a resource are, to act on: pods and deployments have
-- actions of their own, the rest share the ones every object has.
local function kind_of(resource: string): string
	if resource == "pods" then
		return "pod"
	elseif resource == "deployments" then
		return "deployment"
	end
	return "kubernetes"
end

-- What `kubectl get` was asked for: the resource, the context and
-- namespace flags it was given, and whether it got every namespace.
type Asked = {
	resource: string?,
	context: string?,
	namespace: string?,
	all: boolean,
}

-- Reads `words`, a `kubectl get` command line; nil for any other kubectl.
local function asked(words: { string }): Asked?
	local found: Asked = { resource = nil, context = nil, namespace = nil, all = false }
	local getting = false
	local i = 2
	while i <= #words do
		local word = words[i]
		-- `--namespace=x`, `-n=x`, and the short flags run together: `-nx`,
		-- `-ojson`.
		local flag, value = string.match(word, "^(%-%-?[%w%-]+)=(.*)$")
		if flag == nil then
			flag, value = string.match(word, "^(%-[no])(.+)$")
		end
		flag = flag or word
		local function take(): string?
			if value then
				return value
			end
			i += 1
			return words[i]
		end
		if flag == "-n" or flag == "--namespace" then
			found.namespace = take()
		elseif flag == "--context" then
			found.context = take()
		elseif flag == "-A" or flag == "--all-namespaces" then
			found.all = true
		elseif flag == "-o" or flag == "--output" then
			local format = take()
			if format and format ~= "wide" then
				return nil
			end
		elseif flag == "-l" or flag == "--selector" or flag == "--field-selector" then
			take()
		elseif string.sub(word, 1, 1) ~= "-" then
			if not getting then
				if word ~= "get" then
					return nil
				end
				getting = true
			elseif found.resource == nil then
				local first = string.match(word, "^([^,/]+)") or word
				found.resource = SHORT[first] or first
			end
		end
		i += 1
	end
	return if getting then found else nil
end

-- What a `kubectl get` block was about, kept as it finished.
type Captured = { resource: string, context: string?, namespace: string?, all: boolean }

-- The context and namespace kubectl's config makes current for `shell`.
local function current(shell: Shell, block: Block): (string?, string?)
	local ctx = { shell = shell, cwd = block.cwd, env = state.variables(shell) }
	for _, path in segments.kubeconfigs(ctx) do
		local context, namespace = segments.read_kubeconfig(greed.fs.read(path) or "")
		if context then
			return context, namespace
		end
	end
	return nil, nil
end

-- The flags naming where `value` is: its context, and its namespace.
local function where(value: any): string
	local parts: { string } = {}
	if value.context then
		table.insert(parts, "--context " .. parse.quote(value.context))
	end
	if value.namespace then
		table.insert(parts, "-n " .. parse.quote(value.namespace))
	end
	return table.concat(parts, " ")
end

-- `kubectl` with `args`, then where `value` is.
local function kubectl(args: string, value: any): string
	local flags = where(value)
	return if flags == "" then `kubectl {args}` else `kubectl {args} {flags}`
end

-- `value` as kubectl names an object: its resource, then its name.
local function object(value: any): string
	return `{value.resource} {parse.quote(value.name)}`
end

kinds.kind({
	name = "kubernetes",
	match = "kubectl",
	capture = function(block: Block, shell: Shell): any
		local words = parse.words(block.command, greed.fs.dirs().home)
		local got = if words then asked(words) else nil
		if got == nil or got.resource == nil then
			return nil
		end
		local context, namespace = current(shell, block)
		local captured: Captured = {
			resource = got.resource,
			context = got.context or context,
			namespace = if got.all then nil else got.namespace or namespace or "default",
			all = got.all,
		}
		return captured
	end,
	row = function(row: { [string]: string }, captured: Captured): kinds.Thing?
		local name = row.NAME
		if name == nil or name == "" then
			return nil
		end
		-- Several resources at once name each row `pod/api-x`.
		local resource = captured.resource
		local typed, rest = string.match(name, "^([^/]+)/(.+)$")
		if typed and rest then
			local short = string.match(typed, "^([^.]+)") or typed
			resource, name = SHORT[short] or short .. "s", rest
		end
		local namespace = if CLUSTER[resource]
			then nil
			elseif captured.all then row.NAMESPACE
			else captured.namespace
		return {
			kind = kind_of(resource),
			label = name,
			value = {
				resource = resource,
				name = name,
				namespace = namespace,
				context = captured.context,
			},
		}
	end,
	called = function(captured: Captured): (string, string)
		return singular(captured.resource), captured.resource
	end,
})

-- What every kubernetes object has.
for _, kind in { "pod", "deployment", "kubernetes" } do
	kinds.command(kind, "describe", function(value: any): string
		return kubectl(`describe {object(value)}`, value)
	end, { doc = "What kubectl says about it, its events too", default = true })
	kinds.command(kind, "yaml", function(value: any): string
		return kubectl(`get {object(value)} -o yaml`, value)
	end, { doc = "Its whole definition, as YAML" })
	kinds.command(kind, "json", function(value: any): string
		return kubectl(`get {object(value)} -o json`, value)
	end, { doc = "Its whole definition, as JSON the shell keeps as a value" })
	kinds.command(kind, "events", function(value: any): string
		local named = `involvedObject.name={value.name}`
		local known = KIND[value.resource]
		local selector = parse.quote(if known then `{named},involvedObject.kind={known}` else named)
		return kubectl(`get events --field-selector {selector}`, value)
	end, { doc = "The events about it" })
	kinds.command(kind, "delete", function(value: any): string
		return kubectl(`delete {object(value)}`, value)
	end, { doc = "Delete it", danger = true })
end

kinds.command("pod", "logs", function(value: any): string
	return kubectl(`logs {parse.quote(value.name)} --tail 200`, value)
end, { doc = "The end of what it logged" })
kinds.command("pod", "follow logs", function(value: any): string
	return kubectl(`logs -f {parse.quote(value.name)} --tail 50`, value)
end, { doc = "What it logs, as it logs it" })
kinds.command("pod", "shell", function(value: any): string
	return "!" .. kubectl(`exec -it {parse.quote(value.name)}`, value) .. " -- sh"
end, { doc = "A shell in it, in a terminal" })

kinds.command("deployment", "restart", function(value: any): string
	return kubectl(`rollout restart deployment {parse.quote(value.name)}`, value)
end, { doc = "Start its pods again, one by one", danger = true })
kinds.command("deployment", "rollout status", function(value: any): string
	return kubectl(`rollout status deployment {parse.quote(value.name)}`, value)
end, { doc = "How its rollout is going" })

return {}
