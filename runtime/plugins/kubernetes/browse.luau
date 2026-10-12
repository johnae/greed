-- Browsing kubernetes from a `kubectl get` block, as k9s does from its
-- views: `space .` on the block offers "another resource" and "another
-- namespace", which run it again in its place showing that, a watch or
-- `-w` staying live, so one block can go from pods to deployments to the
-- events of another namespace while it stays where it is.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local shell = require("@shell")
local objects = require("./objects")
local context = require("./context")

type Shell = shell.Shell
type Block = shell.Block

local M = {}

-- A word of a line and where it is: from its first character to just after
-- its last.
type Token = { text: string, from: number, to: number }

-- A change to a line: what goes from `from` to just before `to`.
type Edit = { from: number, to: number, text: string }

--- What to show instead: another resource, another namespace, or every
--- namespace (`all`).
export type Retarget = { resource: string?, namespace: string?, all: boolean? }

-- Where `token` starts, the spaces before it included.
local function with_space(line: string, token: Token): number
	local from = token.from
	while from > 1 and string.match(string.sub(line, from - 1, from - 1), "%s") do
		from -= 1
	end
	return from
end

--- `line` showing what `change` says instead, when it runs `kubectl get`
--- on a resource, alone or in a watch or a pipeline: its resource word
--- replaced, and with a namespace or `all`, its namespace flags replaced by
--- `-n NAMESPACE` or `-A`. Nil for any other line.
function M.retarget(line: string, change: Retarget): string?
	local tokens: { Token } = {}
	for from, text, to in string.gmatch(line, "()(%S+)()") do
		table.insert(tokens, { text = text :: string, from = from, to = to :: number })
	end
	local start: number? = nil
	for i, token in tokens do
		if token.text == "kubectl" or string.match(token.text, "/kubectl$") then
			start = i
			break
		end
	end
	if start == nil then
		return nil
	end
	local resource: Token? = nil
	local spaces: { Token } = {}
	local args = 0
	local i = start + 1
	while i <= #tokens do
		local token = tokens[i]
		local text = token.text
		local flag = string.match(text, "^(%-%-?[%w%-]+)=") or string.match(text, "^(%-[no]).+$")
		if string.match(text, "^[|;&]") then
			break
		elseif flag then
			if flag == "-n" or flag == "--namespace" then
				table.insert(spaces, token)
			end
		elseif text == "-n" or text == "--namespace" then
			table.insert(spaces, token)
			if tokens[i + 1] then
				table.insert(spaces, tokens[i + 1])
			end
			i += 1
		elseif text == "-A" or text == "--all-namespaces" then
			table.insert(spaces, token)
		elseif
			text == "--context"
			or text == "-o"
			or text == "--output"
			or objects.VALUED[text]
		then
			i += 1
		elseif text == "--" then
			break
		elseif string.sub(text, 1, 1) ~= "-" then
			args += 1
			if args == 1 and text ~= "get" then
				return nil
			elseif args == 2 then
				resource = token
			end
		end
		i += 1
	end
	if resource == nil then
		return nil
	end
	local edits: { Edit } = {}
	if change.resource then
		table.insert(edits, { from = resource.from, to = resource.to, text = change.resource })
	end
	if change.namespace or change.all then
		for _, token in spaces do
			table.insert(edits, { from = with_space(line, token), to = token.to, text = "" })
		end
		local flag = if change.all then " -A" else ` -n {shell.quote(change.namespace :: string)}`
		table.insert(edits, { from = resource.to, to = resource.to, text = flag })
	end
	-- From the end, so places before stay where they are; what's taken
	-- away at a place before what's put there.
	table.sort(edits, function(a: Edit, b: Edit): boolean
		if a.from ~= b.from then
			return a.from > b.from
		end
		return a.to > b.to
	end)
	for _, edit in edits do
		line = string.sub(line, 1, edit.from - 1) .. edit.text .. string.sub(line, edit.to)
	end
	return line
end

-- The block a target is, with its shell.
local function block_of(target: core.Target): (Shell, Block)
	return target.value.shell, target.value.block
end

-- Runs `block` again in its place, showing what `change` says.
local function change_to(sh: Shell, block: Block, change: Retarget)
	local line = M.retarget(block.command, change)
	if line then
		greed.spawn(function()
			shell.change(sh, block, line)
		end)
	end
end

-- Whether `target`, a block, runs `kubectl get` on a resource.
local function offers(target: core.Target): boolean
	local _, block = block_of(target)
	return M.retarget(block.command, {}) ~= nil
end

core.actions.action({
	kind = "shell-block",
	name = "another resource",
	doc = "Show another kubernetes resource in its place, as it runs",
	offers = offers,
	run = function(target)
		local sh, block = block_of(target)
		local items: { picker.Item } = {}
		local listed: { [string]: boolean } = {}
		local function add(resource: string)
			if not listed[resource] then
				listed[resource] = true
				table.insert(items, { label = resource, value = resource })
			end
		end
		for _, resource in objects.resources() do
			add(resource)
		end
		-- The rest the cluster has, its custom resources too.
		local names = context.kubectl(sh, { "api-resources", "--verbs=list", "-o", "name" })
		for name in string.gmatch(names or "", "%S+") do
			add(name)
		end
		picker.pick("Resource", items, function(item)
			change_to(sh, block, { resource = item.value })
		end)
	end,
})

core.actions.action({
	kind = "shell-block",
	name = "another namespace",
	doc = "Show another kubernetes namespace, or all of them, in its place, as it runs",
	offers = offers,
	run = function(target)
		local sh, block = block_of(target)
		local items: { picker.Item } = { { label = "all namespaces", value = false } }
		local names, err = context.kubectl(sh, { "get", "namespaces", "-o", "name" })
		if names == nil then
			greed.echo(`can't list the namespaces: {err}`)
		end
		for name in string.gmatch(names or "", "namespace/(%S+)") do
			table.insert(items, { label = name, value = name })
		end
		picker.pick("Namespace", items, function(item)
			if item.value then
				change_to(sh, block, { namespace = item.value })
			else
				change_to(sh, block, { all = true })
			end
		end)
	end,
})

return M
