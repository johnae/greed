-- The undo tree, like Emacs's vundo: every state the text has been in, the
-- branches an undo followed by an edit left behind included. `space u t`
-- shows it; moving up and down takes the text to that state as you go,
-- enter keeps it, and esc goes back to where you were.
--
--   ○ 0  loaded
--   ○ 1  3m
--   │ ○ 2  2m        a branch left behind
--   ● 3  now         where the text is
--
-- The newest branch of each state carries on below it; older ones are
-- indented under it.

local greed = require("@greed")

type Open = {
	-- The view whose buffer's tree it shows, and the node it started at.
	view: greed.View,
	start: number,
	float: greed.View,
	-- The node on each line, top to bottom.
	lines: { number },
}

local open: Open? = nil

local function age(time: number?): string
	if time == nil then
		return "loaded"
	end
	local seconds = math.max(0, os.time() - time)
	if seconds < 10 then
		return "now"
	elseif seconds < 60 then
		return `{math.floor(seconds)}s`
	elseif seconds < 3600 then
		return `{seconds // 60}m`
	elseif seconds < 86400 then
		return `{seconds // 3600}h`
	end
	return `{seconds // 86400}d`
end

-- The tree's nodes in the order they're drawn, each with how far it's
-- indented: a node, then its older branches indented, then its newest
-- branch at its own indent.
local function layout(
	tree: { nodes: { greed.UndoNode }, current: number }
): { { id: number, indent: number } }
	local out = {}
	local stack = { { id = 0, indent = 0 } }
	while #stack > 0 do
		local item = table.remove(stack) :: { id: number, indent: number }
		table.insert(out, item)
		local children = tree.nodes[item.id + 1].children
		if #children > 0 then
			table.insert(stack, { id = children[#children], indent = item.indent })
			for i = #children - 1, 1, -1 do
				table.insert(stack, { id = children[i], indent = item.indent + 1 })
			end
		end
	end
	return out
end

-- Draws the tree into the float and puts its cursor on the current node.
local function render(o: Open)
	local tree = o.view:buffer():undo_tree()
	local lines, ids = {}, {}
	local at = 1
	for i, item in layout(tree) do
		local node = tree.nodes[item.id + 1]
		local marker = if item.id == tree.current then "●" else "○"
		table.insert(lines, `{string.rep("│ ", item.indent)}{marker} {item.id}  {age(node.time)}`)
		table.insert(ids, item.id)
		if item.id == tree.current then
			at = i
		end
	end
	o.lines = ids
	local buffer = o.float:buffer()
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:set_readonly(true)
	local pos = buffer:line_start(at - 1)
	o.float:set_cursor(pos)
end

local function close()
	local o = open
	if o then
		open = nil
		o.float:close()
		o.view:focus()
	end
end

greed.command({
	name = "undo-tree",
	doc = "Show every state the file has been in, branches included, and go to one",
	run = function(ctx)
		close()
		local tree = ctx.buffer:undo_tree()
		local buffer = greed.create_buffer("undo-tree", "", { readonly = true })
		buffer:set_line_numbers(false)
		local float = greed.float(buffer, { title = "Undo tree", width = 40, height = "70%" })
		local o: Open = { view = ctx.view, start = tree.current, float = float, lines = {} }
		open = o
		render(o)
	end,
})

-- Moves `delta` lines in the tree and takes the text to that node.
local function move(delta: number)
	local o = open
	if o == nil then
		return
	end
	local line = o.float:buffer():line_of(o.float:cursor()) + 1
	local target = math.clamp(line + delta, 1, #o.lines)
	o.view:undo_to(o.lines[target])
	render(o)
end

greed.command({
	name = "undo-tree-down",
	doc = "Go to the next state down the undo tree",
	run = function()
		move(1)
	end,
})

greed.command({
	name = "undo-tree-up",
	doc = "Go to the next state up the undo tree",
	run = function()
		move(-1)
	end,
})

greed.command({
	name = "undo-tree-keep",
	doc = "Close the undo tree, keeping the text as it is",
	run = close,
})

greed.command({
	name = "undo-tree-cancel",
	doc = "Close the undo tree and put the text back as it was",
	run = function()
		local o = open
		if o then
			o.view:undo_to(o.start)
			close()
		end
	end,
})

greed.on("view.closed", function(event: greed.ViewClosed)
	if open and open.float:id() == event.view then
		open = nil
	end
end)

greed.keymap.bind({ kind = "undo-tree" }, {
	j = "undo-tree-down",
	k = "undo-tree-up",
	down = "undo-tree-down",
	up = "undo-tree-up",
	enter = "undo-tree-keep",
	q = "undo-tree-keep",
	esc = "undo-tree-cancel",
})

greed.keymap.bind({ layer = "leader" }, { ["u t"] = "undo-tree" })

return {}
