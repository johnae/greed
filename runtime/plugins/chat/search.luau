-- Searching messages: `:chat-search` (`/` in the list) asks in the search
-- box and searches every account; in a room (`alt-s`) only that room. What
-- it finds comes newest first in a picker, and the one picked opens in its
-- room. Each service searches its own way: Mattermost on the server (its
-- words and `from:`, `in:`, `before:`), Matrix in what this device has seen
-- (encrypted rooms too) and on the server.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local backend = require("./backend")
local room = require("./room")
local accounts = require("./accounts")

local M = {}

--- A message found: the account ("service id") and room it's in.
export type Found = { account: string, room: string, room_name: string, item: backend.Item }

--- What `query` finds, newest first, in every account or in `only` (an
--- account and a room), and what went wrong in the accounts that failed.
function M.search(query: string, only: { account: string, room: string }?): ({ Found }, { string })
	local found: { Found } = {}
	local troubles: { string } = {}
	local keys: { string } = if only then { only.account } else accounts.keys()
	for _, key in keys do
		local hits, why =
			accounts.ask(key, "search", { query = query, room = if only then only.room else nil })
		if hits == nil then
			table.insert(troubles, `{key}: {why}`)
		else
			for _, hit in hits do
				table.insert(found, {
					account = key,
					room = hit.room,
					room_name = hit.room_name,
					item = hit.item,
				})
			end
		end
	end
	table.sort(found, function(a: Found, b: Found): boolean
		return a.item.at > b.item.at
	end)
	return found, troubles
end

--- How a message found reads in the picker: where, who, what, when.
function M.label(found: Found): string
	local text = string.match(found.item.text, "^[^\n]*") or ""
	return `{found.room_name} · {found.item.sender.name}: {text} · {room.when(found.item.at)}`
end

-- Offers `found` in a picker; the one picked opens in its room in `window`.
local function offer(found: { Found }, window: greed.View)
	local items = {}
	for _, one in found do
		table.insert(items, { label = M.label(one), value = one })
	end
	picker.pick(`Found ({#found})`, items, function(chosen)
		local one: Found = chosen.value
		room.open(one.account, one.room, one.room_name, nil, window, one.item.event)
	end)
end

--- Asks what to search for in the search box, in every account or in
--- `only`, and offers what it finds.
function M.ask(window: greed.View, only: { account: string, room: string }?)
	core.search_box.open({
		title = if only then "Search this room" else "Search chat",
		history = "chat",
		on_submit = function(text: string)
			if core.text.trim(text) == "" then
				return
			end
			greed.spawn(function()
				greed.echo("searching…")
				local found, troubles = M.search(text, only)
				greed.echo(if #troubles > 0 then `chat: {table.concat(troubles, "; ")}` else "")
				if #found == 0 then
					greed.echo(`nothing found for {text}`)
					return
				end
				offer(found, window)
			end)
		end,
	})
end

greed.command({
	name = "chat-search",
	doc = "Search your chat messages; in a room, that room's",
	run = function(ctx: greed.Context)
		local r = room.of(ctx.buffer)
		M.ask(ctx.view, if r then { account = r.account, room = r.room } else nil)
	end,
})

return M
