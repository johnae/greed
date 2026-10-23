-- Searching everything that's yours at once: your notes, your mail, your
-- chat, each kept and searched by its own plugin, which adds itself here
-- as a source. One query goes to all of them, or to those `in:` names
-- (`in:mail in:chat lunch`); any other `in:` goes on to the sources, as
-- their own places (a mail folder, a chat room). What they find comes
-- newest first, each an object (`kind`, `id`) that knows how to open.
-- An app's own search box searches only that app.
--
--     core.everywhere.add({
--         name = "mail",
--         search = function(text, limit)
--             return hits_for(text, limit)
--         end,
--     })

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- Something a source found: what it is (an object's `kind` and `id`),
--- how it reads, a line of what it says, when (milliseconds since 1970)
--- if it has a time, and how to open it.
export type Hit = {
	source: string,
	kind: string,
	id: string,
	label: string,
	snippet: string?,
	at: number?,
	open: () -> (),
}

--- A source: its name, as `in:` names it, and what it finds for a query
--- (at most `limit`), or nil and why. Searching may wait.
export type Source = {
	name: string,
	doc: string?,
	search: (text: string, limit: number) -> ({ Hit }?, string?),
}

local sources: { Source } = {}

--- Adds a source, or replaces the one by the same name, until the plugin
--- that added it goes.
function M.add(source: Source)
	greed.plugin.cleanup(registry.put(sources, source, function(other: Source)
		return other.name == source.name
	end))
end

--- The sources' names, sorted.
function M.names(): { string }
	local names = {}
	for _, source in sources do
		table.insert(names, source.name)
	end
	table.sort(names)
	return names
end

--- `text` without the `in:` words that name sources, and those sources
--- (all, when none is named).
function M.split(text: string): (string, { string })
	local known: { [string]: boolean } = {}
	for _, source in sources do
		known[source.name] = true
	end
	local named: { string } = {}
	local rest: { string } = {}
	for word in string.gmatch(text, "%S+") do
		local place = string.match(word, "^in:(.+)$")
		local name = if place then string.lower(place) else nil
		if name and known[name] then
			table.insert(named, name)
		else
			table.insert(rest, word)
		end
	end
	if #named == 0 then
		named = M.names()
	end
	return table.concat(rest, " "), named
end

--- What `text` finds in every source, or those its `in:` names, newest
--- first, at most `limit` (100); and why the sources that failed did.
--- Waits.
function M.search(text: string, limit: number?): ({ Hit }, { string })
	local most = limit or 100
	local query, named = M.split(text)
	local hits: { Hit } = {}
	local troubles: { string } = {}
	for _, source in sources do
		if table.find(named, source.name) then
			local found, why = source.search(query, most)
			if found then
				for _, hit in found do
					hit.source = source.name
					table.insert(hits, hit)
				end
			else
				table.insert(troubles, `{source.name}: {why or "it can't search now"}`)
			end
		end
	end
	-- Newest first; what has no time keeps its source's order, after.
	local order: { [Hit]: number } = {}
	for i, hit in hits do
		order[hit] = i
	end
	table.sort(hits, function(a: Hit, b: Hit): boolean
		if a.at and b.at and a.at ~= b.at then
			return a.at > b.at
		elseif (a.at == nil) ~= (b.at == nil) then
			return a.at ~= nil
		end
		return order[a] < order[b]
	end)
	while #hits > most do
		table.remove(hits)
	end
	return hits, troubles
end

return M
