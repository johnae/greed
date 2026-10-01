-- Vim-style editing, written only against the plugin API. It has modes of
-- its own (vim, vim-insert and vim-visual), so it sits beside Helix's
-- normal mode instead of replacing it, and borrows the space-leader keys,
-- ":", search and the language server keys from normal mode.
--
-- Switch to it with `:style vim`, or put this in ~/.config/kern/init.luau:
--
--     require("@kern").option.set("editing-style", "vim")
--
-- What's here: counts, h j k l w b e 0 ^ $ gg G f t F T, the operators
-- d c y with any of those motions (and dd cc yy, iw aw), x X D C s S,
-- p P, i a I A o O, u ctrl-r, v, and . to repeat the last change that
-- didn't type text.

local kern = require("@kern")

type Buffer = kern.Buffer

-- How a motion's range is taken: up to but not including the target, up
-- to and including it, or whole lines.
type Kind = "exclusive" | "inclusive" | "line"

-- Where a motion goes from `pos`, done `count` times.
type Motion = (buffer: Buffer, pos: number, count: number) -> (number?, Kind)

-- What `y` and `d` last took, and whether it was whole lines.
local register = { text = "", linewise = false }

-- Repeats the last change for ".", with the count given to it.
local last_change: ((ctx: kern.Context, count: number?) -> ())? = nil

-- Text helpers -----------------------------------------------------------

local function class(ch: string?): string
	if ch == nil or ch == "\n" then
		return "eol"
	elseif ch == " " or ch == "\t" then
		return "space"
	elseif #ch > 1 or string.match(ch, "[%w_]") then
		return "word"
	end
	return "punct"
end

local function is_blank(buffer: Buffer, pos: number): boolean
	local of = class(buffer:char_at(pos))
	return of == "space" or of == "eol"
end

local function line_bounds(buffer: Buffer, pos: number): (number, number, number)
	local line = buffer:line_of(pos)
	return line, buffer:line_start(line), buffer:line_end(line)
end

-- In normal mode the cursor sits on a character, so not past the last one.
local function on_char(buffer: Buffer, pos: number): number
	local _, start, finish = line_bounds(buffer, pos)
	if pos >= finish and finish > start then
		return buffer:prev_char(finish)
	end
	return math.min(pos, finish)
end

local function first_non_blank(buffer: Buffer, line: number): number
	local pos, finish = buffer:line_start(line), buffer:line_end(line)
	while pos < finish and class(buffer:char_at(pos)) == "space" do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The column of `pos` in characters, and the position `column` characters
-- into `line`, stopping at its end.
local function column_of(buffer: Buffer, pos: number): number
	local _, start = line_bounds(buffer, pos)
	local column = 0
	while start < pos do
		start = buffer:next_char(start)
		column += 1
	end
	return column
end

local function at_column(buffer: Buffer, line: number, column: number): number
	local pos, finish = buffer:line_start(line), buffer:line_end(line)
	for _ = 1, column do
		if pos >= finish then
			break
		end
		pos = buffer:next_char(pos)
	end
	return pos
end

-- The column j and k aim for, kept while moving through shorter lines.
local wanted: number? = nil

local function wanted_column(buffer: Buffer, pos: number): number
	local column = wanted or column_of(buffer, pos)
	wanted = column
	return column
end

-- Any command other than j and k forgets the column.
kern.on("command.run", function(event: kern.CommandRun)
	if event.name ~= "vim-motion-j" and event.name ~= "vim-motion-k" then
		wanted = nil
	end
end)

local function cursor(ctx: kern.Context): number
	local selection = ctx.view:selection()
	return selection.ranges[selection.primary].head
end

local function point(pos: number): kern.Selection
	return { ranges = { { anchor = pos, head = pos } }, primary = 1 }
end

-- Motions -----------------------------------------------------------------

local function repeat_step(step: (Buffer, number) -> number?): Motion
	return function(buffer, pos, count)
		for _ = 1, count do
			local next = step(buffer, pos)
			if next == nil then
				break
			end
			pos = next
		end
		return pos, "exclusive"
	end
end

local function next_word_start(buffer: Buffer, pos: number): number?
	local len = buffer:len()
	if pos >= len then
		return nil
	end
	local from = class(buffer:char_at(pos))
	while pos < len and class(buffer:char_at(pos)) == from and from ~= "space" and from ~= "eol" do
		pos = buffer:next_char(pos)
	end
	while pos < len and is_blank(buffer, pos) do
		pos = buffer:next_char(pos)
	end
	return pos
end

local function prev_word_start(buffer: Buffer, pos: number): number?
	if pos == 0 then
		return nil
	end
	pos = buffer:prev_char(pos)
	while pos > 0 and is_blank(buffer, pos) do
		pos = buffer:prev_char(pos)
	end
	local of = class(buffer:char_at(pos))
	while pos > 0 and class(buffer:char_at(buffer:prev_char(pos))) == of do
		pos = buffer:prev_char(pos)
	end
	return pos
end

local function word_end(buffer: Buffer, pos: number): number?
	local len = buffer:len()
	local next = buffer:next_char(pos)
	if next >= len then
		return nil
	end
	pos = next
	while pos < len and is_blank(buffer, pos) do
		pos = buffer:next_char(pos)
	end
	local of = class(buffer:char_at(pos))
	while buffer:next_char(pos) < len and class(buffer:char_at(buffer:next_char(pos))) == of do
		pos = buffer:next_char(pos)
	end
	return pos
end

-- Finds `count`-th `char` on the line: forward or back, landing on it or
-- (`before`) next to it.
local function find_char(forward: boolean, before: boolean): Motion
	return function(buffer, pos, count)
		local char = kern.next_key()
		local _, start, finish = line_bounds(buffer, pos)
		local at = pos
		for _ = 1, count do
			repeat
				at = if forward
					then buffer:next_char(at)
					else (if at > start then buffer:prev_char(at) else -1)
			until at < 0 or at >= finish or buffer:char_at(at) == char
			if at < 0 or at >= finish then
				return nil, "inclusive"
			end
		end
		if before then
			at = if forward then buffer:prev_char(at) else buffer:next_char(at)
		end
		return at, if forward then "inclusive" else "exclusive"
	end
end

local motions: { [string]: Motion } = {
	h = function(buffer, pos, count)
		local _, start = line_bounds(buffer, pos)
		for _ = 1, count do
			if pos > start then
				pos = buffer:prev_char(pos)
			end
		end
		return pos, "exclusive"
	end,
	l = function(buffer, pos, count)
		local _, _, finish = line_bounds(buffer, pos)
		for _ = 1, count do
			if pos < finish then
				pos = buffer:next_char(pos)
			end
		end
		return pos, "exclusive"
	end,
	j = function(buffer, pos, count)
		local line = math.min(buffer:line_of(pos) + count, buffer:line_count() - 1)
		return at_column(buffer, line, wanted_column(buffer, pos)), "line"
	end,
	k = function(buffer, pos, count)
		local line = math.max(buffer:line_of(pos) - count, 0)
		return at_column(buffer, line, wanted_column(buffer, pos)), "line"
	end,
	w = repeat_step(next_word_start),
	b = repeat_step(prev_word_start),
	e = function(buffer, pos, count)
		local target = repeat_step(word_end)(buffer, pos, count)
		return target, "inclusive"
	end,
	["0"] = function(buffer, pos)
		local _, start = line_bounds(buffer, pos)
		return start, "exclusive"
	end,
	["^"] = function(buffer, pos)
		return first_non_blank(buffer, buffer:line_of(pos)), "exclusive"
	end,
	["$"] = function(buffer, pos)
		local _, start, finish = line_bounds(buffer, pos)
		return if finish > start then buffer:prev_char(finish) else start, "inclusive"
	end,
	f = find_char(true, false),
	t = find_char(true, true),
	F = find_char(false, false),
	T = find_char(false, true),
}

-- G goes to line `count`, or the last line; gg to line `count`, or the first.
local function goto_line(first: boolean): Motion
	return function(buffer, _, count)
		local last = buffer:line_count() - 1
		local line = if count > 0 then math.min(count - 1, last) elseif first then 0 else last
		return first_non_blank(buffer, line), "line"
	end
end
motions.G = goto_line(false)
motions["g g"] = goto_line(true)

-- Ranges ------------------------------------------------------------------

-- The text a motion covers from `pos`, as `from, to, linewise`.
local function motion_range(
	buffer: Buffer,
	pos: number,
	target: number,
	kind: Kind
): (number, number, boolean)
	local from, to = math.min(pos, target), math.max(pos, target)
	if kind == "inclusive" then
		to = math.min(buffer:next_char(to), buffer:len())
	elseif kind == "line" then
		local last = buffer:line_of(to)
		from = buffer:line_start(buffer:line_of(from))
		if last + 1 < buffer:line_count() then
			to = buffer:line_start(last + 1)
		else
			-- Deleting the last lines takes the line break before them instead.
			to = buffer:len()
			if from > 0 then
				from = buffer:prev_char(from)
			end
		end
		return from, to, true
	end
	return from, to, false
end

-- The word around `pos`, with the spaces after it for "a word".
local function word_object(buffer: Buffer, pos: number, around: boolean): (number, number)
	local of = class(buffer:char_at(pos))
	local from, to = pos, pos
	while from > 0 and class(buffer:char_at(buffer:prev_char(from))) == of do
		from = buffer:prev_char(from)
	end
	local len = buffer:len()
	while to < len and class(buffer:char_at(to)) == of do
		to = buffer:next_char(to)
	end
	if around then
		while to < len and class(buffer:char_at(to)) == "space" do
			to = buffer:next_char(to)
		end
	end
	return from, to
end

-- Operators ---------------------------------------------------------------

local function enter_insert(ctx: kern.Context, pos: number)
	ctx.view:set_selection(point(pos))
	kern.mode.set("vim-insert")
end

-- Applies operator `op` ("d", "c" or "y") to `from`..`to`.
local function apply(ctx: kern.Context, op: string, from: number, to: number, linewise: boolean)
	local buffer = ctx.buffer
	register = { text = buffer:slice(from, to), linewise = linewise }
	kern.clipboard.set(register.text)
	if op == "y" then
		ctx.view:set_selection(point(on_char(buffer, from)))
		return
	end
	if op == "c" then
		kern.history.start_group()
		if linewise then
			-- Changing lines keeps one empty line to type on.
			local first = buffer:line_of(
				if from > 0 and buffer:char_at(from) == "\n" then buffer:next_char(from) else from
			)
			from, to =
				buffer:line_start(first), buffer:line_end(buffer:line_of(math.max(to - 1, from)))
		end
	end
	local start, finish = from, to :: number
	buffer:edit(function(e)
		e:delete(start, finish)
		e:select(point(start))
	end)
	if op == "c" then
		enter_insert(ctx, from)
	elseif linewise then
		ctx.view:set_selection(
			point(first_non_blank(buffer, buffer:line_of(math.min(from + 1, buffer:len()))))
		)
	else
		ctx.view:set_selection(point(on_char(buffer, from)))
	end
end

-- Reads digits as a count, then returns the key after them and the count.
local function read_count(): (string, number?)
	local key = kern.next_key()
	local count: number? = nil
	while string.match(key, "^%d$") and (count or key ~= "0") do
		count = (count or 0) * 10 + (tonumber(key) :: number)
		key = kern.next_key()
	end
	return key, count
end

-- Runs operator `op` with the motion or object typed after it.
local function operate(ctx: kern.Context, op: string)
	local key, inner_count = read_count()
	local count = (ctx.count or 1) * (inner_count or 1)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local from: number, to: number, linewise: boolean
	if key == op then
		local line = buffer:line_of(pos)
		from, to, linewise = motion_range(
			buffer,
			pos,
			buffer:line_start(math.min(line + count - 1, buffer:line_count() - 1)),
			"line"
		)
	elseif key == "i" or key == "a" then
		if kern.next_key() ~= "w" then
			return
		end
		from, to = word_object(buffer, pos, key == "a")
		linewise = false
	else
		if key == "g" then
			key = "g " .. kern.next_key()
		end
		-- "cw" changes to the end of the word, as in Vim.
		if op == "c" and key == "w" and class(buffer:char_at(pos)) ~= "space" then
			key = "e"
		end
		local motion = motions[key]
		if motion == nil then
			return
		end
		local target, kind = motion(
			buffer,
			pos,
			if inner_count or ctx.count then count else (if key == "G" then 0 else 1)
		)
		if target == nil then
			return
		end
		from, to, linewise = motion_range(buffer, pos, target, kind)
	end
	apply(ctx, op, from, to, linewise)
	if op == "d" then
		last_change = function(c)
			local at = cursor(c)
			apply(c, "d", at, math.min(at + to - from, c.buffer:len()), linewise)
		end
	end
end

-- Commands ----------------------------------------------------------------

local function command(name: string, doc: string, run: (ctx: kern.Context) -> ())
	kern.command({ name = "vim-" .. name, doc = doc, run = run })
end

-- Motions move the cursor, or extend the selection in visual mode.
for key, motion in motions do
	command("motion-" .. string.gsub(key, " ", ""), "Vim motion " .. key, function(ctx)
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local target = motion(ctx.buffer, range.head, ctx.count or (if key == "G" then 0 else 1))
		if target == nil then
			return
		end
		if kern.mode.get() == "vim-visual" then
			ctx.view:set_selection({
				ranges = { { anchor = range.anchor, head = target } },
				primary = 1,
			})
		else
			ctx.view:set_selection(point(on_char(ctx.buffer, target)))
		end
	end)
end

for _, op in { "d", "c", "y" } do
	command("operator-" .. op, "Vim operator " .. op .. ", followed by a motion", function(ctx)
		if kern.mode.get() == "vim-visual" then
			local range = ctx.view:selection().ranges[1]
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			kern.mode.set("vim")
			apply(ctx, op, from, math.min(ctx.buffer:next_char(to), ctx.buffer:len()), false)
			return
		end
		operate(ctx, op)
	end)
end

-- Shorthands for an operator and a motion: x is dl, D is d$, and so on.
local function shorthand(name: string, op: string, key: string, doc: string)
	command(name, doc, function(ctx)
		local buffer, pos = ctx.buffer, cursor(ctx)
		local target, kind = motions[key](buffer, pos, ctx.count or 1)
		if target == nil or (target == pos and kind == "exclusive") then
			return
		end
		apply(ctx, op, motion_range(buffer, pos, target :: number, kind))
		if op == "d" then
			last_change = function(c: kern.Context, count: number?)
				local at = cursor(c)
				local target, kind = motions[key](c.buffer, at, count or ctx.count or 1)
				if target then
					apply(c, "d", motion_range(c.buffer, at, target, kind))
				end
			end
		end
	end)
end
shorthand("delete-char", "d", "l", "Delete the character under the cursor")
shorthand("delete-char-before", "d", "h", "Delete the character before the cursor")
shorthand("delete-to-end", "d", "$", "Delete to the end of the line")
shorthand("change-to-end", "c", "$", "Change to the end of the line")
shorthand("substitute", "c", "l", "Change the character under the cursor")

command("change-line", "Change the whole line", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local line = buffer:line_of(pos)
	kern.history.start_group()
	local from, to = first_non_blank(buffer, line), buffer:line_end(line)
	buffer:edit(function(e)
		e:delete(from, to)
	end)
	enter_insert(ctx, from)
end)

local function paste(ctx: kern.Context, after: boolean)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local text = string.rep(register.text, ctx.count or 1)
	local at: number
	if register.linewise then
		local line = buffer:line_of(pos)
		if after then
			at = if line + 1 < buffer:line_count()
				then buffer:line_start(line + 1)
				else buffer:len()
			if
				at == buffer:len()
				and string.sub(text, -1) == "\n"
				and buffer:char_at(at - 1) ~= "\n"
			then
				text = "\n" .. string.sub(text, 1, -2)
			end
		else
			at = buffer:line_start(line)
		end
	else
		at = if after
			then math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos)))
			else pos
	end
	buffer:edit(function(e)
		e:insert(at, text)
	end)
	if register.linewise then
		ctx.view:set_selection(
			point(
				first_non_blank(
					buffer,
					buffer:line_of(if string.sub(text, 1, 1) == "\n" then at + 1 else at)
				)
			)
		)
	else
		ctx.view:set_selection(point(buffer:prev_char(at + #text)))
	end
end

command("paste-after", "Paste after the cursor, or below the line", function(ctx)
	paste(ctx, true)
end)
command("paste-before", "Paste before the cursor, or above the line", function(ctx)
	paste(ctx, false)
end)

command("insert", "Insert before the cursor", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, cursor(ctx))
end)
command("append", "Insert after the cursor", function(ctx)
	kern.history.start_group()
	local buffer, pos = ctx.buffer, cursor(ctx)
	enter_insert(ctx, math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos))))
end)
command("insert-line-start", "Insert at the first non-blank of the line", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, first_non_blank(ctx.buffer, ctx.buffer:line_of(cursor(ctx))))
end)
command("append-line-end", "Insert at the end of the line", function(ctx)
	kern.history.start_group()
	enter_insert(ctx, ctx.buffer:line_end(ctx.buffer:line_of(cursor(ctx))))
end)

local function open_line(ctx: kern.Context, below: boolean)
	kern.history.start_group()
	local buffer = ctx.buffer
	local line = buffer:line_of(cursor(ctx))
	local at = if below then buffer:line_end(line) else buffer:line_start(line)
	buffer:edit(function(e)
		e:insert(at, "\n")
	end)
	enter_insert(ctx, if below then at + 1 else at)
end
command("open-below", "Open a line below and insert", function(ctx)
	open_line(ctx, true)
end)
command("open-above", "Open a line above and insert", function(ctx)
	open_line(ctx, false)
end)

command("normal", "Back to normal mode", function(ctx)
	kern.history.end_group()
	local was_insert = kern.mode.get() == "vim-insert"
	kern.mode.set("vim")
	local buffer, pos = ctx.buffer, cursor(ctx)
	local _, start = line_bounds(buffer, pos)
	-- Leaving insert mode steps back onto the last character typed.
	if was_insert and pos > start then
		pos = buffer:prev_char(pos)
	end
	ctx.view:set_selection(point(on_char(buffer, pos)))
end)

command("visual", "Select characters, starting here", function(ctx)
	ctx.view:set_selection(point(cursor(ctx)))
	kern.mode.set("vim-visual")
end)

command("undo", "Undo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:undo()
	end
	ctx.view:set_selection(point(on_char(ctx.buffer, cursor(ctx))))
end)
command("redo", "Redo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:redo()
	end
end)

command("repeat", "Repeat the last change", function(ctx)
	local change = last_change
	if change then
		change(ctx, ctx.count)
	end
end)

-- Keys --------------------------------------------------------------------

-- Keys other plugins put in normal mode that work the same here: the
-- space-leader keys, the command line, search, and going to definitions
-- and problems. Plugins loaded later get them too.
kern.keymap.inherit("vim", "normal", { "space", ":", "/", "?", "n", "N", "*", "g d", "]", "[" })
-- Insert mode as everyone has it, except that esc comes back here.
kern.keymap.inherit("vim-insert", "insert")
kern.keymap.fallback("vim-insert", "insert-char")
kern.mode.cursor("vim-insert", "bar")

local keys: { [string]: string } = {
	d = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	x = "vim-delete-char",
	X = "vim-delete-char-before",
	D = "vim-delete-to-end",
	C = "vim-change-to-end",
	s = "vim-substitute",
	S = "vim-change-line",
	p = "vim-paste-after",
	P = "vim-paste-before",
	i = "vim-insert",
	a = "vim-append",
	I = "vim-insert-line-start",
	A = "vim-append-line-end",
	o = "vim-open-below",
	O = "vim-open-above",
	v = "vim-visual",
	u = "vim-undo",
	["ctrl-r"] = "vim-redo",
	["."] = "vim-repeat",
}
local visual: { [string]: string } = {
	d = "vim-operator-d",
	x = "vim-operator-d",
	c = "vim-operator-c",
	y = "vim-operator-y",
	esc = "vim-normal",
	v = "vim-normal",
}
for key in motions do
	keys[key] = "vim-motion-" .. string.gsub(key, " ", "")
	visual[key] = keys[key]
end
kern.keymap.bind("vim", keys)
kern.keymap.bind("vim-visual", visual)
kern.keymap.bind("vim-insert", { esc = "vim-normal" })
kern.keymap.counts("vim")
kern.keymap.counts("vim-visual")

require("@core").style.define({
	name = "vim",
	doc = "Vim's operators and motions, with a visual mode",
	mode = "vim",
	labels = { vim = "normal", ["vim-insert"] = "insert", ["vim-visual"] = "visual" },
	plugin = "vim",
})

return {}
