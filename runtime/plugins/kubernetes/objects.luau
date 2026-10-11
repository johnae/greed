-- `kubectl get`'s rows as kubernetes objects: a pod, a deployment, a
-- service, in the context and namespace the command ran against. Those are
-- taken when the block finishes, from its flags or else from kubectl's
-- config, so acting on an old block after `kubectl config use-context`
-- still goes where the row was, and every action spells them out.

local greed = require("@greed")
local shell = require("@shell")
local config = require("./config")

local parse = shell.parse

type Block = shell.Block
type Shell = shell.Shell
type Thing = shell.Thing

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

-- The kubernetes object `name` of `resource`, in `namespace` (nil for a
-- cluster's own) and `context`, as a thing.
local function thing_of(resource: string, name: string, namespace: string?, context: string?): Thing
	local kind = kind_of(resource)
	local place = `{context or ""}/{namespace or ""}`
	return {
		kind = kind,
		label = if kind == "kubernetes" then `{singular(resource)}/{name}` else name,
		key = if kind == "kubernetes" then `{place}/{resource}/{name}` else `{place}/{name}`,
		value = { resource = resource, name = name, namespace = namespace, context = context },
	}
end

-- A kubectl command line read: the words that aren't flags (the command,
-- then what it's about), and the flags saying where and how.
type Read = {
	args: { string },
	context: string?,
	namespace: string?,
	all: boolean,
	output: string?,
	watch: boolean,
}

-- The flags that take a value, besides those naming where.
local VALUED: { [string]: boolean } = {
	["-l"] = true,
	["--selector"] = true,
	["--field-selector"] = true,
	["-c"] = true,
	["--container"] = true,
	["--tail"] = true,
	["--since"] = true,
}

-- Reads `words`, a kubectl command line from its second word.
local function read_line(words: { string }): Read
	local found: Read =
		{ args = {}, context = nil, namespace = nil, all = false, output = nil, watch = false }
	local i = 2
	while i <= #words do
		local word = words[i]
		-- `--namespace=x`, `-n=x`, and the short flags run together: `-nx`,
		-- `-ojson`.
		local flag, value = string.match(word, "^(%-%-?[%w%-]+)=(.*)$")
		if flag == nil then
			flag, value = string.match(word, "^(%-[no])(.+)$")
		end
		local name: string = flag or word
		local function take(): string?
			if value then
				return value
			end
			i += 1
			return words[i]
		end
		if name == "-n" or name == "--namespace" then
			found.namespace = take()
		elseif name == "--context" then
			found.context = take()
		elseif name == "-A" or name == "--all-namespaces" then
			found.all = true
		elseif name == "-w" or name == "--watch" or name == "--watch-only" then
			found.watch = true
		elseif name == "-o" or name == "--output" then
			found.output = take()
		elseif VALUED[name] then
			take()
		elseif word == "--" then
			break
		elseif string.sub(word, 1, 1) ~= "-" then
			table.insert(found.args, word)
		end
		i += 1
	end
	return found
end

-- A resource as typed (`po`, `deploy`, `pods`) by its full plural name.
local function resource_of(word: string): string
	local first = string.match(word, "^([^,/]+)") or word
	return SHORT[first] or first
end

-- The kubectl commands whose next word is a pod.
local POD_COMMANDS: { [string]: boolean } =
	{ logs = true, exec = true, attach = true, ["port-forward"] = true }

-- The kubectl commands whose next words are a resource and one of its
-- objects: `describe pod NAME`.
local NAMED_COMMANDS: { [string]: boolean } = {
	get = true,
	describe = true,
	delete = true,
	edit = true,
	label = true,
	annotate = true,
	scale = true,
}

-- What `kubectl get` was asked for: the resource, the context and
-- namespace flags it was given, and whether it got every namespace.
type Asked = {
	resource: string,
	context: string?,
	namespace: string?,
	all: boolean,
}

-- Reads `words`, a `kubectl get` command line printing a table; nil for
-- any other kubectl.
local function asked(words: { string }): Asked?
	local line = read_line(words)
	local output = line.output
	if line.args[1] ~= "get" or line.args[2] == nil or (output and output ~= "wide") then
		return nil
	end
	return {
		resource = resource_of(line.args[2]),
		context = line.context,
		namespace = line.namespace,
		all = line.all,
	}
end

-- What a `kubectl get` block was about, kept as it finished.
type Captured = { resource: string, context: string?, namespace: string?, all: boolean }

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

shell.kind({
	name = "kubernetes",
	match = "kubectl",
	capture = function(block: Block, sh: Shell): any
		local words = parse.words(shell.kinds.command_line(block), greed.fs.dirs().home)
		local got = if words then asked(words) else nil
		if got == nil then
			return nil
		end
		local context, namespace = config.current(sh)
		local captured: Captured = {
			resource = got.resource,
			context = got.context or context,
			namespace = if got.all then nil else got.namespace or namespace or "default",
			all = got.all,
		}
		return captured
	end,
	row = function(row: { [string]: string }, captured: Captured): Thing?
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
		local thing = thing_of(resource, name, namespace, captured.context)
		-- The node a pod runs on (with -o wide) and the namespace a row is
		-- in (with -A) are objects of their own.
		local cells: { [string]: Thing } = {}
		local node = row.NODE
		if node and node ~= "" and node ~= "<none>" then
			cells.NODE = thing_of("nodes", node, nil, captured.context)
		end
		if captured.all and namespace then
			cells.NAMESPACE = thing_of("namespaces", namespace, nil, captured.context)
		end
		thing.cells = cells
		return thing
	end,
	called = function(captured: Captured): (string, string)
		return singular(captured.resource), captured.resource
	end,
	streams = function(words: { string }): boolean
		return read_line(words).watch and asked(words) ~= nil
	end,
	complete = {
		kubectl = function(words: { string }, sh: Shell): ((value: any) -> string?)?
			if string.sub(words[#words] or "", 1, 1) == "-" then
				return nil
			end
			local line = read_line(table.move(words, 1, #words - 1, 1, {}))
			local args = line.args
			local resource: string? = nil
			if POD_COMMANDS[args[1]] and #args == 1 then
				resource = "pods"
			elseif NAMED_COMMANDS[args[1]] and #args == 2 then
				resource = resource_of(args[2])
			elseif args[1] == "rollout" and #args == 3 then
				resource = resource_of(args[3])
			end
			if resource == nil then
				return nil
			end
			-- Only what's where this command goes: its flags, else kubectl's
			-- config now.
			local context, namespace = config.current(sh)
			context = line.context or context
			namespace = if line.all then nil else line.namespace or namespace or "default"
			return function(value: any): string?
				local fits = value.resource == resource
					and value.context == context
					and (namespace == nil or value.namespace == nil or value.namespace == namespace)
				return if fits then value.name else nil
			end
		end,
	},
})

-- Watching one gets just it again: `kubectl get pods api-0 -n payments`.
local function get(value: any): string
	return kubectl(`get {object(value)}`, value)
end

shell.object_kind("pod", "A kubernetes pod, by its context, namespace and name", get)
shell.object_kind("deployment", "A kubernetes deployment, by its context, namespace and name", get)
shell.object_kind(
	"kubernetes",
	"A kubernetes object, by its context, namespace, resource and name",
	get
)

-- What every kubernetes object has.
for _, kind in { "pod", "deployment", "kubernetes" } do
	shell.action_command(kind, "describe", function(value: any): string
		return kubectl(`describe {object(value)}`, value)
	end, { doc = "What kubectl says about it, its events too", default = true })
	shell.action_command(kind, "yaml", function(value: any): string
		return kubectl(`get {object(value)} -o yaml`, value)
	end, { doc = "Its whole definition, as YAML" })
	shell.action_command(kind, "json", function(value: any): string
		return kubectl(`get {object(value)} -o json`, value)
	end, { doc = "Its whole definition, as JSON the shell keeps as a value" })
	shell.action_command(kind, "events", function(value: any): string
		local named = `involvedObject.name={value.name}`
		local known = KIND[value.resource]
		local selector = parse.quote(if known then `{named},involvedObject.kind={known}` else named)
		return kubectl(`get events --field-selector {selector}`, value)
	end, { doc = "The events about it" })
	shell.action_command(kind, "delete", function(value: any): string
		return kubectl(`delete {object(value)}`, value)
	end, { doc = "Delete it", danger = true })
end

shell.action_command("pod", "logs", function(value: any): string
	return kubectl(`logs {parse.quote(value.name)} --tail 200`, value)
end, { doc = "The end of what it logged" })
shell.action_command("pod", "follow logs", function(value: any): string
	return kubectl(`logs -f {parse.quote(value.name)} --tail 50`, value)
end, { doc = "What it logs, as it logs it", follow = true })
shell.action_command("pod", "shell", function(value: any): string
	return "!" .. kubectl(`exec -it {parse.quote(value.name)}`, value) .. " -- sh"
end, { doc = "A shell in it, in a terminal" })

shell.action_command("deployment", "restart", function(value: any): string
	return kubectl(`rollout restart deployment {parse.quote(value.name)}`, value)
end, { doc = "Start its pods again, one by one", danger = true })
shell.action_command("deployment", "rollout status", function(value: any): string
	return kubectl(`rollout status deployment {parse.quote(value.name)}`, value)
end, { doc = "How its rollout is going" })

return {}
