-- Your config runs again when you change it: save `~/.config/greed/init.luau`
-- (in Greed or anywhere else) and what it sets takes effect. Reloading takes
-- away what the config registered (commands, keys, theme entries, event
-- handlers) and runs it again; options it set keep their values until it
-- sets them again. `:config-reload` does it by hand.

local greed = require("@greed")

local M = {}

--- The configs that can run, in the order they do: the one `greed ssh`
--- brought first, so this machine's own has the last word.
M.names = { "user/brought-config", "user/config" }

-- Each loaded config's file, by name.
local function files(): { [string]: string }
	local out = {}
	local dirs = greed.plugin.dirs()
	for _, name in M.names do
		local dir = dirs[name]
		if dir then
			out[name] = `{dir}/init.luau`
		end
	end
	return out
end

--- Runs the loaded configs again, in order, and says how it went.
function M.reload()
	local dirs = greed.plugin.dirs()
	for _, name in M.names do
		local dir = dirs[name]
		if dir then
			local ok, err = pcall(greed.plugin.load, dir, name)
			if not ok then
				greed.echo(`config: {err}`)
				return
			end
		end
	end
	greed.echo("config reloaded")
end

--- Watches the loaded configs, so they run again when they change.
function M.watch()
	for _, path in files() do
		greed.fs.watch(path)
	end
end

greed.on("file.changed", function(event: greed.FileChanged)
	for _, path in files() do
		if path == event.path then
			M.reload()
			return
		end
	end
end)

-- The configs run after the plugins, so they're watched once all have.
greed.on("editor.started", M.watch)

greed.command({
	name = "config-reload",
	doc = "Run your config again, as saving it does",
	run = M.reload,
})

return M
