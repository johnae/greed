-- How line numbers count: each line's own number, or relative to the
-- cursor's line, so `5 j` goes to the line marked 5.
--
--     greed.option.set("line-numbers", "relative")

local greed = require("@greed")

greed.option.define({
	name = "line-numbers",
	default = "absolute",
	choices = { "absolute", "relative", "hybrid" },
	doc = 'How line numbers count: "absolute", "relative" to the cursor\'s line, or "hybrid" (relative, with the cursor\'s line its own number)',
})

local function apply()
	greed.line_numbers(greed.option.get("line-numbers") :: any)
end

apply()

greed.on("option.changed", function(event)
	if event.name == "line-numbers" then
		apply()
	end
end)

return {}
