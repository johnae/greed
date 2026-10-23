-- New messages for you, as the services say (`alert`): mentions and direct
-- messages by default, raised once, by the chat service's owner. One marks
-- its room as needing you (that session's status) until you look at the
-- room in any session, and the hub tells you of it wherever you are,
-- through the Greed window or terminal on the machine you're at. With
-- `chat-alerts-desktop` it goes to the desktop's own notifications too
-- (notify-send or osascript), for when no Greed is attached. A room shown
-- in any session doesn't alert. `:chat-alerted` goes to the room of the
-- latest.

local greed = require("@greed")
local core = require("@core")
local backend = require("./backend")
local room = require("./room")

local M = {}

greed.option.define({
	name = "chat-alerts",
	doc = "Which new messages tell you: mentions and direct messages, all the service notifies of, or none",
	default = "mentions",
	choices = { "mentions", "all", "off" },
})

greed.option.define({
	name = "chat-alerts-desktop",
	doc = "Show chat alerts as the desktop's own notifications too (notify-send or osascript), for when no Greed is attached to tell you",
	default = false,
})

-- The most cells a message shows in a notification.
local LONGEST = 200

--- Whether `alert` tells you, by the `chat-alerts` option.
function M.wanted(alert: backend.Alert): boolean
	local which = greed.option.get("chat-alerts")
	if which == "off" then
		return false
	elseif which == "all" then
		return true
	end
	return alert.mention or alert.direct
end

--- The key a room needs you under (`core.attention`).
function M.key(account: string, room_id: string): string
	return `chat-room:{account}|{room_id}`
end

--- The notification `alert` makes: its title and text.
function M.said(alert: backend.Alert): (string, string)
	local text = core.text.clip(core.text.trim(alert.body), LONGEST)
	local title = if alert.direct and alert.room_name == alert.sender.name
		then alert.sender.name
		else `{alert.sender.name} in {alert.room_name}`
	return title, text
end

-- The latest alert, with its account, for `:chat-alerted`.
local latest: { account: string, alert: backend.Alert }? = nil

backend.on_alert(function(account: string, alert: backend.Alert)
	if
		not M.wanted(alert)
		or room.shown(account, alert.room)
		or backend.shown_anywhere(account, alert.room)
	then
		return
	end
	local title, text = M.said(alert)
	core.attention.set(M.key(account, alert.room), { label = title, reason = text, tell = true })
	if greed.option.get("chat-alerts-desktop") == true then
		core.desktop.notify(title, text)
	end
	backend.alerted(account, alert)
end)

backend.on_alerted(function(account: string, alert: backend.Alert)
	latest = { account = account, alert = alert }
end)

backend.on_read(function(account: string, room_id: string)
	core.attention.set(M.key(account, room_id), nil)
end)

greed.command({
	name = "chat-alerted",
	doc = "Go to the room of the latest chat alert",
	run = function(ctx: greed.Context)
		if latest == nil then
			greed.echo("no chat alerts yet")
			return
		end
		room.open(latest.account, latest.alert.room, latest.alert.room_name, nil, ctx.view)
	end,
})

return M
