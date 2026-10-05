-- Folding: `tab` (or `z a`) folds the block the cursor is in under its
-- first line, or unfolds it; `z C` only folds and `z o` only unfolds.
-- `shift-tab` folds or unfolds everything, and `z R` unfolds everything.
--
-- A block is what the language's "folds" query captures as `@fold` (read
-- from `queries/<language>/folds.scm`): the smallest one around the
-- cursor's line that spans more than one line. Without a query it's the
-- lines indented under the nearest line indented less. A plugin can fold a
-- language its own way with `providers`, as markdown does for sections,
-- code blocks and lists.

local greed = require("@greed")
local syntax = require("./syntax")

type Buffer = greed.Buffer

local M = {}

--- Finds the block to fold around 0-based `line`: its first and last line,
--- or nil when there's none.
export type Provider = (buffer: Buffer, line: number) -> (number?, number)

--- Providers by language, used instead of the query and indentation.
M.providers = {} :: { [string]: Provider }

-- The innermost `@fold` node around `line` spanning several lines.
local function from_query(buffer: Buffer, line: number, source: string): (number?, number)
	local first, last = nil, line
	local range: { from: number?, to: number? } =
		{ from = buffer:line_start(line), to = buffer:line_end(line) }
	for _, match in buffer:query(source, range) do
		local node = match.fold
		if node then
			local top = buffer:line_of(node.from)
			-- A node can end at the start of the line after it.
			local bottom = buffer:line_of(math.max(node.from, node.to - 1))
			local inner = first == nil or bottom - top < last - (first :: number)
			if top <= line and line <= bottom and bottom > top and inner then
				first, last = top, bottom
			end
		end
	end
	return first, last
end

-- How far `line` is indented, or nil for a blank line.
local function indent(buffer: Buffer, line: number): number?
	local text = buffer:slice(buffer:line_start(line), buffer:line_end(line))
	local spaces, rest = string.match(text, "^(%s*)()")
	return if (rest :: number) > #text then nil else #(spaces :: string)
end

-- The lines indented under the nearest line around `line` indented less:
-- `line` itself when the next line is indented more.
local function from_indent(buffer: Buffer, line: number): (number?, number)
	local count = buffer:line_count()
	local function next_indent(from: number): number?
		for i = from + 1, count - 1 do
			local found = indent(buffer, i)
			if found then
				return found
			end
		end
		return nil
	end
	local own = indent(buffer, line)
	local below = next_indent(line)
	local header: number? = nil
	if own and below and below > own then
		header = line
	else
		local depth = own or below or 0
		for i = line - 1, 0, -1 do
			local found = indent(buffer, i)
			if found and found < depth then
				header = i
				break
			end
		end
	end
	if header == nil then
		return nil, line
	end
	local base = indent(buffer, header) :: number
	local last = header
	for i = header + 1, count - 1 do
		local found = indent(buffer, i)
		if found and found <= base then
			break
		elseif found then
			last = i
		end
	end
	if last == header then
		return nil, line
	end
	return header, last
end

--- The first and last line of the block to fold around `line`, or nil.
function M.block(buffer: Buffer, line: number): (number?, number)
	local language = buffer:language()
	local provider = language and M.providers[language]
	if provider then
		return provider(buffer, line)
	end
	local source = syntax.query(buffer, "folds")
	if source then
		return from_query(buffer, line, source)
	end
	return from_indent(buffer, line)
end

-- Each fold is two marks in "folds" starting at its first line: the fold,
-- and the line count after that first line.

-- The folds over `line`, by where they start, innermost last.
local function folded(buffer: Buffer, line: number): { number }
	local starts = {}
	for _, mark in buffer:decorations("folds") do
		if mark.fold and buffer:line_of(mark.from) <= line and line <= buffer:line_of(mark.to) then
			table.insert(starts, mark.from)
		end
	end
	table.sort(starts)
	return starts
end

-- Takes away the folds starting at any of `starts`.
local function unfold(buffer: Buffer, starts: { number })
	local kept = {}
	for _, mark in buffer:decorations("folds") do
		if not table.find(starts, mark.from) then
			table.insert(kept, mark)
		end
	end
	buffer:decorate("folds", kept)
end

local function cursor_line(view: greed.View): number
	local selection = view:selection()
	return view:buffer():line_of(selection.ranges[selection.primary].head)
end

--- Folds lines `first` to `last` (0-based) under the first.
function M.fold(buffer: Buffer, first: number, last: number)
	local start = buffer:line_start(first)
	local marks = buffer:decorations("folds")
	table.insert(marks, { from = start, to = buffer:line_end(last), style = "fold", fold = true })
	table.insert(marks, {
		from = start,
		to = buffer:line_end(first),
		style = "comment",
		text = `⋯ {last - first} lines`,
		eol = true,
	})
	buffer:decorate("folds", marks)
end

local function go_to_line(view: greed.View, line: number)
	local start = view:buffer():line_start(line)
	view:set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
end

-- Folds the block around the cursor's line, saying so when there's none.
local function fold(view: greed.View)
	local buffer = view:buffer()
	local line = cursor_line(view)
	local first, last = M.block(buffer, line)
	if first == nil then
		greed.echo("nothing to fold here")
		return
	end
	M.fold(buffer, first, last)
	-- The cursor can't stay on a hidden line.
	if line ~= first then
		go_to_line(view, first)
	end
end

greed.command({
	name = "fold-toggle",
	doc = "Fold the block the cursor is in, or unfold it",
	run = function(ctx)
		local starts = folded(ctx.buffer, cursor_line(ctx.view))
		if #starts > 0 then
			unfold(ctx.buffer, { starts[#starts] })
		else
			fold(ctx.view)
		end
	end,
})

greed.command({
	name = "fold-close",
	doc = "Fold the block the cursor is in under its first line",
	run = function(ctx)
		if #folded(ctx.buffer, cursor_line(ctx.view)) == 0 then
			fold(ctx.view)
		end
	end,
})

greed.command({
	name = "fold-open",
	doc = "Unfold the folds the cursor is in",
	run = function(ctx)
		unfold(ctx.buffer, folded(ctx.buffer, cursor_line(ctx.view)))
	end,
})

greed.command({
	name = "fold-open-all",
	doc = "Unfold everything in the buffer",
	run = function(ctx)
		ctx.buffer:decorate("folds", {})
	end,
})

greed.command({
	name = "fold-close-all",
	doc = "Fold every outermost block in the buffer",
	run = function(ctx)
		local buffer = ctx.buffer
		buffer:decorate("folds", {})
		local line, cursor = 0, cursor_line(ctx.view)
		while line < buffer:line_count() do
			local first, last = M.block(buffer, line)
			if first == line then
				M.fold(buffer, line, last)
				if line < cursor and cursor <= last then
					go_to_line(ctx.view, line)
				end
				line = last
			end
			line += 1
		end
	end,
})

greed.command({
	name = "fold-toggle-all",
	doc = "Unfold everything when anything is folded, or else fold every outermost block",
	run = function(ctx)
		if #ctx.buffer:decorations("folds") > 0 then
			greed.run("fold-open-all")
		else
			greed.run("fold-close-all")
		end
	end,
})

greed.command({
	name = "fold-selection",
	doc = "Fold the selected lines under the first",
	run = function(ctx)
		local buffer, selection = ctx.buffer, ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		local first, last = buffer:line_of(from), buffer:line_of(math.max(from, to - 1))
		if last > first then
			M.fold(buffer, first, last)
			go_to_line(ctx.view, first)
		end
	end,
})

-- fold-next and fold-prev: to the first line of the next block below, or
-- the last line of the one above.
for _, back in { false, true } do
	greed.command({
		name = if back then "fold-prev" else "fold-next",
		doc = if back
			then "Go to the end of the block above the cursor"
			else "Go to the start of the block below the cursor",
		run = function(ctx)
			local buffer = ctx.buffer
			local line = cursor_line(ctx.view)
			local step, stop = if back then -1 else 1, if back then 0 else buffer:line_count() - 1
			for i = line + step, stop, step do
				local first, last = M.block(buffer, i)
				if first and (if back then last == i else first == i) then
					go_to_line(ctx.view, i)
					return
				end
			end
		end,
	})
end

M.keys = {
	["tab"] = "fold-toggle",
	["shift-tab"] = "fold-toggle-all",
	["z a"] = "fold-toggle",
	["z C"] = "fold-close",
	["z o"] = "fold-open",
	["z R"] = "fold-open-all",
} :: { [string]: string }

return M
