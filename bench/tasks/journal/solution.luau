local greed = require("@greed")
local core = require("@core")

greed.command({
	name = "journal-today",
	doc = "Open today's journal entry, journal/YYYY-MM-DD.md, making it if need be",
	run = function()
		local date = os.date("%Y-%m-%d")
		local path = `{core.project.root()}/journal/{date}.md`
		if greed.fs.stat(path) == nil then
			greed.fs.write(path, `# {date}\n\n`)
		end
		greed.open(path)
	end,
})
greed.keymap.bind({ layer = "leader" }, { j = "journal-today" })
