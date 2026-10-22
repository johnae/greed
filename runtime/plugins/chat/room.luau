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

--- What's done when a room is marked read as you look at it (set by the
--- alerts).
M.on_read = function(_account: string, _room: string) end

--- Whether room `room` of account `key` is open and shown somewhere.
function M.shown(key: string, room: string): boolean
	local r = open[key_of(key, room, nil)]
	return r ~= nil and r.buffer:valid() and #r.buffer:views() > 0
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

-- Asks `r`'s service `method`, with the room (and thread) and `extra`.
local function ask(r: Open, method: string, extra: { [string]: any }?): (any, string?)
	local service, id = backend.split(r.account)
	local params: { [string]: any } = { account = id, room = r.room, thread = r.thread }
	local more: { [string]: any } = extra or {}
	for name, value in more do
		params[name] = value
	end
	return backend.ask(service, method, params)
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
			local got = ask(r, "media.get", { event = item.event, thumbnail = true })
			local image = if got then greed.image.load(got.path) else nil
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

--- How an item reads in a room.
function M.item_node(
	item: backend.Item,
	previous: backend.Item?,
	in_thread: boolean,
	shown: core.UiNode?
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

local function render(r: Open): core.UiNode
	local parts: { core.UiNode } = {}
	local previous: backend.Item? = nil
	local first = r.first
	local shown = first ~= nil
	for _, item in r.items do
		shown = shown and item.event ~= (first :: backend.Item).event
	end
	if shown then
		local started = first :: backend.Item
		table.insert(parts, M.item_node(started, nil, true, picture(r, started)) :: core.UiNode)
		previous = first
	end
	for _, item in r.items do
		local node = M.item_node(item, previous, r.thread ~= nil, picture(r, item))
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
		else "enter sends · alt-enter new line · space . on a message: what to do"
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
	M.on_read(r.account, r.room)
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
	local whole = key_of(key, room, thread)
	local target = window or greed.view()
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

--- Opens the file `item` carries: a picture or a PDF in Greed, the rest in
--- the program that opens it (a video or a recording in a player).
function M.open_file(r: Open, item: backend.Item)
	greed.echo("fetching it…")
	greed.spawn(function()
		local got, why = ask(r, "media.get", { event = item.event })
		if got == nil then
			greed.echo(`chat: {why}`)
			return
		end
		greed.echo("")
		core.file.open(got.path)
	end)
end

greed.command({
	name = "chat-enter",
	doc = "In a room: open the file of the message under the cursor, press its buttons, or open its thread",
	run = on_message(function(r, item, ctx)
		if item.kind == "call" and item.link then
			-- Calls happen in the service's own app; Greed shows them start.
			core.file.open_link(item.link)
		elseif item.media then
			M.open_file(r, item)
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
		local _, why = ask(r, "upload", { path = core.project.resolve(path) })
		greed.echo(if why then `chat: {why}` else "sent")
	end,
})

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

-- Out of the box only, so esc while writing leaves writing as it does.
greed.keymap.bind({ role = "command", kind = "chat-room" }, {
	q = "chat-close",
	enter = "chat-enter",
	esc = "chat-close",
})

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
