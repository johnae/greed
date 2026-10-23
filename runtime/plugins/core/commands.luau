-- Tags on commands, by name, for plugins that treat some commands their
-- own way without listing other plugins' names:
--
--   - "typing": types or erases a character, like insert-char. The selection
--     history skips these, and a style without modes undoes a run of them
--     in one step.
--   - "no-repeat": never a change for `.` to repeat, like undo.
--
--     core.commands.tag("typing", { "my-type-char" })
--
-- A tag goes when the plugin that added it does.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

-- Per tag, the commands that have it.
local tagged: { [string]: { [string]: boolean } } = {}

--- Gives the commands `names` the tag `tag`.
function M.tag(tag: string, names: { string })
	local set = tagged[tag] or {}
	tagged[tag] = set
	for _, name in names do
		greed.plugin.cleanup(registry.set(set, name, true))
	end
end

--- Whether the command `name` has the tag `tag`.
function M.has(name: string, tag: string): boolean
	local set = tagged[tag]
	return set ~= nil and set[name] == true
end

return M
