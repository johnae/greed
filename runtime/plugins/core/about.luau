-- What a buffer is, in a few words, for an agent told what the user is in:
-- "the mail list, searching in:inbox, 198 shown". The plugin that shows a
-- kind of buffer says it for that kind; a file needs nothing, its path
-- says it.

local greed = require("@greed")
local registry = require("./registry")

local M = {}

local kinds: { [string]: (buffer: greed.Buffer) -> string? } = {}

--- Says what buffers of `kind` are: `says` gives it for one, or nil when
--- it has nothing to say. It goes with the plugin that said so.
function M.kind(kind: string, says: (buffer: greed.Buffer) -> string?)
	greed.plugin.cleanup(registry.set(kinds, kind, says))
end

--- What `buffer` is, as the plugin showing it says; nil when none does.
function M.of(buffer: greed.Buffer): string?
	local says = kinds[buffer:kind()]
	if says == nil then
		return nil
	end
	local ok, said = pcall(says, buffer)
	return if ok and type(said) == "string" and said ~= "" then said else nil
end

return M
