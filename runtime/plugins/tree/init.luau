-- A file tree in a side panel. `space e` opens it (or moves to it, or closes
-- it if you're in it). In the tree: enter or l opens a file or folds a
-- folder, h folds the folder you're in, r reads the disk again, q closes;
-- a makes a file (or a folder, ending in /), R renames, d deletes.
-- Hidden and ignored files are left out, like in the file picker.
--
-- It's only a plugin: to turn it off, `greed.plugin.unload("tree")` from your
-- config.

local greed = require("@greed")
local core = require("@core")

type Node = {
	path: string,
	name: string,
	dir: boolean,
	depth: number,
}

local ui = core.ui

type Tree = {
	view: greed.View,
	buffer: greed.Buffer,
	root: string,
	-- Folders shown open.
	expanded: { [string]: boolean },
	-- One node per line, as read from the disk last, and what draws them,
	-- each line's value its node.
	nodes: { Node },
	drawn: core.UiView,
	-- The file shown when the tree was last outside focus, as an absolute path.
	open: string?,
}

-- Each project has its own tree, in its own panel.
local trees: { [number]: Tree } = {}

local function join(dir: string, name: string): string
	return if dir == "/" then "/" .. name else dir .. "/" .. name
end

local function collect(t: Tree, dir: string, depth: number)
	local entries: { greed.DirEntry } = greed.fs.list(dir) or {}
	for _, entry in entries do
		local path = join(dir, entry.name)
		table.insert(t.nodes, { path = path, name = entry.name, dir = entry.dir, depth = depth })
		if entry.dir and t.expanded[path] then
			collect(t, path, depth + 1)
		end
	end
end

-- The node on the cursor's line.
local function current(t: Tree): Node?
	return t.drawn:value_at(t.view:cursor())
end

local M = {}

--- Nerd Font icons, shown with the `tree-icons` option set to "nerd": for
--- folders, open folders, files, and files by extension. Add your own:
--- `require("@tree").icons.extensions.zig = "\u{e6a9}"`.
M.icons = {
	folder = "\u{f07b}",
	open = "\u{f07c}",
	file = "\u{f15b}",
	extensions = {
		json = "\u{e60b}",
		lua = "\u{e620}",
		luau = "\u{e620}",
		md = "\u{e609}",
		nix = "\u{f313}",
		rs = "\u{e7a8}",
	} :: { [string]: string },
}

local function icon_of(node: Node, expanded: boolean): string
	if node.dir then
		return if expanded then M.icons.open else M.icons.folder
	end
	local extension = string.match(node.name, "%.([^.]+)$")
	return extension and M.icons.extensions[extension] or M.icons.file
end

-- The tree's nodes, a line each: a guide down the side for each folder a
-- node is in, its icon, its name, the file shown outside it marked.
local function draw(t: Tree): core.UiNode
	local nerd = greed.option.get("tree-icons") == "nerd"
	return ui.list(t.nodes, function(node: Node): { core.UiSpan }
		local expanded = t.expanded[node.path] == true
		local icon = if nerd
			then icon_of(node, expanded) .. " "
			elseif not node.dir then "  "
			elseif expanded then "▾ "
			else "▸ "
		local name = node.name .. (if node.dir then "/" else "")
		local guides: core.UiSpan = {
			text = string.rep("│ ", node.depth),
			style = if node.depth > 0 then "ui.tree.guide" else nil,
			line = if node.path == t.open then "ui.tree.open" else nil,
		}
		return {
			guides,
			ui.span(icon),
			ui.span(name, if node.dir then "ui.tree.directory" else nil),
		}
	end)
end

-- Reads the tree from the disk again and draws it, keeping the cursor on
-- `keep` (a path) or on the node it was on.
local function render(t: Tree, keep: string?)
	t.nodes = {}
	collect(t, t.root, 0)
	-- Outside the tree, the file shown is the one to mark.
	if greed.view() ~= t.view then
		t.open = greed.view():buffer():path()
	end
	t.drawn:redraw()
	local line = keep
		and t.drawn:line_of(function(node: Node): boolean
			return node.path == keep
		end)
	if line then
		t.view:set_cursor(t.buffer:line_start(line))
	end
	t.buffer:decorate("tree-hover", {})
end

-- The tree shown in the current project, if it has one.
local function shown(): Tree?
	return trees[greed.project.current().id]
end

greed.on("view.closed", function(event)
	for project, t in trees do
		if t.view:id() == event.view then
			trees[project] = nil
		end
	end
end)

function M.close()
	local project = greed.project.current().id
	local t = trees[project]
	if t then
		t.view:close()
		trees[project] = nil
	end
end

--- Opens the tree on `root` (default: the project's root) and focuses it.
function M.open(root: string?)
	M.close()
	local dir = if root then core.project.resolve(root) else core.project.root()
	local open = greed.view():buffer():path()
	local buffer = greed.create_buffer("tree", "", { readonly = true })
	local title = if root then core.project.tilde(dir) else "Files"
	local view = greed.panel(buffer, { title = title, width = 32 })
	local t: Tree
	t = {
		view = view,
		buffer = buffer,
		root = dir,
		expanded = {},
		nodes = {},
		open = open,
		drawn = ui.mount(
			buffer,
			function()
				return draw(t)
			end,
			nil,
			{
				ns = "tree",
				keys = false,
				draw = false,
				key = function(node: Node): string
					return node.path
				end,
			}
		),
	}
	trees[greed.project.current().id] = t
	render(t)
end

--- Opens the tree on the project, if it isn't open, with the folders
--- `path` is in unfolded and the cursor on it.
function M.reveal(path: string)
	local t = shown()
	if t == nil or not core.project.inside(path, t.root) then
		M.open()
		t = shown()
	end
	if t == nil or not core.project.inside(path, t.root) then
		greed.echo(`{core.project.short(path)} isn't in the project`)
		return
	end
	local folder = string.match(path, "^(.*)/[^/]*$")
	while folder and #folder > #t.root do
		t.expanded[folder] = true
		folder = string.match(folder, "^(.*)/[^/]*$")
	end
	render(t, path)
	t.view:focus()
end

for _, kind in { "file", "folder" } do
	core.actions.action({
		kind = kind,
		name = "reveal in tree",
		doc = "Show it in the file tree",
		run = function(target)
			M.reveal(target.value)
		end,
	})
end

greed.command({
	name = "tree",
	doc = "Open the file tree, move to it, or close it if you're in it",
	run = function()
		local t = shown()
		if t == nil then
			M.open()
		elseif greed.view() == t.view then
			M.close()
		else
			render(t)
			t.view:focus()
		end
	end,
})

greed.command({
	name = "tree-open",
	doc = "Open the file on the cursor, or fold or unfold the folder",
	run = function()
		local t = shown()
		local node = t and current(t)
		if t == nil or node == nil then
			return
		end
		if node.dir then
			if t.expanded[node.path] then
				t.expanded[node.path] = nil
			else
				t.expanded[node.path] = true
			end
		else
			core.file.open(node.path)
		end
		render(t, node.path)
	end,
})

greed.command({
	name = "tree-fold",
	doc = "Fold the folder on the cursor, or the one it's in",
	run = function()
		local t = shown()
		local node = t and current(t)
		if t == nil or node == nil then
			return
		end
		if node.dir and t.expanded[node.path] then
			t.expanded[node.path] = nil
			render(t, node.path)
			return
		end
		local parent = string.match(node.path, "^(.*)/[^/]*$")
		if parent then
			t.expanded[parent] = nil
			render(t, parent)
		end
	end,
})

greed.command({
	name = "tree-refresh",
	doc = "Read the tree from the disk again",
	run = function()
		local t = shown()
		if t then
			render(t)
		end
	end,
})

greed.command({
	name = "tree-close",
	doc = "Close the file tree",
	run = M.close,
})

-- The folder new files go in from `node`: itself, or the one it's in.
local function folder_of(t: Tree, node: Node?): string
	if node == nil then
		return t.root
	end
	return if node.dir then node.path else string.match(node.path, "^(.*)/[^/]*$") or t.root
end

greed.command({
	name = "tree-add",
	doc = "Make a file in the folder on the cursor, or a folder with a / at the end",
	run = function()
		local t = shown()
		if t == nil then
			return
		end
		local dir = folder_of(t, current(t))
		local name =
			core.prompt.ask(`new in {core.project.short(dir, t.root)}/ (end with / for a folder)`)
		if name == nil or string.match(name, "^%s*$") then
			return
		end
		local path = `{dir}/{name}`
		if greed.fs.stat(path) then
			error(`{name} is there already`, 0)
		end
		t.expanded[dir] = true
		if string.sub(name, -1) == "/" then
			path = string.sub(path, 1, -2)
			greed.fs.mkdir(path)
		else
			local parent = string.match(path, "^(.*)/[^/]+$")
			if parent then
				greed.fs.mkdir(parent)
			end
			greed.fs.write(path, "")
		end
		render(t, path)
	end,
})

greed.command({
	name = "tree-rename",
	doc = "Rename or move the file or folder on the cursor; open files go along",
	run = function()
		local t = shown()
		local node = t and current(t)
		if t == nil or node == nil then
			return
		end
		local parent = string.match(node.path, "^(.*)/[^/]*$") or t.root
		local view = core.prompt.open({
			title = "rename to",
			text = node.name,
			selected = true,
			on_submit = function(name)
				if name == "" or name == node.name then
					return
				end
				local to = if string.find(name, "/", 1, true)
					then core.project.resolve(name, t.root)
					else `{parent}/{name}`
				core.file.rename(node.path, to)
				render(t, to)
			end,
		})
		view:focus()
	end,
})

greed.command({
	name = "tree-delete",
	doc = "Delete the file or folder on the cursor, after you press y",
	run = function()
		local t = shown()
		local node = t and current(t)
		if t == nil or node == nil then
			return
		end
		if core.file.confirm_remove(node.path) then
			render(t)
		end
	end,
})

greed.option.define({
	name = "tree-icons",
	doc = 'Icons by the names in the file tree: "none", or "nerd" for a Nerd Font\'s',
	default = "none",
	choices = { "none", "nerd" },
})

greed.on("option.changed", function(event)
	if event.name == "tree-icons" then
		for _, t in trees do
			render(t)
		end
	end
end)

-- Lights up the row under the mouse in `t`, or none.
local function hover(t: Tree, pos: number?)
	if pos == nil then
		t.buffer:decorate("tree-hover", {})
		return
	end
	local line = t.buffer:line_of(pos)
	local from, to = t.buffer:line_start(line), t.buffer:line_end(line)
	t.buffer:decorate(
		"tree-hover",
		{ { from = from, to = to, style = "ui.tree.hover", line = true } }
	)
end

-- In the tree, a click opens a file or folds a folder, and the row under
-- the mouse lights up.
core.mouse.claim("tree", function(event)
	local t = shown()
	if t == nil or event.view ~= t.view then
		return false
	end
	if event.kind == "move" then
		hover(t, event.pos)
	elseif event.kind == "press" and event.button == "left" and event.pos then
		t.view:set_cursor(event.pos)
		greed.run("tree-open")
		return true
	end
	return false
end)

-- Once the mouse is off the tree, nothing in it is lit up.
greed.on("mouse", function(event: greed.MouseEvent)
	if event.kind == "move" and (event.view == nil or event.view:buffer():kind() ~= "tree") then
		for _, t in trees do
			hover(t, nil)
		end
	end
end)

greed.keymap.bind({ layer = "leader" }, { e = "tree" })
greed.keymap.bind({ kind = "tree" }, {
	enter = "tree-open",
	l = "tree-open",
	h = "tree-fold",
	r = "tree-refresh",
	a = "tree-add",
	R = "tree-rename",
	d = "tree-delete",
	q = "tree-close",
})

return M
