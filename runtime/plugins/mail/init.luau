-- Mail: your mail searched and read in Greed. In the mail session
-- (`greed mail`) the page shows what a search finds, newest first, with
-- the search box over it (in:inbox to start); elsewhere `:mail` opens the
-- same list in a float for a quick look. `enter` reads a thread, `/`
-- searches again, `$` syncs now, `q` goes back or closes; `u` marks read
-- or unread, `s` flags, `t` tags, `e` archives and `d` trashes; `r`
-- replies, `a` replies to all and `c` writes new mail, which `:mail-send`
-- sends.
-- greed-mail syncs the accounts in mail.toml and keeps the index this
-- searches (backend.luau); a search is the query language anywhere in
-- Greed: from:anna is:unread date:2w.. in:work invoice.

local greed = require("@greed")
local core = require("@core")
local backend = require("@self/backend")

local ui = core.ui

type Summary = backend.Summary
type Thread = backend.Thread
type Draft = backend.Draft

local M = {}

--- Where the mail comes from: greed-mail, or a fake in tests
--- (`backend.use`).
M.backend = backend

local function field(kind: string): core.QueryField
	return {
		kind = kind,
		get = function(): any
			return nil
		end,
	}
end

-- The flags the index keeps of each message (greed-mail's indexing.rs).
local FLAGS = { "unread", "flagged", "answered", "draft", "attachment", "mine" }

local function flags(): { [string]: (item: any) -> boolean }
	local out: { [string]: (item: any) -> boolean } = {}
	for _, flag in FLAGS do
		out[flag] = function(): boolean
			return false
		end
	end
	return out
end

--- What a mail search runs over: the fields and flags greed-mail's index
--- has, a message's folders and labels in `tag`, which `in:` matches.
M.source = {
	fields = {
		from = field("text"),
		to = field("text"),
		cc = field("text"),
		subject = field("text"),
		date = field("date"),
		size = field("value"),
		tag = field("exact"),
		account = field("exact"),
		list = field("exact"),
	},
	flags = flags(),
	text = function(): string
		return ""
	end,
	places = "tag",
	stored = FLAGS,
} :: core.QuerySource

--- The search a list starts with.
M.START = "in:inbox"

-- How many messages a list shows at most.
local LIMIT = 200

--- `date` (RFC 3339) as a list shows it: the time today, else the day as
--- dates show everywhere ("3 Oct", "3 Oct 2025").
function M.when(date: string?): string
	local day, time = string.match(date or "", "^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
	if day == nil or time == nil then
		return ""
	end
	return if day == core.dates.today() then time else core.dates.short(day)
end

--- Who `from` is, by name when it has one ("Anna Berg <anna@x>": Anna Berg).
function M.who(from: string): string
	local name = string.match(from, '^%s*"?(.-)"?%s*<[^>]*>')
	if name and name ~= "" then
		return name
	end
	return string.match(from, "^%s*(.-)%s*$") or from
end

-- The list, while it's open: on the mail session's page, or in a float
-- (`floating`) for a quick look anywhere else, `window` showing it.
type Open = {
	window: greed.View,
	buffer: greed.Buffer,
	floating: boolean,
	view: core.UiView,
	query: string,
	rows: { Summary },
	trouble: string?,
	-- Results by the query that found them, as the search box counts the
	-- same queries the list shows.
	found: { [string]: { Summary } },
}
local open: Open? = nil

-- The thread being read, while it's open.
local reading: {
	window: greed.View,
	buffer: greed.Buffer,
	thread: Thread,
	floating: boolean,
	-- Read as its text, rather than laid out from its HTML.
	plain: boolean,
	view: core.UiView,
}? =
	nil

--- The messages `parsed` finds, newest first unless it sorts otherwise,
--- or nil and why.
function M.search(parsed: core.Query): ({ Summary }?, string?)
	local mail = backend.get()
	local index, err = mail.index()
	if index == nil then
		return nil, err
	end
	local asked = table.clone(parsed)
	asked.view = table.clone(parsed.view)
	if #asked.view.sort == 0 then
		asked.view.sort = { { field = "date", descending = true } }
	end
	asked.view.limit = asked.view.limit or LIMIT
	local keys, _, trouble = core.query.search(index, asked, M.source)
	if keys == nil then
		return nil, trouble
	end
	return mail.summaries(keys)
end

-- The list's results for `parsed`, found once for the list and its count.
local function results(o: Open, parsed: core.Query): { Summary }
	local text = core.query.print(parsed)
	local found = o.found[text]
	if found == nil then
		local rows, trouble = M.search(parsed)
		o.trouble = trouble
		found = rows or {}
		o.found[text] = found
	end
	return found
end

-- Where everything new is, so a list doesn't say it of every message.
local UNTOLD = { inbox = true }

--- A message's tags as a list shows them: "#work #trips", the inbox left
--- out.
function M.tag_text(tags: { string }): string
	local shown: { string } = {}
	for _, tag in tags do
		if not UNTOLD[string.lower(tag)] then
			table.insert(shown, `#{tag}`)
		end
	end
	return table.concat(shown, " ")
end

local function render(o: Open): core.UiNode
	local head = if o.trouble
		then ui.text(o.trouble, "diagnostic.error")
		else ui.text(`{#o.rows} · {o.query}`, "comment")
	local rows: { core.UiGridRow } = {}
	for _, row in o.rows do
		table.insert(rows, {
			cells = {
				{ ui.span(if row.unread then "●" else " ", "function") },
				{ ui.span(M.when(row.date), "comment") },
				{
					ui.span(
						core.text.clip(M.who(row.from), 24),
						if row.unread then "keyword" else nil
					),
				},
				{ ui.span(row.subject) },
				{ ui.span(M.tag_text(row.tags), "comment") },
			},
			value = row,
		})
	end
	return ui.column({ head, ui.gap(), ui.grid(rows) })
end

-- Runs the list's query again, as the mail changed or it was typed.
local function refresh(o: Open, parsed: core.Query?)
	o.found = {}
	local query = parsed or core.search_box.read(o.query, { source = M.source })
	if query.ok then
		o.rows = results(o, query)
	end
	o.view:redraw()
end

--- What the open list shows, for tests.
function M.shown(): { Summary }
	return if open then open.rows else {}
end

-- Back in the list from the search box, the cursor on a message: the
-- first, unless it was on one.
local function back(o: Open)
	if not o.window:valid() then
		return
	end
	o.window:focus()
	if o.view:value_at(o.window:cursor()) == nil and o.buffer:line_count() > 2 then
		o.window:set_cursor(o.buffer:line_start(2))
	end
end

--- Asks for a search in the open list, as it's typed.
function M.ask()
	local o = open
	if o == nil then
		return
	end
	core.search_box.open({
		title = "Search mail",
		text = o.query,
		source = M.source,
		history = "mail",
		count = function(parsed: core.Query): (number?, string?)
			return #results(o, parsed), nil
		end,
		on_change = function(text: string, parsed: core.Query)
			o.query = text
			if parsed.ok then
				refresh(o, parsed)
			end
		end,
		on_submit = function()
			back(o)
		end,
		on_cancel = function()
			back(o)
		end,
	})
end

-- A list of what `query` finds, in `window` or a float of its own.
local function list(query: string, window: greed.View?): Open
	local buffer = greed.create_buffer("mail", "", { readonly = true })
	buffer:set_line_numbers(false)
	local shown = window or greed.float(buffer, { title = "Mail", width = "90%", height = "80%" })
	if window then
		-- The page's list stays while a thread is read in its place.
		buffer:set_kept(true)
		window:show(buffer)
	end
	local o: Open = {
		window = shown,
		buffer = buffer,
		floating = window == nil,
		query = query,
		rows = {},
		found = {},
		view = nil :: any,
	}
	o.view = ui.mount(buffer, function()
		return render(o)
	end, {}, {
		key = function(row: Summary): string
			return row.key
		end,
	})
	refresh(o)
	return o
end

--- Opens a quick look at what `query` (in:inbox to start) finds in a
--- float, and the search box over it.
function M.open(query: string?)
	if open and open.floating and open.window:valid() then
		open.window:close()
	end
	open = list(query or M.START, nil)
	M.ask()
end

--- Shows the mail on the page, in the mail session: the list kept from
--- before, or a new one on in:inbox with the search box over it.
function M.page()
	local o = open
	if o and not o.floating and o.buffer:valid() then
		local here = greed.view()
		here:show(o.buffer)
		o.window = here
		back(o)
		return
	end
	open = list(M.START, greed.view())
	M.ask()
end

-- Something attached to a message, as a thread lists it: the message, its
-- place among them (from 0) and its name.
type Attached = { key: string, index: number, name: string }

--- Opens `which` with what the system opens its kind of file with; the
--- mail session fetches it first, the first time.
function M.open_attachment(which: Attached)
	greed.echo(`getting {which.name}`)
	local path, err = backend.get().attachment(which.key, which.index)
	if path == nil then
		greed.echo(err or `{which.name} didn't come`)
		return
	end
	greed.echo("")
	core.file.open_link(`file://{path}`)
end

-- How the styles of a message's HTML show.
local STYLES: { [string]: string } = {
	strong = "markup.bold",
	emphasis = "markup.italic",
	code = "markup.raw",
	strike = "markup.strikethrough",
	link = "markup.link",
	image = "comment",
}

-- Messages' HTML as laid out, by key and width: laying out goes to
-- greed-mail, once for each.
local laid: { [string]: backend.Rendered } = {}

-- The lines `message`'s HTML reads as, `cells` wide, its links pressed to
-- open; nil when it has none.
local function html_lines(message: backend.Message, cells: number): { core.UiNode }?
	if not message.html then
		return nil
	end
	local at = `{message.key} {cells}`
	local rendered = laid[at] or backend.get().render(message.key, cells)
	if rendered == nil then
		return nil
	end
	laid[at] = rendered
	local nodes: { core.UiNode } = {}
	for _, line in rendered.lines do
		local spans: { core.UiSpan } = {}
		for _, span in line do
			local target = if span.link then rendered.links[span.link + 1] else nil
			table.insert(spans, {
				text = span.text,
				style = if span.style then STYLES[span.style] else nil,
				value = if target then { link = target } else nil,
				press = if target
					then function()
						core.file.open_link(target)
					end
					else nil,
			})
		end
		table.insert(nodes, ui.line(spans))
	end
	return nodes
end

-- The lines of `message`'s text, its quoted lines dimmed.
local function text_lines(text: string): { core.UiNode }
	local nodes: { core.UiNode } = {}
	for line in string.gmatch(string.gsub(text, "\r\n", "\n") .. "\n", "(.-)\n") do
		table.insert(nodes, ui.text(line, if string.sub(line, 1, 1) == ">" then "comment" else nil))
	end
	return nodes
end

-- A header line: its name dimmed, then its value.
local function header(name: string, value: string, style: string?): core.UiNode
	return ui.line({ ui.span(`{name}: `, "comment"), ui.span(value, style) })
end

-- A message as it's read, `cells` wide: who, when, to whom, then what it
-- says, from its HTML unless `plain`.
local function message_node(message: backend.Message, cells: number, plain: boolean): core.UiNode
	local day, time = string.match(message.date or "", "^(%d+%-%d+%-%d+)T(%d+:%d+)")
	local date = if day then `{day} {time}` else (message.date or "")
	local parts: { core.UiNode } = {
		header("From", message.from, "markup.bold"),
		header("Date", date),
		header("To", message.to),
	}
	if message.cc ~= "" then
		table.insert(parts, header("Cc", message.cc))
	end
	for i, attached in message.attachments do
		local which: Attached = { key = message.key, index = i - 1, name = attached.name }
		table.insert(
			parts,
			ui.line({
				ui.span("Attached: ", "comment"),
				{
					text = `{attached.name} ({attached.mime}, {core.text.bytes(attached.size)})`,
					style = "markup.link",
					value = { attached = which },
					press = function()
						M.open_attachment(which)
					end,
				},
			})
		)
	end
	table.insert(parts, ui.gap())
	local html = if plain then nil else html_lines(message, cells)
	if html then
		table.move(html, 1, #html, #parts + 1, parts)
	elseif message.text == nil then
		table.insert(
			parts,
			ui.text(
				if backend.here()
					then "(its text is on its way)"
					else "(its text isn't in yet: the mail session fetches it when you open it there)",
				"comment"
			)
		)
	else
		local lines = text_lines(message.text)
		table.move(lines, 1, #lines, #parts + 1, parts)
	end
	if message.text ~= nil and not message.complete then
		table.insert(
			parts,
			ui.text("(it goes on: only the start of a big message is in)", "comment")
		)
	end
	return ui.column(parts)
end

--- The thread as it reads, `cells` wide: its subject, then each message,
--- from their HTML unless `plain`.
function M.thread_node(thread: Thread, cells: number, plain: boolean): core.UiNode
	local rule = string.rep("═", math.max(3, core.text.width(thread.subject)))
	local parts: { core.UiNode } =
		{ ui.text(thread.subject, "markup.heading"), ui.text(rule, "comment") }
	for i, message in thread.messages do
		table.insert(parts, ui.gap())
		if i > 1 then
			table.insert(parts, ui.text(string.rep("─", 40), "comment"))
			table.insert(parts, ui.gap())
		end
		table.insert(parts, message_node(message, cells, plain))
	end
	return ui.column(parts)
end

--- Reads the thread `key` (a message's or a thread's): where the list is,
--- on the page, or in a float over a quick look. In the mail session,
--- reading it marks it read.
function M.read(key: string)
	local thread, err = backend.get().thread(key)
	if thread == nil then
		greed.echo(err or "that mail is gone")
		return
	end
	if reading and reading.floating and reading.window:valid() then
		reading.window:close()
	end
	local buffer = greed.create_buffer("mail-thread", "", { readonly = true })
	buffer:set_line_numbers(false)
	local o = open
	local page = if o and not o.floating and o.window:valid() then o.window else nil
	local window = page
		or greed.float(buffer, { title = thread.subject, width = "90%", height = "90%" })
	if page then
		page:show(buffer)
	end
	local r = {
		window = window,
		buffer = buffer,
		thread = thread,
		floating = page == nil,
		plain = false,
		view = nil :: any,
	}
	r.view = ui.mount(buffer, function()
		return M.thread_node(r.thread, ui.width(buffer), r.plain)
	end)
	reading = r
	window:set_cursor(0)
	if backend.here() and M.any(thread, "unread") then
		backend.get().act({ thread.key }, "read")
	end
end

--- Whether any message in `thread` is `flag` (unread, flagged).
function M.any(thread: Thread, flag: "unread" | "flagged"): boolean
	for _, message in thread.messages do
		if message[flag] then
			return true
		end
	end
	return false
end

backend.on_changed(function()
	local o = open
	if o and o.buffer:valid() then
		refresh(o)
	end
	local r = reading
	if r and r.buffer:valid() then
		local thread = backend.get().thread(r.thread.key)
		if thread then
			r.thread = thread
			r.view:redraw()
		end
	end
end)

-- The mail being written, while it is.
local writing: { window: greed.View, buffer: greed.Buffer, replying: string? }? = nil

--- `draft` as it's written: its header lines, a blank line, its text.
function M.draft_text(draft: Draft): string
	local head = { `To: {draft.to}`, `Cc: {draft.cc}` }
	if draft.bcc ~= "" then
		table.insert(head, `Bcc: {draft.bcc}`)
	end
	table.insert(head, `Subject: {draft.subject}`)
	return table.concat(head, "\n") .. "\n\n" .. draft.text
end

--- The draft written in `text`: header lines up to the first blank one,
--- its text after that.
function M.parse_draft(text: string): Draft
	local head, body = string.match(text, "^(.-)\n\n(.*)$")
	local draft: Draft = { to = "", cc = "", bcc = "", subject = "", text = body or "" }
	for line in string.gmatch(head or text, "[^\n]+") do
		local name, value = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
		local field = string.lower(name or "")
		if field == "to" then
			draft.to = value or ""
		elseif field == "cc" then
			draft.cc = value or ""
		elseif field == "bcc" then
			draft.bcc = value or ""
		elseif field == "subject" then
			draft.subject = value or ""
		end
	end
	return draft
end

--- Writes `draft` on the mail session's page, the cursor where its text
--- goes, or on To when it goes to no one yet.
function M.write(draft: Draft)
	if not backend.here() then
		greed.echo("mail is written in the mail session: :mail-session goes there")
		return
	end
	local o = open
	local window = if o and not o.floating and o.window:valid() then o.window else greed.view()
	local buffer = greed.create_buffer("mail-compose", M.draft_text(draft))
	buffer:set_line_numbers(false)
	window:show(buffer)
	window:focus()
	if reading and reading.window == window then
		reading = nil
	end
	writing = { window = window, buffer = buffer, replying = draft.replying }
	local heads = if draft.bcc ~= "" then 4 else 3
	window:set_cursor(if draft.to == "" then 4 else buffer:line_start(heads + 1))
end

-- From the thread in `ctx` back to the list, or out of a quick look.
local function leave(ctx: greed.Context)
	local w = writing
	if ctx.buffer:kind() == "mail-compose" and w then
		writing = nil
		local list = open
		if list and list.buffer:valid() then
			w.window:show(list.buffer)
			back(list)
		end
		return
	end
	local o = open
	local r = reading
	if ctx.buffer:kind() == "mail-thread" and r then
		reading = nil
		if r.floating then
			r.window:close()
			if o and o.window:valid() then
				o.window:focus()
			end
		elseif o and o.buffer:valid() then
			r.window:show(o.buffer)
			back(o)
		end
	elseif o and o.floating then
		o.window:close()
		open = nil
	end
end

-- What a change in `ctx` is made on: the thread being read, or the
-- message under the cursor in the list; and whether any of it is unread
-- and flagged.
type Chosen = { keys: { string }, unread: boolean, flagged: boolean, tags: { string } }

local function chosen(ctx: greed.Context): Chosen?
	local r = reading
	if ctx.buffer:kind() == "mail-thread" and r then
		local tags: { string } = {}
		for _, message in r.thread.messages do
			for _, tag in message.tags do
				if not table.find(tags, tag) then
					table.insert(tags, tag)
				end
			end
		end
		return {
			keys = { r.thread.key },
			unread = M.any(r.thread, "unread"),
			flagged = M.any(r.thread, "flagged"),
			tags = tags,
		}
	end
	local o = open
	local row: Summary? = if o then o.view:value_at(ctx.view:cursor()) else nil
	if row == nil then
		return nil
	end
	return { keys = { row.key }, unread = row.unread, flagged = row.flagged, tags = row.tags }
end

-- Makes the action `which` picks for what's chosen in `ctx` (nil for none),
-- with the tag it names; a thread archived or trashed is left for the
-- list.
local function acting(which: (chosen: Chosen) -> (string?, string?)): (ctx: greed.Context) -> ()
	return function(ctx: greed.Context)
		local c = chosen(ctx)
		if c == nil then
			return
		end
		local action, tag = which(c)
		if action == nil then
			return
		end
		local _, err = backend.get().act(c.keys, action, tag)
		if err then
			greed.echo(err)
		elseif
			(action == "archive" or action == "trash") and ctx.buffer:kind() == "mail-thread"
		then
			leave(ctx)
		end
	end
end

-- The message a reply in `ctx` answers: the last in the thread being
-- read, or the one under the cursor in the list.
local function answering(ctx: greed.Context): string?
	local r = reading
	if ctx.buffer:kind() == "mail-thread" and r then
		local last = r.thread.messages[#r.thread.messages]
		return if last then last.key else nil
	end
	local o = open
	local row: Summary? = if o then o.view:value_at(ctx.view:cursor()) else nil
	return if row then row.key else nil
end

local function replying(all: boolean): (ctx: greed.Context) -> ()
	return function(ctx: greed.Context)
		local key = answering(ctx)
		if key == nil then
			return
		end
		local draft, err = backend.get().draft(key, all)
		if draft == nil then
			greed.echo(err or "that mail is gone")
			return
		end
		M.write(draft)
	end
end

-- In the mail session, the page is there from the start.
greed.on("editor.started", function()
	if backend.here() then
		M.page()
	end
end)

greed.command({
	name = "mail",
	doc = "Search and read your mail: on the page in the mail session, a quick look elsewhere",
	run = function()
		if backend.here() then
			M.page()
		else
			M.open()
		end
	end,
})

greed.command({
	name = "mail-session",
	doc = "Go to the mail session, starting it if needed: it syncs your mail",
	run = function()
		if backend.here() then
			M.page()
		else
			greed.session.switch({ name = backend.SESSION })
		end
	end,
})

greed.command({
	name = "mail-search",
	doc = "Search the mail in the list again",
	run = M.ask,
})

greed.command({
	name = "mail-read",
	doc = "Read the thread of the message under the cursor",
	run = function(ctx: greed.Context)
		local o = open
		if o == nil then
			return
		end
		local row: Summary? = o.view:value_at(ctx.view:cursor())
		if row then
			M.read(row.thread or row.key)
		end
	end,
})

greed.command({
	name = "mail-sync",
	doc = "Sync your mail now",
	run = function()
		backend.get().sync()
		greed.echo(if backend.here() then "syncing mail" else "the mail session syncs your mail")
	end,
})

greed.command({
	name = "mail-close",
	doc = "Go back from a thread to the list, or close a quick look at mail",
	run = leave,
})

greed.command({
	name = "mail-toggle-read",
	doc = "Mark the message (or the thread being read) read, or unread if it's read",
	run = acting(function(c: Chosen): (string?, string?)
		return if c.unread then "read" else "unread", nil
	end),
})

greed.command({
	name = "mail-toggle-flag",
	doc = "Flag the message (or the thread being read), or take its flag off",
	run = acting(function(c: Chosen): (string?, string?)
		return if c.flagged then "unflag" else "flag", nil
	end),
})

greed.command({
	name = "mail-archive",
	doc = "Move the message (or the thread being read) to the archive",
	run = acting(function(): (string?, string?)
		return "archive", nil
	end),
})

greed.command({
	name = "mail-trash",
	doc = "Move the message (or the thread being read) to the trash; in the trash, delete it for good",
	run = acting(function(): (string?, string?)
		return "trash", nil
	end),
})

--- `tag` as `tags` has it, minding no case, or nil when it hasn't.
function M.tagged(tags: { string }, tag: string): string?
	for _, have in tags do
		if string.lower(have) == string.lower(tag) then
			return have
		end
	end
	return nil
end

greed.command({
	name = "mail-tag",
	doc = "Tag the message (or the thread being read), or take the tag off if it has it",
	run = acting(function(c: Chosen): (string?, string?)
		local tag = core.prompt.ask("Tag")
		if tag == nil or tag == "" then
			return nil, nil
		end
		local have = M.tagged(c.tags, tag)
		if have then
			return "untag", have
		end
		return "tag", tag
	end),
})

greed.command({
	name = "mail-compose",
	doc = "Write new mail",
	run = function()
		M.write({ to = "", cc = "", bcc = "", subject = "", text = "" })
	end,
})

greed.command({
	name = "mail-reply",
	doc = "Reply to the message (or the thread being read), quoting it",
	run = replying(false),
})

greed.command({
	name = "mail-reply-all",
	doc = "Reply to everyone the message (or the thread being read) went to",
	run = replying(true),
})

greed.command({
	name = "mail-send",
	doc = "Send the mail being written",
	run = function(ctx: greed.Context)
		local w = writing
		if ctx.buffer:kind() ~= "mail-compose" or w == nil then
			greed.echo("there's no mail being written here")
			return
		end
		local draft = M.parse_draft(ctx.buffer:text())
		draft.replying = w.replying
		local ok, err = backend.get().send(draft)
		if not ok then
			greed.echo(err or "it couldn't be sent")
			return
		end
		greed.echo("sending")
		leave(ctx)
	end,
})

-- :w in mail being written keeps it as it is; :mail-send sends it.
core.file.on_save("mail-compose", function()
	greed.echo("it stays here as you wrote it: :mail-send sends it")
end)

greed.command({
	name = "mail-plain",
	doc = "Read the thread as its messages' text, or laid out from their HTML again",
	run = function()
		local r = reading
		if r then
			r.plain = not r.plain
			r.view:redraw()
			greed.echo(if r.plain then "as text" else "from its HTML")
		end
	end,
})

-- The message to show in a browser: the last in the thread being read
-- that has HTML, or the one under the cursor in the list.
local function browsed(ctx: greed.Context): string?
	local r = reading
	if ctx.buffer:kind() == "mail-thread" and r then
		for i = #r.thread.messages, 1, -1 do
			if r.thread.messages[i].html then
				return r.thread.messages[i].key
			end
		end
		return nil
	end
	local o = open
	local row: Summary? = if o then o.view:value_at(ctx.view:cursor()) else nil
	return if row then row.key else nil
end

greed.command({
	name = "mail-browser",
	doc = "Show the message in a web browser as it was sent, loading nothing from anywhere",
	run = function(ctx: greed.Context)
		local key = browsed(ctx)
		if key == nil then
			greed.echo("there's no HTML here to show")
			return
		end
		local path, err = backend.get().browse(key)
		if path == nil then
			greed.echo(err or "it has no HTML to show")
			return
		end
		core.file.open_link(`file://{path}`)
	end,
})

-- What's attached that `ctx` is on: the one under the cursor in a thread,
-- or the thread's only one.
local function attachment_at(ctx: greed.Context): Attached?
	local r = reading
	if ctx.buffer:kind() ~= "mail-thread" or r == nil then
		return nil
	end
	local value = r.view:value_at(ctx.view:cursor())
	if type(value) == "table" and value.attached then
		return value.attached
	end
	local all: { Attached } = {}
	for _, message in r.thread.messages do
		for i, attached in message.attachments do
			table.insert(all, { key = message.key, index = i - 1, name = attached.name })
		end
	end
	return if #all == 1 then all[1] else nil
end

greed.command({
	name = "mail-save-attachment",
	doc = "Save what's attached under the cursor (or the thread's only attachment) where you say",
	run = function(ctx: greed.Context)
		local which = attachment_at(ctx)
		if which == nil then
			greed.echo("put the cursor on what's attached, on its Attached line")
			return
		end
		local to = core.prompt.ask("Save as", `~/Downloads/{which.name}`)
		if to == nil or to == "" then
			return
		end
		greed.echo(`getting {which.name}`)
		local path, err = backend.get().attachment(which.key, which.index, to)
		greed.echo(if path then `saved {path}` else err or `{which.name} didn't come`)
	end,
})

-- What a list and a thread both do to their mail.
local ACTIONS = {
	u = "mail-toggle-read",
	s = "mail-toggle-flag",
	e = "mail-archive",
	d = "mail-trash",
	["#"] = "mail-trash",
	r = "mail-reply",
	a = "mail-reply-all",
	c = "mail-compose",
	t = "mail-tag",
	b = "mail-browser",
	q = "mail-close",
	esc = "mail-close",
}

greed.keymap.bind({ kind = "mail" }, ACTIONS)
greed.keymap.bind({ kind = "mail" }, {
	enter = "mail-read",
	["/"] = "mail-search",
	["$"] = "mail-sync",
})
greed.keymap.bind({ kind = "mail-thread" }, ACTIONS)
greed.keymap.bind({ kind = "mail-thread" }, { h = "mail-plain", S = "mail-save-attachment" })

return M
