-- Edit mode: editing without modes, the way most editors work. Typing
-- inserts text (replacing any selection), arrows move, shift+arrows select,
-- and the usual ctrl shortcuts do the usual things.
--
-- Switch to it with `:style edit`, or to use it all the time, put this in
-- ~/.config/kern/init.luau:
--
--     require("@kern").option.set("editing-style", "edit")

local kern = require("@kern")
local text = require("@core").text
local indent = require("@core").indent

-- Commands that type. Typing in a row is undone in one step; any other
-- command ends the step.
local typing = {
	["type-char"] = true,
	["type-newline"] = true,
	["type-tab"] = true,
	["erase-back"] = true,
	["erase-forward"] = true,
}

kern.on("command.run", function(event: kern.CommandRun)
	if kern.mode.get() == "edit" and not typing[event.name] then
		kern.history.end_group()
	end
end)

local function from(range: kern.Range): number
	return math.min(range.anchor, range.head)
end

local function to(range: kern.Range): number
	return math.max(range.anchor, range.head)
end

-- Replaces each selection with a piece of text (`text(i)` for the i-th
-- selection) and leaves a cursor after each.
local function replace_selections(ctx: kern.Context, text: (i: number) -> string)
	local selection = ctx.view:selection()
	ctx.buffer:edit(function(e)
		-- Earlier edits move the later selections by this much.
		local shift = 0
		for i, range in selection.ranges do
			local start, finish = from(range), to(range)
			local piece = text(i)
			e:replace(start, finish, piece)
			local cursor = start + shift + #piece
			selection.ranges[i] = { anchor = cursor, head = cursor }
			shift += #piece - (finish - start)
		end
		e:select(selection)
	end)
end

local function type_text(ctx: kern.Context, text: string)
	kern.history.start_group()
	replace_selections(ctx, function()
		return text
	end)
end

-- Deletes each selection, or one character before (or after) each cursor.
local function erase(ctx: kern.Context, forward: boolean)
	kern.history.start_group()
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				e:delete(from(range), to(range))
			elseif forward and range.head < ctx.buffer:len() then
				e:delete(range.head, text.after(ctx.buffer, range.head))
			elseif not forward and range.head > 0 then
				e:delete(text.before(ctx.buffer, range.head), range.head)
			end
		end
	end)
end

kern.command({
	name = "type-char",
	doc = "Type the pressed character, replacing any selection",
	run = function(ctx)
		if ctx.char then
			type_text(ctx, ctx.char)
			-- A closing bracket at a line's start lines up with its block.
			if string.match(ctx.char, "^[%)%]}]$") then
				indent.reindent(ctx.view)
			end
		end
	end,
})

kern.command({
	name = "type-newline",
	doc = "Type a line break, replacing any selection, and start the new line at its indent",
	run = function(ctx)
		kern.history.start_group()
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				type_text(ctx, "")
				break
			end
		end
		indent.break_lines(ctx.view)
	end,
})

kern.command({
	name = "type-tab",
	doc = "Indent the selected lines when a selection spans lines, otherwise type a level of indent",
	run = function(ctx)
		local buffer = ctx.buffer
		for _, range in ctx.view:selection().ranges do
			if buffer:line_of(from(range)) ~= buffer:line_of(to(range)) then
				kern.run("indent")
				return
			end
		end
		type_text(ctx, indent.unit(buffer))
	end,
})

kern.command({
	name = "erase-back",
	doc = "Delete the selection, or the character before the cursor",
	run = function(ctx)
		erase(ctx, false)
	end,
})

kern.command({
	name = "erase-forward",
	doc = "Delete the selection, or the character after the cursor",
	run = function(ctx)
		erase(ctx, true)
	end,
})

kern.command({
	name = "paste-over",
	doc = "Paste, replacing each selection",
	run = function(ctx)
		local pieces = kern.clipboard.get()
		if pieces == nil then
			return
		end
		local one_each = #pieces == #ctx.view:selection().ranges
		local joined = table.concat(pieces, "\n")
		replace_selections(ctx, function(i)
			return if one_each then pieces[i] else joined
		end)
	end,
})

kern.keymap.bind("edit", {
	left = "move-left",
	right = "move-right",
	up = "move-up",
	down = "move-down",
	home = "line-start",
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
	["shift-home"] = "extend-line-start",
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
	["ctrl-c"] = "copy",
	["ctrl-x"] = "cut",
	["ctrl-v"] = "paste-over",
	["ctrl-z"] = "undo",
	["ctrl-y"] = "redo",
	["ctrl-Z"] = "redo",
	["ctrl-p"] = "pick-file",
	["ctrl-b"] = "pick-buffer",
	["ctrl-P"] = "command-palette",
})

kern.keymap.fallback("edit", "type-char")
kern.mode.cursor("edit", "bar")
-- Panels like the file tree and help keep their keys.
kern.keymap.inherit_kinds("edit", "normal")

require("@core").style.define({
	name = "edit",
	doc = "No modes: typing inserts, shift and the arrows select (most editors)",
	mode = "edit",
	plugin = "edit-mode",
})
