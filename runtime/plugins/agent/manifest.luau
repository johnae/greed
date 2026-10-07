-- Spotting an agent's change to a plugin's manifest that lets the plugin do
-- more. Greed's own plugins load without asking, so in a checkout of Greed
-- an edit to one of their plugin.toml files would widen what it may do
-- unseen; the questions before such a write say so instead.

local M = {}

-- The capabilities `text`, a plugin.toml, lists.
local function capabilities(text: string): { [string]: boolean }
	local listed: { [string]: boolean } = {}
	local list = string.match(text, "capabilities%s*=%s*(%b[])")
	if list then
		for name in string.gmatch(list, "[\"']([^\"']*)[\"']") do
			listed[name] = true
		end
	end
	return listed
end

--- What writing `new` over `old` (nil for a new file) at `path` lets a
--- plugin do that it couldn't, like "widens what acp may do: + plugins,
--- + eval"; nil when `path` isn't a plugin.toml or nothing is added.
function M.widens(path: string, old: string?, new: string): string?
	if not string.match(path, "plugin%.toml$") then
		return nil
	end
	local had = capabilities(old or "")
	local added: { string } = {}
	for name in capabilities(new) do
		if not had[name] then
			table.insert(added, `+ {name}`)
		end
	end
	if #added == 0 then
		return nil
	end
	table.sort(added)
	local name = string.match("\n" .. new, "\n%s*name%s*=%s*[\"']([^\"']*)[\"']") or "a plugin"
	return `widens what {name} may do: {table.concat(added, ", ")}`
end

return M
