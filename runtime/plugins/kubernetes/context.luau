-- Switching kubectl's context and namespace, as kubectx and kubens do:
-- `space o k` (`:kube-context`) picks a context and `space o K`
-- (`:kube-namespace`) a namespace, the current one marked and production
-- ones flagged. `enter` switches everywhere, as `kubectl config
-- use-context` does; `ctrl-s` only in this shell, which then reads a small
-- kubeconfig of its own ahead of yours, so other shells and terminals keep
-- theirs. A click on the prompt's context opens the picker too.

local greed = require("@greed")
local picker = require("@picker")
local shell = require("@shell")
local config = require("./config")

type Shell = shell.Shell

local M = {}

-- The folder this shell's own kubeconfigs are kept in.
local function own_folder(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/kubernetes` else nil
end

-- The kubeconfig of `sh`'s own, which switching in it alone writes.
local function own_file(sh: Shell): string?
	local folder = own_folder()
	return if folder then `{folder}/shell-{sh.id}.yaml` else nil
end

-- `sh`'s kubeconfig files, without a kubeconfig of its own.
local function shared_files(sh: Shell): { string }
	local own = own_file(sh)
	local out = {}
	for _, path in config.files(sh) do
		if path ~= own then
			table.insert(out, path)
		end
	end
	return out
end

--- The contexts `sh`'s kubeconfigs define, each once (the first file
--- defining one wins, as kubectl merges them), and the current one.
function M.contexts(sh: Shell): ({ config.Context }, string?)
	local out: { config.Context } = {}
	local seen: { [string]: boolean } = {}
	local current: string? = nil
	for _, path in config.files(sh) do
		local says, contexts = config.contexts(greed.fs.read(path) or "")
		current = current or says
		for _, context in contexts do
			if not seen[context.name] then
				seen[context.name] = true
				table.insert(out, context)
			end
		end
	end
	return out, current
end

-- The context in `contexts` called `name`.
local function find(contexts: { config.Context }, name: string?): config.Context?
	for _, context in contexts do
		if context.name == name then
			return context
		end
	end
	return nil
end

-- Runs kubectl with `args` as `sh` would, with its variables (its
-- KUBECONFIG, its PATH): what it printed, or nil and why it failed.
local function kubectl(sh: Shell?, args: { string }): (string?, string?)
	local env: { [string]: string | false } = if sh then table.clone(sh.env) else {}
	local argv = { "kubectl" }
	table.move(args, 1, #args, 2, argv)
	local child, err = greed.process.spawn(argv, { env = env })
	if child == nil then
		return nil, err or "can't run kubectl"
	end
	child:close()
	local parts: { string } = {}
	while true do
		local piece = child:read()
		if piece == nil then
			break
		end
		table.insert(parts, piece)
	end
	local code = child:wait()
	if code ~= 0 then
		return nil, string.match(child:stderr(), "^%s*(.-)%s*$")
	end
	return table.concat(parts), nil
end

-- A YAML string, quoted as JSON is, which YAML reads the same.
local function quoted(text: string): string
	return greed.json.encode(text)
end

-- Makes `sh` read a kubeconfig of its own ahead of its others, making
-- `context` current there with `namespace`, or reads only those others
-- again when `context` is nil.
local function own_context(sh: Shell, context: config.Context?, namespace: string?)
	local file = own_file(sh)
	local shared = shared_files(sh)
	if context == nil or file == nil then
		if file then
			greed.fs.remove(file)
		end
		-- With none of its own left, it inherits KUBECONFIG again.
		local env: { [string]: any } = sh.env
		env.KUBECONFIG = if #shared > 0 then table.concat(shared, ":") else nil
		return
	end
	local lines = {
		"apiVersion: v1",
		"kind: Config",
		`current-context: {quoted(context.name)}`,
		"contexts:",
		`- name: {quoted(context.name)}`,
		"  context:",
	}
	for _, field in { "cluster", "user" } do
		local value = (context :: any)[field]
		if value then
			table.insert(lines, `    {field}: {quoted(value)}`)
		end
	end
	local ns = namespace or context.namespace
	if ns then
		table.insert(lines, `    namespace: {quoted(ns)}`)
	end
	greed.fs.mkdir(assert(own_folder()))
	greed.fs.write(file, table.concat(lines, "\n") .. "\n", { private = true })
	table.insert(shared, 1, file)
	sh.env.KUBECONFIG = table.concat(shared, ":")
end

-- The shell to switch in: the one in view, or the project's.
local function here(): Shell?
	return shell.of(greed.view():buffer()) or shell.list(greed.project.current().id)[1]
end

-- Shows the context as it is now on every shell's prompt.
local function redraw()
	for _, other in shell.list() do
		shell.segments.refresh(other)
	end
end

--- Makes `name` the current context: everywhere, as `kubectl config
--- use-context` does, or with `only` only in the shell `sh`. Says how it
--- went.
function M.use(name: string, sh: Shell?, only: boolean?)
	if only then
		if sh == nil then
			greed.echo("no shell here to switch in")
			return
		end
		local found = find((M.contexts(sh)), name)
		if found == nil then
			greed.echo(`there's no context {name}`)
			return
		end
		own_context(sh, found, nil)
		redraw()
		greed.echo(`{name} in this shell only`)
		return
	end
	local own = if sh then own_file(sh) else nil
	if sh and own and string.find(sh.env.KUBECONFIG or "", own, 1, true) then
		own_context(sh, nil, nil)
	end
	local _, err = kubectl(sh, { "config", "use-context", name })
	if err then
		greed.echo(`can't switch to {name}: {err}`)
		return
	end
	redraw()
	greed.echo(`switched to {name}`)
end

--- Makes `namespace` the current context's: everywhere, or with `only`
--- only in the shell `sh`.
function M.use_namespace(namespace: string, sh: Shell?, only: boolean?)
	if only then
		local found: config.Context? = nil
		if sh then
			local contexts, current = M.contexts(sh)
			found = find(contexts, current)
		end
		if sh == nil or found == nil then
			greed.echo("no current context to set the namespace of")
			return
		end
		own_context(sh, found, namespace)
		redraw()
		greed.echo(`namespace {namespace} in this shell only`)
		return
	end
	local _, err = kubectl(sh, { "config", "set-context", "--current", `--namespace={namespace}` })
	if err then
		greed.echo(`can't set the namespace: {err}`)
		return
	end
	redraw()
	greed.echo(`namespace {namespace}`)
end

local KEYS = "enter switches everywhere · ctrl-s in this shell only"

greed.command({
	name = "kube-context",
	doc = "Switch kubectl's context, everywhere or in this shell only; with a name, to that one",
	args = { { name = "name", doc = "The context to switch to" } },
	run = function(ctx)
		local sh = here()
		if ctx.args[1] then
			M.use(ctx.args[1], sh, ctx.force)
			return
		end
		if sh == nil then
			greed.echo("open a shell first: space o s")
			return
		end
		local contexts, current = M.contexts(sh)
		if #contexts == 0 then
			greed.echo("kubectl's config has no contexts")
			return
		end
		local items: { picker.Item } = {}
		for _, context in contexts do
			local marks = {}
			if context.name == current then
				table.insert(marks, "current")
			end
			if shell.segments.production(context.name) then
				table.insert(marks, "PRODUCTION")
			end
			table.insert(items, {
				label = `{context.name}  {context.namespace or "default"}{if #marks > 0
					then "  (" .. table.concat(marks, ", ") .. ")"
					else ""}`,
				value = context.name,
			})
		end
		picker.pick(`Kubernetes context ({KEYS})`, items, function(item)
			M.use(item.value, sh)
		end, {
			keys = {
				["ctrl-s"] = function(_items, item)
					if item then
						M.use(item.value, sh, true)
					end
				end,
			},
		})
	end,
})

greed.command({
	name = "kube-namespace",
	doc = "Switch the namespace of kubectl's context, everywhere or in this shell only; with a name, to that one",
	args = { { name = "name", doc = "The namespace to switch to" } },
	run = function(ctx)
		local sh = here()
		if ctx.args[1] then
			M.use_namespace(ctx.args[1], sh, ctx.force)
			return
		end
		local listed, err = kubectl(sh, { "get", "namespaces", "-o", "name" })
		if listed == nil then
			greed.echo(`can't list the namespaces: {err}`)
			return
		end
		local _, now = if sh then config.current(sh) else nil, nil
		local items: { picker.Item } = {}
		for name in string.gmatch(listed, "namespace/(%S+)") do
			local current = name == (now or "default")
			table.insert(
				items,
				{ label = `{name}{if current then "  (current)" else ""}`, value = name }
			)
		end
		picker.pick(`Namespace ({KEYS})`, items, function(item)
			M.use_namespace(item.value, sh)
		end, {
			keys = {
				["ctrl-s"] = function(_items, item)
					if item then
						M.use_namespace(item.value, sh, true)
					end
				end,
			},
		})
	end,
})

-- A shell's kubeconfig of its own goes with it.
greed.on("buffer.closed", function()
	local folder = own_folder()
	if folder == nil then
		return
	end
	local open: { [string]: boolean } = {}
	for _, sh in shell.list() do
		open[`shell-{sh.id}.yaml`] = true
	end
	local entries = greed.fs.list(folder)
	if entries == nil then
		return
	end
	for _, entry in entries do
		if not open[entry.name] then
			greed.fs.remove(`{folder}/{entry.name}`)
		end
	end
end)

greed.keymap.bind({ layer = "leader" }, { ["o k"] = "kube-context", ["o K"] = "kube-namespace" })

return M
