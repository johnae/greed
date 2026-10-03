-- Editing by syntax, for languages with a tree-sitter grammar:
--
--   m i f / m a f   inside or around the function; t for a type (struct,
--                   class, impl), a for an argument or parameter, c for a
--                   comment
--   ] f / [ f       the next or previous function (and t, a, c)
--   alt-o / alt-i   grow the selection to the enclosing syntax node, or
--                   shrink it back
--
-- What counts as a function or a type comes from each language's
-- "textobjects" query (`kern.syntax.query`), which the languages plugin
-- reads from `queries/<language>/textobjects.scm` files. A query captures
-- nodes as `@function.around` and `@function.inside` (and type,
-- parameter, comment); a match without an inside capture uses what's
-- between the around node's brackets.

local kern = require("@kern")
local motions = require("./motions")

type Buffer = kern.Buffer
type Node = kern.Node
type Range = kern.Range

local M = {}

--- The query of `kind` for the buffer's language, if there is one.
function M.query(buffer: Buffer, kind: string): string?
	local language = buffer:language()
	return if language then kern.syntax.query(language, kind) else nil
end

--- The syntax objects Kern knows, with the key that stands for each.
M.OBJECTS = {
	f = "function",
	t = "type",
	a = "parameter",
	c = "comment",
	T = "test",
	e = "entry",
} :: { [string]: string }

export type Object = { around: Node, inside: Node? }

--- Every `object` ("function", "type", ...) in the buffer, or those
--- overlapping `from`..`to`, in order.
function M.objects(buffer: Buffer, object: string, from: number?, to: number?): { Object }
	local source = M.query(buffer, "textobjects")
	if source == nil then
		return {}
	end
	local range: { from: number?, to: number? }? = if from then { from = from, to = to } else nil
	local found = {}
	for _, captures in buffer:query(source, range) do
		local around = captures[`{object}.around`]
		if around then
			table.insert(found, { around = around, inside = captures[`{object}.inside`] })
		end
	end
	return found
end

-- What's inside `node`: between its first and last children when those are
-- brackets or keywords, like a block's braces or `do ... end`.
local function within(node: Node): (number, number)
	local children = node:children()
	local first, last = children[1], children[#children]
	if #children >= 2 and not first.named and not last.named then
		return first.to, last.from
	end
	return node.from, node.to
end

-- A parameter with the comma and space after it, or before it when it's the
-- last one.
local function with_separator(node: Node): (number, number)
	local after = node:next()
	if after then
		return node.from, after.from
	end
	local before = node:prev()
	if before then
		return before.to, node.to
	end
	return node.from, node.to
end

--- The range `object` would select: around the node, or inside it.
function M.range_of(object: string, found: Object, outer: boolean): (number, number)
	if outer then
		if object == "parameter" then
			return with_separator(found.around)
		end
		return found.around.from, found.around.to
	end
	local inside = found.inside
	if inside then
		if inside.from == found.around.from and inside.to == found.around.to then
			return inside.from, inside.to
		end
		return within(inside)
	end
	return within(found.around)
end

local function bounds(range: Range): (number, number)
	return math.min(range.anchor, range.head), math.max(range.anchor, range.head)
end

-- The smallest named node covering `lo`..`hi`, or the one under a cursor.
local function node_in(buffer: Buffer, lo: number, hi: number): Node?
	return buffer:node_at(lo, math.max(lo, hi - 1))
end

--- The innermost `object` holding `range`, as the range to select, or nil.
function M.select(buffer: Buffer, range: Range, object: string, outer: boolean): Range?
	local lo, hi = bounds(range)
	local best: Object? = nil
	for _, found in M.objects(buffer, object, lo, hi) do
		local around = found.around
		if around.from <= lo and hi <= around.to then
			if best == nil or around.to - around.from < best.around.to - best.around.from then
				best = found
			end
		end
	end
	if best == nil then
		return nil
	end
	local from, to = M.range_of(object, best, outer)
	-- Selecting the same again (inside an empty body, say) grows to around.
	if not outer and from == lo and to == hi then
		from, to = M.range_of(object, best, true)
	end
	return { anchor = from, head = to }
end

--- The next (or with `backward` the previous) `object` starting after (or
--- ending before) `range`, as the range around it, or nil.
function M.next(buffer: Buffer, range: Range, object: string, backward: boolean): Range?
	local lo, hi = bounds(range)
	local pick: Object? = nil
	for _, found in M.objects(buffer, object) do
		local around = found.around
		if backward then
			if around.from < lo then
				pick = found
			end
		elseif around.from > lo or (around.from == lo and around.to > hi) then
			pick = found
			break
		end
	end
	if pick == nil then
		return nil
	end
	local from, to = M.range_of(object, pick, true)
	return { anchor = from, head = to }
end

--- The smallest named node strictly larger than `range` (or, for a cursor,
--- the one under it), or nil at the root.
function M.enclosing(buffer: Buffer, range: Range): Node?
	local lo, hi = bounds(range)
	local node = node_in(buffer, lo, hi)
	while node and node.from >= lo and node.to <= hi and hi > lo do
		node = node:parent()
	end
	return node
end

-- Each growth a view went through, newest last, so shrinking goes back the
-- way it came: what the selection was, and what it grew to.
type Growth = { buffer: number, from: number, to: number, grown_from: number, grown_to: number }
local grown: { [number]: { Growth } } = {}

local function select_node(ctx: kern.Context, step: (Buffer, Range, number) -> Range?)
	local view = ctx.view:id()
	motions.each_range(ctx, function(buffer, range)
		return step(buffer, range, view) or range
	end)
end

kern.command({
	name = "expand-selection",
	doc = "Grow each selection to the syntax node around it",
	run = function(ctx)
		select_node(ctx, function(buffer, range, view)
			local node = M.enclosing(buffer, range)
			if node == nil then
				return nil
			end
			local lo, hi = bounds(range)
			grown[view] = grown[view] or {}
			table.insert(grown[view], {
				buffer = buffer:id(),
				from = lo,
				to = hi,
				grown_from = node.from,
				grown_to = node.to,
			})
			return { anchor = node.from, head = node.to }
		end)
	end,
})

kern.command({
	name = "shrink-selection",
	doc = "Shrink each selection back, or to the first syntax node inside it",
	run = function(ctx)
		select_node(ctx, function(buffer, range, view)
			local lo, hi = bounds(range)
			local stack = grown[view] or {}
			local last = stack[#stack]
			if
				last
				and last.buffer == buffer:id()
				and last.grown_from == lo
				and last.grown_to == hi
			then
				table.remove(stack)
				return { anchor = last.from, head = last.to }
			end
			-- The selection moved on since; that history no longer applies.
			grown[view] = nil
			local node = node_in(buffer, lo, hi)
			while node and not (node.from == lo and node.to == hi) do
				node = node:parent()
			end
			local child = node and node:named_children()[1]
			return if child then { anchor = child.from, head = child.to } else nil
		end)
	end,
})

for _, backward in { false, true } do
	kern.command({
		name = `select-{if backward then "prev" else "next"}-sibling`,
		doc = `Select the {if backward then "previous" else "next"} syntax node beside each selection`,
		run = function(ctx)
			motions.each_range(ctx, function(buffer, range)
				local lo, hi = bounds(range)
				local node = node_in(buffer, lo, hi)
				local sibling = node and (if backward then node:prev() else node:next())
				return if sibling then { anchor = sibling.from, head = sibling.to } else range
			end)
		end,
	})
end

-- Replaces each selection with `pick(node)`'s nodes, for the node the
-- selection covers; a selection with nothing to pick stays.
local function select_nodes(ctx: kern.Context, pick: (kern.Node) -> { kern.Node })
	local buffer = ctx.buffer
	local ranges: { kern.Range } = {}
	for _, range in ctx.view:selection().ranges do
		local lo, hi = bounds(range)
		local node = node_in(buffer, lo, hi)
		local picked = if node then pick(node) else {}
		if #picked == 0 then
			table.insert(ranges, range)
		end
		for _, found in picked do
			table.insert(ranges, { anchor = found.from, head = found.to })
		end
	end
	ctx.view:set_selection({ ranges = ranges, primary = 1 })
end

kern.command({
	name = "select-all-siblings",
	doc = "Select every syntax node beside each selection's, its own included",
	run = function(ctx)
		select_nodes(ctx, function(node)
			local parent = node:parent()
			return if parent then parent:named_children() else {}
		end)
	end,
})

kern.command({
	name = "select-all-children",
	doc = "Select every syntax node inside each selection's",
	run = function(ctx)
		select_nodes(ctx, function(node)
			return node:named_children()
		end)
	end,
})

for _, at_end in { false, true } do
	kern.command({
		name = if at_end then "goto-parent-end" else "goto-parent-start",
		doc = if at_end
			then "Move to the end of the syntax node around each selection's"
			else "Move to the start of the syntax node around each selection's",
		run = function(ctx)
			motions.each_range(ctx, function(buffer, range)
				local lo, hi = bounds(range)
				local node = node_in(buffer, lo, hi)
				local parent = node and node:parent()
				if parent == nil then
					return range
				end
				return motions.point(if at_end then buffer:prev_char(parent.to) else parent.from)
			end)
		end,
	})
end

-- Bindings for every syntax object, filled in below. Helix has the sibling
-- moves on alt-n and alt-p, which are the pane keys here.
M.keys = {
	["alt-o"] = "expand-selection",
	["alt-i"] = "shrink-selection",
	["] n"] = "select-next-sibling",
	["[ n"] = "select-prev-sibling",
	["alt-a"] = "select-all-siblings",
	["alt-I"] = "select-all-children",
	["alt-e"] = "goto-parent-end",
	["alt-b"] = "goto-parent-start",
} :: { [string]: string }

for key, object in M.OBJECTS do
	for _, outer in { false, true } do
		local side = if outer then "around" else "inside"
		local name = `select-{side}-{object}`
		kern.command({
			name = name,
			doc = `Select {side} the {object} at each selection`,
			run = function(ctx)
				motions.each_range(ctx, function(buffer, range)
					return M.select(buffer, range, object, outer) or range
				end)
			end,
		})
		M.keys[`m {if outer then "a" else "i"} {key}`] = name
	end
	for _, backward in { false, true } do
		local direction = if backward then "prev" else "next"
		local name = `{direction}-{object}`
		kern.command({
			name = name,
			doc = `Select the {if backward then "previous" else "next"} {object}`,
			run = function(ctx)
				motions.each_range(ctx, function(buffer, range)
					return M.next(buffer, range, object, backward) or range
				end)
			end,
		})
		M.keys[`{if backward then "[" else "]"} {key}`] = name
	end
end

return M
