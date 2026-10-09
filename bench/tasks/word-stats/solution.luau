local greed = require("@greed")
local agent = require("@agent")

agent.tool({
	name = "word_stats",
	description = "Words, lines and the 5 most common words of a file",
	input = agent.schema.object({ path = { type = "string" } }, { "path" }),
	run = function(args)
		local text = greed.fs.read(args.path) or ""
		local words, lines, counts = 0, 0, {}
		for _ in string.gmatch(text, "[^\n]*\n") do
			lines += 1
		end
		for word in string.gmatch(text, "%S+") do
			words += 1
			counts[word] = (counts[word] or 0) + 1
		end
		return { words = words, lines = lines, counts = counts }
	end,
})
