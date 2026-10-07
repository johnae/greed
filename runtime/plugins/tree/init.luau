-- A file tree in a side panel. `space e` opens it (or moves to it, or closes
-- it if you're in it). In the tree: enter or l opens a file or folds a
-- folder, h folds the folder you're in, r reads the disk again, q closes.
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

type Tree = {
	view: greed.View,
	buffer: greed.Buffer,
	root: string,
	-- Folders shown open.
	expanded: { [string]: boolean },
	-- One node per line.
	nodes: { Node },
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
	local selection = t.view:selection()
	return t.nodes[t.buffer:line_of(selection.ranges[selection.primary].head) + 1]
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

-- Rewrites the tree from the disk, keeping the cursor on `keep` (a path) or
-- on the node it was on.
local function render(t: Tree, keep: string?)
	local on = current(t)
	local at = keep or (on and on.path)
	t.nodes = {}
	collect(t, t.root, 0)

	local lines, marks = {}, {}
	local pos, cursor = 0, 0
	-- Outside the tree, the file shown is the one to mark.
	if greed.view() ~= t.view then
		t.open = greed.view():buffer():path()
	end
	local nerd = greed.option.get("tree-icons") == "nerd"
	for _, node in t.nodes do
		-- A guide down the side of each folder a node is in.
		local guides = string.rep("│ ", node.depth)
		local expanded = t.expanded[node.path] == true
		local icon = if nerd
			then icon_of(node, expanded) .. " "
			elseif not node.dir then "  "
			elseif expanded then "▾ "
			else "▸ "
		local prefix = guides .. icon
		local line = prefix .. node.name .. (if node.dir then "/" else "")
		if node.depth > 0 then
			table.insert(marks, { from = pos, to = pos + #guides, style = "ui.tree.guide" })
		end
		if node.dir then
			table.insert(
				marks,
				{ from = pos + #prefix, to = pos + #line, style = "ui.tree.directory" }
			)
		end
		if node.path == t.open then
			table.insert(
				marks,
				{ from = pos, to = pos + #line, style = "ui.tree.open", line = true }
			)
		end
		if node.path == at then
			cursor = pos
		end
		table.insert(lines, line)
		pos += #line + 1
	end
	t.buffer:edit(function(e)
		e:replace(0, t.buffer:len(), table.concat(lines, "\n"))
		e:select({ ranges = { { anchor = cursor, head = cursor } }, primary = 1 })
	end)
	t.buffer:decorate("tree", marks)
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
	local t: Tree =
		{ view = view, buffer = buffer, root = dir, expanded = {}, nodes = {}, open = open }
	trees[greed.project.current().id] = t
	render(t)
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
			greed.open(node.path)
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

greed.option.define({
	name = "tree-icons",
	doc = 'Icons by the names in the file tree: "none", or "nerd" for a Nerd Font\'s',
	default = "none",
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
		t.view:set_selection({ ranges = { { anchor = event.pos, head = event.pos } }, primary = 1 })
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

greed.keymap.bind("normal", { ["space e"] = "tree" })
greed.keymap.bind({ mode = "normal", kind = "tree" }, {
	enter = "tree-open",
	l = "tree-open",
	h = "tree-fold",
	r = "tree-refresh",
	q = "tree-close",
})

return M
