-- How line numbers count: each line's own number, or relative to the
-- cursor's line, so `5 j` goes to the line marked 5.
--
--     greed.option.set("line-numbers", "relative")

local greed = require("@greed")

local STYLES = { absolute = true, relative = true, hybrid = true }

greed.option.define({
	name = "line-numbers",
	default = "absolute",
	doc = 'How line numbers count: "absolute", "relative" to the cursor\'s line, or "hybrid" (relative, with the cursor\'s line its own number)',
})

local function apply()
	local style = greed.option.get("line-numbers") :: string
	if STYLES[style] then
		greed.line_numbers(style :: any)
	else
		greed.echo(`line-numbers is "absolute", "relative" or "hybrid", not "{style}"`)
	end
end

apply()

greed.on("option.changed", function(event)
	if event.name == "line-numbers" then
		apply()
	end
end)

return {}
