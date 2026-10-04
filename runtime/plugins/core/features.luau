-- Features: what plugins turn on for some buffers beyond their language,
-- like notes for Markdown in the notes folder. The status line shows them
-- after the language, e.g. "markdown · notes".
--
-- A plugin adds one with a test for the buffers it's on in, and its
-- features go when it does:
--
--     require("@core").features.add("notes", is_note, "notes")

local greed = require("@greed")

local M = {}

export type Applies = (buffer: greed.Buffer) -> boolean

local added: { { name: string, applies: Applies, plugin: string? } } = {}

--- Adds the feature `name`, on in the buffers `applies` says, from
--- `plugin` if given. Calling what it returns takes it away again.
function M.add(name: string, applies: Applies, plugin: string?): () -> ()
	local entry = { name = name, applies = applies, plugin = plugin }
	table.insert(added, entry)
	return function()
		local at = table.find(added, entry)
		if at then
			table.remove(added, at)
		end
	end
end

--- The features on in `buffer`, in the order they were added. A test that
--- fails counts as off.
function M.of(buffer: greed.Buffer): { string }
	local on = {}
	for _, feature in added do
		local ok, applies = pcall(feature.applies, buffer)
		if ok and applies then
			table.insert(on, feature.name)
		end
	end
	return on
end

greed.on("plugin.unloaded", function(event)
	for i = #added, 1, -1 do
		if added[i].plugin == event.name then
			table.remove(added, i)
		end
	end
end)

return M
