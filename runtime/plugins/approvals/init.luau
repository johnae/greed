-- Approving plugins. A plugin that isn't one of Kern's own and declares
-- capabilities (running programs, files by path, the network, ...) waits
-- until you approve them, and again if it later asks for more.
--
--   :plugins-approve   review the waiting plugins and approve one

local kern = require("@kern")
local picker = require("@picker")

local M = {}

--- What the plugin described by `about` (from `kern.plugin.describe`) asks
--- for, one line per capability, with the ones not approved yet marked.
function M.lines(about: kern.PluginInfo): { string }
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
kern.on("editor.started", function()
	local waiting = kern.plugin.pending()
	if #waiting > 0 then
		local s = if #waiting == 1 then " waits" else "s wait"
		kern.echo(`{#waiting} plugin{s} for your approval - :plugins-approve`)
	end
end)

kern.command({
	name = "plugins-approve",
	doc = "Review the plugins waiting for approval of what they use, and approve one",
	run = function()
		local waiting = kern.plugin.pending()
		if #waiting == 0 then
			kern.echo("no plugins wait for approval")
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
			local about = item.value :: kern.PluginInfo
			local ok, err = pcall(kern.plugin.approve, about.dir)
			kern.echo(if ok then `approved and loaded {about.name}` else tostring(err))
		end, {
			preview = function(item)
				local about = item.value :: kern.PluginInfo
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

return M
