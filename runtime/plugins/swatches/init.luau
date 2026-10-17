-- Colors written as `#rrggbb` (or `#rgb`, `#rrggbbaa`) get a small square
-- in that color in front of them, in any file. A three-digit one needs a
-- letter in it, so an issue number like #123 stays plain. `:set
-- color-swatches false` turns them off.

local greed = require("@greed")
local core = require("@core")

greed.option.define({
	name = "color-swatches",
	doc = "Show a square in their color in front of colors like #ff8800",
	default = true,
})

local SWATCH = "■ "

local M = {}

--- The color a `#` and the hex digits after it stand for, as "#rrggbb",
--- or nil when they aren't one.
function M.color(digits: string): string?
	if #digits == 6 or #digits == 8 then
		return "#" .. string.lower(string.sub(digits, 1, 6))
	elseif #digits == 3 and string.match(digits, "%a") then
		local r, g, b = string.match(string.lower(digits), "(.)(.)(.)")
		return `#{r}{r}{g}{g}{b}{b}`
	end
	return nil
end

-- The theme entries made for each color so far.
local made: { [string]: boolean } = {}

-- The style drawing `color` ("#rrggbb"), made the first time it's needed.
local function style_of(color: string): string
	local name = "swatch." .. string.sub(color, 2)
	if not made[name] then
		made[name] = true
		greed.theme.set({ [name] = { fg = color } })
	end
	return name
end

local redraw = core.visible.add({
	ns = "color-swatches",
	wants = function(buffer: greed.Buffer): boolean
		return buffer:kind() == "file" and greed.option.get("color-swatches") == true
	end,
	draw = function(buffer: greed.Buffer, first: number, last: number): { greed.Mark }
		local marks: { greed.Mark } = {}
		for n = first, last do
			local text = buffer:line_text(n)
			if not string.find(text, "#", 1, true) then
				continue
			end
			local start = buffer:line_start(n)
			for at, digits, after in string.gmatch(text, "()#(%x+)()") do
				local before = string.sub(text, (at :: number) - 1, (at :: number) - 1)
				local next = string.sub(text, after :: number, after :: number)
				local color = M.color(digits :: string)
				if
					color
					and not string.match(before, "[%w&]")
					and not string.match(next, "[%w_]")
				then
					local from = start + (at :: number) - 1
					table.insert(
						marks,
						{ from = from, to = from, text = SWATCH, style = style_of(color) }
					)
				end
			end
		end
		return marks
	end,
})

greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "color-swatches" then
		redraw()
	end
end)

return M
