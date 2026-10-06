-- Actions on things, like Emacs's Embark: finders say what's at the cursor
-- (a file path, a link, a symbol, a problem, a change, the selected text)
-- and every kind of thing has actions. The picker plugin's `act` (`space .`,
-- `alt-.` in edit mode) lists the actions for what's under the cursor, and
-- `alt-.` in a picker for the current item, so the same verbs work wherever
-- a thing shows up.
--
-- Plugins add both:
--
--     local actions = require("@core").actions
--     actions.finder({ name = "ticket", find = function(view, range)
--         ... return { { kind = "ticket", label = "ABC-12", value = "ABC-12" } }
--     end })
--     actions.action({ kind = "ticket", name = "open", run = function(target)
--         ... end })
--
-- A plugin's finders and actions go when it does.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- A thing to act on: what kind it is ("file", "link", "symbol", ...), how
--- to show it, and the value actions get. `from` and `to` are where it is
--- in the buffer, for things found there.
export type Target = {
	kind: string,
	label: string,
	value: any,
	from: number?,
	to: number?,
}

--- Says what's at `range` (the primary selection) in `view`; nil or {}
--- for nothing. `plugin`, once the plugin it came from, is ignored.
export type Finder = {
	name: string,
	plugin: string?,
	find: (view: greed.View, range: greed.Range) -> { Target }?,
}

--- `plugin`, once the plugin it came from, is ignored.
export type Action = {
	kind: string,
	name: string,
	doc: string?,
	plugin: string?,
	run: (target: Target) -> (),
}

local finders: { Finder } = {}
local actions: { Action } = {}

--- Adds a finder, replacing one by the same name.
function M.finder(finder: Finder)
	greed.plugin.tie(registry.put(finders, finder, function(other: Finder)
		return other.name == finder.name
	end))
end

--- Adds an action for things of `kind`, replacing one by the same name.
function M.action(action: Action)
	greed.plugin.tie(registry.put(actions, action, function(other: Action)
		return other.kind == action.kind and other.name == action.name
	end))
end

--- Adds an action for things of `kind` that runs `command`, for the many
--- actions that are a command acting on what's under the cursor. A fifth
--- argument, once the plugin's name, is ignored.
function M.command(kind: string, name: string, command: string, doc: string, _plugin: string?)
	M.action({
		kind = kind,
		name = name,
		doc = doc,
		run = function()
			greed.run(command)
		end,
	})
end

--- The actions for things of `kind`, in the order they were added.
function M.for_kind(kind: string): { Action }
	local out = {}
	for _, action in actions do
		if action.kind == kind then
			table.insert(out, action)
		end
	end
	return out
end

--- What's at the primary selection in `view`, by every finder, each thing
--- once.
function M.at(view: greed.View): { Target }
	local selection = view:selection()
	local range = selection.ranges[selection.primary]
	local out: { Target } = {}
	local seen: { [string]: boolean } = {}
	for _, finder in finders do
		local ok, found = pcall(finder.find, view, range)
		if ok and found then
			for _, target in found do
				local key = `{target.kind}\0{target.label}`
				if not seen[key] then
					seen[key] = true
					table.insert(out, target)
				end
			end
		end
	end
	return out
end

-- The finders and actions core knows about: files named in the text,
-- buttons, and the selected text.

-- The path-like word around `pos`: letters, digits and . _ - / ~.
local function path_at(buffer: greed.Buffer, pos: number): (number?, number?)
	local line = buffer:line_of(pos)
	local start, stop = buffer:line_start(line), buffer:line_end(line)
	local text = buffer:slice(start, stop)
	local at = pos - start + 1
	local init = 1
	while true do
		local from, to = string.find(text, "[%w%._%-/~]+", init)
		if from == nil or to == nil then
			return nil, nil
		end
		if from <= at and at <= to + 1 then
			return start + from - 1, start + to
		end
		init = to + 1
	end
end

M.finder({
	name = "file",
	find = function(view, range)
		local buffer = view:buffer()
		local from, to = path_at(buffer, range.head)
		if from == nil or to == nil then
			return nil
		end
		local path = buffer:slice(from, to)
		-- Relative to the file's folder, then to the folder the editor started in.
		local own = buffer:path()
		local candidates = { require("./project").expand(path) }
		if own and string.sub(path, 1, 1) ~= "/" then
			table.insert(candidates, 1, (string.match(own, "^(.*)/") or ".") .. "/" .. path)
		end
		for _, candidate in candidates do
			local stat = greed.fs.stat(candidate)
			if stat then
				return {
					{
						kind = if stat.kind == "dir" then "folder" else "file",
						label = path,
						value = candidate,
						from = from,
						to = to,
					},
				}
			end
		end
		return nil
	end,
})

M.action({
	kind = "file",
	name = "open",
	doc = "Open it here",
	run = function(target)
		greed.open(target.value)
	end,
})

for _, kind in { "file", "folder" } do
	M.action({
		kind = kind,
		name = "copy-path",
		doc = "Copy its full path",
		run = function(target)
			greed.clipboard.set(target.value)
			greed.echo(`copied {target.value}`)
		end,
	})
end

M.finder({
	name = "button",
	find = function(view, range)
		local found = {}
		for _, button in require("./buttons").at(view:buffer(), range.head) do
			table.insert(found, { kind = "button", label = button.text, value = button.action })
		end
		return found
	end,
})

M.action({
	kind = "button",
	name = "press",
	doc = "Press it, as enter or a click does",
	run = function(target)
		greed.run(target.value)
	end,
})

M.finder({
	name = "selection",
	find = function(view, range)
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		-- A selection of one character is a cursor in the Helix style.
		local buffer = view:buffer()
		if to <= buffer:next_char(from) then
			return nil
		end
		local text = buffer:slice(from, to)
		local label = string.gsub(string.sub(text, 1, 40), "\n", " ")
		return { { kind = "text", label = label, value = text, from = from, to = to } }
	end,
})

M.command("text", "search", "search-selection", "Search for it")
M.command("text", "copy", "copy", "Copy it")
M.command("text", "comment", "toggle-comment", "Comment or uncomment its lines")
M.command("text", "pipe", "pipe", "Pipe it through a command")

return M
