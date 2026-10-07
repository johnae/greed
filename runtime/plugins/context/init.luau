-- The context: what you've pinned for models and agents to see, as live
-- references read fresh each time they're sent.
--
--   space i p   pin the selection, or the file when nothing is selected
--   space i i   show the pinned items, one a line with its size; delete a
--               line (x d) to drop the item
--
-- `:context-add-problems` pins this file's problems, `:context-add-diff` the
-- changes in progress, `:context-clear` drops everything. Assist commands
-- send the context with each question, and agents read it with the
-- context_get tool. It's kept per project.
--
-- A plugin adds items that are worked out when sent:
--
--     require("@context").define("todos", function()
--         return "the TODO lines of the project ..."
--     end)
--     require("@context").add({ kind = "computed", name = "todos" })

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local vcs = require("@vcs")

--- An item: a selection (a range of a file, kept by a mark so it follows
--- edits), a whole file, a file's problems, the changes in progress, or one
--- worked out by a function `define` registered.
export type Item = {
	kind: "selection" | "file" | "problems" | "diff" | "computed",
	path: string?,
	name: string?,
	-- Where a selection was when last seen, kept for saving.
	from: number?,
	to: number?,
	id: number?,
}

local M = {}

-- The items of each project, by its root.
local pinned: { [string]: { Item } } = {}
local computed: { [string]: () -> string } = {}
local next_id = 0

local function root(): string
	return greed.project.current().root
end

local function items(): { Item }
	local key = root()
	local list = pinned[key]
	if list == nil then
		list = {}
		pinned[key] = list
	end
	return list
end

-- The namespace of a selection item's mark in its file's buffer.
local function ns(item: Item): string
	return `context-{item.id}`
end

local function mark(buffer: greed.Buffer, item: Item, from: number, to: number)
	buffer:decorate(ns(item), { { from = from, to = to, style = "context" } })
end

-- Where a selection is now: its mark, or where it was if the mark went. One
-- restored from the last session gets its mark back here.
local function span(item: Item): (greed.Buffer, number, number)
	local buffer = greed.load(item.path :: string)
	local current = buffer:decorations(ns(item))[1]
	if current then
		item.from, item.to = current.from, current.to
	else
		local from = math.clamp(item.from or 0, 0, buffer:len())
		local to = math.clamp(item.to or from, from, buffer:len())
		item.from, item.to = from, to
		mark(buffer, item, from, to)
	end
	return buffer, item.from :: number, item.to :: number
end

--- The text an item stands for now, and a label for it.
function M.read(item: Item): (string, string)
	if item.kind == "selection" then
		local buffer, from, to = span(item)
		local first, last = buffer:line_of(from) + 1, buffer:line_of(math.max(from, to - 1)) + 1
		return buffer:slice(from, to), `{core.project.relative(item.path :: string)}:{first}-{last}`
	elseif item.kind == "file" then
		return greed.load(item.path :: string):text(), core.project.relative(item.path :: string)
	elseif item.kind == "problems" then
		local buffer = greed.load(item.path :: string)
		local lines = {}
		for _, d in greed.lsp.diagnostics(buffer) do
			table.insert(lines, `line {buffer:line_of(d.from) + 1}: {d.message}`)
		end
		local text = if #lines > 0 then table.concat(lines, "\n") else "(no problems)"
		return text, `problems in {core.project.relative(item.path :: string)}`
	elseif item.kind == "diff" then
		local diff = vcs.diff(root())
		return diff or "(not in a repository)", "changes in progress"
	end
	local f = computed[item.name :: string]
	local ok, text = pcall(f or function()
		return `(nothing is defined as {item.name})`
	end)
	return if ok then text else `({item.name} failed: {text})`, item.name :: string
end

--- About how many tokens `text` is, for showing sizes.
function M.tokens(text: string): number
	return math.ceil(#text / 4)
end

-- Saving, so the context comes back with the project.
local function saved_path(): string?
	local cache = greed.fs.dirs().cache
	return cache and `{cache}/context.json`
end

local function save()
	local path = saved_path()
	if path == nil then
		return
	end
	local all: { [string]: any } = {}
	for project, list in pinned do
		local plain = {}
		for _, item in list do
			if item.kind == "selection" then
				span(item)
			end
			table.insert(plain, {
				kind = item.kind,
				path = item.path,
				name = item.name,
				from = item.from,
				to = item.to,
			})
		end
		all[project] = greed.json.array(plain)
	end
	greed.fs.write(path, greed.json.encode(all))
end

--- Pins `item` to the shown project's context.
function M.add(item: Item)
	next_id += 1
	item.id = next_id
	if item.kind == "selection" then
		mark(greed.load(item.path :: string), item, item.from :: number, item.to :: number)
	end
	table.insert(items(), item)
	save()
end

--- Drops `item` from the context.
function M.remove(item: Item)
	local list = items()
	local index = table.find(list, item)
	if index then
		table.remove(list, index)
		if item.kind == "selection" and item.path then
			greed.load(item.path):decorate(ns(item), {})
		end
		save()
	end
end

--- Every pinned item, in the order pinned.
function M.list(): { Item }
	return table.clone(items())
end

--- Registers a computed item's function, for `{ kind = "computed", name }`,
--- until the plugin that registered it goes.
function M.define(name: string, f: () -> string)
	greed.plugin.tie(core.registry.set(computed, name, f))
end

--- The whole context as text for a model: each item under a heading with
--- its label, or "" when nothing is pinned.
function M.text(): string
	local parts = {}
	for _, item in items() do
		local text, label = M.read(item)
		table.insert(parts, `## {label}\n\n{text}`)
	end
	return table.concat(parts, "\n\n")
end

-- The context buffer while it's shown, and the item each line stands for.
local shown: { view: greed.View, buffer: greed.Buffer, lines: { Item } }? = nil

local function render(): (string, { Item }, number)
	local lines, list, total = {}, {}, 0
	for _, item in items() do
		local text, label = M.read(item)
		local size = M.tokens(text)
		total += size
		table.insert(lines, `{label}  ({size} tokens)`)
		table.insert(list, item)
	end
	return table.concat(lines, "\n"), list, total
end

local function title(total: number): string
	return `Context: {total} tokens - x d drops an item, q closes`
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local open = shown
	if open == nil or event.buffer ~= open.buffer then
		return
	end
	-- Lines whose mark went with their text were deleted: drop their items.
	for i, item in open.lines do
		if #open.buffer:decorations(`context-line-{i}`) == 0 then
			M.remove(item)
		end
	end
	local _, list, total = render()
	open.lines = list
	open.view:configure({ title = title(total) })
end)

greed.command({
	name = "context",
	doc = "Show what's pinned for models and agents, with sizes; delete a line to drop it",
	run = function()
		if shown then
			shown.view:close()
		end
		local text, list, total = render()
		if #list == 0 then
			greed.echo("nothing is pinned - space i p pins the selection or the file")
			return
		end
		local buffer = greed.create_buffer("context", text)
		for i in list do
			local stop = if i < #list then buffer:line_start(i) else buffer:len()
			buffer:decorate(
				`context-line-{i}`,
				{ { from = buffer:line_start(i - 1), to = stop, style = "context" } }
			)
		end
		local view = greed.float(buffer, { title = title(total), width = "70%", height = "40%" })
		shown = { view = view, buffer = buffer, lines = list }
	end,
})

greed.command({
	name = "context-add",
	doc = "Pin the selection to the context, or the file when nothing is selected",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil then
			greed.echo("only text in files can be pinned")
			return
		end
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		if to - from > 1 then
			M.add({ kind = "selection", path = path, from = from, to = to })
			greed.echo(`pinned {to - from} characters of {core.project.relative(path)}`)
		else
			M.add({ kind = "file", path = path })
			greed.echo(`pinned {core.project.relative(path)}`)
		end
	end,
})

greed.command({
	name = "context-add-problems",
	doc = "Pin this file's problems to the context",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path then
			M.add({ kind = "problems", path = path })
			greed.echo(`pinned the problems in {core.project.relative(path)}`)
		end
	end,
})

greed.command({
	name = "context-add-diff",
	doc = "Pin the changes in progress to the context",
	run = function()
		M.add({ kind = "diff" })
		greed.echo("pinned the changes in progress")
	end,
})

greed.command({
	name = "context-clear",
	doc = "Drop everything pinned to the context",
	run = function()
		for _, item in M.list() do
			M.remove(item)
		end
		greed.echo("the context is empty")
	end,
})

greed.command({
	name = "context-close",
	doc = "Close the context list",
	run = function()
		if shown then
			shown.view:close()
		end
	end,
})

agent.tool({
	name = "context_get",
	description = "What the user pinned for you in the editor: selections, files, problems, "
		.. "the changes in progress. Each item under a heading saying what it is",
	run = function()
		local text = M.text()
		return if text == "" then "(nothing is pinned)" else text
	end,
})

-- Back from the last session.
local function restore()
	local path = saved_path()
	local text = path and greed.fs.read(path)
	local all = if text then greed.json.decode(text) else nil
	for project, list in all or {} do
		pinned[project] = {}
		for _, saved in list do
			next_id += 1
			local item: Item = {
				kind = saved.kind,
				path = saved.path,
				name = saved.name,
				from = saved.from,
				to = saved.to,
				id = next_id,
			}
			table.insert(pinned[project], item)
		end
	end
end

restore()

greed.keymap.bind("normal", {
	["space i p"] = "context-add",
	["space i i"] = "context",
})
greed.keymap.bind(
	{ mode = "normal", kind = "context" },
	{ q = "context-close", esc = "context-close" }
)

return M
