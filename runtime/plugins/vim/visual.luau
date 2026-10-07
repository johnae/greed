-- The visual modes: by character, by line, and by block, which keeps a
-- selection per line. Motions and operators act on the selection there,
-- so their commands are here too.

local greed = require("@greed")
local core = require("@core")
local common = require("./common")
local motions_module = require("./motions")
local objects = require("./objects")
local operators = require("./operators")

type Buffer = greed.Buffer

local command, cursor, on_char, point = common.command, common.cursor, common.on_char, common.point
local visual, visual_start = common.visual, common.visual_start
local motions, COUNTLESS = motions_module.motions, motions_module.COUNTLESS
local motion_range, text_object = objects.motion_range, objects.text_object
local apply, operate, store, on_lines =
	operators.apply, operators.operate, operators.store, operators.on_lines
local LINE_OPERATORS, CASE_OPERATORS = operators.LINE_OPERATORS, operators.CASE_OPERATORS
local surround, search_match, to_paste =
	operators.surround, operators.search_match, operators.to_paste

-- The line V started on, which stays selected as other lines are added.
local visual_line = 0

-- Every line from `from` to `to`, whichever way round, as a selection.
local function lines_selection(buffer: Buffer, from: number, to: number): greed.Selection
	local range = if to >= from
		then { anchor = buffer:line_start(from), head = buffer:line_end(to) }
		else { anchor = buffer:line_end(from), head = buffer:line_start(to) }
	return { ranges = { range }, primary = 1 }
end

-- Visual block mode: a rectangle of columns across lines, kept as one
-- selection per line, so what's typed after I, A or c goes on every line.
-- The corner it started from, where the cursor is, and whether $ took it
-- to the end of every line.
local block = { line = 0, column = 0, cursor = 0, to_end = false }

-- The selection for the block from its corner to `block.cursor`, both
-- columns included.
local function block_selection(buffer: Buffer): greed.Selection
	local line, column = buffer:line_of(block.cursor), core.text.column(buffer, block.cursor)
	local top, bottom = math.min(block.line, line), math.max(block.line, line)
	local left, right = math.min(block.column, column), math.max(block.column, column)
	local ranges: { greed.Range } = {}
	local primary = 1
	for row = top, bottom do
		local finish = buffer:line_end(row)
		-- Up to the end of the character on the right column, however wide.
		local head = core.text.at_column(buffer, row, right)
		if block.to_end or head >= finish then
			head = finish
		else
			head = buffer:next_char(head)
		end
		table.insert(ranges, { anchor = core.text.at_column(buffer, row, left), head = head })
		if row == line then
			primary = #ranges
		end
	end
	return { ranges = ranges, primary = primary }
end

-- The motions the `motion-hints` option numbers the next places of.
local HINTED: { [string]: boolean } =
	{ w = true, b = true, e = true, W = true, B = true, E = true, ["g e"] = true, ["g E"] = true }

-- Motions move the cursor, or extend the selection in visual mode.
for key, motion in motions do
	local name = "motion-" .. string.gsub(key, " ", "")
	command(name, "Vim motion " .. key, function(ctx)
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local mode = greed.mode.get()
		local from = if mode == "vim-visual-block" then block.cursor else cursor(ctx)
		local target = motion(ctx.buffer, from, ctx.count or (if COUNTLESS[key] then 0 else 1))
		if target == nil then
			return
		end
		if mode == "vim-visual-block" then
			block.cursor, block.to_end = target, key == "$"
			ctx.view:set_selection(block_selection(ctx.buffer))
		elseif mode == "vim-visual-line" then
			ctx.view:set_selection(
				lines_selection(ctx.buffer, visual_line, ctx.buffer:line_of(target))
			)
		elseif mode == "vim-visual" then
			ctx.view:set_selection(visual(ctx.buffer, visual_start(ctx.buffer, range), target))
		else
			ctx.view:set_cursor(on_char(ctx.buffer, target))
		end
		if HINTED[key] and (mode == "vim" or mode == "vim-visual") then
			core.hints.after(ctx, "vim-" .. name, function(buffer, at)
				local next = motion(buffer, core.motions.cursor(buffer, at), 1)
				if next == nil then
					return nil, nil
				end
				next = on_char(buffer, next)
				local moved = if mode == "vim-visual"
					then visual(buffer, visual_start(buffer, at), next)
					else point(next)
				return moved.ranges[1], next
			end)
		end
	end)
end

-- Operator `op` on the visual block, each line's piece on its own. What c
-- types goes on every line.
local function block_operate(ctx: greed.Context, op: string)
	local buffer = ctx.buffer
	local ranges = ctx.view:selection().ranges
	local top = ranges[1].anchor
	greed.mode.set("vim")
	local line_command = LINE_OPERATORS[op]
	if line_command then
		on_lines(ctx, line_command, top, ranges[#ranges].head, op)
		return
	end
	local case = CASE_OPERATORS[op]
	if case == nil then
		local pieces = {}
		for _, range in ranges do
			table.insert(pieces, buffer:slice(range.anchor, range.head))
		end
		store(op, table.concat(pieces, "\n"), false)
		if op == "y" then
			ctx.view:set_cursor(on_char(buffer, top))
			return
		end
	end
	if op == "c" then
		greed.history.start_group()
	end
	buffer:edit(function(e)
		for _, range in ranges do
			if case then
				e:replace(range.anchor, range.head, case(buffer:slice(range.anchor, range.head)))
			else
				e:delete(range.anchor, range.head)
			end
		end
	end)
	if op ~= "c" then
		ctx.view:set_cursor(on_char(buffer, top))
		return
	end
	local points, removed = {}, 0
	for _, range in ranges do
		local pos = range.anchor - removed
		table.insert(points, { anchor = pos, head = pos })
		removed += range.head - range.anchor
	end
	ctx.view:set_selection({ ranges = points, primary = 1 })
	greed.mode.set("vim-insert")
end

for _, op in { "d", "c", "y", ">", "<", "gc", "g~", "gu", "gU", "g?", "gq", "gw", "=", "!", "zf" } do
	command("operator-" .. op, "Vim operator " .. op .. ", followed by a motion", function(ctx)
		local mode = greed.mode.get()
		if mode == "vim-visual-block" then
			block_operate(ctx, op)
			return
		elseif mode == "vim-visual" or mode == "vim-visual-line" then
			local range = ctx.view:selection().ranges[1]
			local from, to = core.text.span(range)
			greed.mode.set("vim")
			if mode == "vim-visual-line" then
				apply(ctx, op, motion_range(ctx.buffer, from, to, "line"))
			else
				-- The selection already includes the cursor's character.
				apply(
					ctx,
					op,
					from,
					math.max(to, math.min(ctx.buffer:next_char(from), ctx.buffer:len())),
					false
				)
			end
			return
		end
		operate(ctx, op)
	end)
end

-- The last visual selection and its mode, for gv.
local last_visual: { mode: string, selection: greed.Selection, block: typeof(block) }? = nil

greed.on("mode.changed", function(event: greed.ModeChanged)
	local visual_mode = "^vim%-visual"
	if string.match(event.from, visual_mode) and not string.match(event.to, visual_mode) then
		last_visual = {
			mode = event.from,
			selection = greed.view():selection(),
			block = table.clone(block),
		}
	end
end)

command(
	"command-line",
	"Open the command line, with the selected lines (or the count's) as its range",
	function(ctx)
		local mode = greed.mode.get()
		local text = ""
		if string.match(mode, "^vim%-visual") then
			-- A block's lines, as one range for '<,'> to read.
			local ranges = ctx.view:selection().ranges
			ctx.view:set_selection({
				ranges = { { anchor = ranges[1].anchor, head = ranges[#ranges].head } },
				primary = 1,
			})
			greed.mode.set("vim")
			text = "'<,'>"
		elseif ctx.count then
			text = if ctx.count == 1 then "." else `.,.+{ctx.count - 1}`
		end
		greed.run("command-line", { args = { text } })
	end
)

command("visual-surround", "Wrap the selection in the pair typed next", function(ctx)
	local mode = greed.mode.get()
	local range = ctx.view:selection().ranges[1]
	local from, to = core.text.span(range)
	greed.mode.set("vim")
	surround(ctx, from, to, mode == "vim-visual-line")
end)

command("reselect", "Select the last visual selection again", function(ctx)
	if last_visual == nil then
		return
	end
	local len = ctx.buffer:len()
	local ranges = {}
	for _, range in last_visual.selection.ranges do
		table.insert(
			ranges,
			{ anchor = math.min(range.anchor, len), head = math.min(range.head, len) }
		)
	end
	if last_visual.mode == "vim-visual-block" then
		local kept = last_visual.block
		block.line, block.column, block.cursor, block.to_end =
			kept.line, kept.column, kept.cursor, kept.to_end
	elseif last_visual.mode == "vim-visual-line" then
		visual_line = ctx.buffer:line_of(ranges[1].anchor)
	end
	greed.mode.set(last_visual.mode)
	ctx.view:set_selection({ ranges = ranges, primary = last_visual.selection.primary })
end)

command("select-match", "Select the search match under the cursor, or the next one", function(ctx)
	local from, to = search_match(ctx.buffer, cursor(ctx))
	if from == nil or to == nil then
		greed.echo("no match")
		return
	end
	greed.mode.set("vim-visual")
	ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
end)

command("visual", "Select characters, starting here", function(ctx)
	local at = cursor(ctx)
	ctx.view:set_selection(visual(ctx.buffer, at, at))
	greed.mode.set("vim-visual")
end)

command("visual-block", "Select a block of columns across lines", function(ctx)
	local at = cursor(ctx)
	block.line, block.column, block.cursor =
		ctx.buffer:line_of(at), core.text.column(ctx.buffer, at), at
	block.to_end = false
	ctx.view:set_selection(block_selection(ctx.buffer))
	greed.mode.set("vim-visual-block")
end)

-- I and A: type at the start (or, `at_end`, the end) of each of the block's
-- lines. I skips lines too short to reach the block, as Vim does.
local function block_insert(at_end: boolean): (ctx: greed.Context) -> ()
	return function(ctx)
		local all = ctx.view:selection().ranges
		local ranges = {}
		for _, range in all do
			if at_end or range.anchor < range.head then
				local pos = if at_end then range.head else range.anchor
				table.insert(ranges, { anchor = pos, head = pos })
			end
		end
		if #ranges == 0 then
			ranges = { { anchor = all[1].anchor, head = all[1].anchor } }
		end
		greed.history.start_group()
		ctx.view:set_selection({ ranges = ranges, primary = 1 })
		greed.mode.set("vim-insert")
	end
end

command("block-insert", "Type before the block on each of its lines", block_insert(false))
command("block-append", "Type after the block on each of its lines", block_insert(true))

command("visual-swap", "Go to the other end of the selection", function(ctx)
	local mode = greed.mode.get()
	local buffer = ctx.buffer
	if mode == "vim-visual-block" then
		local corner = core.text.at_column(buffer, block.line, block.column)
		block.line, block.column, block.cursor =
			buffer:line_of(block.cursor), core.text.column(buffer, block.cursor), corner
		ctx.view:set_selection(block_selection(buffer))
	elseif mode == "vim-visual-line" then
		local line = buffer:line_of(cursor(ctx))
		ctx.view:set_selection(lines_selection(buffer, line, visual_line))
		visual_line = line
	else
		local range = ctx.view:selection().ranges[1]
		ctx.view:set_selection(visual(buffer, cursor(ctx), visual_start(buffer, range)))
	end
end)

command("visual-line", "Select whole lines, starting with this one", function(ctx)
	visual_line = ctx.buffer:line_of(cursor(ctx))
	ctx.view:set_selection(lines_selection(ctx.buffer, visual_line, visual_line))
	greed.mode.set("vim-visual-line")
end)

-- In visual mode, i and a select a text object: v i w, v a (.
for _, around in { false, true } do
	local word = if around then "around" else "inside"
	command(`visual-{word}`, `Select {word} the text object typed next`, function(ctx)
		local from, to = text_object(ctx.buffer, cursor(ctx), greed.next_key(), around)
		if from and to then
			ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
		end
	end)
end

command("visual-replace", "Replace every selected character with the next one typed", function(ctx)
	local char = greed.next_key()
	if utf8.len(char) ~= 1 then
		return
	end
	local buffer, ranges = ctx.buffer, ctx.view:selection().ranges
	local top = core.text.span(ranges[1])
	greed.mode.set("vim")
	buffer:edit(function(e)
		for _, range in ranges do
			local from, to = core.text.span(range)
			local text = string.gsub(buffer:slice(from, to), utf8.charpattern, function(c)
				return if c == "\n" then c else char
			end)
			e:replace(from, to, text)
		end
	end)
	ctx.view:set_cursor(on_char(buffer, top))
end)

command("visual-paste", "Replace the selection with what's in the register", function(ctx)
	local from = to_paste(ctx)
	if from == nil then
		return
	end
	local mode = greed.mode.get()
	local buffer = ctx.buffer
	if mode == "vim-visual-block" then
		-- The block goes first, then what's pasted goes where it started.
		block_operate(ctx, "d")
	end
	local range = ctx.view:selection().ranges[1]
	local start, stop = core.text.span(range)
	greed.mode.set("vim")
	local lines = mode == "vim-visual-line"
	local text = from.text
	if lines then
		-- Whole lines take their line break, except the last line's.
		if stop < buffer:len() then
			stop += 1
			if not from.linewise then
				text ..= "\n"
			end
		elseif from.linewise then
			text = string.gsub(text, "\r?\n$", "")
		end
	elseif from.linewise then
		text = "\n" .. text
	end
	-- What it replaces goes in the unnamed register, as a delete would (the
	-- block's delete already did).
	if stop > start then
		store("d", buffer:slice(start, stop), lines)
	end
	buffer:edit(function(e)
		e:replace(start, stop, text)
	end)
	if lines or from.linewise then
		local first = if lines then start else start + 1
		ctx.view:set_cursor(core.text.first_non_blank(buffer, first))
	else
		ctx.view:set_cursor(on_char(buffer, buffer:prev_char(start + #text)))
	end
end)

return {
	block = block,
}
