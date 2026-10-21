-- Actions on things, like Emacs's Embark: finders say what's at the cursor
-- (a file path, a link, a symbol, a problem, a change, the selected text)
-- and every kind of thing has actions. The picker plugin's `act` (`space .`,
-- `alt-.` in the vscode style) lists the actions for what's under the cursor, and
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
local span = require("./text").span

local M = {}

--- A thing to act on: what kind it is ("file", "link", "symbol", ...), how
--- to show it, and the value actions get. `from` and `to` are where it is
--- in the buffer, for things found there; one that names itself as an
--- object (objects.luau) gives its `id`, and the `buffer` it's in.
--- Things of a kind with the same `group` were found together, like the
--- rows a selection covers, and are acted on together.
export type Target = {
	kind: string,
	label: string,
	value: any,
	id: string?,
	buffer: greed.Buffer?,
	from: number?,
	to: number?,
	group: string?,
}

--- Says what's at `range` (the primary selection) in `view`; nil or {}
--- for nothing. `plugin`, once the plugin it came from, is ignored.
export type Finder = {
	name: string,
	plugin: string?,
	find: (view: greed.View, range: greed.Range) -> { Target }?,
}

--- `plugin`, once the plugin it came from, is ignored. `run` may give back
--- what it made to look at, as an object id: a shell action its block.
--- One that only looks (`history` itself) is `quiet`: it isn't kept.
--- One that destroys or stops something (`delete`, `kill`) is `danger`:
--- it asks first, saying what it will do (`says`, the command it runs) and
--- warning where one is due (`warns`, "in PRODUCTION (prod-eu)").
--- One that decides for you (answering an agent's question) is `yours`:
--- an agent can't run it.
export type Action = {
	kind: string,
	name: string,
	doc: string?,
	plugin: string?,
	quiet: boolean?,
	danger: boolean?,
	yours: boolean?,
	says: ((target: Target) -> string?)?,
	warns: ((target: Target) -> string?)?,
	--- Whether it's offered for `target`, for an action that suits only
	--- some things of its kind: every one of them without.
	offers: ((target: Target) -> boolean)?,
	run: (target: Target) -> ...any,
}

--- An action done: on what (its id when it has one, its kind and label),
--- which action, by whom ("you", "agent"), when (milliseconds since 1970)
--- and what it made, as an object id.
export type Done = {
	id: string?,
	kind: string,
	label: string,
	action: string,
	by: string,
	at: number,
	made: string?,
}

local finders: { Finder } = {}
local actions: { Action } = {}
-- What was done, oldest first; only so many are kept.
local done: { Done } = {}
local KEEP = 500

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

-- The name of what enter does to things of each kind.
local defaults: { [string]: string } = {}

--- Makes action `name` what enter does to things of `kind`, wherever they
--- show (a shell block, the inspector), until the plugin that said so goes.
function M.set_default(kind: string, name: string)
	greed.plugin.tie(registry.set(defaults, kind, name))
end

--- What enter does to `target`: its kind's default action, when it has
--- one that suits it.
function M.default_for(target: Target): Action?
	local first = M.for_kind(target.kind, target)[1]
	return if first
			and first.kind == target.kind
			and first.name == defaults[target.kind]
		then first
		else nil
end

--- The actions for things of `kind`: its default first (`set_default`),
--- then the rest in the order they were added, then those for every kind
--- (an action of kind "*"). Given `target`, only those its `offers` says
--- suit it.
function M.for_kind(kind: string, target: Target?): { Action }
	local out = {}
	for _, wanted in { kind, "*" } do
		for _, action in actions do
			local offers = action.offers
			if action.kind == wanted and (target == nil or offers == nil or offers(target)) then
				local first = action.kind == kind and action.name == defaults[kind]
				table.insert(out, if first then 1 else #out + 1, action)
			end
		end
	end
	-- Commands that act on one thing of this kind are its actions too.
	for _, command in greed.commands() do
		local takes = false
		local others_optional = true
		for _, arg in command.args do
			if arg.type == "object" and arg.kind == kind and not takes then
				takes = true
			elseif not arg.optional then
				others_optional = false
			end
		end
		local named = false
		for _, action in out do
			named = named or action.name == command.name
		end
		if takes and others_optional and not named then
			table.insert(out, {
				kind = kind,
				name = command.name,
				doc = command.doc,
				run = function(target: Target)
					local key = if target.id
						then string.sub(target.id, #kind + 2)
						else tostring(target.value)
					greed.run(command.name, { args = { key } })
				end,
			})
		end
	end
	return out
end

-- Runs `action` on `target` for `by`, keeping it in the history.
local function run_one(action: Action, target: Target, by: string?)
	if action.quiet then
		action.run(target)
		return
	end
	local id = target.id
	if id == nil and (type(target.value) == "string" or type(target.value) == "number") then
		id = `{target.kind}:{target.value}`
	end
	local entry: Done = {
		id = id,
		kind = target.kind,
		label = target.label,
		action = action.name,
		by = by or "you",
		at = greed.now(),
	}
	table.insert(done, entry)
	if #done > KEEP then
		table.remove(done, 1)
	end
	local made = action.run(target)
	if type(made) == "string" then
		entry.made = made
	end
end

-- What `f` says about `target`, or nil when it says nothing or fails.
local function asked(f: ((target: Target) -> string?)?, target: Target): string?
	if f == nil then
		return nil
	end
	local ok, said = pcall(f, target)
	return if ok then said else nil
end

--- Asks before `action`, one that destroys or stops something, runs on
--- `targets` for `by`: one of yours with a y/n, several or an agent's in a
--- review listing what each will do. Gives back those it may run on.
function M.confirm(action: Action, targets: { Target }, by: string?): { Target }
	if #targets == 1 and (by or "you") == "you" then
		local target = targets[1]
		local warning = asked(action.warns, target)
		greed.echo(`{action.name} {target.label}{if warning then " - " .. warning else ""}? y/n`)
		local yes = greed.next_key() == "y"
		greed.echo("")
		return if yes then targets else {}
	end
	local items = {}
	for _, target in targets do
		table.insert(items, {
			label = `{action.name}  {target.label}`,
			says = asked(action.says, target),
			warning = asked(action.warns, target),
		})
	end
	local who = if by == "agent" then "An agent asks to " else ""
	local ticked = require("./review").ask(`{who}{action.name} {#targets}`, items) or {}
	local out = {}
	for i, target in targets do
		if ticked[i] then
			table.insert(out, target)
		end
	end
	return out
end

--- Runs `action` on each of `targets` for `by` ("you" by default, "agent"
--- for an agent's), keeping each in the history of what was done. One
--- that destroys or stops something asks first (`confirm`), unless you
--- chose it already where it was shown (`confirmed`, as from another
--- machine). `before`, if given, runs before each, as to put the cursor on
--- it. Gives back those it ran on.
function M.run_all(
	action: Action,
	targets: { Target },
	by: string?,
	before: ((target: Target) -> ())?,
	confirmed: boolean?
): { Target }
	if action.yours and by == "agent" then
		error(`only the user can {action.name}: an agent can't decide that for them`, 0)
	end
	local asks = action.danger and not (confirmed and by ~= "agent")
	local chosen: { Target } = if asks then M.confirm(action, targets, by) else targets
	for _, target in chosen do
		if before then
			before(target)
		end
		run_one(action, target, by)
	end
	return chosen
end

--- Runs `action` on `target` for `by`, as `run_all` does on one; whether
--- it ran.
function M.run(action: Action, target: Target, by: string?): boolean
	return #M.run_all(action, { target }, by) > 0
end

--- Runs `target`'s default action (`default_for`) for `by`; whether it had
--- one.
function M.run_default(target: Target, by: string?): boolean
	local action = M.default_for(target)
	if action == nil then
		return false
	end
	M.run(action, target, by)
	return true
end

--- What was done to the thing with `id`, newest first; with no `id`,
--- everything done.
function M.history(id: string?): { Done }
	local out: { Done } = {}
	for i = #done, 1, -1 do
		if id == nil or done[i].id == id then
			table.insert(out, table.clone(done[i]))
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
				local key = target.id or `{target.kind}\0{target.label}`
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
		require("./file").open(target.value)
	end,
})

M.action({
	kind = "file",
	name = "open-outside",
	doc = "Open it with the program your system opens it with (never a program itself)",
	run = function(target)
		require("./file").open_outside(target.value)
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
	M.action({
		kind = kind,
		name = "rename",
		doc = "Rename or move it: a name alone keeps it in its folder; open files go along",
		run = function(target)
			local path: string = target.value
			local folder = string.match(path, "^(.*)/[^/]*$") or "."
			local name = require("./prompt").ask("rename to", string.match(path, "[^/]*$"))
			if name == nil or name == "" or `{folder}/{name}` == path then
				return
			end
			local project = require("./project")
			local to = if string.find(name, "/", 1, true)
				then project.resolve(name)
				else `{folder}/{name}`
			require("./file").rename(path, to)
			greed.echo(`renamed to {project.short(to)}`)
		end,
	})
	M.action({
		kind = kind,
		name = "delete",
		doc = "Delete it, after you say yes",
		danger = true,
		says = function(target)
			return `delete {target.value}{if kind == "folder" then " and what's in it" else ""}`
		end,
		run = function(target)
			require("./file").remove(target.value)
			greed.echo(`deleted {require("./project").short(target.value)}`)
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
		local from, to = span(range)
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
