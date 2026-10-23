-- Kinds of buffer whose text someone else wrote, like mail being read:
-- what an agent reads of one is marked as data from outside, so words in
-- it that look like instructions aren't taken for the user's.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

local kinds: { [string]: string } = {}

--- Says the text of buffers of `kind` came from someone else, and from
--- whom: `source` names it to an agent ("mail you received"). It goes
--- with the plugin that said so.
function M.kind(kind: string, source: string)
	greed.plugin.cleanup(registry.set(kinds, kind, source))
end

--- Where the text of `buffer` came from, when someone else wrote it.
function M.source(buffer: greed.Buffer): string?
	return kinds[buffer:kind()]
end

return M
