-- Key hints: after a key that starts longer sequences, like "space", show
-- what can come next and what each key does. f1 shows the keys of the mode
-- you're in, and the first time you're in a mode listed in `intro` (like
-- typing into a terminal), a line in the status line says how to get out.

local greed = require("@greed")
local core = require("@core")

local M = {}

--- What to say the first time you're in a mode, once a session.
M.intro = {
	terminal = "typing into the terminal: esc esc or ctrl-\\ stops, alt-p for panes, f1 for more",
} :: { [string]: string }

--- Names for keys that start longer sequences, as Helix names its menus,
--- by the keys after the leader (`space` in Helix and Vim, `ctrl-space` in
--- the vscode style)...
M.leader_groups = {
	g = "version control",
	h = "help",
	i = "agents",
	l = "Luau",
	m = "markdown and code blocks",
	n = "notes",
	o = "proposals, shells and tasks",
	u = "operations and undo",
	w = "panes",
	["w n"] = "new pane",
} :: { [string]: string }

--- ... and by the keys as typed.
M.groups = {
	g = "goto",
	["g r"] = "language server",
	m = "match",
	["m a"] = "select around",
	["m i"] = "select inside",
	z = "view and folds",
	["]"] = "next",
	["["] = "previous",
	space = "leader",
	["ctrl-space"] = "leader",
} :: { [string]: string }

local shown: greed.View? = nil
-- Whether what's shown is f1's help, which goes with the next command.
local helping = false

local function hide()
	if shown then
		shown:close()
		shown = nil
	end
	helping = false
end

-- The name of the group of keys `keys` starts, from `M.groups` or, after
-- the leader, `M.leader_groups`; else the word its commands share, as in
-- "pane...", or how many keys follow.
local function group(keys: string): string
	local leader = core.style.current().leader
	local after = if leader and string.sub(keys, 1, #leader + 1) == leader .. " "
		then string.sub(keys, #leader + 2)
		else nil
	local name = M.groups[keys] or (after and M.leader_groups[after])
	if name then
		return name .. "…"
	end
	local words: { [string]: boolean } = {}
	local count, distinct, word = 0, 0, ""
	for _, following in greed.keymap.next(keys) do
		count += 1
		word = string.match(following.command or "", "^[^-]+") or ""
		if not words[word] then
			words[word] = true
			distinct += 1
		end
	end
	return if distinct == 1 and word ~= "" then `{word}…` else `{count} more keys…`
end

local function describe(keys: string, command: string?, docs: { [string]: string }): string
	if command == nil then
		return group(keys)
	end
	local doc = docs[command]
	if doc == nil or doc == "" then
		return command
	end
	return doc
end

--- Shows the keys that can follow `keys` (the mode's own keys for "") and
--- what each does, at the bottom, under `title`. Returns whether there was
--- anything to show.
function M.show(keys: string, title: string): boolean
	hide()
	local nexts = greed.keymap.next(if keys == "" then nil else keys)
	if #nexts == 0 then
		return false
	end
	local docs = {}
	for _, command in greed.commands() do
		docs[command.name] = command.doc
	end
	-- Descriptions start in one column, after the longest key name.
	local width = 8
	for _, next in nexts do
		width = math.max(width, #next.key)
	end
	local lines = {}
	-- As wide as the widest line, with room for the border and a space.
	local widest = utf8.len(title) or #title
	for _, next in nexts do
		local key = next.key .. string.rep(" ", width - #next.key)
		local full = if keys == "" then next.key else `{keys} {next.key}`
		local line = `{key} {describe(full, next.command, docs)}`
		widest = math.max(widest, utf8.len(line) or #line)
		table.insert(lines, line)
	end
	local buffer = greed.create_buffer("hints", table.concat(lines, "\n"))
	shown = greed.float(buffer, {
		title = title,
		width = widest + 4,
		height = #lines + 2,
		anchor = "bottom-right",
		focus = false,
	})
	return true
end

greed.on("keys.pending", function(event: greed.KeysPending)
	if event.keys == "" then
		hide()
	else
		M.show(event.keys, event.keys)
	end
end)

greed.command({
	name = "keys-help",
	doc = "Show the keys of the mode you're in and what each does",
	run = function()
		if M.show("", `{greed.mode.get()} keys`) then
			helping = true
		end
	end,
})

-- f1's help stays until the next command.
greed.on("command.run", function(event: greed.CommandRun)
	if helping and event.name ~= "keys-help" then
		hide()
	end
end)

-- The modes introduced already this session.
local introduced: { [string]: boolean } = {}

greed.on("mode.changed", function(event: greed.ModeChanged)
	local intro = M.intro[event.to]
	if intro and not introduced[event.to] then
		introduced[event.to] = true
		greed.echo(intro)
	end
end)

-- In every mode, and in the terminal's, which takes every other key.
greed.keymap.bind({}, { f1 = "keys-help" })
greed.keymap.bind("terminal", { f1 = "keys-help" })

return M
