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
local markdown = require("@markdown")

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

-- An open room: its account ("service id"), its id, what it shows.
type Open = {
	account: string,
	room: string,
	name: string,
	buffer: greed.Buffer,
	view: core.UiView,
	items: { backend.Item },
	--- What the message under the cursor would be answered with, if set.
	replying: backend.Item?,
}

-- Open rooms, by "service id room".
local open: { [string]: Open } = {}

-- The account's service and its id there, from "service id".
local function split(key: string): (string, string)
	local service, id = string.match(key, "^(%S+) (.*)$")
	return service or key, id or ""
end

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
					{ ui.span(M.marker(room), "comment") },
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
	local service, id = split(key)
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

--- A message's time of day, or its day too when it isn't today's.
function M.when(at: number): string
	local seconds = at // 1000
	if os.date("%Y-%m-%d", seconds) == os.date("%Y-%m-%d") then
		return os.date("%H:%M", seconds) :: string
	end
	return os.date("%b %d %H:%M", seconds) :: string
end

-- What a line of a room stands for: its item, and whether it's the
-- message's text (Markdown) rather than who sent it, when, and the like.
export type Line = { item: backend.Item, body: boolean }

-- `node`'s lines, each standing for `item`; `body` when they're its text.
local function valued(node: core.UiNode, item: backend.Item, body: boolean): core.UiNode
	local value: Line = { item = item, body = body }
	return {
		lay = function(cells: number): { core.UiLine }
			local lines = node.lay(cells)
			for _, line in lines do
				if not line[1] then
					table.insert(line, ui.span("", nil))
				end
				line[1].value = value
			end
			return lines
		end,
	}
end

-- What a message that isn't text says instead, or its text.
local function said(item: backend.Item): string
	if item.kind == "deleted" then
		return "*(deleted)*"
	elseif item.kind == "unreadable" then
		return "*(can't be read here yet: its key hasn't come)*"
	elseif item.kind == "emote" then
		return `*{item.sender.name}* {item.text}`
	end
	return item.text
end

--- How an item reads in a room.
function M.item_node(item: backend.Item, previous: backend.Item?): core.UiNode?
	if item.kind == "day" then
		return ui.line({
			ui.span(`── {os.date("%A %d %B", item.at // 1000)} ──`, "comment"),
		})
	elseif item.kind == "read_marker" then
		return ui.line({ ui.span("── new ──", "diagnostic.warning") })
	elseif item.kind == "start" then
		return ui.line({ ui.span("The start of the room", "comment") })
	elseif item.kind == "change" or item.kind == "call" then
		local what = if item.kind == "call" then `{item.sender.name} started a call` else item.text
		return valued(ui.text(`{M.when(item.at)}  {what}`, "comment"), item, false)
	end
	local parts: { core.UiNode } = {}
	-- The sender over a run of their messages, as chat clients show it.
	local same = previous ~= nil
		and M.is_message(previous)
		and previous.sender.id == item.sender.id
		and item.at - previous.at < 5 * 60 * 1000
	-- A blank line between people, and after Markdown that would run on
	-- into what comes next (a quote, a list, code).
	if previous and (not same or M.runs_on(said(previous))) then
		table.insert(parts, ui.gap())
	end
	if not same or item.thread then
		local head = {
			ui.span(item.sender.name, if item.mine then "function" else "keyword"),
			ui.span(`  {M.when(item.at)}`, "comment"),
		}
		if item.thread then
			table.insert(head, ui.span("  ↳ in a thread", "comment"))
		end
		table.insert(parts, valued(ui.line(head), item, false))
	end
	if M.attached(item) then
		table.insert(parts, valued(ui.line(M.attachment_spans(item)), item, false))
	end
	if item.text ~= "" or item.kind ~= "message" then
		table.insert(parts, valued(ui.text(said(item)), item, true))
	end
	local notes: { core.UiSpan } = {}
	for _, reaction in item.reactions do
		table.insert(
			notes,
			ui.span(
				` {reaction.key} {reaction.count} `,
				if reaction.mine then "function" else "comment"
			)
		)
	end
	if item.edited then
		table.insert(notes, ui.span(" (edited)", "comment"))
	end
	if item.replies > 0 then
		table.insert(notes, ui.span(` {item.replies} replies`, "comment"))
	end
	if item.sending then
		local failed = item.sending.state == "failed"
		table.insert(
			notes,
			ui.span(
				if failed then ` not sent: {item.sending.why}` else " sending…",
				if failed then "diagnostic.error" else "comment"
			)
		)
	end
	if #notes > 0 then
		table.insert(parts, valued(ui.line(notes), item, false))
	end
	return ui.column(parts)
end

--- Whether `item` is something someone wrote or sent, rather than a day
--- starting or the room changing.
function M.is_message(item: backend.Item): boolean
	local kind = item.kind
	return kind ~= "day"
		and kind ~= "read_marker"
		and kind ~= "start"
		and kind ~= "change"
		and kind ~= "call"
end

--- Whether Markdown `text` ends in what the next line would join: a
--- quote, a list's item, indented code.
function M.runs_on(text: string): boolean
	local last = string.match(text, "([^\n]*)%s*$") or ""
	return string.match(last, "^%s*>") ~= nil
		or string.match(last, "^%s*[-*+] ") ~= nil
		or string.match(last, "^%s*%d+[.)] ") ~= nil
		or string.match(last, "^    ") ~= nil
end

--- Whether `item` is a file, a picture or the like.
function M.attached(item: backend.Item): boolean
	local kind = item.kind
	return kind == "image"
		or kind == "file"
		or kind == "video"
		or kind == "audio"
		or kind == "sticker"
end

--- What an attachment shows as.
function M.attachment_spans(item: backend.Item): { core.UiSpan }
	local icon = ({
		image = "🖼",
		video = "🎞",
		audio = "🔊",
		sticker = "🖼",
		file = "📄",
	})[item.kind] or "📄"
	return { ui.span(`{icon} {item.kind}`, "markdown.link") }
end

local function render_room(r: Open): core.UiNode
	local parts: { core.UiNode } = {}
	local previous: backend.Item? = nil
	for _, item in r.items do
		local node = M.item_node(item, previous)
		if node then
			table.insert(parts, node)
		end
		previous = item
	end
	local replying = r.replying
	table.insert(parts, ui.gap())
	table.insert(
		parts,
		ui.text(
			if replying
				then `replying to {replying.sender.name} (esc: not)`
				else "enter sends · alt-enter new line",
			"comment"
		)
	)
	return ui.column(parts)
end

--- Applies a timeline's `changes` to `items`, as the protocol says.
function M.apply(items: { backend.Item }, changes: { any })
	for _, change in changes do
		local op = change.op
		if op == "reset" then
			table.clear(items)
			for _, item in change.items do
				table.insert(items, item)
			end
		elseif op == "insert" then
			table.insert(items, change.at + 1, change.item)
		elseif op == "set" then
			items[change.at + 1] = change.item
		elseif op == "remove" then
			table.remove(items, change.at + 1)
		elseif op == "truncate" then
			for _ = change.len + 1, #items do
				table.remove(items)
			end
		elseif op == "clear" then
			table.clear(items)
		end
	end
end

-- The view of the open room in `buffer`, if it's one.
local function open_view(buffer: greed.Buffer): core.UiView?
	for _, r in open do
		if r.buffer == buffer then
			return r.view
		end
	end
	return nil
end

--- Opens room `room` of account `key` in `window`: its messages and the
--- box to write in.
function M.room(key: string, room: backend.Room, window: greed.View?)
	local whole = `{key} {room.id}`
	local target = window or greed.view()
	local already = open[whole]
	if already and already.buffer:valid() then
		target:show(already.buffer)
		target:set_cursor(already.buffer:len())
		return
	end
	local buffer = greed.create_buffer("chat-room", "", { language = "markdown" })
	buffer:set_line_numbers(false)
	-- Only what people wrote is Markdown; who, when and the rest show as
	-- they are. What you write in the box is Markdown too.
	markdown.plain(
		buffer,
		setmetatable({}, {
			__index = function(_, line: number): boolean?
				local shown = open_view(buffer)
				if shown == nil or line >= buffer:line_of(shown:input_start()) then
					return nil
				end
				local value: Line? = shown:value_on(line)
				return not (value and value.body)
			end,
		}) :: any
	)
	local r: Open
	local view = ui.mount(buffer, function()
		return render_room(r)
	end, {}, { ns = "chat", input = true, keys = false, draw = false })
	local made: Open = {
		account = key,
		room = room.id,
		name = room.name,
		buffer = buffer,
		view = view,
		items = {},
		replying = nil,
	}
	r = made
	open[whole] = r
	target:show(buffer)
	greed.spawn(function()
		local service, id = split(key)
		local opened, why = backend.ask(service, "timeline", { account = id, room = room.id })
		if opened then
			r.items = opened.items
		else
			greed.echo(`chat: {why}`)
		end
		view:redraw()
		target:set_cursor(buffer:len())
	end)
end

-- The room the view is on, if it's one.
local function room_of(buffer: greed.Buffer): Open?
	for _, r in open do
		if r.buffer == buffer then
			return r
		end
	end
	return nil
end

backend.on_timeline(function(key: string, room: string, changes: { any })
	local r = open[`{key} {room}`]
	if r == nil or not r.buffer:valid() then
		return
	end
	M.apply(r.items, changes)
	r.view:soon()
end)

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

greed.command({
	name = "chat-send",
	doc = "In a room: send what's written in its box",
	run = function(ctx)
		local r = room_of(ctx.buffer)
		if r == nil then
			return
		end
		local text = core.text.trim(r.view:input())
		if text == "" then
			return
		end
		local replying = r.replying
		r.replying = nil
		local buffer = r.buffer
		buffer:edit(function(e)
			e:replace(r.view:input_start(), buffer:len(), "")
		end)
		local service, id = split(r.account)
		local _, why = backend.ask(service, "send", {
			account = id,
			room = r.room,
			text = text,
			reply_to = if replying then replying.event else nil,
		})
		if why then
			greed.echo(`chat: {why}`)
		end
	end,
})

greed.command({
	name = "chat-newline",
	doc = "In a room's box: start a new line",
	run = function(ctx)
		local at = ctx.view:cursor()
		ctx.buffer:edit(function(e)
			e:replace(at, at, "\n")
		end)
		ctx.view:set_cursor(at + 1)
	end,
})

greed.command({
	name = "chat-reply",
	doc = "In a room: answer the message under the cursor with what's sent next",
	run = function(ctx)
		local r = room_of(ctx.buffer)
		if r == nil then
			return
		end
		local line: Line? = r.view:value_at(ctx.view:cursor())
		local item = line and line.item
		if item and item.event then
			r.replying = item
			r.view:redraw()
			ctx.view:set_cursor(ctx.buffer:len())
		end
	end,
})

greed.command({
	name = "chat-older",
	doc = "In a room: fetch older messages",
	run = function(ctx)
		local r = room_of(ctx.buffer)
		if r == nil then
			return
		end
		local service, id = split(r.account)
		local _, why = backend.ask(service, "timeline.back", { account = id, room = r.room })
		if why then
			greed.echo(`chat: {why}`)
		end
	end,
})

greed.command({
	name = "chat-close",
	doc = "In a room: back to the list of rooms",
	run = function(ctx)
		local r = room_of(ctx.buffer)
		if r and r.replying then
			r.replying = nil
			r.view:redraw()
			return
		end
		if r then
			local service, id = split(r.account)
			open[`{r.account} {r.room}`] = nil
			greed.spawn(function()
				backend.ask(service, "timeline.close", { account = id, room = r.room })
			end)
		end
		local o = list
		if o and o.buffer:valid() then
			ctx.view:show(o.buffer)
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

greed.keymap.bind({ kind = "chat-room" }, {
	["alt-up"] = "chat-older",
	["alt-r"] = "chat-reply",
})

-- Out of the box only, so esc while writing leaves writing as it does.
greed.keymap.bind({ role = "command", kind = "chat-room" }, {
	q = "chat-close",
	esc = "chat-close",
})

greed.keymap.bind({ role = "typing", kind = "chat-room" }, {
	enter = "chat-send",
	["alt-enter"] = "chat-newline",
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

core.about.kind("chat-room", function(buffer: greed.Buffer): string
	local r = room_of(buffer)
	return if r then `A chat room, {r.name}: its messages and a box to write in` else "A chat room"
end)

return M
