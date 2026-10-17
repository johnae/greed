local test = require("@greed/test")
local greed = require("@greed")
local swatches = require("@swatches")

test("#rrggbb, #rgb with a letter and #rrggbbaa are colors; #123 isn't", function()
	assert(swatches.color("FF8800") == "#ff8800")
	assert(swatches.color("fa0") == "#ffaa00")
	assert(swatches.color("ff880080") == "#ff8800")
	assert(swatches.color("123") == nil, "an issue number")
	assert(swatches.color("12345") == nil)
end)

test("a color gets a square in its color in front of it", function(t)
	t:buffer("|color: #ff8800; see #123 and a#fff")
	greed.view():buffer():set_line_numbers(false)
	local rows = t:draw(50, 3)
	assert(rows[1] == "color: ■ #ff8800; see #123 and a#fff", rows[1])
	local styles = {}
	for _, mark in greed.view():buffer():decorations("color-swatches") do
		table.insert(styles, mark.style)
	end
	assert(#styles == 1 and styles[1] == "swatch.ff8800", table.concat(styles, ","))
	local entry = greed.theme.get("swatch.ff8800")
	assert(entry and entry.fg == "#ff8800", "its theme entry")
end)

test("color-swatches off takes them away", function(t)
	greed.option.set("color-swatches", false)
	t:buffer("|#ff8800")
	greed.view():buffer():set_line_numbers(false)
	assert(t:draw(20, 2)[1] == "#ff8800")
	greed.option.set("color-swatches", true)
end)
