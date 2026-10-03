-- Approving plugins. A plugin that isn't one of Greed's own and declares
-- capabilities (running programs, files by path, the network, ...) waits
-- until you approve them, and again if it later asks for more.
--
--   :plugins-approve   review the waiting plugins and approve one
--   :plugins           every plugin, where it comes from and what it may use

local greed = require("@greed")
local picker = require("@picker")

local M = {}

--- What the plugin described by `about` (from `greed.plugin.describe`) asks
--- for, one line per capability, with the ones not approved yet marked.
function M.lines(about: greed.PluginInfo): { string }
	if #about.capabilities == 0 then
		return { "It uses nothing beyond the editor." }
	end
	local lines = { "It asks to:" }
	for _, capability in about.capabilities do
		local new = if table.find(about.missing, capability.name) then "  (new)" else ""
		table.insert(lines, `  {capability.name}: {capability.what}{new}`)
	end
	return lines
end

-- Tells you what waits, once the editor is up.
greed.on("editor.started", function()
	local waiting = greed.plugin.pending()
	if #waiting > 0 then
		local s = if #waiting == 1 then " waits" else "s wait"
		greed.echo(`{#waiting} plugin{s} for your approval - :plugins-approve`)
	end
end)

greed.command({
	name = "plugins-approve",
	doc = "Review the plugins waiting for approval of what they use, and approve one",
	run = function()
		local waiting = greed.plugin.pending()
		if #waiting == 0 then
			greed.echo("no plugins wait for approval")
			return
		end
		local items = {}
		for _, about in waiting do
			local asks = {}
			for _, capability in about.capabilities do
				table.insert(asks, capability.name)
			end
			table.insert(items, {
				label = `{about.name}  {table.concat(asks, ", ")}`,
				value = about,
			})
		end
		picker.pick("Approve a plugin", items, function(item)
			local about = item.value :: greed.PluginInfo
			local ok, err = pcall(greed.plugin.approve, about.dir)
			greed.echo(if ok then `approved and loaded {about.name}` else tostring(err))
		end, {
			preview = function(item)
				local about = item.value :: greed.PluginInfo
				local lines = { about.name, about.dir, "" }
				for _, line in M.lines(about) do
					table.insert(lines, line)
				end
				if #about.requires > 0 then
					table.insert(lines, "")
					table.insert(lines, `It uses the plugins {table.concat(about.requires, ", ")}.`)
				end
				return { text = table.concat(lines, "\n") }
			end,
		})
	end,
})

-- Whether `path` is `dir` or inside it.
local function inside(path: string, dir: string?): boolean
	return dir ~= nil and (path == dir or string.sub(path, 1, #dir + 1) == dir .. "/")
end

--- Where the plugin in `dir` comes from, in words: Greed's own, your config,
--- the copy of it greed ssh brought, the data folder (plugins made in the
--- editor), or the project.
function M.origin(dir: string): string
	local dirs = greed.fs.dirs()
	local core = greed.plugin.dirs().core
	local shipped = core and string.match(core, "^(.*)/[^/]+$")
	if inside(dir, shipped) then
		return "Greed's own"
	elseif inside(dir, dirs.brought) then
		return "your config, brought by greed ssh"
	elseif inside(dir, dirs.data) then
		return "made in the editor (data folder)"
	elseif inside(dir, dirs.config) then
		return "your config"
	elseif inside(dir, greed.project.current().root) then
		return "this project"
	end
	return "loaded from " .. dir
end

greed.command({
	name = "plugins",
	doc = "List the plugins, where each comes from and what it may use; enter opens one",
	run = function()
		local items = {}
		for _, about in greed.plugin.pending() do
			table.insert(items, {
				label = `{about.name}  waiting for approval  ({M.origin(about.dir)})`,
				value = about,
			})
		end
		local dirs = greed.plugin.dirs()
		for _, name in greed.plugin.list() do
			local dir = dirs[name]
			if dir then
				local about = greed.plugin.describe(dir)
				local asks = {}
				for _, capability in about.capabilities do
					table.insert(asks, capability.name)
				end
				local uses = if #asks > 0 then "  " .. table.concat(asks, ", ") else ""
				table.insert(items, { label = `{name}  {M.origin(dir)}{uses}`, value = about })
			end
		end
		picker.pick("Plugins", items, function(item)
			local about = item.value :: greed.PluginInfo
			greed.open(about.dir .. "/init.luau")
		end, {
			preview = function(item)
				local about = item.value :: greed.PluginInfo
				local lines = { about.name, about.dir, M.origin(about.dir), "" }
				for _, line in M.lines(about) do
					table.insert(lines, line)
				end
				return { text = table.concat(lines, "\n") }
			end,
		})
	end,
})

return M
