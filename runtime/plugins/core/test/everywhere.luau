local test = require("@greed/test")
local core = require("@core")

local everywhere = core.everywhere

-- A source called `name` whose hits are `found` (label and when), keeping
-- the queries it was asked in `asked`.
local function source(name: string, found: { { label: string, at: number? } }, asked: { string })
	everywhere.add({
		name = name,
		search = function(text: string, limit: number): ({ core.EverywhereHit }?, string?)
			table.insert(asked, text)
			local hits: { core.EverywhereHit } = {}
			for i, one in found do
				if i > limit then
					break
				end
				table.insert(hits, {
					source = name,
					kind = name,
					id = `{name}:{i}`,
					label = one.label,
					at = one.at,
					open = function() end,
				})
			end
			return hits, nil
		end,
	})
end

local function labels(hits: { core.EverywhereHit }): string
	local out = {}
	for _, hit in hits do
		table.insert(out, `{hit.source}:{hit.label}`)
	end
	return table.concat(out, " ")
end

test("one query searches every source, newest first; in: picks some", function()
	local asked: { string } = {}
	source("letters", { { label = "old", at = 1000 }, { label = "new", at = 3000 } }, asked)
	source("talk", { { label = "middle", at = 2000 }, { label = "undated" } }, asked)
	local hits, troubles = everywhere.search("lunch in:letters in:talk")
	assert(#troubles == 0, table.concat(troubles, "; "))
	assert(
		labels(hits) == "letters:new talk:middle letters:old talk:undated",
		"newest first, undated last: " .. labels(hits)
	)
	-- in: naming a source picks it; any other in: goes on to the sources.
	table.clear(asked)
	hits = everywhere.search("lunch in:talk in:plans")
	assert(labels(hits) == "talk:middle talk:undated", labels(hits))
	assert(#asked == 1 and asked[1] == "lunch in:plans", table.concat(asked, " | "))
	-- At most as many as asked for.
	hits = everywhere.search("lunch in:letters in:talk", 2)
	assert(#hits == 2, labels(hits))
end)

test("a source that can't search says why, and the others still answer", function()
	everywhere.add({
		name = "broken",
		search = function(): ({ core.EverywhereHit }?, string?)
			return nil, "it's down"
		end,
	})
	local asked: { string } = {}
	source("fine", { { label = "here", at = 1 } }, asked)
	local hits, troubles = everywhere.search("x in:broken in:fine")
	assert(labels(hits) == "fine:here", labels(hits))
	assert(#troubles == 1 and troubles[1] == "broken: it's down", table.concat(troubles, "; "))
end)
