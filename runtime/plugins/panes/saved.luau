-- Saved layouts: a tab's arrangement and what each pane shows, kept to
-- open again.
--
--   :layout-save NAME       saves the tab in the project, .greed/layouts/
--   :layout-save-mine NAME  saves it in your config, for any project
--   :layout-open [NAME]     opens one as a new tab (picks one without)
--
-- A pane is saved as the file it shows (relative to the project), or as a
-- terminal and what it runs. A project can open one itself, from its
-- .greed/init.luau:
--
--     require("@panes").saved.open("dev", { here = true })

local greed = require("@greed")
local core = require("@core")
local terminal = require("@terminal")
local layouts = require("./layouts")

local M = {}

-- What a saved pane shows, or a split of them.
type Saved = {
	split: ("row" | "column")?,
	sizes: { number }?,
	children: { Saved }?,
	file: string?,
	terminal: any?,
}

local function project_dir(): string
	return `{core.project.root()}/.greed/layouts`
end

local function my_dir(): string?
	local config = greed.fs.dirs().config
	return if config then `{config}/layouts` else nil
end

-- Where layouts are looked for: the project's folder, then yours.
local function layout_dirs(): { string }
	local dirs = { project_dir() }
	local mine = my_dir()
	if mine then
		table.insert(dirs, mine)
	end
	return dirs
end

local function describe(node: any): Saved
	if type(node) == "table" then
		local children = {}
		for _, child in node.children do
			table.insert(children, describe(child))
		end
		return { split = node.split, sizes = node.sizes, children = children }
	end
	local buffer = node:buffer()
	if terminal.terminal(buffer) then
		return { terminal = terminal.asked(buffer) or true }
	end
	local path = buffer:path()
	return if path then { file = core.project.relative(path, core.project.root()) } else {}
end

--- Saves the shown tab as layout `name`, in the project or with `mine` in
--- your config. Returns where it went, or nil and why not.
function M.save(name: string, mine: boolean?): (string?, string?)
	if name == "" or string.find(name, "/", 1, true) then
		return nil, "a layout's name can't be empty or have a /"
	end
	local dir = if mine then my_dir() else project_dir()
	if dir == nil then
		return nil, "there's no config folder to save it in"
	end
	local file = `{dir}/{name}.json`
	local ok, err = greed.fs.write(file, greed.json.encode(describe(greed.tab.layout())) .. "\n")
	if not ok then
		return nil, err
	end
	return file, nil
end

--- The saved layouts' names: the project's, then yours, each once.
function M.names(): { string }
	local names, seen = {}, {}
	for _, dir in layout_dirs() do
		local entries: { greed.DirEntry } = greed.fs.list(dir, { hidden = true }) or {}
		for _, entry in entries do
			local name = string.match(entry.name, "^(.+)%.json$")
			if name and not entry.dir and not seen[name] then
				seen[name] = true
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	return names
end

local function load(name: string): (Saved?, string?)
	for _, dir in layout_dirs() do
		local text = greed.fs.read(`{dir}/{name}.json`)
		if text then
			local saved, err = greed.json.decode(text)
			if saved == nil then
				return nil, `layout {name} isn't JSON: {err}`
			end
			return saved, nil
		end
	end
	return nil, `there's no layout called {name}`
end

local function leaves(node: Saved, into: { Saved }): { Saved }
	if node.children then
		for _, child in node.children do
			leaves(child, into)
		end
	else
		table.insert(into, node)
	end
	return into
end

-- What a saved pane runs, for `terminal.open`: its command, or nil for the
-- shell.
local function command_of(leaf: Saved): { string }?
	return if type(leaf.terminal) == "table" then leaf.terminal else nil
end

-- Opens `leaf` in a new pane beside `base`, or with `here` in `base`
-- itself. Returns the pane it's in.
local function open_leaf(leaf: Saved, base: greed.View, here: boolean): greed.View
	if leaf.terminal ~= nil then
		local command = command_of(leaf)
		if here then
			base:focus()
			terminal.open(command)
			return base
		end
		terminal.open(command, { split = "right", from = base })
		return greed.view()
	end
	local buffer = if leaf.file
		then greed.load(core.project.resolve(leaf.file, core.project.root()))
		else greed.create_buffer("file", "")
	if here then
		base:show(buffer)
		return base
	end
	return base:split("right", buffer)
end

-- The saved tree with each pane's place taken by its view.
local function with_views(node: Saved, views: { greed.View }, next: { number }): any
	if node.children then
		local children = {}
		for _, child in node.children do
			table.insert(children, with_views(child, views, next))
		end
		return { split = node.split, sizes = node.sizes, children = children }
	end
	next[1] += 1
	return views[next[1]]
end

--- Opens layout `name` as a new tab, or with `here`, in the shown tab in
--- place of what it has.
function M.open(name: string, opts: { here: boolean? }?)
	local saved, err = load(name)
	if saved == nil then
		greed.echo(err)
		return
	end
	if opts and opts.here then
		local tab = greed.tab.current()
		for _, pane in tab.panes do
			if pane ~= tab.active then
				pane:close()
			end
		end
	else
		greed.tab.new()
	end
	-- It's arranged as saved, not by a layout manager.
	layouts.use("manual")
	local base = greed.tab.current().active
	local views = {}
	for i, leaf in leaves(saved, {}) do
		table.insert(views, open_leaf(leaf, base, i == 1))
	end
	if #views > 1 then
		local ok: boolean, problem: unknown =
			pcall(greed.tab.set_layout, with_views(saved, views, { 0 }))
		if not ok then
			greed.echo(`layout {name}: {problem}`)
			return
		end
	end
	views[1]:focus()
	terminal.settle(views[1])
	greed.echo(`opened layout {name}`)
end

return M
