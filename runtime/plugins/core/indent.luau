-- Indentation for new lines: enter, `o` and `O` start the line at the
-- indent the code around it calls for.
--
-- With a language's "indents" query (`queries/<language>/indents.scm`), a
-- new line goes one level in from the line where the innermost node
-- captured as `@indent` around it starts, like a block or an argument
-- list. When the text moving onto it starts with an `@outdent` node, like
-- `}` or `end`, it lines up with that line instead. Without a query, a new
-- line keeps the indent of the line it came from, one level more after an
-- opening bracket. A plugin can indent a language its own way with
-- `providers`, as the languages plugin does for Python's colons.

local kern = require("@kern")
local syntax = require("./syntax")
local text = require("./text")

type Buffer = kern.Buffer

local M = {}

--- The indent for a new line starting at `pos`, where a line break goes
--- in, and whether the text moving onto it closes a block (so it lines up
--- with the block's first line).
export type Provider = (buffer: Buffer, pos: number) -> (string, boolean)

--- Providers by language, used instead of the query and the fallback.
M.providers = {} :: { [string]: Provider }

--- One level of indent in each language, e.g. "  " or "\t", as the
--- languages plugin sets it.
M.units = {} :: { [string]: string }

--- One level of indent in `buffer`: its language's, or the "indent" option.
function M.unit(buffer: Buffer): string
	local language = buffer:language()
	return language and M.units[language] or kern.option.get("indent") :: string
end

--- The indent `line` starts with.
function M.of(buffer: Buffer, line: number): string
	local start = buffer:line_start(line)
	return string.match(buffer:slice(start, buffer:line_end(line)), "^[ \t]*") :: string
end

-- Whether `node` is open at `pos`: it holds it, or ends there missing its
-- closing token, as while typing a block.
local function open_at(node: kern.Node, pos: number): boolean
	if node.from >= pos then
		return false
	elseif pos < node.to then
		return true
	end
	local children = node:children()
	local last = children[#children]
	return last ~= nil and last.error and last.from == last.to
end

local function from_query(buffer: Buffer, pos: number, source: string): (string, boolean)
	local finish = buffer:line_end(buffer:line_of(pos))
	local rest = buffer:slice(pos, finish)
	local closer = pos + #(string.match(rest, "^[ \t]*") :: string)
	local inner: kern.Node? = nil
	local closes = false
	for _, match in buffer:query(source, { from = pos, to = finish }) do
		local node = match.indent
		if node and open_at(node, pos) and (inner == nil or node.from >= inner.from) then
			inner = node
		end
		local outdent = match.outdent
		if outdent and outdent.from == closer then
			closes = true
		end
	end
	if inner == nil then
		return "", closes
	end
	local base = M.of(buffer, buffer:line_of(inner.from))
	return if closes then base else base .. M.unit(buffer), closes
end

--- A provider that keeps the indent of the line being broken, one level
--- more when what's before the break ends with a match of `opener` (a Luau
--- pattern), e.g. "[%(%[{:]" for brackets and Python's colons. Before a
--- closing bracket it closes a block.
function M.by_line(opener: string): Provider
	local ends = opener .. "[ \t]*$"
	return function(buffer: Buffer, pos: number): (string, boolean)
		local line = buffer:line_of(pos)
		local before = buffer:slice(buffer:line_start(line), pos)
		local after = buffer:slice(pos, buffer:line_end(line))
		local base = M.of(buffer, line)
		local closes = string.match(after, "^[ \t]*[%)%]}]") ~= nil
		if string.match(before, ends) and not closes then
			return base .. M.unit(buffer), false
		end
		return base, closes
	end
end

local from_line = M.by_line("[%(%[{]")

--- The indent for a new line starting at `pos`, and whether the text
--- moving onto it closes a block.
function M.at(buffer: Buffer, pos: number): (string, boolean)
	local language = buffer:language()
	local provider = language and M.providers[language]
	if provider then
		return provider(buffer, pos)
	end
	local source = syntax.query(buffer, "indents")
	if source then
		return from_query(buffer, pos, source)
	end
	return from_line(buffer, pos)
end

-- Breaks the line at each cursor, as `M.break_lines` says; the cursors in
-- `above` instead get a line put in above the first one.
local function break_lines(view: kern.View, above: { [number]: boolean })
	local buffer = view:buffer()
	local br = text.line_break(buffer)
	local selection = view:selection()
	buffer:edit(function(e)
		-- Earlier edits move the later cursors by this much.
		local shift = 0
		for i, range in selection.ranges do
			local pos = range.head
			local from, to, inserted, cursor = pos, pos, br, 0
			if not above[i] then
				local line = buffer:line_of(pos)
				local start = buffer:line_start(line)
				local before = buffer:slice(start, pos)
				local after = buffer:slice(pos, buffer:line_end(line))
				local indent, closes = M.at(buffer, pos)
				if string.match(before, "^[ \t]+$") then
					from = start
				end
				to = pos + #(string.match(after, "^[ \t]*") :: string)
				inserted = br .. indent
				cursor = #inserted
				if closes and string.match(before, "[%(%[{][ \t]*$") then
					local unit = M.unit(buffer)
					inserted = br .. indent .. unit .. br .. indent
					cursor = #br + #indent + #unit
				end
			end
			e:replace(from, to, inserted)
			local at = from + shift + cursor
			selection.ranges[i] = { anchor = at, head = at }
			shift += #inserted - (to - from)
		end
		e:select(selection)
	end)
end

--- Breaks the line at each cursor and starts the new line at its indent,
--- leaving the cursor there. Spaces right after the cursor go, and so does
--- the indent of a line left blank. Between brackets, the closing one gets
--- a line of its own below.
function M.break_lines(view: kern.View)
	break_lines(view, {})
end

--- Opens a line below (or above) each cursor's line at the indent it calls
--- for, with the cursor on it.
function M.open(view: kern.View, below: boolean)
	local buffer = view:buffer()
	local selection = view:selection()
	local above = {}
	for i, range in selection.ranges do
		local line = buffer:line_of(range.head)
		-- A line above is a line below the one before, except at the top.
		local at = if below
			then buffer:line_end(line)
			elseif line > 0 then buffer:line_end(line - 1)
			else 0
		above[i] = not below and line == 0
		selection.ranges[i] = { anchor = at, head = at }
	end
	view:set_selection(selection)
	break_lines(view, above)
end

return M
