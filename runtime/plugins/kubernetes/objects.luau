-- `kubectl get`'s rows as kubernetes objects: a pod, a deployment, a
-- service, in the context and namespace the command ran against. Those are
-- taken when the block finishes, from its flags or else from kubectl's
-- config, so acting on an old block after `kubectl config use-context`
-- still goes where the row was, and every action spells them out.

local greed = require("@greed")
local core = require("@core")
local shell = require("@shell")
local config = require("./config")
local json = require("./json")

local parse = shell.parse

local M = {}

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

-- The flags naming where `value` is, as words: its context, and its
-- namespace.
local function where_words(value: any): { string }
	local words: { string } = {}
	if value.context then
		table.insert(words, "--context")
		table.insert(words, value.context)
	end
	if value.namespace then
		table.insert(words, "-n")
		table.insert(words, value.namespace)
	end
	return words
end

-- The flags naming where `value` is, quoted for a command line.
local function where(value: any): string
	local quoted: { string } = {}
	for _, word in where_words(value) do
		table.insert(quoted, parse.quote(word))
	end
	return table.concat(quoted, " ")
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
		local words = parse.words(shell.command_line(block), greed.fs.dirs().home)
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
		-- An event's row is the object it's about, as `pod/api-x`.
		local name = if captured.resource == "events" then row.OBJECT else row.NAME
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
	-- Read as data when stages follow: `kubectl get` as it prints JSON.
	structured = function(words: { string }): string?
		local line = read_line(words)
		if line.args[1] ~= "get" or line.args[2] == nil or line.output or line.watch then
			return nil
		end
		local quoted: { string } = {}
		for _, word in words do
			table.insert(quoted, parse.quote(word))
		end
		return table.concat(quoted, " ") .. " -o json"
	end,
	from_json = function(value: any): shell.Table?
		return json.table(value)
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

-- How long kubectl may take to answer a lookup, in seconds.
local LOOKUP_SECONDS = 5

-- Variables kubectl runs with for lookups: a shell's `KUBECONFIG`, say;
-- the editor's own without.
type Env = { [string]: string | false }?

-- What kubectl prints for `args` about where `value` is (its context and
-- namespace), within LOOKUP_SECONDS; nil when it fails or says nothing.
local function ask(value: any, args: { string }, env: Env): string?
	local argv = { "kubectl", `--request-timeout={LOOKUP_SECONDS}s` }
	table.move(args, 1, #args, #argv + 1, argv)
	local flags = where_words(value)
	table.move(flags, 1, #flags, #argv + 1, argv)
	local ran = greed.process.run(argv, { env = env, timeout = (LOOKUP_SECONDS + 2) * 1000 })
	if ran == nil or ran.code ~= 0 or ran.stdout == "" then
		return nil
	end
	return ran.stdout
end

-- What kubectl says of `args` as JSON, or nil.
local function ask_json(value: any, args: { string }, env: Env): any
	local out = ask(value, args, env)
	if out == nil then
		return nil
	end
	local ok, decoded = pcall(greed.json.decode, out)
	return if ok then decoded else nil
end

-- `thing` as an object.
local function object_of(thing: Thing): core.Object
	return {
		kind = thing.kind,
		id = `{thing.kind}:{thing.key}`,
		label = thing.label,
		value = thing.value,
	}
end

--- The object of `kind` ("pod", "deployment", "kubernetes") with `key`
--- (`context/namespace/name`, or `context/namespace/resource/name` for
--- "kubernetes"): the newest row showing it, or else asked of kubectl. Nil
--- when kubectl says it isn't there or can't say in time. `env` is what
--- kubectl runs with; the editor's variables without.
function M.find(kind: string, key: string, env: Env): core.Object?
	local shown = core.objects.shown(`{kind}:{key}`)
	if shown then
		return shown
	end
	-- From the right: a context's name may have slashes in it.
	local parts = string.split(key, "/")
	local name = table.remove(parts)
	local resource = if kind == "kubernetes" then table.remove(parts) else `{kind}s`
	local namespace = table.remove(parts)
	if name == nil or name == "" or resource == nil or namespace == nil then
		return nil
	end
	local context = table.concat(parts, "/")
	local thing = thing_of(
		resource,
		name,
		if namespace == "" then nil else namespace,
		if context == "" then nil else context
	)
	if ask(thing.value, { "get", resource, name, "-o", "name" }, env) == nil then
		return nil
	end
	return object_of(thing)
end

-- The resource things of an object kind are, by the kind ("ReplicaSet" is
-- "replicasets").
local function resource_of_kind(kind: string): string
	for resource, named in KIND do
		if named == kind then
			return resource
		end
	end
	return string.lower(kind) .. "s"
end

-- The object that owns the one kubectl described as `described`, if one
-- does: its controller, in the same place as `value`.
local function owner_of(value: any, described: any): Thing?
	local owners = described and described.metadata and described.metadata.ownerReferences
	local owner = if type(owners) == "table" then owners[1] else nil
	if owner == nil or type(owner.kind) ~= "string" or type(owner.name) ~= "string" then
		return nil
	end
	return thing_of(resource_of_kind(owner.kind), owner.name, value.namespace, value.context)
end

-- The label selector of deployment `value`'s pods, `app=api,tier=web`, as
-- kubectl says; nil when it can't say.
local function selector_of(value: any, env: Env): string?
	local deployment = ask_json(value, { "get", "deployment", value.name, "-o", "json" }, env)
	local labels = deployment
		and deployment.spec
		and deployment.spec.selector
		and deployment.spec.selector.matchLabels
	if type(labels) ~= "table" then
		return nil
	end
	local selector: { string } = {}
	for label, wanted in labels do
		table.insert(selector, `{label}={wanted}`)
	end
	table.sort(selector)
	return table.concat(selector, ",")
end

--- What the kubernetes object with `value` relates to, asked of kubectl
--- (`env` as `find` takes it): a deployment's `pods`, by its selector, and
--- what owns a pod (`deployment`, through its ReplicaSet, or `owner`).
function M.related(value: any, env: Env): { [string]: { core.Object } }
	if value.resource == "deployments" then
		local selector = selector_of(value, env)
		if selector == nil then
			return {}
		end
		local pods = ask_json(value, { "get", "pods", "-l", selector, "-o", "json" }, env)
		local out: { core.Object } = {}
		local items: { any } = if pods and type(pods.items) == "table" then pods.items else {}
		for _, pod in items do
			local name = pod.metadata and pod.metadata.name
			if type(name) == "string" then
				table.insert(out, object_of(thing_of("pods", name, value.namespace, value.context)))
			end
		end
		return { pods = out }
	elseif value.resource == "pods" then
		local pod = ask_json(value, { "get", "pod", value.name, "-o", "json" }, env)
		local owner = owner_of(value, pod)
		if owner and owner.value.resource == "replicasets" then
			local set =
				ask_json(value, { "get", "replicaset", owner.value.name, "-o", "json" }, env)
			local deployment = owner_of(value, set)
			if deployment then
				return { deployment = { object_of(deployment) } }
			end
		end
		return if owner then { owner = { object_of(owner) } } else {}
	end
	return {}
end

local fresh = shell.fresh(get)
local function relations(value: any): { [string]: { core.Object } }
	return M.related(value, shell.env_of(value))
end
core.objects.kind({
	name = "pod",
	doc = "A kubernetes pod, by its context, namespace and name",
	get = function(key)
		return M.find("pod", key)
	end,
	relations = relations,
	fresh = fresh,
})
core.objects.kind({
	name = "deployment",
	doc = "A kubernetes deployment, by its context, namespace and name",
	get = function(key)
		return M.find("deployment", key)
	end,
	relations = relations,
	fresh = fresh,
})
core.objects.kind({
	name = "kubernetes",
	doc = "A kubernetes object, by its context, namespace, resource and name",
	get = function(key)
		return M.find("kubernetes", key)
	end,
	fresh = fresh,
})

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

-- `kubectl logs` of every pod of deployment `value`, each line saying its
-- pod: by the deployment's selector, or else the deployment itself, which
-- is one of its pods. `follow` keeps printing.
local function pods_logs(value: any, follow: boolean): string
	local selector = selector_of(value, shell.env_of(value))
	local which = if selector
		then `-l {parse.quote(selector)} --max-log-requests 20`
		else `deployment/{parse.quote(value.name)}`
	local tail = if follow then "-f --tail 20" else "--tail 50"
	return kubectl(`logs {which} --all-containers --prefix {tail}`, value)
end

shell.action_command("deployment", "logs", function(value: any): string
	return pods_logs(value, false)
end, { doc = "The end of what all its pods logged, merged, each line saying its pod" })
shell.action_command("deployment", "follow logs", function(value: any): string
	return pods_logs(value, true)
end, { doc = "What all its pods log, as they log it", follow = true })

-- `kubectl logs --prefix` puts the pod and container before each line, as
-- `[pod/api-1/app] `: shown as fields, after the line's message.
shell.log_prefix(function(text: string): ({ [string]: any }?, string)
	local pod, container, rest = string.match(text, "^%[pod/([^/%]]+)/([^%]]+)%] (.*)$")
	if pod == nil or container == nil or rest == nil then
		return nil, text
	end
	return { pod = pod, container = container }, rest
end)

--- The resources people get most, by their full plural names.
function M.resources(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, resource in SHORT do
		if not seen[resource] then
			seen[resource] = true
			table.insert(out, resource)
		end
	end
	table.sort(out)
	return out
end

-- The kubectl commands that only look.
local LOOKS: { [string]: boolean } = {
	get = true,
	describe = true,
	logs = true,
	top = true,
	explain = true,
	["api-resources"] = true,
	["api-versions"] = true,
	version = true,
	["cluster-info"] = true,
	diff = true,
	auth = true,
	wait = true,
	events = true,
	completion = true,
	["port-forward"] = true,
}

-- The `kubectl config` commands that only look.
local CONFIG_LOOKS: { [string]: boolean } = {
	view = true,
	["current-context"] = true,
	["get-contexts"] = true,
	["get-clusters"] = true,
	["get-users"] = true,
}

-- What kubectl `words` does that's risky, when an agent runs it.
core.risk.rule("kubectl", function(words: { string }): string?
	local args = read_line(words).args
	local command = args[1]
	if command == nil or LOOKS[command] then
		return nil
	elseif command == "config" then
		return if CONFIG_LOOKS[args[2] or ""] then nil else "changes which cluster kubectl talks to"
	elseif
		command == "exec"
		or command == "attach"
		or command == "cp"
		or command == "debug"
		or command == "run"
	then
		return `runs or puts something inside the cluster (kubectl {command})`
	end
	return `changes the cluster (kubectl {command})`
end)

M.VALUED = VALUED

return M
