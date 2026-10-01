-- A file tree in a side panel. `space e` opens it (or moves to it, or closes
-- it if you're in it). In the tree: enter or l opens a file or folds a
-- folder, h folds the folder you're in, r reads the disk again, q closes.
-- Hidden and ignored files are left out, like in the file picker.
--
-- It's only a plugin: to turn it off, `kern.plugin.unload("tree")` from your
-- config.

local kern = require("@kern")

type Node = {
	path: string,
	name: string,
	dir: boolean,
	depth: number,
}

type Tree = {
	view: kern.View,
	buffer: kern.Buffer,
	root: string,
	-- Folders shown open.
	expanded: { [string]: boolean },
	-- One node per line.
	nodes: { Node },
}

local tree: Tree? = nil

local function join(dir: string, name: string): string
	return if dir == "." then name else dir .. "/" .. name
end

local function collect(t: Tree, dir: string, depth: number)
	for _, entry in kern.fs.list(dir) or {} do
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

-- Rewrites the tree from the disk, keeping the cursor on `keep` (a path) or
-- on the node it was on.
local function render(t: Tree, keep: string?)
	local on = current(t)
	local at = keep or (on and on.path)
	t.nodes = {}
	collect(t, t.root, 0)

	local lines, marks = {}, {}
	local pos, cursor = 0, 0
	local open = kern.view() ~= t.view and kern.view():buffer():path() or nil
	for _, node in t.nodes do
		local icon = if not node.dir then "  " elseif t.expanded[node.path] then "▾ " else "▸ "
		local prefix = string.rep("  ", node.depth) .. icon
		local line = prefix .. node.name .. (if node.dir then "/" else "")
		if node.dir then
			table.insert(
				marks,
				{ from = pos + #prefix, to = pos + #line, style = "ui.tree.directory" }
			)
		end
		if node.path == open then
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
end

local M = {}

function M.close()
	if tree then
		tree.view:close()
		tree = nil
	end
end

--- Opens the tree on `root` (default: the current directory) and focuses it.
function M.open(root: string?)
	M.close()
	local dir = root or "."
	local buffer = kern.create_buffer("tree", "", { readonly = true })
	local view = kern.panel(buffer, { title = if dir == "." then "Files" else dir, width = 32 })
	local t: Tree = { view = view, buffer = buffer, root = dir, expanded = {}, nodes = {} }
	tree = t
	render(t)
end

kern.command({
	name = "tree",
	doc = "Open the file tree, move to it, or close it if you're in it",
	run = function()
		if tree == nil then
			M.open()
		elseif kern.view():id() == tree.view:id() then
			M.close()
		else
			tree.view:focus()
			render(tree)
		end
	end,
})

kern.command({
	name = "tree-open",
	doc = "Open the file on the cursor, or fold or unfold the folder",
	run = function()
		local t = tree
		local node = t and current(t)
		if t == nil or node == nil then
			return
		end
		if node.dir then
			t.expanded[node.path] = not t.expanded[node.path] or nil
		else
			kern.open(node.path)
		end
		render(t, node.path)
	end,
})

kern.command({
	name = "tree-fold",
	doc = "Fold the folder on the cursor, or the one it's in",
	run = function()
		local t = tree
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

kern.command({
	name = "tree-refresh",
	doc = "Read the tree from the disk again",
	run = function()
		if tree then
			render(tree)
		end
	end,
})

kern.command({
	name = "tree-close",
	doc = "Close the file tree",
	run = M.close,
})

kern.keymap.bind("normal", { ["space e"] = "tree" })
kern.keymap.bind({ mode = "normal", kind = "tree" }, {
	enter = "tree-open",
	l = "tree-open",
	h = "tree-fold",
	r = "tree-refresh",
	q = "tree-close",
})

return M
