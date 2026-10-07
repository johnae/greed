-- Edit mode: editing without modes, the way most editors work. Typing
-- inserts text (replacing any selection), arrows move, shift+arrows select,
-- and the usual ctrl shortcuts do the usual things.
--
-- Switch to it with `:style edit`, or to use it all the time, put this in
-- ~/.config/greed/init.luau:
--
--     require("@greed").option.set("editing-style", "edit")

local greed = require("@greed")
local core = require("@core")
local text, indent, registers = core.text, core.indent, core.registers
local span = text.span

-- Typing in a row is undone in one step; any command not tagged as typing
-- ends the step.
core.commands.tag(
	"typing",
	{ "type-char", "type-newline", "type-tab", "erase-back", "erase-forward" }
)

greed.on("command.run", function(event: greed.CommandRun)
	if greed.mode.get() == "edit" and not core.commands.has(event.name, "typing") then
		greed.history.end_group()
	end
end)

-- Replaces each selection with a piece of text (`text(i)` for the i-th
-- selection) and leaves a cursor after each.
local function replace_selections(ctx: greed.Context, text: (i: number) -> string)
	local selection = ctx.view:selection()
	ctx.buffer:edit(function(e)
		-- Earlier edits move the later selections by this much.
		local shift = 0
		for i, range in selection.ranges do
			local start, finish = span(range)
			local piece = text(i)
			e:replace(start, finish, piece)
			local cursor = start + shift + #piece
			selection.ranges[i] = { anchor = cursor, head = cursor }
			shift += #piece - (finish - start)
		end
		e:select(selection)
	end)
end

local function type_text(ctx: greed.Context, text: string)
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
			elseif not forward and range.head > 0 then
				e:delete(text.before(ctx.buffer, range.head), range.head)
			end
		end
	end)
end

greed.command({
	name = "type-char",
	doc = "Type the pressed character, replacing any selection",
	run = function(ctx)
		if ctx.char then
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
		greed.history.start_group()
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				type_text(ctx, "")
				break
			end
		end
		indent.break_lines(ctx.view)
	end,
})

greed.command({
	name = "type-tab",
	doc = "Indent the selected lines when a selection spans lines, otherwise type a level of indent",
	run = function(ctx)
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

local function nothing_selected(selection: greed.Selection): boolean
	for _, range in selection.ranges do
		if range.anchor ~= range.head then
			return false
		end
	end
	return true
end

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
		if nothing_selected(ctx.view:selection()) then
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
		if not nothing_selected(ctx.view:selection()) then
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
		local pieces = register.pieces
		local selection = ctx.view:selection()
		local joined = registers.join(register)
		if register.linewise and nothing_selected(selection) then
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

greed.command({
	name = "replace-in-file",
	doc = "Replace a regex everywhere in the file, on the command line",
	run = function()
		greed.run("command-line", { args = { "%s/" } })
	end,
})

greed.keymap.bind("edit", {
	left = "move-left",
	right = "move-right",
	up = "move-up",
	down = "move-down",
	home = "smart-home",
	["end"] = "line-end",
	["ctrl-left"] = "move-word-left",
	["ctrl-right"] = "move-word-right",
	["ctrl-home"] = "goto-start",
	["ctrl-end"] = "goto-end",
	pagedown = "page-down",
	pageup = "page-up",
	["shift-left"] = "extend-left",
	["shift-right"] = "extend-right",
	["shift-up"] = "extend-up",
	["shift-down"] = "extend-down",
	["shift-home"] = "extend-smart-home",
	["shift-end"] = "extend-line-end",
	["ctrl-shift-left"] = "extend-word-left",
	["ctrl-shift-right"] = "extend-word-right",
	["ctrl-shift-home"] = "extend-start",
	["ctrl-shift-end"] = "extend-end",
	enter = "type-newline",
	tab = "type-tab",
	["shift-tab"] = "dedent",
	backspace = "erase-back",
	delete = "erase-forward",
	esc = "collapse",
	["ctrl-a"] = "select-all",
	["ctrl-c"] = "copy-or-line",
	["ctrl-x"] = "cut-or-line",
	["ctrl-v"] = "paste-over",
	["ctrl-z"] = "undo",
	["ctrl-y"] = "redo",
	["ctrl-Z"] = "redo",
	["ctrl-p"] = "pick-file",
	["ctrl-b"] = "pick-buffer",
	["ctrl-P"] = "command-palette",
	["ctrl-f"] = "search",
	f3 = "search-next",
	["shift-f3"] = "search-prev",
	["ctrl-h"] = "replace-in-file",
	["ctrl-g"] = "command-line",
	["ctrl-d"] = "select-next-match",
	["ctrl-L"] = "select-all-matches",
	["ctrl-l"] = "select-lines",
	["ctrl-K"] = "delete-lines-at-cursor",
	["alt-up"] = "move-lines-up",
	["alt-down"] = "move-lines-down",
	["alt-shift-up"] = "copy-lines-up",
	["alt-shift-down"] = "copy-lines-down",
	["ctrl-alt-up"] = "copy-selection-up",
	["ctrl-alt-down"] = "copy-selection-down",
	["ctrl-enter"] = "insert-line-below",
	["ctrl-shift-enter"] = "insert-line-above",
	["ctrl-/"] = "toggle-comment",
	["ctrl-_"] = "toggle-comment",
	["ctrl-]"] = "indent",
	["ctrl-backspace"] = "delete-word-back",
	["ctrl-delete"] = "delete-word-forward",
	["ctrl-w"] = "buffer-close",
	f12 = "goto-definition",
	["shift-f12"] = "goto-references",
	f2 = "rename",
	f8 = "next-diagnostic",
	["shift-f8"] = "prev-diagnostic",
	["ctrl-."] = "code-action",
	["ctrl-O"] = "pick-outline",
	["ctrl-t"] = "pick-workspace-symbol",
	["ctrl-M"] = "pick-problem",
	["alt-left"] = "jump-back",
	["alt-right"] = "jump-forward",
	["ctrl-u"] = "selection-undo",
	["ctrl-U"] = "selection-redo",
})

-- Without modes there's no ":" to find, so switching here says where
-- commands are.
greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "editing-style" and event.value == "edit" then
		greed.echo("ctrl-P runs any command, alt-x opens the command line")
	end
end)

greed.keymap.fallback("edit", "type-char")
greed.mode.set_cursor("edit", "bar")

core.style.define({
	name = "edit",
	doc = "No modes: typing inserts, shift and the arrows select (VS Code, most editors)",
	mode = "edit",
	typing = { "edit" },
})
