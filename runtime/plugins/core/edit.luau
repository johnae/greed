-- Modes and editing commands: insert, append, delete, change, undo, copy,
-- paste.

local kern = require("@kern")
local indent = require("./indent")
local motions = require("./motions")
local registers = require("./registers")
local style = require("./style")
local text = require("./text")

local each_range, point = motions.each_range, motions.point

local function from(range: kern.Range): number
	return math.min(range.anchor, range.head)
end

local function to(range: kern.Range): number
	return math.max(range.anchor, range.head)
end

-- Everything typed in one insert session, plus the delete that `change` does
-- before it, is undone as one step.
local function enter_insert()
	kern.history.start_group()
	kern.mode.set("insert")
end

kern.command({
	name = "normal-mode",
	doc = "Back to the editing style's own mode (normal, in Helix's)",
	run = function()
		kern.history.end_group()
		kern.mode.set(style.home())
	end,
})

kern.command({
	name = "insert-mode",
	doc = "Insert before each selection",
	run = function(ctx)
		each_range(ctx, function(_, range)
			return point(from(range))
		end)
		enter_insert()
	end,
})

kern.command({
	name = "append-mode",
	doc = "Insert after each selection",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			if range.anchor ~= range.head then
				return point(to(range))
			end
			return point(math.min(buffer:len(), buffer:next_char(range.head)))
		end)
		enter_insert()
	end,
})

-- Inserts `text` at every cursor; cursors end up after it.
local function insert_at_heads(ctx: kern.Context, text: string)
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			e:insert(range.head, text)
		end
	end)
end

kern.command({
	name = "insert-char",
	doc = "Insert the typed character at each cursor",
	run = function(ctx)
		if ctx.char then
			insert_at_heads(ctx, ctx.char)
		end
	end,
})

kern.command({
	name = "insert-newline",
	doc = "Insert a line break at each cursor, starting the new line at its indent",
	run = function(ctx)
		indent.break_lines(ctx.view)
	end,
})

kern.command({
	name = "delete-back",
	doc = "Delete the character before each cursor",
	run = function(ctx)
		ctx.buffer:edit(function(e)
			for _, range in ctx.view:selection().ranges do
				if range.head > 0 then
					e:delete(text.before(ctx.buffer, range.head), range.head)
				end
			end
		end)
	end,
})

-- Deletes each selection, or the character under each cursor.
local function delete_selections(ctx: kern.Context)
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				e:delete(from(range), to(range))
			elseif range.head < ctx.buffer:len() then
				e:delete(range.head, text.after(ctx.buffer, range.head))
			end
		end
	end)
end

kern.command({
	name = "open-below",
	doc = "Open a new line below each cursor and insert there",
	run = function(ctx)
		kern.history.start_group()
		indent.open(ctx.view, true)
		enter_insert()
	end,
})

kern.command({
	name = "open-above",
	doc = "Open a new line above each cursor and insert there",
	run = function(ctx)
		kern.history.start_group()
		indent.open(ctx.view, false)
		enter_insert()
	end,
})

kern.command({
	name = "undo",
	doc = "Undo the last change",
	run = function(ctx)
		ctx.view:undo()
	end,
})

kern.command({
	name = "redo",
	doc = "Redo the last undone change",
	run = function(ctx)
		ctx.view:redo()
	end,
})

-- Copies the text of each selection, one piece per selection.
local function copy_selections(ctx: kern.Context, quiet: boolean?): boolean
	local pieces = {}
	for _, range in ctx.view:selection().ranges do
		if range.anchor ~= range.head then
			table.insert(pieces, ctx.buffer:slice(from(range), to(range)))
		end
	end
	if #pieces == 0 then
		if not quiet then
			kern.echo("nothing selected")
		end
		return false
	end
	registers.copy(pieces)
	return true
end

-- Pastes the latest copy before or after each selection, and selects what
-- was pasted. With as many pieces as selections, each selection gets its
-- own piece.
local function paste(ctx: kern.Context, after: boolean)
	local pieces = registers.paste()
	if pieces == nil then
		return
	end
	local selection = ctx.view:selection()
	local one_each = #pieces == #selection.ranges
	local joined = table.concat(pieces, "\n")
	ctx.buffer:edit(function(e)
		-- Text inserted earlier in the buffer shifts the later selections.
		local shift = 0
		for i, range in selection.ranges do
			local text = if one_each then pieces[i] else joined
			local at = if after then to(range) else from(range)
			e:insert(at, text)
			selection.ranges[i] = { anchor = at + shift, head = at + shift + #text }
			shift += #text
		end
		e:select(selection)
	end)
end

kern.command({
	name = "copy",
	doc = "Copy each selection to the clipboard",
	run = function(ctx)
		copy_selections(ctx)
	end,
})

kern.command({
	name = "cut",
	doc = "Copy each selection to the clipboard and delete it",
	run = function(ctx)
		if copy_selections(ctx) then
			delete_selections(ctx)
		end
	end,
})

kern.command({
	name = "paste-after",
	doc = "Paste after each selection",
	run = function(ctx)
		paste(ctx, true)
	end,
})

kern.command({
	name = "paste-before",
	doc = "Paste before each selection",
	run = function(ctx)
		paste(ctx, false)
	end,
})

kern.command({
	name = "delete",
	doc = "Copy each selection and delete it",
	run = function(ctx)
		copy_selections(ctx, true)
		delete_selections(ctx)
	end,
})

kern.command({
	name = "delete-without-copy",
	doc = "Delete each selection, leaving the clipboard alone",
	run = delete_selections,
})

kern.command({
	name = "change",
	doc = "Copy each selection, delete it and switch to insert mode",
	run = function(ctx)
		kern.history.start_group()
		copy_selections(ctx, true)
		delete_selections(ctx)
		enter_insert()
	end,
})

kern.command({
	name = "change-without-copy",
	doc = "Delete each selection and switch to insert mode, leaving the clipboard alone",
	run = function(ctx)
		kern.history.start_group()
		delete_selections(ctx)
		enter_insert()
	end,
})

kern.option.define({
	name = "indent",
	doc = "One level of indent, spaces or a tab, in languages that don't set their own",
	default = "    ",
})

-- Replaces the text of each selection (or the character under each cursor)
-- with `change(text)`, keeping the selections around the new text.
local function transform(ctx: kern.Context, change: (string) -> string)
	local buffer = ctx.buffer
	local selection = ctx.view:selection()
	buffer:edit(function(e)
		local shift = 0
		for i, range in selection.ranges do
			local a, b = from(range), to(range)
			if a == b then
				b = text.after(buffer, a)
			end
			local new = change(buffer:slice(a, b))
			e:replace(a, b, new)
			local grow = #new - (b - a)
			local anchor, head = range.anchor + shift, range.head + shift
			if range.anchor ~= range.head then
				if range.anchor > range.head then
					anchor += grow
				else
					head += grow
				end
			end
			selection.ranges[i] = { anchor = anchor, head = head }
			shift += grow
		end
		e:select(selection)
	end)
end

kern.command({
	name = "replace-char",
	doc = "Replace every selected character with the next one typed",
	run = function(ctx)
		local char = kern.next_key()
		if utf8.len(char) ~= 1 then
			return
		end
		transform(ctx, function(s)
			return (
				string.gsub(s, utf8.charpattern, function(c)
					return if c == "\n" or c == "\r" then c else char
				end)
			)
		end)
	end,
})

kern.command({
	name = "switch-case",
	doc = "Switch the case of each selected letter",
	run = function(ctx)
		transform(ctx, function(s)
			return (
				string.gsub(s, "%a", function(c)
					return if string.match(c, "%l") then string.upper(c) else string.lower(c)
				end)
			)
		end)
	end,
})

kern.command({
	name = "lowercase",
	doc = "Make the selections lowercase",
	run = function(ctx)
		transform(ctx, string.lower)
	end,
})

kern.command({
	name = "uppercase",
	doc = "Make the selections uppercase",
	run = function(ctx)
		transform(ctx, string.upper)
	end,
})

kern.command({
	name = "indent",
	doc = "Indent the lines of each selection",
	run = function(ctx)
		local unit = indent.unit(ctx.buffer)
		local buffer = ctx.buffer
		local starts = {}
		for _, line in motions.selected_lines(ctx) do
			if buffer:line_end(line) > buffer:line_start(line) then
				table.insert(starts, buffer:line_start(line))
			end
		end
		motions.insert_at(ctx, starts, unit)
	end,
})

kern.command({
	name = "dedent",
	doc = "Take one level of indent off the lines of each selection",
	run = function(ctx)
		local width = #indent.unit(ctx.buffer)
		local buffer = ctx.buffer
		buffer:edit(function(e)
			for _, line in motions.selected_lines(ctx) do
				local start = buffer:line_start(line)
				local lead = indent.of(buffer, line)
				local take = if string.sub(lead, 1, 1) == "\t" then 1 else math.min(#lead, width)
				if take > 0 then
					e:delete(start, start + take)
				end
			end
		end)
	end,
})

kern.command({
	name = "join-lines",
	doc = "Join the next line onto each cursor's, or the lines of each selection, with one space",
	run = function(ctx)
		local buffer = ctx.buffer
		local joins = {}
		for _, range in ctx.view:selection().ranges do
			local first, last = buffer:line_of(from(range)), buffer:line_of(to(range))
			for line = first, math.max(last - 1, first) do
				if line + 1 < buffer:line_count() then
					joins[line] = true
				end
			end
		end
		buffer:edit(function(e)
			for line in joins do
				local stop = buffer:line_end(line)
				local next_start = buffer:line_start(line + 1)
				e:replace(stop, next_start + #indent.of(buffer, line + 1), " ")
			end
		end)
	end,
})

kern.command({
	name = "insert-line-start",
	doc = "Insert at the start of each line, after its indent",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			return point(text.first_non_blank(buffer, range.head))
		end)
		enter_insert()
	end,
})

kern.command({
	name = "append-line-end",
	doc = "Insert at the end of each line",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			return point(buffer:line_end(buffer:line_of(range.head)))
		end)
		enter_insert()
	end,
})

kern.command({
	name = "replace-with-copy",
	doc = "Replace each selection with what was copied",
	run = function(ctx)
		local pieces = registers.paste()
		if pieces == nil then
			return
		end
		local count = #ctx.view:selection().ranges
		local joined = table.concat(pieces, "\n")
		local i = 0
		transform(ctx, function()
			i += 1
			return if #pieces == count then pieces[i] else joined
		end)
	end,
})

return {}
