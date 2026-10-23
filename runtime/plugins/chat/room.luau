-- A room's view: its messages, kept up to date, and a box under them to
-- write in. A thread opens the same way, with the thread's replies; what's
-- sent there goes in the thread. On a message: alt-r answers it, alt-t
-- opens its thread, alt-k reacts, alt-e changes it (yours), alt-d deletes
-- it, alt-b presses its buttons; `space .` offers the same. alt-s searches
-- the room; alt-/ picks a command (Mattermost) into the box. Whoever's
-- writing shows under the messages, and the room is marked read as you
-- look at it.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local markdown = require("@markdown")
local backend = require("./backend")

local ui = core.ui

local M = {}

-- An open room or thread: its account ("service id"), ids, what it shows.
export type Open = {
	account: string,
	room: string,
	--- The thread it is, by its first message's event; nil for a room.
	thread: string?,
	name: string,
	buffer: greed.Buffer,
	view: core.UiView,
	items: { backend.Item },
	--- What's sent next answers this.
	replying: backend.Item?,
	--- What's sent next changes this, one of yours.
	editing: backend.Item?,
	--- What started the thread, over its replies.
	first: backend.Item?,
	--- Who's writing in the room.
	typing: { string },
	--- When you last said you're writing, in seconds.
	said_typing: number,
	--- When the room was last marked read, in seconds.
	marked: number,
}

-- Open rooms and threads, by "service id room thread".
local open: { [string]: Open } = {}

local function key_of(account: string, room: string, thread: string?): string
	return `{account} {room} {thread or ""}`
end

-- What a line of a room stands for: its item, and whether it's the
-- message's text (Markdown) rather than who sent it, when, and the like.
export type Line = { item: backend.Item, body: boolean }

--- What's done when a room is left: back to the list (set by the plugin).
M.on_leave = function(_view: greed.View) end

--- Where a room asked for in `view` opens: there, or beside the list's
--- sidebar (set by the plugin).
M.window_for = function(view: greed.View): greed.View
	return view
end

--- Whether room `room` of account `key` is open and shown somewhere here.
function M.shown(key: string, room: string): boolean
	local r = open[key_of(key, room, nil)]
	return r ~= nil and r.buffer:valid() and #r.buffer:views() > 0
end

-- How often this session tells the owner which rooms it shows, in
-- milliseconds, while any is open; the owner forgets what it wasn't told
-- again for a while, as of a session that went.
local SHOWING_EVERY = 5000

-- The rooms this session shows to someone, as "key|room".
local function showing(): { string }
	local list = {}
	if not greed.session.attached() then
		return list
	end
	for _, r in open do
		if r.thread == nil and r.buffer:valid() and #r.buffer:views() > 0 then
			table.insert(list, `{r.account}|{r.room}`)
		end
	end
	table.sort(list)
	return list
end

local reporting = false

-- Tells the owner which rooms this session shows, so it doesn't alert you
-- of one you're reading: now, and every while as long as a room is open.
local function report()
	greed.spawn(backend.showing, showing())
	if reporting then
		return
	end
	reporting = true
	greed.spawn(function()
		while next(open) ~= nil do
			greed.sleep(SHOWING_EVERY)
			backend.showing(showing())
		end
		reporting = false
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

-- `node`'s lines, each standing for `item`; `body` when they're its text.
local function valued(node: core.UiNode, item: backend.Item, body: boolean): core.UiNode
	local value: Line = { item = item, body = body }
	return {
		lay = function(cells: number): { core.UiLine }
			local lines = node.lay(cells)
			for _, line in lines do
				if line[1] == nil then
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

--- What a file a message carries shows as: what kind, its name, how big.
function M.attachment_spans(item: backend.Item): { core.UiSpan }
	local media = item.media :: backend.Media
	local icons =
		{ image = "🖼", video = "🎞", audio = "🔊", sticker = "🖼", file = "📄" }
	local spans = { ui.span(`{icons[item.kind] or "📄"} {media.name}`, "markdown.link") }
	if media.size then
		table.insert(spans, ui.span(`  {core.text.bytes(media.size)}`, "comment"))
	end
	table.insert(spans, ui.span("  enter opens", "comment"))
	return spans
end

-- `r`'s service, and the room (and thread) with `extra` for its methods.
local function addressed(r: Open, extra: { [string]: any }?): (string, { [string]: any })
	local service, id = backend.split(r.account)
	local params: { [string]: any } = { account = id, room = r.room, thread = r.thread }
	local more: { [string]: any } = extra or {}
	for name, value in more do
		params[name] = value
	end
	return service, params
end

-- Asks `r`'s service `method`, with the room (and thread) and `extra`.
local function ask(r: Open, method: string, extra: { [string]: any }?): (any, string?)
	local service, params = addressed(r, extra)
	return backend.ask(service, method, params)
end

-- The bytes of the file a message in `r` carries, as `extra` says which.
local function carried(r: Open, extra: { [string]: any }): (string?, string?)
	local service, params = addressed(r, extra)
	return backend.media(service, params)
end

-- Small pictures of what messages carry, by "account room event": the
-- image to draw once it's fetched and read, or none while it's fetched.
local thumbnails: { [string]: { image: number? } } = {}

-- How wide a picture in a room is drawn at most, in cells.
local PICTURE_COLS = 40

-- The picture `item` carries, drawn over the rows under its line, once
-- it's here; until then nothing, and it's fetched.
local function picture(r: Open, item: backend.Item): core.UiNode?
	local media = item.media
	if media == nil or not media.thumbnail or item.event == nil then
		return nil
	end
	local key = `{r.account} {r.room} {item.event}`
	local known = thumbnails[key]
	if known == nil then
		thumbnails[key] = {}
		greed.spawn(function()
			local bytes = carried(r, { event = item.event, thumbnail = true })
			local image = if bytes then greed.image.decode(bytes) else nil
			thumbnails[key] = { image = image }
			if image and r.buffer:valid() then
				r.view:soon()
			end
		end)
		return nil
	end
	local image = known.image
	if image == nil then
		return nil
	end
	local natural_cols, natural_rows = greed.image.cells(image)
	if natural_cols == nil or natural_rows == nil then
		return nil
	end
	local scale = math.min(1, PICTURE_COLS / math.max(natural_cols, 1))
	local cols = math.max(1, math.round(natural_cols * scale))
	local rows = math.max(1, math.round(natural_rows * scale))
	local mark: greed.Mark = {
		from = 0,
		to = 0,
		style = "image.image",
		image = { id = image, cols = cols, rows = rows },
	}
	local lines: { core.UiLine } = { { { text = "", marks = { mark } } } }
	for _ = 2, rows do
		table.insert(lines, { ui.span("", nil) })
	end
	return {
		lay = function(_cells: number): { core.UiLine }
			return table.clone(lines)
		end,
	}
end

greed.option.define({
	name = "chat-previews",
	doc = "Show what links in chat messages lead to, under them, where the service can say",
	default = true,
})

--- The first link in `text`, without what ends the sentence after it.
function M.first_link(text: string): string?
	local link = string.match(text, "https?://[^%s<>()%[%]\"'`]+")
	if link == nil then
		return nil
	end
	return (string.gsub(link, "[.,;:!?]+$", ""))
end

-- What links lead to, by URL: the preview once it's come (none for a
-- link with none), or nothing while it's asked.
local previews: { [string]: { preview: backend.Preview? } } = {}

-- What `item`'s first link leads to: as it came with the message, or
-- asked of a service that previews; nothing until it's come.
local function link_preview(r: Open, item: backend.Item): backend.Preview?
	if greed.option.get("chat-previews") ~= true then
		return nil
	elseif item.preview then
		return item.preview
	end
	local service = backend.split(r.account)
	local can = backend.can[service]
	if not (can and can.previews) then
		return nil
	end
	local link = M.first_link(item.text)
	if link == nil then
		return nil
	end
	local url: string = link
	local known = previews[url]
	if known == nil then
		previews[url] = {}
		greed.spawn(function()
			local preview = ask(r, "preview", { url = url })
			previews[url] = { preview = preview }
			if preview and r.buffer:valid() then
				r.view:soon()
			end
		end)
		return nil
	end
	return known.preview
end

--- The lines a link's preview shows as: where and what, then a little of
--- what it says.
function M.preview_lines(preview: backend.Preview): { { core.UiSpan } }
	local site = preview.site or string.match(preview.url, "^%a+://([^/]+)") or preview.url
	local head = { ui.span("▎ ", "comment"), ui.span(site, "comment") }
	if preview.title then
		table.insert(head, ui.span(` · {preview.title}`, "markdown.link"))
	end
	local lines = { head }
	if preview.description then
		local text = string.gsub(preview.description, "%s+", " ")
		table.insert(lines, { ui.span(`▎ {core.text.clip(text, 120)}`, "comment") })
	end
	return lines
end

--- The lines a poll shows as: each answer with its votes, yours marked,
--- then whether it's over.
function M.poll_lines(poll: backend.Poll): { { core.UiSpan } }
	local lines = {}
	for _, answer in poll.answers do
		local votes = if answer.votes == 1 then "1 vote" else `{answer.votes} votes`
		table.insert(lines, {
			ui.span(
				if answer.mine then "  ● " else "  ○ ",
				if answer.mine then "function" else "comment"
			),
			ui.span(answer.text, nil),
			ui.span(`  {votes}`, "comment"),
		})
	end
	local how = if poll.ended then "  the poll is over" else "  enter votes"
	table.insert(lines, { ui.span(how, "comment") })
	return lines
end

--- Where a location opens: OpenStreetMap, at it.
function M.map_link(location: backend.Location): string
	local lat, lon = location.latitude, location.longitude
	return `https://www.openstreetmap.org/?mlat={lat}&mlon={lon}#map=16/{lat}/{lon}`
end

--- How an item reads in a room.
function M.item_node(
	item: backend.Item,
	previous: backend.Item?,
	in_thread: boolean,
	shown: core.UiNode?,
	preview: backend.Preview?
): core.UiNode?
	if item.kind == "day" then
		return ui.line({
			ui.span(`── {os.date("%A %d %B", item.at // 1000)} ──`, "comment"),
		})
	elseif item.kind == "read_marker" then
		return ui.line({ ui.span("── new ──", "diagnostic.warning") })
	elseif item.kind == "start" then
		return ui.line({ ui.span("The start of the room", "comment") })
	elseif item.kind == "change" or item.kind == "call" then
		local what = if item.kind == "call"
			then `{item.sender.name} started a call{if item.link
				then " · enter joins it in the browser"
				else ""}`
			else item.text
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
	if not same then
		table.insert(
			parts,
			valued(
				ui.line({
					ui.span(item.sender.name, if item.mine then "function" else "keyword"),
					ui.span(`  {M.when(item.at)}`, "comment"),
				}),
				item,
				false
			)
		)
	end
	local media = item.media
	if media then
		table.insert(parts, valued(ui.line(M.attachment_spans(item)), item, false))
		if shown then
			table.insert(parts, valued(shown, item, false))
		end
	end
	-- A file's text is its name, shown already, unless it's a caption.
	local caption = media == nil or item.text ~= media.name
	if caption and (item.text ~= "" or item.kind ~= "message") then
		table.insert(parts, valued(ui.text(said(item)), item, true))
	end
	if preview then
		for _, line in M.preview_lines(preview) do
			table.insert(parts, valued(ui.line(line), item, false))
		end
	end
	local poll = item.poll
	if poll then
		for _, line in M.poll_lines(poll) do
			table.insert(parts, valued(ui.line(line), item, false))
		end
	end
	local location = item.location
	if location then
		local at = `📍 {location.latitude}, {location.longitude}`
		local spans = { ui.span(at, "markdown.link"), ui.span("  enter opens the map", "comment") }
		table.insert(parts, valued(ui.line(spans), item, false))
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
	if item.replies > 0 and not in_thread then
		local replies = if item.replies == 1 then "1 reply" else `{item.replies} replies`
		table.insert(notes, ui.span(` ↳ {replies} (alt-t)`, "markdown.link"))
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
	local readers: { { id: string, name: string } } = item.read_by or {}
	if #readers > 0 then
		local names = {}
		for _, person in readers do
			table.insert(names, person.name)
		end
		table.insert(notes, ui.span(` seen by {table.concat(names, ", ")}`, "comment"))
	end
	if #notes > 0 then
		table.insert(parts, valued(ui.line(notes), item, false))
	end
	local actions: { backend.Action } = item.actions or {}
	if #actions > 0 then
		local buttons: { core.UiSpan } = {}
		for _, action in actions do
			local menu = if action.options and #action.options > 0 then " ▾" else ""
			table.insert(buttons, ui.span(` [ {action.name}{menu} ]`, "function"))
		end
		table.insert(buttons, ui.span("  (enter)", "comment"))
		table.insert(parts, valued(ui.line(buttons), item, false))
	end
	return ui.column(parts)
end

--- Who's writing, in words, or nil when no one is.
function M.writing(who: { string }): string?
	if #who == 0 then
		return nil
	elseif #who == 1 then
		return `{who[1]} is writing…`
	elseif #who == 2 then
		return `{who[1]} and {who[2]} are writing…`
	end
	return `{#who} people are writing…`
end

--- How many unread messages room `room` of account `key` has, as the list
--- knows it (set by the plugin).
M.unread = function(_account: string, _room: string): number
	return 0
end

-- How many rooms the bar over a room keeps.
local RECENT = 9

-- The rooms opened, in the order they were, as the bar over a room shows
-- them: the oldest goes once there are more than `RECENT`.
local recent: { { account: string, room: string, name: string } } = {}

local function remember(account: string, room: string, name: string)
	for _, one in recent do
		if one.account == account and one.room == room then
			return
		end
	end
	table.insert(recent, { account = account, room = room, name = name })
	if #recent > RECENT then
		table.remove(recent, 1)
	end
end

--- Forgets the rooms the bar keeps, for tests.
function M.forget_recent()
	table.clear(recent)
end

--- Opens the bar's `n`th room in `window`.
function M.go_recent(n: number, window: greed.View)
	local one = recent[n]
	if one then
		M.open(one.account, one.room, one.name, nil, window)
	end
end

-- Where room `r` is in the bar, if it's there.
local function recent_index(r: Open): number?
	for i, one in recent do
		if one.account == r.account and one.room == r.room then
			return i
		end
	end
	return nil
end

-- The bar over a room: the rooms opened, each with what's unread, `r`'s
-- picked out; none in a thread, or with only the one room.
local function bar(r: Open): core.UiNode?
	if r.thread or #recent < 2 then
		return nil
	end
	local tabs: { core.UiTab } = {}
	for i, one in recent do
		local n = M.unread(one.account, one.room)
		table.insert(tabs, {
			label = if n > 0 then `{one.name} {n}` else one.name,
			current = one.account == r.account and one.room == r.room,
			press = function()
				M.go_recent(i, greed.view())
			end,
		})
	end
	return ui.tabs(tabs)
end

local function render(r: Open): core.UiNode
	local parts: { core.UiNode } = {}
	local top = bar(r)
	if top then
		table.insert(parts, top)
		table.insert(parts, ui.gap())
	end
	local previous: backend.Item? = nil
	local first = r.first
	local shown = first ~= nil
	for _, item in r.items do
		shown = shown and item.event ~= (first :: backend.Item).event
	end
	if shown then
		local started = first :: backend.Item
		table.insert(
			parts,
			M.item_node(started, nil, true, picture(r, started), link_preview(r, started)) :: core.UiNode
		)
		previous = first
	end
	for _, item in r.items do
		local node =
			M.item_node(item, previous, r.thread ~= nil, picture(r, item), link_preview(r, item))
		if node then
			table.insert(parts, node)
		end
		previous = item
	end
	table.insert(parts, ui.gap())
	local writing = M.writing(r.typing)
	if writing then
		table.insert(parts, ui.text(writing, "comment"))
	end
	local hint = if r.editing
		then "changing your message · esc: not"
		elseif r.replying then `answering {r.replying.sender.name} · esc: not`
		elseif r.thread then "in the thread · enter sends · q: back to the room"
		else "enter sends · alt-enter new line · space . on a message: what to do · esc q: the rooms"
	table.insert(parts, ui.text(hint, "comment"))
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

--- Draws the shown rooms again soon, as when what's unread changed.
function M.redraw()
	for _, r in open do
		if r.buffer:valid() and #r.buffer:views() > 0 then
			r.view:soon()
		end
	end
end

--- The open room or thread in `buffer`, if it's one.
function M.of(buffer: greed.Buffer): Open?
	for _, r in open do
		if r.buffer == buffer then
			return r
		end
	end
	return nil
end

-- Marks a room read, at most every couple of seconds, when it's shown.
local function mark_read(r: Open)
	if r.thread or os.time() - r.marked < 2 or #r.buffer:views() == 0 then
		return
	end
	r.marked = os.time()
	greed.spawn(function()
		ask(r, "read")
	end)
end

-- The most pages of older messages `go_to` fetches looking for one.
local PAGES = 20

--- Puts `window`'s cursor on message `event` in `r`, fetching older
--- messages until it's there or there are none. Waits, so it runs in a
--- coroutine; says so when it isn't found.
function M.go_to(r: Open, event: string, window: greed.View)
	local function show(): boolean
		r.view:redraw()
		local line = r.view:line_of(function(value: any): boolean
			return value ~= nil and value.item.event == event
		end)
		if line then
			window:set_cursor(r.buffer:line_start(line))
		end
		return line ~= nil
	end
	for _ = 1, PAGES do
		if show() then
			return
		end
		local back = ask(r, "timeline.back")
		-- The older messages come as changes, a moment after.
		greed.sleep(100)
		if back == nil or not back.more then
			break
		end
	end
	if not show() then
		greed.echo("that message isn't in the room's history here")
	end
end

--- Opens room `room` of account `key` in `window`, or its thread `thread`
--- (by its first message's event): its messages and the box to write in;
--- with `at`, the cursor on that message.
function M.open(
	key: string,
	room: string,
	name: string,
	thread: string?,
	window: greed.View?,
	at: string?
): Open
	if thread == nil then
		remember(key, room, name)
	end
	local whole = key_of(key, room, thread)
	local target = M.window_for(window or greed.view())
	if target ~= greed.view() then
		target:focus()
	end
	local already = open[whole]
	if already and already.buffer:valid() then
		target:show(already.buffer)
		target:set_cursor(already.buffer:len())
		if at then
			greed.spawn(M.go_to, already, at, target)
		end
		return already
	end
	local buffer = greed.create_buffer("chat-room", "", { language = "markdown" })
	-- Kept while a thread or the list is shown in its place; closed with
	-- chat-close.
	buffer:set_kept(true)
	buffer:set_line_numbers(false)
	-- Only what people wrote is Markdown; who, when and the rest show as
	-- they are. What you write in the box is Markdown too.
	markdown.plain(
		buffer,
		setmetatable({}, {
			__index = function(_, line: number): boolean?
				local shown = M.of(buffer)
				if shown == nil or line >= buffer:line_of(shown.view:input_start()) then
					return nil
				end
				local value: Line? = shown.view:value_on(line)
				return not (value and value.body)
			end,
		}) :: any
	)
	local r: Open
	local view = ui.mount(buffer, function()
		return render(r)
	end, {}, { ns = "chat", input = true, keys = false, draw = false })
	local made: Open = {
		account = key,
		room = room,
		thread = thread,
		name = name,
		buffer = buffer,
		view = view,
		items = {},
		replying = nil,
		editing = nil,
		typing = {},
		first = nil,
		said_typing = -math.huge,
		marked = -math.huge,
	}
	r = made
	open[whole] = r
	target:show(buffer)
	report()
	greed.spawn(function()
		local opened, why = ask(r, "timeline")
		if opened then
			r.items = opened.items
		else
			greed.echo(`chat: {why}`)
		end
		view:redraw()
		target:set_cursor(buffer:len())
		mark_read(r)
		if at then
			M.go_to(r, at, target)
		end
	end)
	return r
end

backend.on_timeline(function(key: string, room: string, thread: string?, changes: { any })
	local r = open[key_of(key, room, thread)]
	if r == nil or not r.buffer:valid() then
		return
	end
	M.apply(r.items, changes)
	r.view:soon()
	mark_read(r)
end)

backend.on_typing(function(key: string, room: string, who: { string })
	local r = open[key_of(key, room, nil)]
	if r and r.buffer:valid() then
		r.typing = who
		r.view:soon()
	end
end)

-- Once the owner is back, as after it started again, the open rooms' and
-- threads' timelines are asked for again.
backend.on_reset(function()
	for _, r in open do
		if r.buffer:valid() then
			greed.spawn(function()
				local opened = ask(r, "timeline")
				if opened then
					r.items = opened.items
					r.view:redraw()
				end
			end)
		end
	end
	if next(open) ~= nil then
		report()
	end
end)

-- Writing in a room's box says so, every few seconds while it goes on.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local r = M.of(event.buffer)
	if r == nil or core.text.trim(r.view:input()) == "" or os.time() - r.said_typing < 4 then
		return
	end
	r.said_typing = os.time()
	greed.spawn(function()
		ask(r, "typing", { on = true })
	end)
end)

-- The message at `at` in `r`, if there's one there the service knows.
local function message_on(r: Open, at: number): backend.Item?
	local line: Line? = r.view:value_at(at)
	local item = line and line.item
	if item and item.event then
		return item
	end
	return nil
end

-- The message the cursor is on in `ctx`'s room, with the room.
local function message_at(ctx: greed.Context): (Open?, backend.Item?)
	local r = M.of(ctx.buffer)
	if r == nil then
		return nil, nil
	end
	return r, message_on(r, ctx.view:cursor())
end

-- Puts `text` in `r`'s box, and the cursor after it.
local function fill(r: Open, view: greed.View, text: string)
	local buffer = r.buffer
	buffer:edit(function(e)
		e:replace(r.view:input_start(), buffer:len(), text)
	end)
	view:set_cursor(buffer:len())
end

--- Sends what's in `r`'s box: a new message, an answer, or the change to
--- one of yours.
function M.send(r: Open, view: greed.View)
	local text = core.text.trim(r.view:input())
	if text == "" then
		return
	end
	local replying, editing = r.replying, r.editing
	r.replying, r.editing = nil, nil
	fill(r, view, "")
	r.view:redraw()
	local _, why
	if editing then
		_, why = ask(r, "edit", { event = editing.event, text = text })
	else
		_, why = ask(r, "send", {
			text = text,
			reply_to = if replying then replying.event else nil,
		})
		ask(r, "typing", { on = false })
		r.said_typing = -math.huge
	end
	if why then
		greed.echo(`chat: {why}`)
	end
end

--- Makes what's sent next in `r` answer `item`.
function M.reply(r: Open, item: backend.Item, view: greed.View)
	r.replying, r.editing = item, nil
	r.view:redraw()
	view:set_cursor(r.buffer:len())
end

--- The reactions offered first.
M.QUICK = {
	"👍",
	"❤️",
	"😄",
	"🎉",
	"👀",
	"✅",
	"🙏",
	"😂",
	"🚀",
	"🔥",
	"😢",
	"🤔",
}

--- Reacts to `item` with an emoji picked, or takes yours back.
function M.react(r: Open, item: backend.Item)
	local items = {}
	for _, emoji in M.QUICK do
		table.insert(items, { label = emoji, value = emoji })
	end
	table.insert(items, { label = "Another, by name or as typed", value = "" })
	picker.pick("React with", items, function(chosen)
		greed.spawn(function()
			local key: string? = chosen.value
			if key == "" then
				key = core.prompt.ask("The emoji, or a Mattermost emoji's name")
			end
			if key and key ~= "" then
				local _, why = ask(r, "react", { event = item.event, key = key })
				if why then
					greed.echo(`chat: {why}`)
				end
			end
		end)
	end)
end

--- Presses one of `item`'s buttons, or picks from one of its menus, as
--- picked: each button, and each menu's choices.
function M.press(r: Open, item: backend.Item)
	local items = {}
	local actions: { backend.Action } = item.actions or {}
	for _, action in actions do
		local options: { { text: string, value: string } } = action.options or {}
		if #options == 0 then
			table.insert(items, { label = action.name, value = { action = action.id } })
		end
		for _, option in options do
			table.insert(items, {
				label = `{action.name}: {option.text}`,
				value = { action = action.id, option = option.value },
			})
		end
	end
	picker.pick("Press", items, function(chosen)
		greed.spawn(function()
			local _, why = ask(r, "press", {
				event = item.event,
				action = chosen.value.action,
				option = chosen.value.option,
			})
			if why then
				greed.echo(`chat: {why}`)
			end
		end)
	end)
end

--- Puts a command the room's service has in `r`'s box, picked from those
--- it lists, for its arguments to follow.
function M.pick_command(r: Open, view: greed.View)
	local commands, why = ask(r, "commands")
	if commands == nil then
		greed.echo(`chat: {why}`)
		return
	end
	local items = {}
	for _, command in commands do
		local hint = if command.hint ~= "" then ` {command.hint}` else ""
		local about = if command.description ~= "" then `  · {command.description}` else ""
		table.insert(items, { label = `/{command.trigger}{hint}{about}`, value = command.trigger })
	end
	picker.pick("Command", items, function(chosen)
		fill(r, view, `/{chosen.value} `)
	end)
end

--- Asks, then deletes `item`.
function M.delete(r: Open, item: backend.Item)
	greed.echo("Delete this message? y deletes, anything else doesn't")
	if greed.next_key() ~= "y" then
		greed.echo("")
		return
	end
	greed.spawn(function()
		local _, why = ask(r, "redact", { event = item.event })
		greed.echo(if why then `chat: {why}` else "deleted")
	end)
end

--- Starts changing `item`, one of yours: its text in the box.
function M.edit(r: Open, item: backend.Item, view: greed.View)
	if not item.mine then
		greed.echo("only your own messages can be changed")
		return
	end
	r.editing, r.replying = item, nil
	r.view:redraw()
	fill(r, view, item.text)
end

--- Opens `item`'s thread, the one it starts or is in.
function M.thread(r: Open, item: backend.Item, view: greed.View)
	local root = item.thread or item.event
	if root == nil then
		return
	end
	-- What started it, as the room has it, to show over its replies.
	local first = item
	for _, other in r.items do
		if other.event == root then
			first = other
		end
	end
	local thread = M.open(r.account, r.room, r.name, root, view)
	thread.first = first
	thread.view:redraw()
end

local function on_message(
	f: (r: Open, item: backend.Item, ctx: greed.Context) -> ()
): (ctx: greed.Context) -> ()
	return function(ctx: greed.Context)
		local r, item = message_at(ctx)
		if r and item then
			f(r, item, ctx)
		end
	end
end

greed.command({
	name = "chat-send",
	doc = "In a room: send what's written in its box",
	run = function(ctx)
		local r = M.of(ctx.buffer)
		if r then
			M.send(r, ctx.view)
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
	run = on_message(function(r, item, ctx)
		M.reply(r, item, ctx.view)
	end),
})

greed.command({
	name = "chat-thread",
	doc = "In a room: open the thread of the message under the cursor",
	run = on_message(function(r, item, ctx)
		M.thread(r, item, ctx.view)
	end),
})

greed.command({
	name = "chat-react",
	doc = "In a room: react to the message under the cursor, or take your reaction back",
	run = on_message(function(r, item)
		M.react(r, item)
	end),
})

greed.command({
	name = "chat-edit",
	doc = "In a room: change your message under the cursor",
	run = on_message(function(r, item, ctx)
		M.edit(r, item, ctx.view)
	end),
})

greed.command({
	name = "chat-delete",
	doc = "In a room: delete the message under the cursor, asking first",
	run = on_message(function(r, item)
		M.delete(r, item)
	end),
})

-- Fetches the file `item` carries into this session's cache, then gives
-- `done` its path there.
local function fetch(r: Open, item: backend.Item, done: (path: string) -> ())
	greed.echo("fetching it…")
	greed.spawn(function()
		local bytes, why = carried(r, { event = item.event })
		local cache = greed.fs.dirs().cache
		if bytes == nil or cache == nil then
			greed.echo(`chat: {why or "there's no cache folder to keep it in"}`)
			return
		end
		local name = if item.media then item.media.name else "file"
		local event = string.gsub(item.event or "", "[^%w]", "")
		local path = `{cache}/chat/files/{event}-{name}`
		local wrote, trouble = greed.fs.write(path, bytes, { private = true })
		if not wrote then
			greed.echo(`chat: {trouble}`)
			return
		end
		done(path)
	end)
end

--- Opens the file `item` carries: a picture or a PDF in Greed, the rest in
--- the program that opens it (a video or a recording in a player).
function M.open_file(r: Open, item: backend.Item)
	fetch(r, item, function(path)
		greed.echo("")
		core.file.open(path)
	end)
end

--- Votes in `item`'s poll for the answer picked.
function M.vote(r: Open, item: backend.Item)
	local poll = item.poll
	if poll == nil then
		return
	elseif poll.ended then
		greed.echo("the poll is over")
		return
	end
	local items = {}
	for _, answer in poll.answers do
		table.insert(items, { label = answer.text, value = answer.id })
	end
	picker.pick(poll.question, items, function(chosen)
		greed.spawn(function()
			local _, why = ask(r, "vote", { event = item.event, answers = { chosen.value } })
			if why then
				greed.echo(`chat: {why}`)
			end
		end)
	end)
end

--- The command that plays the recording at `path` in the background, if
--- a player is installed: mpv, else ffplay.
function M.player(path: string): { string }?
	if greed.which("mpv") then
		return { "mpv", "--no-video", "--really-quiet", path }
	elseif greed.which("ffplay") then
		return { "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", path }
	end
	return nil
end

-- The recording playing, by its message's event, and its player.
local playing: { event: string?, child: greed.Child }? = nil

--- Plays the recording `item` carries in the background (with mpv or
--- ffplay), or opens it in your system's player where neither is there.
--- Playing another stops the one before; the same one again stops it.
function M.play(r: Open, item: backend.Item)
	local was = playing
	if was then
		playing = nil
		pcall(was.child.kill, was.child)
		if was.event == item.event then
			greed.echo("stopped")
			return
		end
	end
	fetch(r, item, function(path)
		local command = M.player(path)
		if command == nil then
			greed.echo("")
			core.file.open(path)
			return
		end
		local child, failed = greed.vouch(greed.process.spawn, command, nil)
		if child == nil then
			greed.echo(`chat: can't play it: {failed}`)
			return
		end
		playing = { event = item.event, child = child }
		greed.echo("playing: enter on it again stops")
	end)
end

greed.command({
	name = "chat-enter",
	doc = "In a room: open the file of the message under the cursor (play a recording), vote in its poll, open its place on the map, press its buttons, or open its thread",
	run = on_message(function(r, item, ctx)
		if item.kind == "call" and item.link then
			-- Calls happen in the service's own app; Greed shows them start.
			core.file.open_link(item.link)
		elseif item.media and item.kind == "audio" then
			M.play(r, item)
		elseif item.media then
			M.open_file(r, item)
		elseif item.poll then
			M.vote(r, item)
		elseif item.location then
			core.file.open_link(M.map_link(item.location))
		elseif item.actions and #item.actions > 0 then
			M.press(r, item)
		elseif item.replies > 0 and r.thread == nil then
			M.thread(r, item, ctx.view)
		end
	end),
})

greed.command({
	name = "chat-press",
	doc = "In a room: press a button in the message under the cursor, or pick from its menu",
	run = on_message(function(r, item)
		M.press(r, item)
	end),
})

greed.command({
	name = "chat-commands",
	doc = "In a room: pick one of the service's commands (Mattermost) into the box",
	run = function(ctx)
		local r = M.of(ctx.buffer)
		if r == nil then
			greed.echo("open a room first")
			return
		end
		local service = backend.split(r.account)
		local can = backend.can[service]
		if not (can and can.commands) then
			greed.echo(`{service} has no commands`)
			return
		end
		greed.spawn(M.pick_command, r, ctx.view)
	end,
})

greed.command({
	name = "chat-attach",
	doc = "In a room: send a file, picked by its path",
	args = { { name = "path", doc = "the file", type = "string", optional = true } },
	run = function(ctx)
		local r = M.of(ctx.buffer)
		if r == nil then
			greed.echo("open a room first")
			return
		end
		local path = ctx.values.path or core.prompt.ask("The file to send")
		if path == nil or path == "" then
			return
		end
		local service, params = addressed(r)
		local _, why = backend.upload(service, params, core.project.resolve(path))
		greed.echo(if why then `chat: {why}` else "sent")
	end,
})

-- Goes `by` rooms on in the bar from the one in `ctx`, round the ends.
local function step(ctx: greed.Context, by: number)
	local r = M.of(ctx.buffer)
	if r == nil or #recent == 0 then
		return
	end
	local at = recent_index(r) or 0
	M.go_recent((at - 1 + by) % #recent + 1, ctx.view)
end

greed.command({
	name = "chat-room-next",
	doc = "In a room: the next room in the bar over it",
	run = function(ctx)
		step(ctx, 1)
	end,
})

greed.command({
	name = "chat-room-previous",
	doc = "In a room: the room before in the bar over it",
	run = function(ctx)
		step(ctx, -1)
	end,
})

for i = 1, 9 do
	greed.command({
		name = `chat-room-{i}`,
		doc = `In a room: room {i} of the bar over it`,
		run = function(ctx)
			M.go_recent(i, ctx.view)
		end,
	})
end

greed.command({
	name = "chat-older",
	doc = "In a room: fetch older messages",
	run = function(ctx)
		local r = M.of(ctx.buffer)
		if r then
			local _, why = ask(r, "timeline.back")
			if why then
				greed.echo(`chat: {why}`)
			end
		end
	end,
})

greed.command({
	name = "chat-close",
	doc = "In a room: stop answering or changing; else back to the room from a thread, or to the list",
	run = function(ctx)
		local r = M.of(ctx.buffer)
		if r == nil then
			M.on_leave(ctx.view)
			return
		end
		if r.replying or r.editing then
			if r.editing then
				fill(r, ctx.view, "")
			end
			r.replying, r.editing = nil, nil
			r.view:redraw()
			return
		end
		open[key_of(r.account, r.room, r.thread)] = nil
		greed.spawn(function()
			ask(r, "timeline.close")
		end)
		local room = if r.thread then open[key_of(r.account, r.room, nil)] else nil
		if room and room.buffer:valid() then
			ctx.view:show(room.buffer)
		else
			M.on_leave(ctx.view)
		end
		-- Closed once nothing shows it.
		if #r.buffer:views() == 0 then
			r.buffer:close()
		end
	end,
})

-- `space .` on a message: what can be done to it.
core.actions.finder({
	name = "chat",
	find = function(view: greed.View, range: greed.Range): { core.Target }?
		local buffer = view:buffer()
		local r = M.of(buffer)
		if r == nil then
			return nil
		end
		local item = message_on(r, range.head)
		if item == nil then
			return nil
		end
		local label = core.text.clip(`{item.sender.name}: {item.text}`, 40)
		return {
			{
				kind = "chat-message",
				label = label,
				value = { room = r, item = item },
				buffer = buffer,
			},
		}
	end,
})

local ACTIONS: {
	{
		name: string,
		doc: string,
		mine: boolean?,
		--- Only for a message that carries a file.
		media: boolean?,
		--- Only for a message with buttons or menus.
		actions: boolean?,
		--- Only for a message it says yes for.
		offers: ((item: backend.Item) -> boolean)?,
		--- Only for a message with a link.
		link: boolean?,
		danger: boolean?,
		run: (r: Open, item: backend.Item, view: greed.View) -> (),
	}
} =
	{
		{
			name = "open",
			doc = "Open its file: a picture in Greed, the rest in its program",
			media = true,
			run = function(r, item)
				M.open_file(r, item)
			end,
		},
		{
			name = "play",
			doc = "Play the recording, or stop it",
			offers = function(item)
				return item.kind == "audio" and item.media ~= nil
			end,
			run = function(r, item)
				M.play(r, item)
			end,
		},
		{
			name = "vote",
			doc = "Vote in the poll",
			offers = function(item)
				return item.poll ~= nil and not item.poll.ended
			end,
			run = function(r, item)
				M.vote(r, item)
			end,
		},
		{
			name = "map",
			doc = "Open the place on OpenStreetMap",
			offers = function(item)
				return item.location ~= nil
			end,
			run = function(_r, item)
				local location = item.location
				if location then
					core.file.open_link(M.map_link(location))
				end
			end,
		},
		{
			name = "press",
			doc = "Press one of its buttons, or pick from its menu",
			actions = true,
			run = function(r, item)
				M.press(r, item)
			end,
		},
		{
			name = "reply",
			doc = "Answer it with what's sent next",
			run = function(r, item, view)
				M.reply(r, item, view)
			end,
		},
		{
			name = "thread",
			doc = "Open its thread",
			run = function(r, item, view)
				M.thread(r, item, view)
			end,
		},
		{
			name = "react",
			doc = "React to it, or take your reaction back",
			run = function(r, item)
				M.react(r, item)
			end,
		},
		{
			name = "edit",
			doc = "Change it",
			mine = true,
			run = function(r, item, view)
				M.edit(r, item, view)
			end,
		},
		{
			name = "delete",
			doc = "Delete it",
			danger = true,
			run = function(r, item)
				M.delete(r, item)
			end,
		},
		{
			name = "browser",
			doc = "Open it in the service's own app or web client (to join a call, say)",
			link = true,
			run = function(_r, item)
				core.file.open_link(item.link :: string)
			end,
		},
		{
			name = "copy link",
			doc = "Copy the link to it",
			link = true,
			run = function(_r, item)
				greed.clipboard.set(item.link :: string)
				greed.echo("copied the link")
			end,
		},
		{
			name = "copy",
			doc = "Copy what it says",
			run = function(_r, item)
				greed.clipboard.set(item.text)
				greed.echo("copied")
			end,
		},
	}

for _, a in ACTIONS do
	core.actions.action({
		kind = "chat-message",
		name = a.name,
		doc = a.doc,
		danger = a.danger,
		offers = function(target: core.Target): boolean
			local item = target.value.item
			return (not a.mine or item.mine == true)
				and (not a.media or item.media ~= nil)
				and (not a.link or item.link ~= nil)
				and (not a.actions or (item.actions ~= nil and #item.actions > 0))
				and (a.offers == nil or a.offers(item))
		end,
		run = function(target: core.Target)
			a.run(target.value.room, target.value.item, greed.view())
		end,
	})
end
core.actions.set_default("chat-message", "reply")

greed.keymap.bind({ kind = "chat-room" }, {
	["alt-up"] = "chat-older",
	["alt-r"] = "chat-reply",
	["alt-t"] = "chat-thread",
	["alt-k"] = "chat-react",
	["alt-e"] = "chat-edit",
	["alt-d"] = "chat-delete",
	["alt-b"] = "chat-press",
	["alt-s"] = "chat-search",
	["alt-/"] = "chat-commands",
})

-- Out of the box only, so esc while writing leaves writing as it does; tab
-- and shift-tab go through the bar's rooms as mail's go through its
-- searches, alt and a number to one.
greed.keymap.bind({ role = "command", kind = "chat-room" }, {
	q = "chat-close",
	enter = "chat-enter",
	esc = "chat-close",
	tab = "chat-room-next",
	["shift-tab"] = "chat-room-previous",
	["]"] = "chat-room-next",
	["["] = "chat-room-previous",
})
for i = 1, 9 do
	greed.keymap.bind({ kind = "chat-room" }, { [`alt-{i}`] = `chat-room-{i}` })
end

greed.keymap.bind({ role = "typing", kind = "chat-room" }, {
	enter = "chat-send",
	["alt-enter"] = "chat-newline",
	["alt-/"] = "chat-commands",
})

core.about.kind("chat-room", function(buffer: greed.Buffer): string
	local r = M.of(buffer)
	if r == nil then
		return "A chat room"
	end
	return if r.thread
		then `A thread in the chat room {r.name}: its replies and a box to write in`
		else `A chat room, {r.name}: its messages and a box to write in`
end)

return M
