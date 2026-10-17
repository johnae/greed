-- Modes and editing commands: insert, append, delete, change, undo, copy,
-- paste.

local greed = require("@greed")
local commands = require("./commands")
local indent = require("./indent")
local motions = require("./motions")
local pairing = require("./pairs")
local registers = require("./registers")
local style = require("./style")
local text = require("./text")
local writable = require("./writable")

local each_range, point = motions.each_range, motions.point
local span = text.span

-- Whether the insert session started with `a`, which Helix leaves with the
-- cursor on the last character typed rather than the one after it.
local appending = false

-- Everything typed in one insert session, plus the delete that `change` does
-- before it, is undone as one step.
local function enter_insert(append: boolean?)
	appending = append == true
	greed.history.start_group()
	greed.mode.set(style.typing_mode())
end

-- `range`, or for a bare cursor sitting on a character (a block), that
-- character, which commands like copy and paste act on as Helix does.
local function on_cursor(buffer: greed.Buffer, range: greed.Range): greed.Range
	if range.anchor == range.head and range.head < buffer:len() and motions.on_chars() then
		return { anchor = range.head, head = buffer:next_char(range.head) }
	end
	return range
end

greed.command({
	name = "normal-mode",
	doc = "Back to the editing style's own mode (normal, in Helix's)",
	run = function(ctx)
		greed.history.end_group()
		greed.mode.set(style.home())
		if appending and motions.on_chars() then
			each_range(ctx, function(buffer, range)
				local start = buffer:line_start(buffer:line_of(range.head))
				return if range.anchor == range.head and range.head > start
					then point(buffer:prev_char(range.head))
					else range
			end)
		end
		appending = false
	end,
})

greed.command({
	name = "insert-mode",
	doc = "Insert before each selection",
	run = function(ctx)
		each_range(ctx, function(_, range)
			return point((span(range)))
		end)
		enter_insert()
	end,
})

greed.command({
	name = "append-mode",
	doc = "Insert after each selection",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			if range.anchor ~= range.head then
				local _, to = span(range)
				return point(to)
			end
			return point(math.min(buffer:len(), buffer:next_char(range.head)))
		end)
		enter_insert(true)
	end,
})

-- Inserts `text` at every cursor; cursors end up after it.
local function insert_at_heads(ctx: greed.Context, text: string)
	writable.cursor(ctx.view)
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			e:insert(range.head, text)
		end
	end)
end

greed.command({
	name = "insert-char",
	doc = "Insert the typed character at each cursor",
	run = function(ctx)
		if ctx.char then
			writable.cursor(ctx.view)
			if pairing.type(ctx.view, ctx.char, false) then
				return
			end
			insert_at_heads(ctx, ctx.char)
			-- A closing bracket at a line's start lines up with its block.
			if string.match(ctx.char, "^[%)%]}]$") and indent.typed_first(ctx.view) then
				indent.reindent(ctx.view)
			end
		end
	end,
})

greed.command({
	name = "insert-newline",
	doc = "Insert a line break at each cursor, starting the new line at its indent",
	run = function(ctx)
		writable.cursor(ctx.view)
		indent.break_lines(ctx.view)
	end,
})

-- Adds command `name`, which deletes from each cursor to where
-- `target(buffer, head)` says, back or forward, for typing keys like ctrl-w;
-- and when it deletes back, `beyond(buffer, head)` bytes after the cursor
-- too.
local function delete_to_command(
	name: string,
	doc: string,
	target: (greed.Buffer, number) -> number,
	beyond: ((greed.Buffer, number) -> number)?
)
	local also: (greed.Buffer, number) -> number = beyond or function()
		return 0
	end
	greed.command({
		name = name,
		doc = doc,
		run = function(ctx)
			ctx.buffer:edit(function(e)
				for _, range in ctx.view:selection().ranges do
					local head = range.head
					local at = writable.back_to(ctx.buffer, target(ctx.buffer, head), head)
					if at < head then
						e:delete(at, head + also(ctx.buffer, head))
					elseif at > head then
						e:delete(head, at)
					end
				end
			end)
		end,
	})
end

delete_to_command(
	"delete-back",
	"Delete the character before each cursor, and the closer of an empty pair",
	text.before,
	pairing.closer_after
)
delete_to_command("delete-forward", "Delete the character after each cursor", text.after)
delete_to_command(
	"delete-word-back",
	"Delete back to the start of the word before each cursor",
	text.prev_word_start
)
delete_to_command(
	"delete-word-forward",
	"Delete to the start of the next word after each cursor",
	text.next_word_start
)
delete_to_command(
	"delete-to-line-start",
	"Delete back to the start of the line from each cursor",
	function(buffer, pos)
		return buffer:line_start(buffer:line_of(pos))
	end
)
delete_to_command(
	"delete-to-line-end",
	"Delete to the end of the line from each cursor",
	function(buffer, pos)
		return buffer:line_end(buffer:line_of(pos))
	end
)

greed.command({
	name = "insert-tab",
	doc = "Insert a level of indent at each cursor",
	run = function(ctx)
		insert_at_heads(ctx, indent.unit(ctx.buffer))
	end,
})

commands.tag(
	"typing",
	{ "insert-char", "insert-newline", "insert-tab", "delete-back", "delete-forward" }
)

greed.command({
	name = "insert-register",
	doc = "Insert what the register typed next holds at each cursor",
	run = function(ctx)
		local key = greed.next_key()
		if utf8.len(key) ~= 1 then
			return
		end
		registers.pick(key)
		local register = registers.paste(ctx)
		if register then
			insert_at_heads(ctx, registers.join(register))
		end
	end,
})

-- Deletes each selection, or the character under each cursor.
local function delete_selections(ctx: greed.Context)
	ctx.buffer:edit(function(e)
		for _, range in ctx.view:selection().ranges do
			if range.anchor ~= range.head then
				e:delete(span(range))
			elseif range.head < ctx.buffer:len() then
				e:delete(range.head, text.after(ctx.buffer, range.head))
			end
		end
	end)
end

greed.command({
	name = "open-below",
	doc = "Open a new line below each cursor and insert there",
	run = function(ctx)
		greed.history.start_group()
		indent.open(ctx.view, true)
		enter_insert()
	end,
})

greed.command({
	name = "open-above",
	doc = "Open a new line above each cursor and insert there",
	run = function(ctx)
		greed.history.start_group()
		indent.open(ctx.view, false)
		enter_insert()
	end,
})

greed.command({
	name = "undo",
	doc = "Undo the last change",
	run = function(ctx)
		for _ = 1, ctx.count or 1 do
			ctx.view:undo()
		end
	end,
})

greed.command({
	name = "redo",
	doc = "Redo the last undone change",
	run = function(ctx)
		for _ = 1, ctx.count or 1 do
			ctx.view:redo()
		end
	end,
})

-- Copies the text of each selection, one piece per selection. Selections
-- that all end in a line break, as `x` makes them, are whole lines.
local function copy_selections(ctx: greed.Context, quiet: boolean?): boolean
	local pieces = {}
	local linewise = true
	for _, range in ctx.view:selection().ranges do
		range = on_cursor(ctx.buffer, range)
		if range.anchor ~= range.head then
			local piece = ctx.buffer:slice(span(range))
			table.insert(pieces, piece)
			linewise = linewise and string.sub(piece, -1) == "\n"
		end
	end
	if #pieces == 0 then
		-- A register picked for this goes unused rather than to the next copy.
		registers.take()
		if not quiet then
			greed.echo("nothing selected")
		end
		return false
	end
	registers.copy(pieces, linewise)
	return true
end

-- Where `piece` goes before or after `range`: whole lines go above or below
-- the selected lines, anything else right at the selection. Returns the
-- place and the text to insert, with a line break put in front when lines
-- go below a last line that has none.
local function paste_place(
	buffer: greed.Buffer,
	range: greed.Range,
	after: boolean,
	piece: string,
	linewise: boolean
): (number, string)
	local from, to = span(range)
	if not linewise then
		return (if after then to else from), piece
	end
	if not after then
		return buffer:line_start(buffer:line_of(from)), piece
	end
	local line = buffer:line_of(math.max(from, to - 1))
	if line + 1 < buffer:line_count() then
		return buffer:line_start(line + 1), piece
	end
	return buffer:line_end(line), text.line_break(buffer) .. string.sub(piece, 1, -2)
end

-- Pastes the latest copy before or after each selection, and selects what
-- was pasted. With as many pieces as selections, each selection gets its
-- own piece.
local function paste(ctx: greed.Context, after: boolean)
	writable.cursor(ctx.view)
	local register = registers.paste(ctx)
	if register == nil then
		return
	end
	local pieces = register.pieces
	local one_each = #pieces == #ctx.view:selection().ranges
	local joined = registers.join(register)
	motions.replace_each(ctx.view, function(i, range)
		local piece = string.rep(if one_each then pieces[i] else joined, ctx.count or 1)
		local at, inserted =
			paste_place(ctx.buffer, on_cursor(ctx.buffer, range), after, piece, register.linewise)
		return { text = inserted, from = at, to = at }
	end)
end

greed.command({
	name = "copy",
	doc = "Copy each selection to the clipboard",
	run = function(ctx)
		copy_selections(ctx)
	end,
})

greed.command({
	name = "cut",
	doc = "Copy each selection to the clipboard and delete it",
	run = function(ctx)
		if copy_selections(ctx) then
			delete_selections(ctx)
		end
	end,
})

greed.command({
	name = "paste-after",
	doc = "Paste after each selection",
	run = function(ctx)
		paste(ctx, true)
	end,
})

greed.command({
	name = "paste-before",
	doc = "Paste before each selection",
	run = function(ctx)
		paste(ctx, false)
	end,
})

greed.command({
	name = "delete",
	doc = "Copy each selection and delete it",
	run = function(ctx)
		copy_selections(ctx, true)
		delete_selections(ctx)
	end,
})

greed.command({
	name = "delete-without-copy",
	doc = "Delete each selection, leaving the clipboard alone",
	run = delete_selections,
})

greed.command({
	name = "change",
	doc = "Copy each selection, delete it and switch to insert mode",
	run = function(ctx)
		greed.history.start_group()
		copy_selections(ctx, true)
		delete_selections(ctx)
		enter_insert()
	end,
})

greed.command({
	name = "change-without-copy",
	doc = "Delete each selection and switch to insert mode, leaving the clipboard alone",
	run = function(ctx)
		greed.history.start_group()
		delete_selections(ctx)
		enter_insert()
	end,
})

greed.option.define({
	name = "text-width",
	doc = "How wide :reflow (and Vim's gq) makes lines",
	default = 80,
})

greed.command({
	name = "reflow",
	doc = "Rewrap the lines of each selection to the text width, or the width given",
	args = {
		{
			name = "width",
			doc = "Columns; the text-width option without",
			type = "number",
			optional = true,
		},
	},
	run = function(ctx)
		local width: number = ctx.values.width or greed.option.get("text-width") :: number
		local buffer = ctx.buffer
		buffer:edit(function(e)
			for _, range in ctx.view:selection().ranges do
				local from, to = span(range)
				local first, last = buffer:line_of(from), buffer:line_of(math.max(from, to - 1))
				local start, stop = buffer:line_start(first), buffer:line_end(last)
				e:replace(start, stop, text.reflow(buffer:slice(start, stop), width))
			end
		end)
	end,
})

greed.command({
	name = "reindent-lines",
	doc = "Indent each selected line as its language and the lines around it say",
	run = function(ctx)
		local buffer = ctx.buffer
		local lines = motions.selected_lines(ctx)
		-- Line by line, so each one is indented after the ones above it.
		for _, line in lines do
			local start = buffer:line_start(line)
			local current = indent.of(buffer, line)
			local wanted = indent.at(buffer, start + #current)
			if wanted ~= current and buffer:line_end(line) > start + #current then
				buffer:edit(function(e)
					e:replace(start, start + #current, wanted)
				end)
			end
		end
	end,
})

greed.option.define({
	name = "indent",
	doc = "One level of indent, spaces or a tab, in languages that don't set their own",
	default = "    ",
})

-- Replaces the text of each selection (or the character under each cursor)
-- with `change(text)`, keeping the selections around the new text.
local function transform(ctx: greed.Context, change: (string) -> string)
	local buffer = ctx.buffer
	motions.replace_each(ctx.view, function(_, range)
		local a, b = span(range)
		if a == b then
			b = text.after(buffer, a)
		end
		return { text = change(buffer:slice(a, b)), place = "keep", from = a, to = b }
	end)
end

greed.command({
	name = "replace-char",
	doc = "Replace every selected character with the next one typed",
	run = function(ctx)
		local key = greed.next_key()
		local char = if key == "enter"
			then text.line_break(ctx.buffer)
			elseif key == "tab" then "\t"
			else key
		if utf8.len(key) ~= 1 and char == key then
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

greed.command({
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

greed.command({
	name = "lowercase",
	doc = "Make the selections lowercase",
	run = function(ctx)
		transform(ctx, string.lower)
	end,
})

greed.command({
	name = "uppercase",
	doc = "Make the selections uppercase",
	run = function(ctx)
		transform(ctx, string.upper)
	end,
})

greed.command({
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
		motions.insert_at(ctx, starts, string.rep(unit, ctx.count or 1))
	end,
})

greed.command({
	name = "dedent",
	doc = "Take one level of indent off the lines of each selection",
	run = function(ctx)
		local width = #indent.unit(ctx.buffer)
		local buffer = ctx.buffer
		buffer:edit(function(e)
			for _, line in motions.selected_lines(ctx) do
				local start = buffer:line_start(line)
				local lead = indent.of(buffer, line)
				local take = 0
				-- A tab or a unit's worth of spaces per level.
				for _ = 1, ctx.count or 1 do
					local rest = string.sub(lead, take + 1)
					take += if string.sub(rest, 1, 1) == "\t" then 1 else math.min(#rest, width)
				end
				if take > 0 then
					e:delete(start, start + take)
				end
			end
		end)
	end,
})

-- Adds an empty line above or below each selection's lines, `count` of
-- them, leaving the selections where they are.
for _, above in { false, true } do
	greed.command({
		name = if above then "add-newline-above" else "add-newline-below",
		doc = if above
			then "Add an empty line above each selection, staying put"
			else "Add an empty line below each selection, staying put",
		run = function(ctx)
			local buffer = ctx.buffer
			local points, seen = {}, {}
			for _, range in ctx.view:selection().ranges do
				local from, to = span(range)
				local line = buffer:line_of(if above then from else math.max(from, to - 1))
				local at = if above then buffer:line_start(line) else buffer:line_end(line)
				if not seen[at] then
					seen[at] = true
					table.insert(points, at)
				end
			end
			local breaks = string.rep(text.line_break(buffer), ctx.count or 1)
			-- Lines added above a selection's start go before it.
			motions.insert_at(ctx, points, breaks, above)
		end,
	})
end

greed.command({
	name = "join-lines",
	doc = "Join the next line onto each cursor's, or the lines of each selection, with one space",
	run = function(ctx)
		local buffer = ctx.buffer
		local joins = {}
		for _, range in ctx.view:selection().ranges do
			local from, to = span(range)
			local first, last = buffer:line_of(from), buffer:line_of(to)
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

greed.command({
	name = "insert-line-start",
	doc = "Insert at the start of each line, after its indent",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			return point(text.first_non_blank(buffer, range.head))
		end)
		enter_insert()
	end,
})

greed.command({
	name = "append-line-end",
	doc = "Insert at the end of each line",
	run = function(ctx)
		each_range(ctx, function(buffer, range)
			return point(buffer:line_end(buffer:line_of(range.head)))
		end)
		enter_insert()
	end,
})

greed.command({
	name = "replace-with-copy",
	doc = "Replace each selection with what was copied",
	run = function(ctx)
		local register = registers.paste(ctx)
		if register == nil then
			return
		end
		local pieces = register.pieces
		local count = #ctx.view:selection().ranges
		local joined = registers.join(register)
		local i = 0
		transform(ctx, function()
			i += 1
			return if #pieces == count then pieces[i] else joined
		end)
	end,
})

return {}
