-- Operators, applied through `apply` and the line and case tables, and
-- the registers they keep what they take in.

local greed = require("@greed")
local core = require("@core")
local common = require("./common")
local motions_module = require("./motions")
local objects = require("./objects")

type Buffer = greed.Buffer
type Kind = common.Kind

local cursor, on_char, point = common.cursor, common.on_char, common.point
local motions, COUNTLESS = motions_module.motions, motions_module.COUNTLESS
local word_class, word_end = motions_module.word_class, motions_module.word_end
local motion_range, text_object = objects.motion_range, objects.text_object

-- What 3i and 3o type again when insert mode ends: the count, where typing
-- began, and whether it opened a line.
local insert_repeat = { count = 1, start = 0, open = false }

local function enter_insert(ctx: greed.Context, pos: number)
	ctx.view:set_cursor(pos)
	greed.mode.set("vim-insert")
	insert_repeat.count, insert_repeat.start, insert_repeat.open = 1, pos, false
end

-- Operators that work on whole lines through core's commands.
local LINE_OPERATORS: { [string]: string } = {
	[">"] = "indent",
	["<"] = "dedent",
	["gc"] = "toggle-comment",
	["gq"] = "reflow",
	["gw"] = "reflow",
	["="] = "reindent-lines",
	["!"] = "pipe",
	["zf"] = "fold-selection",
}

-- Operators that rewrite the text they cover, character by character.
local CASE_OPERATORS: { [string]: (string) -> string } = {
	["g~"] = function(text)
		return (
			string.gsub(text, "%a", function(c)
				return if string.match(c, "%l") then string.upper(c) else string.lower(c)
			end)
		)
	end,
	gu = string.lower,
	gU = string.upper,
	["g?"] = function(text)
		return (
			string.gsub(text, "%a", function(c)
				local base = if string.match(c, "%l") then 97 else 65
				return string.char((string.byte(c) - base + 13) % 26 + base)
			end)
		)
	end,
}

-- Runs core's `command` on the lines `from`..`to` touch, keeping the cursor
-- on the same character (or the line's first, for indents).
local function on_lines(ctx: greed.Context, command: string, from: number, to: number, op: string?)
	local buffer = ctx.buffer
	-- A linewise range at the end of the buffer starts with the break before it.
	if from < to and buffer:char_at(from) == "\n" then
		from += 1
	end
	local first, last = buffer:line_of(from), buffer:line_of(math.max(to - 1, from))
	local at = cursor(ctx)
	local line = buffer:line_of(at)
	local before = buffer:line_end(line) - buffer:line_start(line)
	ctx.view:set_selection({
		ranges = { { anchor = buffer:line_start(first), head = buffer:line_end(last) } },
		primary = 1,
	})
	greed.run(command)
	local grew = buffer:line_end(line) - buffer:line_start(line) - before
	if command == "toggle-comment" then
		at = math.clamp(at + grew, buffer:line_start(line), buffer:line_end(line))
	elseif op == "gw" then
		-- gw leaves the cursor where it was.
		at = math.min(at, buffer:len())
	else
		local top = buffer:line_start(math.min(first, buffer:line_count() - 1))
		at = core.text.first_non_blank(buffer, top)
	end
	ctx.view:set_cursor(on_char(buffer, at))
end

-- Whole lines as registers keep them, ending in a line break: lines taken
-- at the end of the buffer start with the break before them instead.
local function as_lines(text: string): string
	if string.sub(text, -1) == "\n" then
		return text
	end
	local br = string.match(text, "^\r?\n")
	if br then
		return string.sub(text, #br + 1) .. br
	end
	return text .. "\n"
end

-- Keeps what operator `op` took (whole lines with `linewise`) in the
-- register picked with ", or the clipboard. "_ keeps nothing, and an
-- uppercase letter adds to its lowercase one.
local function store(op: string, text: string, linewise: boolean)
	local registers = core.registers
	local name = registers.take()
	if name and string.match(name, "^%u$") then
		name = string.lower(name)
		local before = registers.get(name)
		if before then
			local joined = registers.join(before)
			-- Lines added to a register of text start on a line of their own.
			text = joined .. (if linewise and not before.linewise then "\n" else "") .. text
			linewise = linewise or before.linewise
		end
	end
	if linewise then
		text = as_lines(text)
	end
	if registers.is_clipboard(name) then
		registers.to_clipboard({ text }, linewise)
		-- The numbered registers, as Vim keeps them: "0 the last yank, "1 to
		-- "9 the last deletes of lines (older ones moving down), "- the last
		-- smaller delete.
		if op == "y" then
			registers.set("0", { text }, linewise)
		elseif linewise or string.find(text, "\n", 1, true) then
			for n = 9, 2, -1 do
				local older = registers.get(tostring(n - 1))
				if older then
					registers.set(tostring(n), older.pieces, older.linewise)
				end
			end
			registers.set("1", { text }, linewise)
		else
			registers.set("-", { text }, linewise)
		end
	elseif name ~= "_" then
		registers.set(name :: string, { text }, linewise)
	end
end

-- vim-surround's keys for brackets: b B r a stand for ( { [ <.
local PAIR_KEYS: { [string]: string } = { b = "(", B = "{", r = "[", a = "<" }

-- What ys, cs and visual S wrap text in for `char`: as vim-surround has
-- it, an opening bracket adds spaces inside, and a closing one or a letter
-- standing for one doesn't. Any other character goes on both sides.
local function pair_for(char: string): (string, string)
	return core.objects.pair(PAIR_KEYS[char] or char, PAIR_KEYS[char] == nil)
end

-- Wraps `from`..`to` in the pair for the key typed next; whole lines wrap
-- from their first non-blank to their end.
local function surround(ctx: greed.Context, from: number, to: number, linewise: boolean)
	local char = greed.next_key()
	if utf8.len(char) ~= 1 then
		return
	end
	local buffer = ctx.buffer
	if linewise then
		local first =
			buffer:line_of(if buffer:char_at(from) == "\n" and from < to then from + 1 else from)
		local last = buffer:line_of(math.max(from, to - 1))
		from, to =
			core.text.first_non_blank(buffer, buffer:line_start(first)), buffer:line_end(last)
	end
	local open, close = pair_for(char)
	local start, finish = from, to :: number
	buffer:edit(function(e)
		e:insert(start, open)
		e:insert(finish, close)
	end)
	ctx.view:set_cursor(from)
end

-- Applies operator `op` (one of "d", "c", "y", "ys" or LINE_OPERATORS) to `from`..`to`.
local function apply(ctx: greed.Context, op: string, from: number, to: number, linewise: boolean)
	local buffer = ctx.buffer
	if op == "ys" then
		surround(ctx, from, to, linewise)
		return
	end
	local line_command = LINE_OPERATORS[op]
	if line_command then
		on_lines(ctx, line_command, from, to, op)
		return
	end
	local case = CASE_OPERATORS[op]
	if case then
		local start, finish = from, to :: number
		local new = case(buffer:slice(start, finish))
		buffer:edit(function(e)
			e:replace(start, finish, new)
		end)
		ctx.view:set_cursor(on_char(buffer, from))
		return
	end
	store(op, buffer:slice(from, to), linewise)
	if op == "y" then
		-- Whole lines at the end start with the line break before them.
		local at = if linewise
				and to == buffer:len()
				and buffer:char_at(from) == "\n"
			then from + 1
			else from
		ctx.view:set_cursor(on_char(buffer, at))
		return
	end
	if op == "c" then
		greed.history.start_group()
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
		ctx.view:set_cursor(core.text.first_non_blank(buffer, math.min(from, buffer:len())))
	else
		ctx.view:set_cursor(on_char(buffer, from))
	end
end

-- The match of the last search that `pos` is in, or the next one round the
-- end: what gn takes.
local function search_match(buffer: Buffer, pos: number): (number?, number?)
	local last = core.search.last()
	if last == nil then
		return nil, nil
	end
	local pattern = core.search.smart_case(last)
	local start = buffer:line_start(buffer:line_of(pos))
	while start <= pos do
		local from, to = buffer:find(pattern, start)
		if from == nil or to == nil or from > pos then
			break
		elseif to > pos then
			return from, to
		end
		local next = math.max(to, buffer:next_char(from))
		if next <= start then
			break
		end
		start = next
	end
	local from, to = buffer:find(pattern, pos, { wrap = true })
	return from, to
end

-- Reads digits as a count, then returns the key after them and the count.
local function read_count(): (string, number?)
	local key = greed.next_key()
	local count: number? = nil
	while string.match(key, "^%d$") and (count or key ~= "0") do
		count = (count or 0) * 10 + (tonumber(key) :: number)
		key = greed.next_key()
	end
	return key, count
end

-- Runs operator `op` with the motion or object typed after it.
local function operate(ctx: greed.Context, op: string)
	local key, inner_count = read_count()
	local count = (ctx.count or 1) * (inner_count or 1)
	local buffer, pos = ctx.buffer, cursor(ctx)
	-- vim-surround's keys: ds( deletes a pair, cs"' changes one, and ys
	-- takes a motion or object and then the pair to wrap it in.
	if (op == "d" or op == "c") and key == "s" then
		local char = greed.next_key()
		local with = if op == "c" then greed.next_key() else nil
		local open, close = core.objects.around(buffer, pos, PAIR_KEYS[char] or char)
		if open == nil or close == nil then
			return
		end
		local new_open, new_close = "", ""
		if with then
			new_open, new_close = pair_for(with)
		end
		local start, finish = open :: number, close :: number
		buffer:edit(function(e)
			e:replace(start, buffer:next_char(start), new_open)
			e:replace(finish, buffer:next_char(finish), new_close)
		end)
		ctx.view:set_cursor(on_char(buffer, start))
		return
	elseif op == "y" and key == "s" then
		operate(ctx, "ys")
		return
	end
	local from: number, to: number, linewise: boolean
	-- The operator's last key again (dd, >>, gcc) means whole lines.
	if key == string.sub(op, -1) then
		local line = buffer:line_of(pos)
		from, to, linewise = motion_range(
			buffer,
			pos,
			buffer:line_start(math.min(line + count - 1, buffer:line_count() - 1)),
			"line"
		)
	elseif key == "i" or key == "a" then
		local found_from, found_to, object_linewise =
			text_object(buffer, pos, greed.next_key(), key == "a")
		if found_from == nil or found_to == nil then
			return
		end
		from, to, linewise = found_from, found_to, object_linewise
	else
		if key == "g" then
			key = "g " .. greed.next_key()
		end
		if key == "g n" then
			local found_from, found_to = search_match(buffer, pos)
			if found_from and found_to then
				apply(ctx, op, found_from, found_to, false)
			end
			return
		end
		local motion = motions[key]
		if motion == nil then
			return
		end
		local target: number?, kind: Kind = motion(
			buffer,
			pos,
			if inner_count or ctx.count then count else (if COUNTLESS[key] then 0 else 1)
		)
		if target == nil then
			return
		end
		local big = key == "W"
		local of = word_class(buffer:char_at(pos), big)
		if (key == "w" or big) and op == "c" and (of == "word" or of == "punct") then
			-- "cw" changes to the end of the word, even from its last character.
			target, kind = pos, "inclusive"
			while word_class(buffer:char_at(buffer:next_char(target)), big) == of do
				target = buffer:next_char(target)
			end
			for _ = 2, count do
				target = word_end(buffer, target, big) or target
			end
		elseif key == "w" or big then
			-- When the last word moved over ends a line, the operator stops at
			-- the line's end rather than taking the line break too.
			local before = if count > 1 then motion(buffer, pos, count - 1) or pos else pos
			local line = buffer:line_of(before)
			if buffer:line_of(target) > line then
				target = buffer:line_end(line)
			end
		end
		from, to, linewise = motion_range(buffer, pos, target, kind)
	end
	apply(ctx, op, from, to, linewise)
end

-- What p pastes: the register picked with " (an uppercase letter is its
-- lowercase one), or the clipboard, as one text. Nil for "_ or an empty
-- register.
local function to_paste(ctx: greed.Context): { text: string, linewise: boolean }?
	local registers = core.registers
	local name = registers.take()
	if name then
		registers.pick(if string.match(name, "^%u$") then string.lower(name) else name)
	end
	local register = registers.paste(ctx)
	return if register
		then { text = registers.join(register), linewise = register.linewise }
		else nil
end

return {
	insert_repeat = insert_repeat,
	enter_insert = enter_insert,
	LINE_OPERATORS = LINE_OPERATORS,
	CASE_OPERATORS = CASE_OPERATORS,
	on_lines = on_lines,
	store = store,
	surround = surround,
	apply = apply,
	search_match = search_match,
	operate = operate,
	to_paste = to_paste,
}
