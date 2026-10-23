-- Features: what plugins turn on for some buffers beyond their language,
-- like notes for Markdown in the notes folder. The status line shows them
-- after the language, e.g. "markdown · notes".
--
-- A plugin adds one with a test for the buffers it's on in, and its
-- features go when it does:
--
--     require("@core").features.add("notes", is_note)

local greed = require("@greed")
local registry = require("./registry")

local M = {}

export type Applies = (buffer: greed.Buffer) -> boolean

local added: { { name: string, applies: Applies } } = {}

--- Adds the feature `name`, on in the buffers `applies` says. It goes when
--- the plugin that added it does, or when what it returns is called. A
--- third argument, once the plugin's name, is ignored.
function M.add(name: string, applies: Applies, _plugin: string?): () -> ()
	local remove = registry.put(added, { name = name, applies = applies })
	greed.plugin.cleanup(remove)
	return remove
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

return M
