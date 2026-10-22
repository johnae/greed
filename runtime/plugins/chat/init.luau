-- Chat: Matrix and Mattermost in Greed. In the chat session (`greed chat`)
-- the page lists your rooms and channels, those with something unread
-- first; elsewhere `:chat` opens the same list in a float. `enter` opens a
-- room: its messages, kept up to date, and a box under them where `enter`
-- sends what's written (as Markdown) and `alt-enter` starts a new line.
-- `:chat-login` signs in to a server, by password or through the browser;
-- `:chat-logout` signs out. The services run as programs of their own
-- (backend.luau).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local backend = require("@self/backend")
local room = require("@self/room")

local ui = core.ui

local M = {}

M.backend = backend

-- The list of rooms, while it's open.
type List = {
	buffer: greed.Buffer,
	view: core.UiView,
	--- Each account's rooms, by "service id".
	rooms: { [string]: { backend.Room } },
	trouble: string?,
}

local list: List? = nil

--- A room's marker: what kind of room it is.
function M.marker(room: backend.Room): string
	if room.kind == "direct" then
		return "@"
	elseif room.kind == "group" then
		return "@@"
	elseif room.kind == "invite" then
		return "+"
	end
	return "#"
end

--- A dot for whether someone's around: green online, amber away or busy,
--- dim when they're offline or it isn't known.
function M.presence(presence: string?): string
	if presence == "online" then
		return " 🟢"
	elseif presence == "away" or presence == "dnd" then
		return " 🟡"
	elseif presence == "offline" then
		return " ⚪"
	end
	return ""
end

--- Opens room `room` of account `key` in `window`.
function M.room(key: string, shown: backend.Room, window: greed.View?)
	room.open(key, shown.id, shown.name, nil, window)
end

--- The rooms to list, unread and recent first; spaces aren't listed.
function M.sorted(rooms: { backend.Room }): { backend.Room }
	local out: { backend.Room } = {}
	for _, room in rooms do
		if room.kind ~= "space" then
			table.insert(out, room)
		end
	end
	table.sort(out, function(a: backend.Room, b: backend.Room): boolean
		if (a.mentions > 0) ~= (b.mentions > 0) then
			return a.mentions > 0
		end
		if (a.unread > 0) ~= (b.unread > 0) then
			return a.unread > 0
		end
		if (a.active or 0) ~= (b.active or 0) then
			return (a.active or 0) > (b.active or 0)
		end
		return a.name < b.name
	end)
	return out
end

local function render_list(o: List): core.UiNode
	local parts: { core.UiNode } = {}
	if o.trouble then
		table.insert(parts, ui.text(o.trouble, "diagnostic.error"))
	end
	local keys: { string } = {}
	for key in backend.accounts do
		table.insert(keys, key)
	end
	table.sort(keys)
	if #keys == 0 then
		table.insert(parts, ui.text("No accounts yet: :chat-login signs in.", "comment"))
	end
	for _, key in keys do
		local account = backend.accounts[key]
		local state = account.state.state
		local said = if state == "trouble"
			then `  {account.state.why or "trouble"}`
			elseif state == "syncing" then "  syncing…"
			else ""
		table.insert(
			parts,
			ui.line({
				ui.span(account.name or account.id, "keyword"),
				ui.span(`  {account.service} · {account.server}`, "comment"),
				ui.span(said, if state == "trouble" then "diagnostic.error" else "comment"),
			})
		)
		local rows: { core.UiGridRow } = {}
		for _, room in M.sorted(o.rooms[key] or {}) do
			local value = { account = key, room = room }
			table.insert(rows, {
				cells = {
					{
						ui.span(M.marker(room), "comment"),
						ui.span(M.presence(room.presence)),
					},
					{ ui.span(room.name, if room.unread > 0 then "keyword" else nil) },
					{
						ui.span(
							if room.mentions > 0 then `@{room.mentions}` else "",
							"diagnostic.warning"
						),
						ui.span(if room.unread > 0 then ` {room.unread}` else "", "function"),
					},
				},
				value = value,
			})
		end
		table.insert(parts, ui.grid(rows))
		table.insert(parts, ui.gap())
	end
	return ui.column(parts)
end

-- Fetches account `key`'s rooms into the list, and draws it again.
local function fetch_rooms(o: List, key: string)
	local service, id = backend.split(key)
	local rooms, why = backend.ask(service, "rooms", { account = id })
	if rooms then
		o.rooms[key] = rooms
	else
		o.trouble = why
	end
	if o.buffer:valid() then
		o.view:redraw()
	end
end

--- The list of rooms in `window`, or a float when there's none.
function M.list(window: greed.View?)
	local buffer = greed.create_buffer("chat", "", { readonly = true })
	buffer:set_line_numbers(false)
	local o: List
	local view = ui.mount(buffer, function()
		return render_list(o)
	end, {}, {
		key = function(value: any): string
			return `{value.account} {value.room.id}`
		end,
		draw = false,
	})
	local made: List = { buffer = buffer, view = view, rooms = {}, trouble = nil }
	o = made
	list = o
	view:redraw()
	buffer:set_kept(true)
	if window then
		window:show(buffer)
	else
		greed.float(buffer, { title = "Chat", width = "70%", height = "80%" })
	end
	greed.spawn(function()
		backend.start()
		for key in backend.accounts do
			fetch_rooms(o, key)
		end
		view:redraw()
		-- On the first room, rather than an account's name.
		local first = view:line_of(function(value: any): boolean
			return value ~= nil
		end)
		for _, shown in buffer:views() do
			if first and view:value_at(shown:cursor()) == nil then
				shown:set_cursor(buffer:line_start(first))
			end
		end
	end)
end

backend.on_rooms(function(key: string)
	local o = list
	if o and o.buffer:valid() then
		greed.spawn(function()
			fetch_rooms(o, key)
		end)
	end
end)

backend.on_accounts(function()
	local o = list
	if o and o.buffer:valid() then
		o.view:redraw()
	end
end)

greed.command({
	name = "chat",
	doc = "Your rooms and channels: the page in the chat session, a float elsewhere",
	run = function()
		M.list(if backend.here() then greed.view() else nil)
	end,
})

greed.command({
	name = "chat-session",
	doc = "Go to the chat session, starting it if it isn't running",
	run = function()
		greed.session.switch({ name = backend.SESSION })
	end,
})

greed.command({
	name = "chat-open",
	doc = "In the list of rooms: open the room under the cursor",
	run = function(ctx)
		local o = list
		if o == nil or o.buffer ~= ctx.buffer then
			return
		end
		local value = o.view:value_at(ctx.view:cursor())
		if value then
			M.room(value.account, value.room, ctx.view)
		end
	end,
})

-- Asks for each of `fields`: their values by name, or nil if cancelled.
local function ask_fields(fields: { any }, why: string?): { [string]: string }?
	if why then
		greed.echo(why)
	end
	local values: { [string]: string } = {}
	for _, field in fields do
		local answer = core.prompt.ask(field.label, nil, { secret = field.secret })
		if answer == nil then
			return nil
		end
		values[field.name] = answer
	end
	return values
end

-- Goes through a sign-in's steps from `step` until it's done or given up.
local function follow(service: string, login: string, first: any)
	local step = first
	while step do
		local kind = step.step
		local answer: any = nil
		if kind == "ask" then
			local values = ask_fields(step.fields, step.why)
			if values == nil then
				backend.ask(service, "login.cancel", { login = login })
				return
			end
			answer = values
		elseif kind == "open" then
			core.file.open_link(step.url)
			local link = core.prompt.ask(
				`Signing in in the browser. If it doesn't come back by itself, paste {step.paste or "the link it ends on"}`
			)
			if link == nil or link == "" then
				-- It may come back by itself; `login.step` says so.
				return
			end
			answer = { link = link }
		elseif kind == "code" then
			greed.echo(`Go to {step.url} and enter {step.code}`)
			return
		elseif kind == "done" then
			backend.signed_in(service, step)
			greed.echo(`signed in as {step.account.name or step.account.id}`)
			return
		elseif kind == "failed" then
			greed.echo(`chat: {step.why}`)
			return
		else
			greed.echo(`chat: this sign-in needs {kind}, which isn't here yet`)
			return
		end
		local next_step, why =
			backend.ask(service, "login.answer", { login = login, values = answer })
		if next_step == nil then
			greed.echo(`chat: {why}`)
			return
		end
		step = next_step
	end
end

-- Sign-ins whose browser may come back by themselves, by login id.
local waiting: { [string]: string } = {}

backend.on_step(function(login: string, step: any)
	local service = waiting[login]
	if service then
		waiting[login] = nil
		greed.spawn(function()
			follow(service, login, step)
		end)
	end
end)

greed.command({
	name = "chat-login",
	doc = "Sign in to a Matrix or Mattermost server",
	run = function()
		local items = {}
		for _, service in backend.SERVICES do
			table.insert(items, { label = service, value = service })
		end
		picker.pick("Sign in to", items, function(chosen)
			local service: string = chosen.value
			greed.spawn(function()
				local server = core.prompt.ask(`The {service} server, like example.org`)
				if server == nil or server == "" then
					return
				end
				local methods, why = backend.ask(service, "login.methods", { server = server })
				if methods == nil then
					greed.echo(`chat: {why}`)
					return
				end
				local offered = {}
				for _, method in methods do
					local label = if method.kind == "password"
						then "Password"
						elseif method.kind == "browser" then `In the browser: {method.name}`
						else method.kind
					table.insert(offered, { label = label, value = method })
				end
				picker.pick("Sign in with", offered, function(how)
					greed.spawn(function()
						local started, trouble = backend.ask(
							service,
							"login.start",
							{ server = server, method = how.value }
						)
						if started == nil then
							greed.echo(`chat: {trouble}`)
							return
						end
						waiting[started.login] = service
						follow(service, started.login, started.step)
					end)
				end)
			end)
		end)
	end,
})

greed.command({
	name = "chat-logout",
	doc = "Sign out of a chat account, and forget it",
	run = function()
		local items = {}
		for key, account in backend.accounts do
			table.insert(
				items,
				{ label = `{account.name or account.id} ({account.service})`, value = key }
			)
		end
		picker.pick("Sign out of", items, function(chosen)
			greed.spawn(function()
				local why = backend.logout(chosen.value)
				greed.echo(if why then `chat: {why}` else "signed out")
			end)
		end)
	end,
})

greed.keymap.bind({ kind = "chat" }, {
	enter = "chat-open",
	q = "chat-close",
})

-- The chat session opens on the list, and keeps the accounts connected.
greed.on("editor.started", function()
	if backend.here() then
		M.list(greed.view())
	end
end)

core.about.kind("chat", function(): string
	return "Greed's chat: the list of the user's Matrix and Mattermost rooms"
end)

--- The room view (room.luau).
M.rooms = room
M.apply = room.apply
M.runs_on = room.runs_on

-- Leaving a room goes back to the list, where there is one.
room.on_leave = function(view: greed.View)
	local o = list
	if o and o.buffer:valid() and view:buffer() ~= o.buffer then
		view:show(o.buffer)
	end
end

return M
