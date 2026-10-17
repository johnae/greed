-- Snippets, in the syntax language servers and VS Code use: text with
-- places to fill in. `$1` and `${1}` are places tab goes to in order,
-- `${1:name}` one with text already there (typing replaces it), `${1|a,b|}`
-- one with choices (the first goes in), and `$0` where the cursor ends up.
-- The same number twice is filled in together. `$TM_FILENAME` and
-- `${CURRENT_YEAR}` are variables, `${NAME:text}` one with text for when
-- it has no value; `\$`, `\}` and `\\` are those characters as they are.
--
-- While a snippet is being filled in, tab goes to the next place and
-- shift-tab back. It ends at `$0` (or its end), and when you leave the
-- mode you type in.

local greed = require("@greed")
local comment = require("./comment")
local indent = require("./indent")
local style = require("./style")
local text = require("./text")

--- A place in a snippet's text: the `index`th tab goes to, from byte
--- `from` to `to` in it, with `choices` when it offers some.
export type Stop = { index: number, from: number, to: number, choices: { string }? }

--- A snippet read: its text with the syntax gone, and its places.
export type Parsed = { text: string, stops: { Stop } }

local M = {}

-- The variable called `name`'s value, or nil when it has none.
type Variables = (name: string) -> string?

-- Reads `s` from `i`, up to an unescaped "}" when `closing` (or the end):
-- the text, its places (from its start) and where reading stopped, on
-- the "}" or past the end.
local function read(
	s: string,
	i: number,
	closing: boolean,
	var: Variables
): (string, { Stop }, number)
	local parts: { string } = {}
	local stops: { Stop } = {}
	local len = 0
	local function add(piece: string, inner: { Stop }?)
		if inner then
			for _, place in inner do
				table.insert(stops, {
					index = place.index,
					from = place.from + len,
					to = place.to + len,
					choices = place.choices,
				})
			end
		end
		table.insert(parts, piece)
		len += #piece
	end
	local function stop(index: string, width: number, choices: { string }?)
		table.insert(
			stops,
			{ index = tonumber(index) :: number, from = len - width, to = len, choices = choices }
		)
	end
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			local next = string.sub(s, i + 1, i + 1)
			if next == "$" or next == "}" or next == "\\" then
				add(next)
				i += 2
			else
				add(c)
				i += 1
			end
		elseif c == "}" and closing then
			return table.concat(parts), stops, i
		elseif c ~= "$" then
			local run = string.match(s, "^[^\\$}]+", i) or c
			add(run)
			i += #run
		else
			local index, after = string.match(s, "^%$(%d+)()", i)
			if not index then
				index, after = string.match(s, "^%${(%d+)}()", i)
			end
			if index and after then
				stop(index, 0)
				i = after :: any
				continue
			end
			local placeholder, from = string.match(s, "^%${(%d+):()", i)
			if placeholder and from then
				local inner_text, inner, j = read(s, from :: any, true, var)
				add(inner_text, inner)
				stop(placeholder, #inner_text)
				i = j + 1
				continue
			end
			local choice, list = string.match(s, "^%${(%d+)|()", i)
			if choice and list then
				local close = string.find(s, "|}", list :: any, true)
				if close then
					local choices = {}
					for option in
						string.gmatch(string.sub(s, list :: any, close - 1) .. ",", "(.-),")
					do
						table.insert(choices, (string.gsub(option, "\\(.)", "%1")))
					end
					add(choices[1] or "")
					stop(choice, #(choices[1] or ""), choices)
					i = close + 2
					continue
				end
			end
			local name, past = string.match(s, "^%$([%a_][%w_]*)()", i)
			if not name then
				name, past = string.match(s, "^%${([%a_][%w_]*)}()", i)
			end
			if name and past then
				add(var(name) or name)
				i = past :: any
				continue
			end
			local named, fallback = string.match(s, "^%${([%a_][%w_]*):()", i)
			if named and fallback then
				local inner_text, inner, j = read(s, fallback :: any, true, var)
				local value = var(named)
				if value then
					add(value)
				else
					add(inner_text, inner)
				end
				i = j + 1
				continue
			end
			-- A transform, ${NAME/regex/format/}: the value as it is.
			local transformed, rest = string.match(s, "^%${([%a_][%w_]*)/()", i)
			local close = if rest then string.find(s, "}", rest :: any, true) else nil
			if transformed and close then
				add(var(transformed) or "")
				i = close + 1
				continue
			end
			add("$")
			i += 1
		end
	end
	return table.concat(parts), stops, i
end

--- Reads `snippet`, with each variable's value from `var` (none, by
--- default).
function M.parse(snippet: string, var: Variables?): Parsed
	local out, stops = read(snippet, 1, false, var or function()
		return nil
	end)
	return { text = out, stops = stops }
end

-- The variables a snippet put in at `from`..`to` in `buffer` can use.
local function variables(buffer: greed.Buffer, from: number, to: number): Variables
	local line = buffer:line_of(from)
	local path = buffer:path()
	local now = os.date("*t") :: any
	local word_from = text.prev_word_start(buffer, from)
	local values: { [string]: string? } = {
		TM_SELECTED_TEXT = buffer:slice(from, to),
		TM_CURRENT_LINE = buffer:line_text(line),
		TM_CURRENT_WORD = buffer:slice(math.min(word_from, from), from),
		TM_LINE_INDEX = tostring(line),
		TM_LINE_NUMBER = tostring(line + 1),
		TM_FILEPATH = path,
		TM_FILENAME = if path then string.match(path, "[^/]*$") else nil,
		TM_FILENAME_BASE = if path then string.match(path, "([^/]-)%.?[^%./]*$") else nil,
		TM_DIRECTORY = if path then string.match(path, "^(.*)/[^/]*$") else nil,
		LINE_COMMENT = comment.token(buffer:language()),
		CURRENT_YEAR = tostring(now.year),
		CURRENT_YEAR_SHORT = string.format("%02d", now.year % 100),
		CURRENT_MONTH = string.format("%02d", now.month),
		CURRENT_DATE = string.format("%02d", now.day),
		CURRENT_HOUR = string.format("%02d", now.hour),
		CURRENT_MINUTE = string.format("%02d", now.min),
		CURRENT_SECOND = string.format("%02d", now.sec),
		CURRENT_DAY_NAME = os.date("%A") :: string,
		CURRENT_MONTH_NAME = os.date("%B") :: string,
	}
	return function(name: string): string?
		return values[name]
	end
end

-- A place being filled in: the ranges its number covers, as they move with
-- edits.
type Group = { index: number, ranges: { greed.Tracked } }

-- A snippet being filled in: its places in the order tab goes to them,
-- the one it's at, and where it ends.
type Session = { groups: { Group }, at: number, final: greed.Anchor }

-- The snippet being filled in, by view.
local sessions: { [number]: Session } = {}

local function finish(view: greed.View)
	local session = sessions[view:id()]
	if session == nil then
		return
	end
	sessions[view:id()] = nil
	for _, group in session.groups do
		for _, range in group.ranges do
			range:forget()
		end
	end
	session.final:forget()
end

-- Selects group `n` of `view`'s snippet, or ends the snippet at its end
-- past the last. Returns false when nothing of the group is left.
local function go(view: greed.View, session: Session, n: number): boolean
	if n > #session.groups then
		local at = session.final:pos()
		finish(view)
		if at then
			view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end
		return true
	end
	local ranges = {}
	for _, range in session.groups[n].ranges do
		local from, to = range:range()
		if from and to then
			table.insert(ranges, { anchor = from, head = to })
		end
	end
	if #ranges == 0 then
		return false
	end
	session.at = n
	view:set_selection({ ranges = ranges, primary = 1 })
	if session.groups[n].index == 0 then
		finish(view)
	end
	return true
end

--- Puts `snippet` in place of `from`..`to` in `view`'s buffer, its lines
--- at the indent of the line it goes in and its tabs as the buffer's
--- indent, and selects its first place. With no places, the cursor goes
--- to its end.
function M.expand(view: greed.View, from: number, to: number, snippet: string)
	finish(view)
	local buffer = view:buffer()
	local lead = indent.of(buffer, buffer:line_of(from))
	local body = string.gsub(snippet, "\t", indent.unit(buffer))
	body = string.gsub(body, "\n", "\n" .. lead)
	local parsed = M.parse(body, variables(buffer, from, to))
	buffer:edit(function(e)
		e:replace(from, to, parsed.text)
	end)
	local by_index: { [number]: Group } = {}
	local groups: { Group } = {}
	for _, stop in parsed.stops do
		local group = by_index[stop.index]
		if group == nil then
			group = { index = stop.index, ranges = {} }
			by_index[stop.index] = group
			table.insert(groups, group)
		end
		table.insert(
			group.ranges,
			buffer:track_range(from + stop.from, from + stop.to, { from = "left", to = "right" })
		)
	end
	-- 1, 2, ... in order, and $0 last.
	table.sort(groups, function(a: Group, b: Group): boolean
		if (a.index == 0) ~= (b.index == 0) then
			return b.index == 0
		end
		return a.index < b.index
	end)
	local ending = from + #parsed.text
	if #groups == 0 then
		view:set_selection({ ranges = { { anchor = ending, head = ending } }, primary = 1 })
		return
	end
	sessions[view:id()] = { groups = groups, at = 0, final = buffer:track(ending) }
	M.move(view)
end

--- Whether a snippet is being filled in in `view`.
function M.active(view: greed.View): boolean
	return sessions[view:id()] ~= nil
end

--- Goes to the next place in `view`'s snippet, or back one with `back`.
--- Returns false, doing nothing, when no snippet is being filled in there.
function M.move(view: greed.View, back: boolean?): boolean
	local session = sessions[view:id()]
	if session == nil then
		return false
	end
	local step = if back then -1 else 1
	local n = session.at + step
	while n >= 1 and n <= #session.groups + 1 do
		if go(view, session, n) then
			return true
		end
		n += step
	end
	return true
end

--- When `view`'s selections are its snippet's place with its text still
--- there, deletes that text so what's typed replaces it, as typing over a
--- selection does where typing replaces it anyway. Returns whether it did.
function M.clear_place(view: greed.View): boolean
	local session = sessions[view:id()]
	local group = if session then session.groups[session.at] else nil
	if group == nil then
		return false
	end
	local ranges = view:selection().ranges
	if #ranges ~= #group.ranges then
		return false
	end
	for i, range in group.ranges do
		local from, to = range:range()
		local lo, hi = text.span(ranges[i])
		if from ~= lo or to ~= hi or from == to then
			return false
		end
	end
	view:buffer():edit(function(e)
		for _, range in ranges do
			e:delete(text.span(range))
		end
	end)
	return true
end

-- Leaving the mode typed in ends the snippet in the view typed in. A menu
-- over it, like completion's, has a mode named after the typing mode's,
-- which keeps its keys, and isn't leaving.
greed.on("mode.changed", function(event: greed.ModeChanged)
	if style.is_typing(event.to) or string.find(event.to, event.from, 1, true) then
		return
	end
	finish(greed.view())
end)

return M
