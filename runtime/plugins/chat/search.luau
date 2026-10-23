-- Searching messages: `:chat-search` (`/` in the list) asks in the search
-- box and searches every account; in a room (`alt-s`) only that room. It
-- searches the messages the chat service keeps (`index.luau`), in Greed's
-- query language as mail and notes are: words, `from:bea`, `in:plans`,
-- `before:2026-10-01`, `is:mine`, `is:direct`. What it finds comes newest
-- first in a picker, and the one picked opens in its room.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local backend = require("./backend")
local room = require("./room")

local M = {}

--- A message found: the account ("service id") and room it's in.
export type Found = { account: string, room: string, room_name: string, item: backend.Item }

--- `text` read as the search box reads it; nil and why when it won't.
function M.query(text: string): (core.Query?, string?)
	local parsed = core.search_box.read(text, { source = backend.source })
	if not parsed.ok then
		local problem = parsed.problems[1]
		return nil, `{text}: {if problem then problem.message else "it won't read"}`
	end
	return parsed, nil
end

--- What `text` finds, newest first, everywhere or in `only` (an account
--- and a room); nil and why.
function M.search(text: string, only: { account: string, room: string }?): ({ Found }?, string?)
	local asked = text
	if only then
		asked = `{text} account:"{only.account}" room_id:"{only.room}"`
	end
	local parsed, why = M.query(asked)
	if parsed == nil then
		return nil, why
	end
	return backend.search(parsed)
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
		source = backend.source,
		on_submit = function(text: string)
			if core.text.trim(text) == "" then
				return
			end
			greed.spawn(function()
				greed.echo("searching…")
				local found, why = M.search(text, only)
				if found == nil then
					greed.echo(`chat: {why}`)
					return
				elseif #found == 0 then
					greed.echo(`nothing found for {text}`)
					return
				end
				greed.echo("")
				offer(found, window)
			end)
		end,
	})
end

-- The chat, when everything that's yours is searched at once.
core.everywhere.add({
	name = "chat",
	doc = "Your chat messages, every account, as the chat service keeps them",
	search = function(text: string, limit: number): ({ core.EverywhereHit }?, string?)
		local found, why = M.search(text)
		if found == nil then
			return nil, why
		end
		local hits: { core.EverywhereHit } = {}
		for i = 1, math.min(#found, limit) do
			local one = found[i]
			local item = one.item
			local said = string.match(item.text, "^[^\n]*") or ""
			table.insert(hits, {
				source = "chat",
				kind = "chat-message",
				id = `chat:{one.account}|{one.room}|{item.event}`,
				label = `{one.room_name} · {item.sender.name}: {said}`,
				snippet = item.text,
				at = item.at,
				open = function()
					room.open(one.account, one.room, one.room_name, nil, greed.view(), item.event)
				end,
			})
		end
		return hits, nil
	end,
})

greed.command({
	name = "chat-search",
	doc = "Search your chat messages; in a room, that room's",
	run = function(ctx: greed.Context)
		local r = room.of(ctx.buffer)
		M.ask(ctx.view, if r then { account = r.account, room = r.room } else nil)
	end,
})

return M
