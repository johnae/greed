-- Indent guides: a thin line at each level of indent, so you can see the
-- lines a block holds. Blank lines inside a block get them too, except one
-- a cursor is on, where they'd sit in the way of typing. `:set
-- indent-guides false` turns them off; their style is "ui.indent.guide".

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "indent-guides",
	doc = "Show a line at each level of indent",
	default = true,
})

local GUIDE = "│"
local STYLE = "ui.indent.guide"

-- How far to look past the lines drawn for the indent of the lines a
-- blank one sits between.
local LOOK = 200

local M = {}

-- How many columns `lead` (a line's leading blanks) takes, tabs reaching
-- the next stop `tab` apart.
local function columns(lead: string, tab: number): number
	local col = 0
	for i = 1, #lead do
		if string.byte(lead, i) == 9 then
			col += tab - col % tab
		else
			col += 1
		end
	end
	return col
end

-- The indent of line `n` in columns, or nil for a blank line.
local function indent_of(buffer: greed.Buffer, n: number, tab: number): number?
	local text = buffer:line_text(n)
	local lead = string.match(text, "^[ \t]*") :: string
	if #lead == #text then
		return nil
	end
	return columns(lead, tab)
end

--- The columns a line indented `cols` deep has guides at, a level `step`
--- columns apart: every level short of where its text starts.
function M.guides(cols: number, step: number): { number }
	local out = {}
	local col = 0
	while col < cols do
		table.insert(out, col)
		col += step
	end
	return out
end

-- The marks for guides at `cols` on line `n`, whose leading blanks are
-- `lead`: over the blanks where there are some, and past the line's end
-- for the rest.
local function marks_for(
	buffer: greed.Buffer,
	n: number,
	lead: string,
	cols: { number },
	tab: number,
	out: { greed.Mark }
)
	local start = buffer:line_start(n)
	-- The byte each column starts at over the leading blanks, and whether
	-- it's a tab.
	local at: { [number]: number } = {}
	local tabs: { [number]: boolean } = {}
	local col = 0
	for i = 1, #lead do
		local is_tab = string.byte(lead, i) == 9
		at[col], tabs[col] = i - 1, is_tab
		col += if is_tab then tab - col % tab else 1
	end
	local past = ""
	for _, guide in cols do
		local byte = at[guide]
		if byte then
			-- Over a space; before a tab, which still reaches its stop.
			table.insert(out, {
				from = start + byte,
				to = start + byte + 1,
				style = STYLE,
				text = GUIDE,
				overlay = not tabs[guide],
			})
		elseif guide >= col then
			past ..= string.rep(" ", guide - col - core.text.width(past)) .. GUIDE
		end
	end
	if past ~= "" then
		local finish = start + #lead
		table.insert(out, { from = finish, to = finish, style = STYLE, text = past })
	end
end

-- The lines with a cursor on them in `buffer`'s views.
local function cursor_lines(buffer: greed.Buffer): { [number]: boolean }
	local lines = {}
	for _, view in buffer:views() do
		for _, range in view:selection().ranges do
			lines[buffer:line_of(range.head)] = true
		end
	end
	return lines
end

local redraw = core.visible.add({
	ns = "indent-guides",
	-- A blank line a cursor is on has none.
	cursor = true,
	wants = function(buffer: greed.Buffer): boolean
		return buffer:kind() == "file" and greed.option.get("indent-guides") == true
	end,
	draw = function(buffer: greed.Buffer, first: number, last: number): { greed.Mark }
		local tab = buffer:tab_width()
		local unit = core.indent.unit(buffer)
		local step = if unit == "\t" then tab else math.max(1, #unit)
		local cursors = cursor_lines(buffer)
		local count = buffer:line_count()
		local marks: { greed.Mark } = {}
		-- The indent of the last line with text above, and of the next
		-- below, for blank lines in between.
		local above: number? = nil
		for n = first - 1, math.max(0, first - LOOK), -1 do
			above = indent_of(buffer, n, tab)
			if above then
				break
			end
		end
		local below: number? = nil
		local below_line = -1
		for n = first, last do
			local text = buffer:line_text(n)
			local lead = string.match(text, "^[ \t]*") :: string
			local cols: number
			if #lead < #text then
				cols = columns(lead, tab)
				above = cols
			else
				if cursors[n] then
					continue
				end
				if below_line < n then
					below = nil
					below_line = math.min(count - 1, last + LOOK)
					for m = n + 1, below_line do
						below = indent_of(buffer, m, tab)
						if below then
							below_line = m
							break
						end
					end
				end
				cols = math.min(above or 0, below or 0)
			end
			marks_for(buffer, n, lead, M.guides(cols, step), tab, marks)
		end
		return marks
	end,
})

greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "indent-guides" then
		redraw()
	end
end)

return M
