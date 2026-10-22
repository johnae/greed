-- Joining and leaving rooms. `:chat-join` (`+` in the list) offers the
-- rooms you could join, the server's directory on Matrix and your teams'
-- public channels on Mattermost, or joining one by its address or id.
-- `enter` on a space (or team) in the list offers the rooms it holds: one
-- you're in opens, another is joined, a space inside it opens the same
-- way. An invite is answered when it's opened; `:chat-leave` (`-` in the
-- list) leaves a room after asking.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local accounts = require("./accounts")
local room = require("./room")

local M = {}

--- A room `directory` or `space` lists.
export type Listed = {
	id: string,
	name: string,
	topic: string?,
	members: number?,
	address: string?,
	joined: boolean?,
	space: boolean?,
	via: { string }?,
}

--- How a room you could join reads in the picker.
function M.label(listed: Listed): string
	local parts = { listed.name }
	if listed.topic then
		table.insert(parts, core.text.clip(listed.topic, 50))
	end
	if listed.members then
		table.insert(parts, if listed.members == 1 then "1 member" else `{listed.members} members`)
	end
	if listed.address then
		table.insert(parts, listed.address)
	end
	return table.concat(parts, " · ")
end

--- Joins `target` (an id or an address) in account `key`, through the
--- servers in `via` where it's on another, and opens it in `window` as
--- `name`. Waits, so it runs in a coroutine.
function M.join(key: string, target: string, name: string, window: greed.View, via: { string }?)
	-- A room on another server can take its server a minute or more.
	greed.echo(`joining {name}…`)
	local joined, why = accounts.ask(key, "join", { room = target, via = via })
	if joined == nil then
		greed.echo(`chat: {why}`)
		return
	end
	greed.echo("")
	room.open(key, joined.room, name, nil, window)
end

--- How a room a space holds reads in the picker: ✓ before one you're in,
--- ◆ before a space.
function M.held_label(listed: Listed): string
	local mark = if listed.space then "◆ " elseif listed.joined then "✓ " else "  "
	return mark .. M.label(listed)
end

--- Offers the rooms space `id` (`name`) of account `key` holds, in
--- `window`: one you're in opens, another is joined, a space opens the
--- same way. Waits, so it runs in a coroutine.
function M.browse(key: string, id: string, name: string, window: greed.View)
	greed.echo(`listing {name}…`)
	local held, why = accounts.ask(key, "space", { room = id })
	if held == nil then
		greed.echo(`chat: {why}`)
		return
	end
	greed.echo("")
	local rooms: { Listed } = held
	if #rooms == 0 then
		greed.echo(`{name} holds no rooms you can see`)
		return
	end
	local items = {}
	for _, one in rooms do
		table.insert(items, { label = M.held_label(one), value = one })
	end
	picker.pick(name, items, function(chosen)
		local one: Listed = chosen.value
		greed.spawn(function()
			if one.space then
				M.browse(key, one.id, one.name, window)
			elseif one.joined then
				room.open(key, one.id, one.name, nil, window)
			else
				M.join(key, one.id, one.name, window, one.via)
			end
		end)
	end)
end

--- Leaves room `id` (`name`) of account `key` after asking, or says no to
--- being asked to it; `left` runs once it's done. Waits, so it runs in a
--- coroutine.
function M.leave(key: string, id: string, name: string, left: (() -> ())?)
	greed.echo(`Leave {name}? y leaves, anything else doesn't`)
	if greed.next_key() ~= "y" then
		greed.echo("")
		return
	end
	local _, why = accounts.ask(key, "leave", { room = id })
	greed.echo(if why then `chat: {why}` else `left {name}`)
	if why == nil and left then
		left()
	end
end

--- Answers an invite to room `id` (`name`) of account `key`: joining it
--- and opening it in `window`, or saying no. Waits, so it runs in a
--- coroutine.
function M.answer(key: string, id: string, name: string, window: greed.View)
	greed.echo(`You're asked to {name}: y joins, n says no, anything else waits`)
	local answer = greed.next_key()
	greed.echo("")
	if answer == "y" then
		M.join(key, id, name, window)
	elseif answer == "n" then
		local _, why = accounts.ask(key, "leave", { room = id })
		greed.echo(if why then `chat: {why}` else `said no to {name}`)
	end
end

greed.command({
	name = "chat-join",
	doc = "Join a room: one the server lists, or by its address or id",
	run = function(ctx: greed.Context)
		local window = ctx.view
		accounts.with_account(
			accounts.keys(),
			"no chat accounts: :chat-login signs in",
			function(key)
				local listed, why = accounts.ask(key, "directory", { query = "" })
				if listed == nil then
					greed.echo(`chat: {why}`)
				end
				local items: { any } = { { label = "By its address or id…", value = false } }
				local found: { Listed } = listed or {}
				for _, one in found do
					table.insert(items, { label = M.label(one), value = one })
				end
				picker.pick("Join", items, function(chosen)
					greed.spawn(function()
						local one: Listed? = chosen.value or nil
						if one then
							M.join(key, one.id, one.name, window)
							return
						end
						local target =
							core.prompt.ask("The room's address or id (#garden:example.org)")
						local trimmed = if target then core.text.trim(target) else ""
						if trimmed ~= "" then
							M.join(key, trimmed, trimmed, window)
						end
					end)
				end)
			end
		)
	end,
})

return M
