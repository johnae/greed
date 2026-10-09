local greed = require("@greed")
local core = require("@core")

greed.command({
	name = "blame-line",
	doc = "Who last changed the line under the cursor, and why",
	run = function(ctx)
		local path = ctx.buffer:path()
		if path == nil then
			return
		end
		local line = ctx.buffer:line_of(ctx.view:cursor()) + 1
		local dir = string.match(path, "^(.*)/") or "."
		local blame = greed.process.run({ "git", "blame", "-L", `{line},{line}`, "--porcelain", path }, { cwd = dir })
		if blame == nil or blame.code ~= 0 then
			greed.echo("no blame here")
			return
		end
		local summary = string.match(blame.stdout, "\nsummary ([^\n]*)") or "?"
		local author = string.match(blame.stdout, "\nauthor ([^\n]*)") or "?"
		core.floats.show_text("Blame", `{author}: {summary}`, { anchor = "cursor", width = 60, height = 3 })
	end,
})
greed.keymap.bind({ layer = "leader" }, { ["g b"] = "blame-line" })
