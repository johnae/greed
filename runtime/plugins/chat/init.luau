-- Chat: Matrix and Mattermost in Greed. In the chat session (`greed chat`)
-- a sidebar lists your rooms and channels, those with something unread
-- first, then each space (or team) with its rooms under it, and rooms open
-- beside it; elsewhere `:chat` opens the same list in a float of the tab,
-- rooms opening in its place. A room shows its messages, kept up to date,
-- and a box under them where `enter` sends what's written (as Markdown)
-- and `alt-enter` starts a new line; `enter` on a space offers the rooms
-- it holds. `:chat-login` signs in to a server, by password or through the
-- browser; `:chat-logout` signs out. The services run as programs of their
-- own (backend.luau).

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local panes = require("@panes")
local backend = require("@self/backend")
local encryption = require("@self/encryption")
local alerts = require("@self/alerts")
local search = require("@self/search")
local join = require("@self/join")
local room = require("@self/room")

local ui = core.ui

local M = {}

M.backend = backend
M.alerts = alerts
M.search = search
M.join = join

-- The list of rooms, while it's open.
type List = {
	buffer: greed.Buffer,
	view: core.UiView,
	--- Each account's rooms, by "service id".
	rooms: { [string]: { backend.Room } },
	--- What's wrong with each account's encryption, where something is.
	encryption: { [string]: string? },
	trouble: string?,
}

local list: List? = nil

--- A server as the list names it: its address without the scheme or a
--- slash at the end ("https://matrix.org/" is "matrix.org"), so it fits
--- a sidebar.
function M.host(server: string): string
	local bare = string.gsub(server, "^%a+://", "")
	return (string.gsub(bare, "/+$", ""))
end

--- A room's marker: what kind of room it is.
function M.marker(room: backend.Room): string
	if room.kind == "direct" then
		return "@"
	elseif room.kind == "group" then
		return "@@"
	elseif room.kind == "invite" then
		return "+"
	elseif room.kind == "space" then
		return "◆"
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

--- The rooms to list, unread and recent first; spaces are `grouped`'s.
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

--- A space (or team) with the rooms of yours in it, as the list shows it;
--- the first group, with no space, has the rooms in none.
export type Group = { space: backend.Room?, rooms: { backend.Room } }

--- `rooms` grouped by the space they're in: those in none first, then
--- each space by name, each group's rooms as `sorted` orders them.
function M.grouped(rooms: { backend.Room }): { Group }
	local spaces: { backend.Room } = {}
	local by: { [string]: Group } = {}
	for _, one in rooms do
		if one.kind == "space" then
			table.insert(spaces, one)
			by[one.id] = { space = one, rooms = {} }
		end
	end
	table.sort(spaces, function(a: backend.Room, b: backend.Room): boolean
		return a.name < b.name
	end)
	local loose: Group = { space = nil, rooms = {} }
	for _, one in M.sorted(rooms) do
		local group = if one.parent then by[one.parent] else nil
		table.insert((group or loose).rooms, one)
	end
	local out = { loose }
	for _, space in spaces do
		table.insert(out, by[space.id])
	end
	return out
end

-- A room's row in the list, its name indented under a space's.
local function room_row(key: string, one: backend.Room, under: boolean): core.UiGridRow
	local name = if under then `  {one.name}` else one.name
	local strong = one.unread > 0 or one.kind == "space"
	return {
		cells = {
			{
				ui.span(M.marker(one), "comment"),
				ui.span(M.presence(one.presence)),
			},
			{ ui.span(name, if strong then "keyword" else nil) },
			{
				ui.span(if one.mentions > 0 then `@{one.mentions}` else "", "diagnostic.warning"),
				ui.span(if one.unread > 0 then ` {one.unread}` else "", "function"),
			},
		},
		value = { account = key, room = one },
	}
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
				ui.span(`  {account.service} · {M.host(account.server)}`, "comment"),
				ui.span(said, if state == "trouble" then "diagnostic.error" else "comment"),
			})
		)
		local unverified = o.encryption[key]
		if unverified then
			table.insert(parts, ui.text(unverified, "diagnostic.warning"))
		end
		local rows: { core.UiGridRow } = {}
		local rooms: { backend.Room } = o.rooms[key] or {}
		for _, group in M.grouped(rooms) do
			local space = group.space
			if space then
				table.insert(rows, room_row(key, space, false))
			end
			for _, one in group.rooms do
				table.insert(rows, room_row(key, one, space ~= nil))
			end
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
	local can = backend.can[service]
	if can and can.encryption then
		local state = backend.ask(service, "encryption.state", { account = id })
		o.encryption[key] = if state then encryption.trouble(state) else nil
	end
	if rooms then
		o.rooms[key] = rooms
	else
		o.trouble = why
	end
	if o.buffer:valid() then
		o.view:redraw()
	end
	-- The bar over a room shows what's unread in each.
	room.redraw()
end

-- Puts `window`'s cursor in list `o` on room `left` (the one just left),
-- or else on the first room, rather than an account's name.
local function on_room(o: List, window: greed.View, left: { account: string, room: string }?)
	local line = o.view:line_of(function(value: any): boolean
		return value ~= nil
			and (left == nil or (value.account == left.account and value.room.id == left.room))
	end) or o.view:line_of(function(value: any): boolean
		return value ~= nil
	end)
	if line then
		window:set_cursor(o.buffer:line_start(line))
	end
end

-- Shows list `o` in `window`, in place of the room there, on that room.
local function show_list(o: List, window: greed.View)
	local left = room.of(window:buffer())
	window:show(o.buffer)
	on_room(o, window, left)
end

--- The tab's float showing chat (the list or a room), if there is one.
local function chat_float(): greed.View?
	for _, view in panes.floats.all() do
		local kind = view:buffer():kind()
		if kind == "chat" or kind == "chat-room" then
			return view
		end
	end
	return nil
end

-- A new list of rooms, filled as the services answer, its cursor put on
-- the first room in each view showing it by then.
local function new_list(): List
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
	local made: List = { buffer = buffer, view = view, rooms = {}, encryption = {}, trouble = nil }
	o = made
	list = o
	view:redraw()
	buffer:set_kept(true)
	greed.spawn(function()
		backend.start()
		for key in backend.accounts do
			fetch_rooms(o, key)
		end
		view:redraw()
		for _, shown in buffer:views() do
			if view:value_at(shown:cursor()) == nil then
				on_room(o, shown, nil)
			end
		end
	end)
	return o
end

--- The list of rooms in a float of the tab, which `alt-f` hides and shows
--- like the others; one there already comes to the front, showing the
--- list again where it showed a room.
function M.list()
	local shown = chat_float()
	if shown then
		panes.floats.focus(shown)
		-- The rooms, rather than the room it shows: the bar over a room
		-- has the ones opened.
		local o = list
		if shown:buffer():kind() == "chat-room" and o and o.buffer:valid() then
			show_list(o, shown)
		end
		return
	end
	local o = new_list()
	panes.floats.show(o.buffer, { title = "Chat", width = "70%", height = "80%" })
end

-- The panel showing the list of rooms, if one does.
local function sidebar(): greed.View?
	local o = list
	if o == nil or not o.buffer:valid() then
		return nil
	end
	for _, view in o.buffer:views() do
		if not view:is_pane() and not table.find(panes.floats.all(), view) then
			return view
		end
	end
	return nil
end

--- The list of rooms as a sidebar, a panel on the left, with the rooms
--- opening in the main view beside it; the one there already is focused.
function M.sidebar()
	local shown = sidebar()
	if shown then
		shown:focus()
		return
	end
	local o = if list and list.buffer:valid() then list else new_list()
	local panel = greed.panel(o.buffer, { side = "left", width = 34, title = "Chat" })
	on_room(o, panel, nil)
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
	doc = "Your rooms and channels: a sidebar in the chat session, a float elsewhere",
	run = function()
		if backend.here() then
			M.sidebar()
		else
			M.list()
		end
	end,
})

greed.command({
	name = "chat-sidebar",
	doc = "Your rooms and channels as a sidebar on the left, rooms opening beside it",
	run = function()
		M.sidebar()
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
	doc = "In the list of rooms: open the room under the cursor, answer its invite, or offer a space's rooms",
	run = function(ctx)
		local o = list
		if o == nil or o.buffer ~= ctx.buffer then
			return
		end
		local value = o.view:value_at(ctx.view:cursor())
		if value == nil then
			return
		elseif value.room.kind == "invite" then
			greed.spawn(join.answer, value.account, value.room.id, value.room.name, ctx.view)
		elseif value.room.kind == "space" then
			greed.spawn(join.browse, value.account, value.room.id, value.room.name, ctx.view)
		else
			M.room(value.account, value.room, ctx.view)
		end
	end,
})

greed.command({
	name = "chat-leave",
	doc = "Leave the room under the cursor in the list, or the room you're in, after asking",
	run = function(ctx)
		local o = list
		local r = room.of(ctx.buffer)
		if r then
			greed.spawn(join.leave, r.account, r.room, r.name, function()
				room.on_leave(ctx.view)
			end)
		elseif o and o.buffer == ctx.buffer then
			local value = o.view:value_at(ctx.view:cursor())
			if value then
				greed.spawn(join.leave, value.account, value.room.id, value.room.name)
			end
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

-- Sign-ins whose browser may come back by themselves, or whose link may
-- come through `greed link`, by login id.
local waiting: { [string]: string } = {}

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
				-- It may come back by itself (`login.step`) or through
				-- `greed link`.
				return
			end
			if waiting[login] == nil then
				-- The link came another way meanwhile.
				return
			end
			waiting[login] = nil
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

backend.on_step(function(login: string, step: any)
	local service = waiting[login]
	if service then
		waiting[login] = nil
		greed.spawn(function()
			follow(service, login, step)
		end)
	end
end)

--- Hands `link`, the one a browser sign-in ended on, to the sign-in
--- waiting for it: a `mattermost:` link to Mattermost's, one of Greed's own
--- (`io.github.johnae:`, as OAuth may end on) to Matrix's, any other to the
--- first waiting. Whether one took it.
function M.link(link: string): boolean
	local wanted = if string.match(link, "^mattermost:")
		then "mattermost"
		elseif string.match(link, "^io%.github%.johnae:") then "matrix"
		else nil
	for login, service in waiting do
		if wanted == nil or service == wanted then
			waiting[login] = nil
			greed.spawn(function()
				local values = { link = link }
				local step, why =
					backend.ask(service, "login.answer", { login = login, values = values })
				if step then
					follow(service, login, step)
				else
					greed.echo(`chat: {why}`)
				end
			end)
			return true
		end
	end
	return false
end

greed.command({
	name = "chat-link",
	doc = "Finish signing in with the link the browser ended on (what `greed link` hands over)",
	args = { { name = "link", doc = "the link", type = "string" } },
	run = function(ctx)
		if not M.link(ctx.values.link) then
			greed.echo("no sign-in is waiting for a link: :chat-login starts one")
		end
	end,
})

-- A mattermost: link, or one of Greed's own, opened in Greed as a sign-in
-- in the browser ends on, finishes signing in.
for _, scheme in { "mattermost", "io.github.johnae" } do
	core.file.link_scheme(scheme, function(uri: string)
		if not M.link(uri) then
			greed.echo("no sign-in is waiting for that link")
		end
	end)
end

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
	["/"] = "chat-search",
	["+"] = "chat-join",
	["-"] = "chat-leave",
	q = "chat-close",
})

-- The chat session opens on the list, and keeps the accounts connected.
greed.on("editor.started", function()
	if backend.here() then
		M.sidebar()
	end
end)

core.about.kind("chat", function(): string
	return "Greed's chat: the list of the user's Matrix and Mattermost rooms"
end)

--- The room view (room.luau).
M.rooms = room
M.apply = room.apply
M.runs_on = room.runs_on

-- What's unread in a room, for the bar over a room, as the list knows it.
room.unread = function(account: string, room_id: string): number
	local o = list
	local rooms: { backend.Room } = if o then o.rooms[account] or {} else {}
	for _, one in rooms do
		if one.id == room_id then
			return one.unread
		end
	end
	return 0
end

-- Leaving a room goes back to the list, on that room: to the sidebar,
-- the room staying beside it, or else the list in its place.
room.on_leave = function(view: greed.View)
	local left = room.of(view:buffer())
	local o = list
	if o == nil or not o.buffer:valid() or view:buffer() == o.buffer then
		return
	end
	local panel = sidebar()
	if panel then
		panel:focus()
		on_room(o, panel, left)
	else
		show_list(o, view)
	end
end

-- A room asked for from the sidebar opens in the main view beside it.
room.window_for = function(view: greed.View): greed.View
	return if view == sidebar() then greed.tab.current().active else view
end

return M
