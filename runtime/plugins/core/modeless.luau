-- Editing without modes, the way most editors work: typing inserts text
-- (replacing any selection), shift and the arrows select, and the editing
-- commands such editors have (copy and cut take the line with nothing
-- selected, lines move up and down, ...). A style without modes, like the
-- vscode plugin's, binds its keys to these commands in its one mode and
-- adds itself with `define`:
--
--     greed.keymap.bind("mine", { ["ctrl-c"] = "copy-or-line", ... })
--     require("@core").modeless.define({ name = "mine", doc = "My keys", leader = "ctrl-space" })

local greed = require("@greed")
local commands = require("./commands")
local indent = require("./indent")
local motions = require("./motions")
local pairing = require("./pairs")
local registers = require("./registers")
local registry = require("./registry")
local snippet = require("./snippet")
local style = require("./style")
local text = require("./text")
local writable = require("./writable")
local span = text.span

local M = {}

-- The modes of the styles without modes.
local modes: { [string]: boolean } = {}

-- Typing in a row is undone in one step; any command not tagged as typing
-- ends the step.
commands.tag("typing", { "type-char", "type-newline", "type-tab", "erase-back", "erase-forward" })

greed.on("command.run", function(event: greed.CommandRun)
	if modes[greed.mode.get()] and not commands.has(event.name, "typing") then
		greed.history.end_group()
	end
end)

-- Replaces each selection with a piece of text (`text(i)` for the i-th
-- selection) and leaves a cursor after each.
local function replace_selections(ctx: greed.Context, text: (i: number) -> string)
	motions.replace_each(ctx.view, function(i)
		return { text = text(i), place = "end" }
	end)
end

local function type_text(ctx: greed.Context, text: string)
	writable.cursor(ctx.view)
	greed.history.start_group()
	replace_selections(ctx, function()
		return text
	end)
end

-- Deletes each selection, or one character before (or after) each cursor.
local function erase(ctx: greed.Context, forward: boolean)
	greed.history.start_group()
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				e:delete(span(range))
			elseif forward and range.head < ctx.buffer:len() then
				e:delete(range.head, text.after(ctx.buffer, range.head))
			elseif not forward then
				local from =
					writable.back_to(ctx.buffer, text.before(ctx.buffer, range.head), range.head)
				if from < range.head then
					e:delete(from, range.head + pairing.closer_after(ctx.buffer, range.head))
				end
			end
		end
	end)
end

greed.command({
	name = "type-char",
	doc = "Type the pressed character, replacing any selection",
	run = function(ctx)
		if ctx.char then
			writable.cursor(ctx.view)
			greed.history.start_group()
			if pairing.type(ctx.view, ctx.char, true) then
				return
			end
			type_text(ctx, ctx.char)
			-- A closing bracket at a line's start lines up with its block.
			if string.match(ctx.char, "^[%)%]}]$") and indent.typed_first(ctx.view) then
				indent.reindent(ctx.view)
			end
		end
	end,
})

greed.command({
	name = "type-newline",
	doc = "Type a line break, replacing any selection, and start the new line at its indent",
	run = function(ctx)
		writable.cursor(ctx.view)
		greed.history.start_group()
		if text.anything_selected(ctx.view:selection()) then
			type_text(ctx, "")
		end
		indent.break_lines(ctx.view)
	end,
})

greed.command({
	name = "type-tab",
	doc = "Go to the next place of the snippet being filled in; otherwise indent the selected "
		.. "lines when a selection spans lines, or type a level of indent",
	run = function(ctx)
		if snippet.move(ctx.view) then
			return
		end
		local buffer = ctx.buffer
		for _, range in ctx.view:selection().ranges do
			local from, to = span(range)
			if buffer:line_of(from) ~= buffer:line_of(to) then
				greed.run("indent")
				return
			end
		end
		type_text(ctx, indent.unit(buffer))
	end,
})

greed.command({
	name = "erase-back",
	doc = "Delete the selection, or the character before the cursor",
	run = function(ctx)
		erase(ctx, false)
	end,
})

greed.command({
	name = "erase-forward",
	doc = "Delete the selection, or the character after the cursor",
	run = function(ctx)
		erase(ctx, true)
	end,
})

-- With nothing selected, copy and cut take whole lines, as in most
-- editors, and pasting whole lines with nothing selected puts them above
-- the line rather than at the cursor.

-- A run of lines, first and last.
type Block = { first: number, last: number }

-- The lines the selection's ranges touch, merged where they meet, top to
-- bottom.
local function line_blocks(buffer: greed.Buffer, selection: greed.Selection): { Block }
	local blocks: { Block } = {}
	for _, range in selection.ranges do
		local a, b = span(range)
		table.insert(
			blocks,
			{ first = buffer:line_of(a), last = buffer:line_of(math.max(a, b - 1)) }
		)
	end
	table.sort(blocks, function(x: Block, y: Block)
		return x.first < y.first
	end)
	local merged: { Block } = {}
	for _, block in blocks do
		local top = merged[#merged]
		if top and block.first <= top.last + 1 then
			top.last = math.max(top.last, block.last)
		else
			table.insert(merged, { first = block.first, last = block.last })
		end
	end
	return merged
end

-- Deletes each block of lines and the line break after it (or before it,
-- at the end of the buffer).
local function delete_lines(buffer: greed.Buffer, blocks: { Block })
	buffer:edit(function(e)
		for _, block in blocks do
			local start, stop = buffer:line_start(block.first), buffer:line_end(block.last)
			if stop < buffer:len() then
				stop += 1
			elseif start > 0 then
				start -= 1
			end
			e:delete(start, stop)
		end
	end)
end

-- Copies the lines the cursors are on, each with its line break. Returns
-- the blocks of lines.
local function copy_lines(ctx: greed.Context): { Block }
	local blocks = line_blocks(ctx.buffer, ctx.view:selection())
	local pieces = {}
	for _, block in blocks do
		table.insert(pieces, text.lines(ctx.buffer, block.first, block.last) .. "\n")
	end
	registers.to_clipboard({ table.concat(pieces) }, true)
	return blocks
end

greed.command({
	name = "copy-or-line",
	doc = "Copy the selection, or the line when nothing is selected",
	run = function(ctx)
		if not text.anything_selected(ctx.view:selection()) then
			copy_lines(ctx)
		else
			greed.run("copy")
		end
	end,
})

greed.command({
	name = "cut-or-line",
	doc = "Cut the selection, or the line when nothing is selected",
	run = function(ctx)
		if text.anything_selected(ctx.view:selection()) then
			greed.run("cut")
			return
		end
		delete_lines(ctx.buffer, copy_lines(ctx))
	end,
})

greed.command({
	name = "paste-over",
	doc = "Paste, replacing each selection; whole lines go above the cursor's line",
	run = function(ctx)
		local register = registers.clipboard()
		if register == nil then
			return
		end
		writable.cursor(ctx.view)
		local pieces = register.pieces
		local selection = ctx.view:selection()
		local joined = registers.join(register)
		if register.linewise and not text.anything_selected(selection) then
			local buffer = ctx.buffer
			buffer:edit(function(e)
				for _, block in line_blocks(buffer, selection) do
					e:insert(buffer:line_start(block.first), joined)
				end
			end)
			return
		end
		local one_each = #pieces == #selection.ranges
		replace_selections(ctx, function(i)
			return if one_each then pieces[i] else joined
		end)
	end,
})

greed.command({
	name = "delete-lines-at-cursor",
	doc = "Delete the lines the cursors are on",
	run = function(ctx)
		delete_lines(ctx.buffer, line_blocks(ctx.buffer, ctx.view:selection()))
	end,
})

-- move-lines-up and move-lines-down: the lines the cursors are on swap
-- with the line above or below them, cursors and all.
for _, down in { false, true } do
	greed.command({
		name = if down then "move-lines-down" else "move-lines-up",
		doc = if down then "Move the cursors' lines down one" else "Move the cursors' lines up one",
		run = function(ctx)
			local buffer = ctx.buffer
			local selection = ctx.view:selection()
			local blocks = line_blocks(buffer, selection)
			local edge = if down
				then blocks[#blocks].last == buffer:line_count() - 1
				else blocks[1].first == 0
			if edge then
				return
			end
			local shifts: { { from: number, to: number, by: number } } = {}
			buffer:edit(function(e)
				for _, block in blocks do
					local other = if down then block.last + 1 else block.first - 1
					local moved, swapped =
						text.lines(buffer, block.first, block.last),
						text.lines(buffer, other, other)
					local top = math.min(block.first, other)
					local bottom = math.max(block.last, other)
					e:replace(
						buffer:line_start(top),
						buffer:line_end(bottom),
						if down then swapped .. "\n" .. moved else moved .. "\n" .. swapped
					)
					table.insert(shifts, {
						from = buffer:line_start(block.first),
						to = buffer:line_end(block.last),
						by = (#swapped + 1) * (if down then 1 else -1),
					})
				end
			end)
			for i, range in selection.ranges do
				local from, to = span(range)
				for _, shift in shifts do
					if from >= shift.from and to <= shift.to + 1 then
						selection.ranges[i] =
							{ anchor = range.anchor + shift.by, head = range.head + shift.by }
					end
				end
			end
			ctx.view:set_selection(selection)
		end,
	})
end

-- copy-lines-up and copy-lines-down: the cursors' lines doubled, the
-- cursors going with the copy above or below.
for _, down in { false, true } do
	greed.command({
		name = if down then "copy-lines-down" else "copy-lines-up",
		doc = if down
			then "Copy the cursors' lines below them"
			else "Copy the cursors' lines above them",
		run = function(ctx)
			local buffer = ctx.buffer
			local selection = ctx.view:selection()
			-- Each copy moves the cursors after it down by its length, and a
			-- copy below moves its own cursors down too.
			local blocks = line_blocks(buffer, selection)
			local copies: { string } = {}
			local ranges = {}
			local grown = 0
			for i, block in blocks do
				local lines = text.lines(buffer, block.first, block.last)
				copies[i] = lines
				for _, range in selection.ranges do
					local line = buffer:line_of(range.head)
					if line >= block.first and line <= block.last then
						local by = grown + (if down then #lines + 1 else 0)
						table.insert(ranges, { anchor = range.anchor + by, head = range.head + by })
					end
				end
				grown += #lines + 1
			end
			buffer:edit(function(e)
				for i, block in blocks do
					if down then
						e:insert(buffer:line_end(block.last), "\n" .. copies[i])
					else
						e:insert(buffer:line_start(block.first), copies[i] .. "\n")
					end
				end
			end)
			ctx.view:set_selection({ ranges = ranges, primary = 1 })
		end,
	})
end

-- insert-line-below and insert-line-above: a new line at the indent the
-- code calls for, without breaking the one the cursor is on.
for _, below in { true, false } do
	greed.command({
		name = if below then "insert-line-below" else "insert-line-above",
		doc = if below
			then "Start a new line below this one"
			else "Start a new line above this one",
		run = function(ctx)
			greed.history.start_group()
			indent.open(ctx.view, below)
		end,
	})
end

-- smart-home and extend-smart-home: to the line's first non-blank, or to
-- its start when already there.
for _, extend in { false, true } do
	greed.command({
		name = if extend then "extend-smart-home" else "smart-home",
		doc = if extend
			then "Select to the first non-blank of the line, or to its start"
			else "Go to the first non-blank of the line, or to its start",
		run = function(ctx)
			local buffer = ctx.buffer
			local selection = ctx.view:selection()
			for i, range in selection.ranges do
				local start = buffer:line_start(buffer:line_of(range.head))
				local first = text.first_non_blank(buffer, start)
				local pos = if range.head == first then start else first
				selection.ranges[i] = { anchor = if extend then range.anchor else pos, head = pos }
			end
			ctx.view:set_selection(selection)
		end,
	})
end

greed.command({
	name = "select-lines",
	doc = "Select the cursor's line, or the next one too when whole lines are selected",
	run = function(ctx)
		local buffer = ctx.buffer
		local selection = ctx.view:selection()
		for i, range in selection.ranges do
			local a, b = span(range)
			local first, last = buffer:line_of(a), buffer:line_of(math.max(a, b - 1))
			local whole = a == buffer:line_start(first)
				and b > a
				and (b == buffer:len() or b == buffer:line_start(last + 1))
			if whole then
				last += 1
			end
			local stop = if last + 1 < buffer:line_count()
				then buffer:line_start(last + 1)
				else buffer:len()
			selection.ranges[i] = { anchor = buffer:line_start(first), head = stop }
		end
		ctx.view:set_selection(selection)
	end,
})

-- Selects the word at the primary cursor, when nothing is selected there.
-- Returns whether it did.
local function select_word(ctx: greed.Context): boolean
	local selection = ctx.view:selection()
	local range = selection.ranges[selection.primary]
	if range.anchor ~= range.head then
		return false
	end
	local start, stop = text.word_at(ctx.buffer, range.head)
	ctx.view:set_selection({ ranges = { { anchor = start, head = stop } }, primary = 1 })
	return true
end

greed.command({
	name = "select-next-match",
	doc = "Select the word at the cursor, then add the next match of it as another selection",
	run = function(ctx)
		if select_word(ctx) then
			return
		end
		if #ctx.view:selection().ranges == 1 then
			greed.run("search-selection")
		end
		greed.run("search-next-add")
	end,
})

greed.command({
	name = "select-all-matches",
	doc = "Select every match of the selected text (or the word at the cursor)",
	run = function(ctx)
		select_word(ctx)
		greed.run("search-selection")
		local count = 0
		repeat
			count = #ctx.view:selection().ranges
			greed.run("search-next-add")
		until #ctx.view:selection().ranges == count
	end,
})

--- Whether `mode` is the one mode of a style without modes, where typing
--- and pasting replace the selection.
function M.is(mode: string): boolean
	return modes[mode] == true
end

export type Style = {
	--- The style's name, which is its mode's too.
	name: string,
	doc: string,
	--- The keys that open the leader, e.g. "ctrl-space".
	leader: string?,
	--- What the status line calls its mode; "edit" if left out.
	label: string?,
	--- Whether brackets and quotes are typed in pairs (see pairs.luau).
	pairs: boolean?,
}

--- Adds a style without modes. Its one mode, named like the style, types
--- what's typed, replacing the selection; bind its keys in that mode.
--- It goes when the plugin that added it does.
function M.define(spec: Style)
	local mode = spec.name
	greed.keymap.fallback(mode, "type-char")
	greed.mode.set_cursor(mode, "bar")
	greed.plugin.tie(registry.set(modes, mode, true))
	style.define({
		name = spec.name,
		doc = spec.doc,
		mode = mode,
		roles = { typing = mode },
		labels = { [mode] = spec.label or "edit" },
		leader = spec.leader,
		pairs = spec.pairs,
	})
end

return M
