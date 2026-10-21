-- Mail: your mail searched and read in Greed. In the mail session
-- (`greed mail`) the page shows what a search finds, newest first, with
-- the search box over it (in:inbox to start); elsewhere `:mail` opens the
-- same list in a float for a quick look. `enter` reads a thread, `/`
-- searches again, `$` syncs now, `q` goes back or closes; `u` marks read
-- or unread, `s` flags, `t` tags, `T` makes a todo, `e` archives and
-- `d` trashes; `r` replies, `a` replies to all and `c` writes new mail,
-- which `:mail-send` sends.
-- greed-mail syncs the accounts in mail.toml and keeps the index this
-- searches (backend.luau); a search is the query language anywhere in
-- Greed: from:anna is:unread date:2w.. in:work invoice.

local greed = require("@greed")
local core = require("@core")
local notes = require("@notes")
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
		-- What's attached: its names, and its kinds (pdf, image, ...).
		file = field("text"),
		type = field("exact"),
	},
	flags = flags(),
	text = function(): string
		return ""
	end,
	places = "tag",
	stored = FLAGS,
} :: core.QuerySource

--- The searches kept to go back to, shown over the list with how many
--- unread messages each finds; `tab` and `alt-1` to `alt-9` go to them. Set them in your
--- config: `require("@mail").searches = { { name = "Work", query = "in:work" } }`.
M.searches = {
	{ name = "Inbox", query = "in:inbox" },
	{ name = "Unread", query = "is:unread" },
	{ name = "Flagged", query = "is:flagged" },
	{ name = "Sent", query = "is:mine" },
	{ name = "Attached", query = "is:attachment" },
}

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
	-- How many unread messages each saved search finds, by its query, once
	-- counted; counting goes on while this is set.
	unread: { [string]: number },
	counting: boolean,
}
local open: Open? = nil

-- The thread being read, while it's open.
local reading: {
	window: greed.View,
	buffer: greed.Buffer,
	thread: Thread,
	-- What a change made while reading changes, when not all of it.
	found: { string }?,
	floating: boolean,
	-- Read as its text, rather than laid out from its HTML.
	plain: boolean,
	view: core.UiView,
	-- Which messages are opened and quotes unfolded.
	shown: Shown,
}? =
	nil

--- The keys of the messages `parsed` finds, newest first unless it sorts
--- otherwise, from the index alone; or nil and why.
function M.found(parsed: core.Query): ({ string }?, string?)
	local index, err = backend.get().index()
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
	return keys, trouble
end

--- The messages `parsed` finds, newest first unless it sorts otherwise,
--- or nil and why.
function M.search(parsed: core.Query): ({ Summary }?, string?)
	local keys, trouble = M.found(parsed)
	if keys == nil then
		return nil, trouble
	end
	return backend.get().summaries(keys)
end

greed.option.define({
	name = "mail-markdown",
	doc = "Whether mail you write is Markdown, sent as what you wrote and the HTML it makes; off sends plain text alone",
	default = true,
})

greed.option.define({
	name = "mail-threads",
	doc = "Whether a mail list shows each thread once, as its newest message found, rather than every message",
	default = true,
})

--- `found` (newest first) a row a thread: each thread's newest message,
--- unread or flagged if any found of the thread is, with the tags of all
--- and their keys in `found`.
function M.threads(found: { Summary }): { Summary }
	local rows: { Summary } = {}
	local by: { [string]: Summary } = {}
	for _, message in found do
		local thread = message.thread or message.key
		local row = by[thread]
		if row == nil then
			row = table.clone(message)
			-- A list from greed-mail is a JSON array, which won't clone.
			row.tags = table.move(message.tags, 1, #message.tags, 1, {})
			row.found = { message.key }
			by[thread] = row
			table.insert(rows, row)
		else
			table.insert(row.found :: { string }, message.key)
			row.unread = row.unread or message.unread
			row.flagged = row.flagged or message.flagged
			row.attached = (row.attached or 0) + (message.attached or 0)
			for _, tag in message.tags do
				if not table.find(row.tags, tag) then
					table.insert(row.tags, tag)
				end
			end
		end
	end
	return rows
end

-- The list's results for `parsed`, found once for the list and its count:
-- a row a thread, or a message, as `mail-threads` says.
local function results(o: Open, parsed: core.Query): { Summary }
	local text = core.query.print(parsed)
	local found = o.found[text]
	if found == nil then
		local rows, trouble = M.search(parsed)
		o.trouble = trouble
		found = rows or {}
		if greed.option.get("mail-threads") then
			found = M.threads(found)
		end
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

-- How many unread messages a saved search counts at most.
local COUNTED = 999

-- Counts the unread messages each saved search finds, in the background,
-- then draws the list again. From the index alone: counting asks
-- greed-mail nothing.
local function count(o: Open)
	if o.counting then
		return
	end
	o.counting = true
	greed.spawn(function()
		for _, saved in M.searches do
			local text = if saved.query == "" then "is:unread" else `({saved.query}) is:unread`
			local parsed = core.search_box.read(text, { source = M.source })
			if parsed.ok then
				parsed.view.limit = COUNTED + 1
				o.unread[saved.query] = #(M.found(parsed) or {})
			end
		end
		o.counting = false
		if o.buffer:valid() then
			o.view:redraw()
		end
	end)
end

-- The saved searches over the list: each with its number and unread
-- count, the one shown picked out, pressing one going to it.
local function tabs(o: Open): core.UiNode
	local spans: { core.UiSpan } = {}
	for i, saved in M.searches do
		local n = o.unread[saved.query] or 0
		local unread = if n > COUNTED then ` {COUNTED}+` elseif n > 0 then ` {n}` else ""
		table.insert(spans, {
			text = ` {i} {saved.name}{unread} `,
			style = if o.query == saved.query then "markup.bold" else "comment",
			press = function()
				M.go(saved.query)
			end,
		})
	end
	return ui.line(spans)
end

local function render(o: Open): core.UiNode
	local head = if o.trouble
		then ui.text(o.trouble, "diagnostic.error")
		else ui.text(`{#o.rows} · {o.query}`, "comment")
	local rows: { core.UiGridRow } = {}
	for _, row in o.rows do
		table.insert(rows, {
			cells = {
				{
					ui.span(if row.unread then "●" else " ", "function"),
					ui.span(
						if row.flagged then "⚑" else " ",
						if row.flagged then "constant" else nil
					),
					-- Two cells wide either way, so the columns stay put.
					ui.span(if (row.attached or 0) > 0 then "📎" else "  ", "comment"),
				},
				{ ui.span(M.when(row.date), "comment") },
				{
					ui.span(
						core.text.clip(M.who(row.from), 24),
						if row.unread then "keyword" else nil
					),
				},
				{
					ui.span(row.subject),
					ui.span(
						if row.found and #row.found > 1 then ` ({#row.found})` else "",
						"comment"
					),
				},
				{ ui.span(M.tag_text(row.tags), "comment") },
			},
			value = row,
		})
	end
	local parts: { core.UiNode } = { tabs(o), head }
	local busy = M.busy_node()
	if busy then
		table.insert(parts, busy)
	end
	table.insert(parts, ui.gap())
	table.insert(parts, ui.grid(rows))
	return ui.column(parts)
end

--- What greed-mail is busy with, as a line over the list: a bar while it
--- indexes, how much is in while an account syncs; nil when it isn't.
function M.busy_node(): core.UiNode?
	local indexing = backend.busy.indexing
	if indexing then
		return ui.progress("indexing your mail", indexing.done, indexing.of)
	end
	local said = backend.syncing_text()
	return if said then ui.text(said, "comment") else nil
end

-- Drawn again as what greed-mail is busy with changes.
backend.on_busy(function()
	local o = open
	if o and o.buffer:valid() then
		o.view:redraw()
	end
end)

-- Runs the list's query again, as the mail changed or it was typed; as
-- the mail changed (no `parsed`), counts the saved searches' unread too.
local function refresh(o: Open, parsed: core.Query?)
	o.found = {}
	local query = parsed or core.search_box.read(o.query, { source = M.source })
	if query.ok then
		o.rows = results(o, query)
	end
	o.view:redraw()
	if parsed == nil then
		count(o)
	end
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
	if o.view:value_at(o.window:cursor()) == nil then
		local first = o.view:line_of(function(value: any): boolean
			return value ~= nil
		end)
		if first then
			o.window:set_cursor(o.buffer:line_start(first))
		end
	end
end

--- Shows what `query` finds in the open list, the cursor on its first.
function M.go(query: string)
	local o = open
	if o == nil or not o.buffer:valid() then
		return
	end
	o.query = query
	refresh(o, core.search_box.read(query, { source = M.source }))
	o.window:set_cursor(0)
	back(o)
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
	-- The list stays while mail is written in its place.
	buffer:set_kept(true)
	if window then
		window:show(buffer)
	end
	local o: Open = {
		window = shown,
		buffer = buffer,
		floating = window == nil,
		query = query,
		rows = {},
		found = {},
		unread = {},
		counting = false,
		view = nil :: any,
	}
	o.view = ui.mount(buffer, function()
		return render(o)
	end, {}, {
		key = function(row: Summary): string
			return row.key
		end,
		-- tab goes through the saved searches here, not the view's buttons.
		keys = false,
	})
	refresh(o)
	return o
end

--- Opens a quick look at what `query` (in:inbox to start) finds in a
--- float, and the search box over it.
function M.open(query: string?)
	local o = open
	if o and o.floating then
		if o.window:valid() then
			o.window:close()
		end
		if o.buffer:valid() then
			pcall(o.buffer.close, o.buffer)
		end
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

--- An icon for what's attached, by its kind: a picture, a document, sound,
--- video, an archive, an invite, a program (which never opens), or a clip.
function M.attachment_icon(attached: backend.Attachment): string
	local mime = string.lower(attached.mime)
	local how = core.file.opening(attached.name, attached.mime)
	if how == "refused" then
		return "⚠"
	elseif string.match(mime, "^image/") then
		return "🖼"
	elseif string.match(mime, "^audio/") then
		return "🎵"
	elseif string.match(mime, "^video/") then
		return "🎞"
	elseif mime == "text/calendar" then
		return "📅"
	elseif
		string.match(mime, "zip")
		or string.match(mime, "tar")
		or string.match(mime, "compress")
	then
		return "📦"
	elseif mime == "application/pdf" or how == "outside" or string.match(mime, "^text/") then
		return "📄"
	end
	return "📎"
end

--- Opens `which` as its kind of file opens (`core.file.open`: in Greed, or
--- with the program that opens it); the mail session fetches it first, the
--- first time.
function M.open_attachment(which: Attached)
	local path = M.kept_attachment(which)
	if path then
		core.file.open(path)
	end
end

--- Where `which` is kept beside your mail, fetched the first time; nil
--- when it didn't come, having said why.
function M.kept_attachment(which: Attached): string?
	greed.echo(`getting {which.name}`)
	local path, err = backend.get().attachment(which.key, which.index)
	greed.echo(if path then "" else err or `{which.name} didn't come`)
	return path
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
-- open, and what each says; nil when it has none.
local function html_lines(message: backend.Message, cells: number): ({ core.UiNode }?, { string })
	if not message.html then
		return nil, {}
	end
	local at = `{message.key} {cells}`
	local rendered = laid[at] or backend.get().render(message.key, cells)
	if rendered == nil then
		return nil, {}
	end
	laid[at] = rendered
	local nodes: { core.UiNode } = {}
	local texts: { string } = {}
	for _, line in rendered.lines do
		local spans: { core.UiSpan } = {}
		local said: { string } = {}
		for _, span in line do
			table.insert(said, span.text)
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
		table.insert(texts, table.concat(said))
	end
	return nodes, texts
end

-- The lines of `message`'s text, its quoted lines dimmed, and what each
-- says.
local function text_lines(text: string): ({ core.UiNode }, { string })
	local nodes: { core.UiNode } = {}
	local texts: { string } = {}
	for line in string.gmatch(string.gsub(text, "\r\n", "\n") .. "\n", "(.-)\n") do
		table.insert(nodes, ui.text(line, if string.sub(line, 1, 1) == ">" then "comment" else nil))
		table.insert(texts, line)
	end
	return nodes, texts
end

-- A header line: its name dimmed, then its value.
local function header(name: string, value: string, style: string?): core.UiNode
	return ui.line({ ui.span(`{name}: `, "comment"), ui.span(value, style) })
end

-- Answers given here, by the key of the invite's message, until its
-- organizer's next update says so itself.
local answered: { [string]: string } = {}

local ANSWERS = {
	ACCEPTED = "accepted",
	TENTATIVE = "said maybe",
	DECLINED = "declined",
	["NEEDS-ACTION"] = "not answered",
}

--- When an invite is, in words: "Friday 24 Oct 10:00 to 11:00", "today
--- 09:30", a day for a day-long one.
function M.invite_when(invite: backend.Invite): string
	local function at(stamp: string?): (string?, string?)
		return string.match(stamp or "", "^(%d+%-%d+%-%d+)T?(%d*:?%d*)")
	end
	local day, time = at(invite.start)
	if day == nil then
		return ""
	end
	local said = core.dates.day(day)
	if invite.all_day or time == "" then
		return said
	end
	said ..= ` {time}`
	local end_day, end_time = at(invite["end"])
	if end_day == day and end_time ~= "" then
		said ..= ` to {end_time}`
	elseif end_day then
		said ..= ` to {core.dates.day(end_day)} {end_time}`
	end
	return said
end

--- Answers the invite in the message `key` (`accepted`, `tentative`,
--- `declined`), sending it to its organizer.
function M.respond(key: string, answer: string)
	local ok, err = backend.get().respond(key, answer)
	if not ok then
		greed.echo(err or "the answer couldn't be sent")
		return
	end
	local word = string.upper(answer)
	answered[key] = word
	greed.echo(`your answer goes in the next round: {ANSWERS[word]}`)
	local r = reading
	if r and r.buffer:valid() then
		r.view:redraw()
	end
end

-- The invite `message` carries, as a card: what, when, where, who asks,
-- and buttons to answer a request.
local function invite_node(message: backend.Message, invite: backend.Invite): core.UiNode
	local lines: { core.UiNode } = { ui.text(invite.summary, "markup.bold") }
	local when = M.invite_when(invite)
	if when ~= "" then
		table.insert(lines, ui.text(if invite.repeats then `{when}, repeating` else when))
	end
	if invite.location then
		table.insert(lines, ui.text(invite.location))
	end
	local organizer = invite.organizer
	if organizer then
		table.insert(lines, header("From", organizer.name or organizer.address))
	end
	if invite.cancelled then
		table.insert(lines, ui.text("Cancelled", "diagnostic.warning"))
		return ui.box("Invite", ui.column(lines))
	elseif invite.method == "REPLY" then
		for _, who in invite.attendees do
			local said = ANSWERS[who.answer or ""] or "answered"
			table.insert(lines, ui.text(`{who.name or who.address} {said}`))
		end
		return ui.box("Answer", ui.column(lines))
	end
	local yours = answered[message.key] or invite.answer
	if yours and yours ~= "NEEDS-ACTION" then
		table.insert(lines, ui.text(`You {ANSWERS[yours] or "answered"}`, "comment"))
	end
	local function answer(label: string, word: string): any
		return {
			text = ` {label} `,
			style = "ui.button",
			press = function()
				M.respond(message.key, word)
			end,
		}
	end
	table.insert(
		lines,
		ui.line({
			answer("Accept", "accepted"),
			{ text = " " },
			answer("Maybe", "tentative"),
			{ text = " " },
			answer("Decline", "declined"),
		})
	)
	return ui.box("Invite", ui.column(lines))
end

--- What of a thread shows: the messages opened and the quotes unfolded,
--- by key, or `all` of it; `changed` draws it again once pressed.
export type Shown = {
	messages: { [string]: boolean },
	quotes: { [string]: boolean },
	all: boolean,
	changed: () -> (),
}

-- How many quoted lines in a row fold away.
local FOLDED = 4

local function quoted(text: string): boolean
	return string.match(text, "^%s*>") ~= nil
end

local function blank(text: string): boolean
	return string.match(text, "^%s*$") ~= nil
end

--- The runs of quoted lines among `texts` that fold away, as `from` and
--- `to` (1-based, both in): at least `FOLDED` lines starting with `>`, the
--- blank lines between them, and the line saying who wrote it ("On ...,
--- Anna wrote:") just before.
function M.quoted_runs(texts: { string }): { { from: number, to: number } }
	local runs: { { from: number, to: number } } = {}
	local i = 1
	while i <= #texts do
		if quoted(texts[i]) then
			local from, to, count = i, i, 0
			local j = i
			while j <= #texts and (quoted(texts[j]) or blank(texts[j])) do
				if quoted(texts[j]) then
					to = j
					count += 1
				end
				j += 1
			end
			if count >= FOLDED then
				-- Who wrote it, with a blank line between or not.
				local before = from - 1
				while before >= 1 and blank(texts[before]) do
					before -= 1
				end
				if before >= 1 and string.match(texts[before], ":%s*$") then
					from = before
				end
				table.insert(runs, { from = from, to = to })
			end
			i = to + 1
		else
			i += 1
		end
	end
	return runs
end

-- `nodes` (a line each, `texts` what they say) with their quoted runs
-- folded into a line to press, unless `shown` unfolds them; `key` is the
-- message's.
local function folded(
	nodes: { core.UiNode },
	texts: { string },
	key: string,
	shown: Shown
): { core.UiNode }
	if shown.all then
		return nodes
	end
	local out: { core.UiNode } = {}
	local rest = 1
	for n, run in M.quoted_runs(texts) do
		local id = `{key} {n}`
		table.move(nodes, rest, run.from - 1, #out + 1, out)
		if shown.quotes[id] then
			table.move(nodes, run.from, run.to, #out + 1, out)
		else
			table.insert(
				out,
				ui.line({
					{
						text = `··· {run.to - run.from + 1} lines quoted`,
						style = "comment",
						press = function()
							shown.quotes[id] = true
							shown.changed()
						end,
					},
				})
			)
		end
		rest = run.to + 1
	end
	table.move(nodes, rest, #nodes, #out + 1, out)
	return out
end

-- A message read before, as one line to press: who, when, how it starts.
local function closed_node(message: backend.Message, shown: Shown): core.UiNode
	local start = string.match(message.text or "", "^%s*([^\r\n]*)") or ""
	return ui.line({
		{
			text = `▸ {M.who(message.from)}  {M.when(message.date)}  `,
			style = "markup.bold",
			press = function()
				shown.messages[message.key] = true
				shown.changed()
			end,
		},
		{ text = start, style = "comment" },
	})
end

-- A message as it's read, `cells` wide: who, when, to whom, then what it
-- says, from its HTML unless `plain`, its quotes folded as `shown` says.
local function message_node(
	message: backend.Message,
	cells: number,
	plain: boolean,
	shown: Shown
): core.UiNode
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
	local count = #message.attachments
	if count > 0 then
		table.insert(parts, ui.gap())
		table.insert(parts, ui.text(`📎 {count} attached`, "comment"))
	end
	for i, attached in message.attachments do
		local which: Attached = { key = message.key, index = i - 1, name = attached.name }
		local _, opens = core.file.opening(attached.name, attached.mime)
		table.insert(
			parts,
			ui.line({
				ui.span(`  {M.attachment_icon(attached)} `),
				{
					text = attached.name,
					style = "markup.link",
					value = { attached = which },
					press = function()
						M.open_attachment(which)
					end,
				},
				ui.span(`  {core.text.bytes(attached.size)} · {opens}`, "comment"),
			})
		)
	end
	local invite = message.invite
	if invite then
		table.insert(parts, ui.gap())
		table.insert(parts, invite_node(message, invite))
	end
	table.insert(parts, ui.gap())
	local html, said: { string } = nil, {}
	if not plain then
		html, said = html_lines(message, cells)
	end
	if html then
		local lines = folded(html, said, message.key, shown)
		table.move(lines, 1, #lines, #parts + 1, parts)
	elseif message.text == nil then
		table.insert(parts, ui.text("(its text is on its way)", "comment"))
	else
		local nodes, texts = text_lines(message.text)
		local lines = folded(nodes, texts, message.key, shown)
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

--- What a thread shows when it's opened: the messages that are unread
--- then, and the last, opened; quotes folded.
function M.showing(thread: Thread, changed: () -> ()): Shown
	local opened: { [string]: boolean } = {}
	for i, message in thread.messages do
		if message.unread or i == #thread.messages then
			opened[message.key] = true
		end
	end
	return { messages = opened, quotes = {}, all = false, changed = changed }
end

--- The thread as it reads, `cells` wide: its subject, then each message,
--- from their HTML unless `plain`; those `shown` doesn't open as a line
--- each, their quotes folded.
function M.thread_node(thread: Thread, cells: number, plain: boolean, shown: Shown?): core.UiNode
	local showing = shown or M.showing(thread, function() end)
	local rule = string.rep("═", math.max(3, core.text.width(thread.subject)))
	local parts: { core.UiNode } =
		{ ui.text(thread.subject, "markup.heading"), ui.text(rule, "comment") }
	for i, message in thread.messages do
		local opened = showing.all or showing.messages[message.key]
		if opened or i == 1 then
			table.insert(parts, ui.gap())
		end
		if i > 1 and opened then
			table.insert(parts, ui.text(string.rep("─", 40), "comment"))
			table.insert(parts, ui.gap())
		end
		table.insert(
			parts,
			if opened
				then message_node(message, cells, plain, showing)
				else closed_node(message, showing)
		)
	end
	return ui.column(parts)
end

--- Reads the thread `key` (a message's or a thread's): where the list is,
--- on the page, or in a float over a quick look. In the mail session,
--- reading it marks it read. A change made while reading changes the
--- messages `found` (a list row's), or the whole thread without them.
function M.read(key: string, found: { string }?)
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
		found = found,
		floating = page == nil,
		plain = false,
		view = nil :: any,
		shown = nil :: any,
	}
	r.shown = M.showing(thread, function()
		r.view:redraw()
	end)
	r.view = ui.mount(buffer, function()
		return M.thread_node(r.thread, ui.width(buffer), r.plain, r.shown)
	end)
	reading = r
	window:set_cursor(0)
	if M.any(thread, "unread") then
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
local writing: { window: greed.View, buffer: greed.Buffer }? = nil

-- Mail being written, by its buffer's id: the file its draft is kept in
-- (none without a data folder) and the message it answers.
local drafts: { [number]: { path: string?, replying: string? } } = {}

-- The draft of the mail sent last, while z can still take it back.
local sent_draft: string? = nil

--- Where drafts are kept, a file each, beside greed-mail's store.
function M.drafts_dir(): string?
	local data = greed.fs.dirs().data
	return if data then data .. "/mail/drafts" else nil
end

--- A draft as its file keeps it: what's written, the message it answers
--- and when it was kept (Unix seconds).
export type Kept = { text: string, replying: string?, saved: number }

-- The draft kept in the file at `path`, if it holds one.
local function read_kept(path: string): Kept?
	local text = greed.fs.read(path)
	local kept = if text then greed.json.decode(text) else nil
	return if type(kept) == "table" and type(kept.text) == "string" then kept :: Kept else nil
end

-- Keeps `buffer`'s draft in its file, waiting for the disk off the
-- editor's thread with `background`.
local function keep(buffer: greed.Buffer, background: boolean?)
	local d = drafts[buffer:id()]
	if d == nil or d.path == nil then
		return
	end
	local kept: Kept = { text = buffer:text(), replying = d.replying, saved = os.time() }
	local ok, err =
		greed.fs.write(d.path, greed.json.encode(kept), { private = true, background = background })
	if not ok then
		greed.echo(`the draft couldn't be kept: {err or "?"}`)
	end
end

core.autosave.on_quiet("mail-compose", function(buffer: greed.Buffer)
	keep(buffer, true)
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	drafts[event.id] = nil
end)

--- The drafts kept, newest first: each one's file and what it holds.
function M.drafts(): { { path: string, kept: Kept } }
	local dir = M.drafts_dir()
	local out: { { path: string, kept: Kept } } = {}
	local entries: { greed.DirEntry } = (if dir then greed.fs.list(dir) else nil) or {}
	for _, entry in entries do
		local path = `{dir}/{entry.name}`
		local kept = if entry.dir then nil else read_kept(path)
		if kept then
			table.insert(out, { path = path, kept = kept })
		end
	end
	table.sort(
		out,
		function(a: { path: string, kept: Kept }, b: { path: string, kept: Kept }): boolean
			return a.kept.saved > b.kept.saved
		end
	)
	return out
end

--- `draft` as it's written: its header lines, a blank line, its text.
function M.draft_text(draft: Draft): string
	local head = { `From: {draft.from or ""}`, `To: {draft.to}`, `Cc: {draft.cc}` }
	if draft.bcc ~= "" then
		table.insert(head, `Bcc: {draft.bcc}`)
	end
	if (draft.reply_to or "") ~= "" then
		table.insert(head, `Reply-To: {draft.reply_to}`)
	end
	table.insert(head, `Subject: {draft.subject}`)
	local attach = draft.attach or {}
	if #attach > 0 then
		table.insert(head, `Attach: {table.concat(attach, ", ")}`)
	end
	return table.concat(head, "\n") .. "\n\n" .. draft.text
end

-- The paths an Attach line names, apart by commas.
local function paths(value: string): { string }
	local out: { string } = {}
	for path in string.gmatch(value, "[^,]+") do
		local trimmed = string.match(path, "^%s*(.-)%s*$") or ""
		if trimmed ~= "" then
			table.insert(out, trimmed)
		end
	end
	return out
end

--- The draft written in `text`: header lines up to the first blank one,
--- its text after that.
function M.parse_draft(text: string): Draft
	local head, body = string.match(text, "^(.-)\n\n(.*)$")
	local draft: Draft =
		{ from = "", to = "", cc = "", bcc = "", subject = "", text = body or "", attach = {} }
	for line in string.gmatch(head or text, "[^\n]+") do
		local name, value = string.match(line, "^([%w%-]+):%s*(.-)%s*$")
		local field = string.lower(name or "")
		if field == "from" then
			draft.from = value or ""
		elseif field == "to" then
			draft.to = value or ""
		elseif field == "cc" then
			draft.cc = value or ""
		elseif field == "bcc" then
			draft.bcc = value or ""
		elseif field == "reply-to" then
			draft.reply_to = value or ""
		elseif field == "subject" then
			draft.subject = value or ""
		elseif field == "attach" then
			draft.attach = paths(value or "")
		end
	end
	return draft
end

-- How many drafts were started here, to tell their files apart.
local started = 0

--- Every address you send from, as it goes out: each account's, then its
--- aliases', in mail.toml's order.
function M.identities(): { backend.Identity }
	local out: { backend.Identity } = {}
	for _, account in backend.get().accounts() do
		local identities: { backend.Identity } = account.identities or {}
		table.move(identities, 1, #identities, #out + 1, out)
	end
	return out
end

--- How mail from `from` ("Anna <anna@x>" or the address) goes out, as
--- mail.toml says; nil for an address that isn't yours.
function M.identity(from: string): backend.Identity?
	local address = string.lower(string.match(from, "<([^>]+)>") or core.text.trim(from))
	for _, identity in M.identities() do
		if string.lower(identity.address) == address then
			return identity
		end
	end
	return nil
end

--- The address new mail is from: mail.toml's `from`, else your first
--- account's.
function M.default_from(): string
	for _, identity in M.identities() do
		if identity.default then
			return identity.address
		end
	end
	local first = backend.get().accounts()[1]
	return if first then first.address else ""
end

-- What `identity` puts on the From line.
local function from_line(identity: backend.Identity): string
	local name = identity.display_name
	return if name and name ~= "" then `{name} <{identity.address}>` else identity.address
end

-- A signature as it's written in mail, after its "-- " line; "" for none.
-- "-- " starts a signature, as mail programs know to leave it out of a
-- reply's quote.
local function signature_block(identity: backend.Identity?): string
	local signature = identity and identity.signature
	return if signature and signature ~= "" then `\n\n-- \n{signature}` else ""
end

--- `draft`, new, made as its From's identity says: the name on the From
--- line, its Reply-To and Bcc where the draft has none, and its signature
--- under where you write, above what a reply quotes.
function M.as_identity(draft: Draft): Draft
	local identity = M.identity(draft.from or "")
	if identity == nil then
		return draft
	end
	local out = table.clone(draft)
	local name = identity.display_name
	if name and name ~= "" and not string.find(out.from or "", "<", 1, true) then
		out.from = `{name} <{identity.address}>`
	end
	if (out.reply_to or "") == "" then
		out.reply_to = identity.reply_to
	end
	if out.bcc == "" then
		out.bcc = identity.bcc or ""
	end
	local signature = signature_block(identity)
	if signature ~= "" then
		out.text = signature .. (if out.text == "" then "\n" else out.text)
	end
	return out
end

--- `draft` from `to` instead: its From line, and the Reply-To, Bcc and
--- signature of the identity it was from, where they're still as it put
--- them, made `to`'s. A new signature goes where the old one was, else
--- above what a reply quotes, else at the end.
function M.from_identity(draft: Draft, to: backend.Identity): Draft
	local out = table.clone(draft)
	local was = M.identity(draft.from or "")
	out.from = from_line(to)
	if (out.reply_to or "") == (was and was.reply_to or "") then
		out.reply_to = to.reply_to or ""
	end
	if out.bcc == (was and was.bcc or "") then
		out.bcc = to.bcc or ""
	end
	local old, new = signature_block(was), signature_block(to)
	-- The old one whole, as it put it: up to a line's end, or the end.
	local at: number? = nil
	if old ~= "" then
		local found = string.find(out.text .. "\n", old .. "\n", 1, true)
		at = found
	end
	if at then
		out.text = string.sub(out.text, 1, at - 1) .. new .. string.sub(out.text, at + #old)
	elseif new ~= "" and not string.find("\n" .. out.text, "\n-- \n", 1, true) then
		local quote = string.find(out.text, "\n[^\n]*wrote:\n>")
		if quote then
			out.text = string.sub(out.text, 1, quote - 1) .. new .. string.sub(out.text, quote)
		else
			local ended = string.gsub(out.text, "\n+$", "")
			out.text = ended .. new .. "\n"
		end
	end
	return out
end

--- Asks which of your addresses the mail written in `buffer` is from,
--- and makes it so (`from_identity`).
function M.pick_from(buffer: greed.Buffer)
	local items: { { label: string, value: any, kind: string? } } = {}
	for _, identity in M.identities() do
		table.insert(items, { label = from_line(identity), value = identity })
	end
	require("@picker").pick("From", items, function(item)
		local draft = M.parse_draft(buffer:text())
		local text = M.draft_text(M.from_identity(draft, item.value))
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
	end)
end

--- Writes `draft` where the list is, the cursor where its text goes, or on
--- To when it goes to no one yet. New mail is from mail.toml's `from` (or
--- your first account), and goes as its identity says. It's kept as a
--- draft as it's written: in the file `kept`, when it was kept before, or
--- a new one.
function M.write(draft: Draft, kept: string?)
	if draft.from == nil or draft.from == "" then
		draft.from = M.default_from()
	end
	if kept == nil then
		draft = M.as_identity(draft)
	end
	local o = open
	local window = if o and o.window:valid() then o.window else greed.view()
	local buffer = greed.create_buffer("mail-compose", M.draft_text(draft))
	buffer:set_line_numbers(false)
	window:show(buffer)
	window:focus()
	if reading and reading.window == window then
		reading = nil
	end
	writing = { window = window, buffer = buffer }
	local dir = M.drafts_dir()
	started += 1
	drafts[buffer:id()] = {
		path = kept or (if dir then `{dir}/{os.time()}-{started}-{math.random(1e9)}.json` else nil),
		replying = draft.replying,
	}
	if draft.to == "" then
		window:set_cursor(buffer:line_end(1))
	else
		local text = buffer:text()
		local blank = string.find(text, "\n\n", 1, true) or #text
		window:set_cursor(blank + 1)
	end
end

-- The buffer writing the draft kept in `path`, if one is.
local function writing_draft(path: string): greed.Buffer?
	for id, d in drafts do
		local buffer = if d.path == path then greed.buffer(id) else nil
		if buffer and buffer:valid() then
			return buffer
		end
	end
	return nil
end

--- Writes the draft kept in `path` again, or says why it can't.
function M.open_draft(path: string)
	local writing_it = writing_draft(path)
	if writing_it then
		local window = greed.view()
		window:show(writing_it)
		writing = { window = window, buffer = writing_it }
		return
	end
	local kept = read_kept(path)
	if kept == nil then
		greed.echo("that draft is gone")
		return
	end
	local draft = M.parse_draft(kept.text)
	draft.replying = kept.replying
	M.write(draft, path)
end

--- Throws away the draft kept in `path`, closing mail that's writing it.
function M.discard_draft(path: string)
	greed.fs.remove(path)
	for id, d in drafts do
		if d.path == path then
			drafts[id] = nil
			local w = writing
			if w and w.buffer:id() == id then
				writing = nil
				local list = open
				if list and list.buffer:valid() and w.window:valid() then
					w.window:show(list.buffer)
				end
			end
			local buffer = greed.buffer(id)
			if buffer and buffer:valid() then
				pcall(buffer.close, buffer)
			end
		end
	end
end

--- Adds the file at `path` to what the mail being written attaches, on
--- its Attach line.
function M.attach(path: string)
	local w = writing
	if w == nil or not w.buffer:valid() then
		greed.echo("there's no mail being written: c writes some")
		return
	end
	local buffer = w.buffer
	local draft = M.parse_draft(buffer:text())
	local attach = draft.attach or {}
	table.insert(attach, path)
	local line = `Attach: {table.concat(attach, ", ")}`
	buffer:edit(function(e)
		for i = 0, buffer:line_count() - 1 do
			local text = buffer:line_text(i)
			if text == "" then
				e:insert(buffer:line_start(i), line .. "\n")
				return
			elseif string.match(string.lower(text), "^attach:") then
				e:replace(buffer:line_start(i), buffer:line_end(i), line)
				return
			end
		end
	end)
	greed.echo(`attached {path}`)
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
		o.buffer:close()
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
			keys = r.found or { r.thread.key },
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
	-- A thread's row changes the messages found of it, not others of
	-- the thread: archiving a thread found in the inbox leaves your replies
	-- in Sent.
	return {
		keys = row.found or { row.key },
		unread = row.unread,
		flagged = row.flagged,
		tags = row.tags,
	}
end

-- Whether you press y to delete `count` messages for good, which can't be
-- undone (keys a plugin feeds don't answer).
local function for_good(count: number): boolean
	local what = if count == 1 then "it's in the trash" else `{count} are in the trash`
	greed.echo(`{what}: delete for good? It can't be undone. y deletes, anything else keeps`)
	local key = greed.next_key()
	greed.echo(if key == "y" then "" else "kept")
	return key == "y"
end

-- Makes the action `which` picks for what's chosen in `ctx` (nil for none),
-- with the tag it names; a thread archived or trashed is left for the
-- list. Deleting for good asks first.
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
		local mail = backend.get()
		local _, err, in_trash = mail.act(c.keys, action, tag)
		if in_trash and in_trash > 0 then
			if not for_good(in_trash) then
				return
			end
			_, err = mail.act(c.keys, action, tag, true)
		end
		if err then
			greed.echo(err)
		elseif
			(action == "archive" or action == "trash") and ctx.buffer:kind() == "mail-thread"
		then
			leave(ctx)
		end
	end
end

-- The message a reply or a todo in `ctx` is about: the last in the thread
-- being read, or the one under the cursor in the list.
local function answering(ctx: greed.Context): Summary?
	local r = reading
	if ctx.buffer:kind() == "mail-thread" and r then
		return r.thread.messages[#r.thread.messages]
	end
	local o = open
	return if o then o.view:value_at(ctx.view:cursor()) else nil
end

local function replying(all: boolean): (ctx: greed.Context) -> ()
	return function(ctx: greed.Context)
		local message = answering(ctx)
		if message == nil then
			return
		end
		local draft, err = backend.get().draft(message.key, all)
		if draft == nil then
			greed.echo(err or "that mail is gone")
			return
		end
		M.write(draft)
	end
end

--- A link to the message whose Message-ID is `id`, as notes write it:
--- `[mail](mail:ID)`, percent-encoded but for the `@+=` most have.
function M.link(id: string): string
	return `[mail](mail:{core.text.percent_encode(id, "@+=")})`
end

--- The Message-ID a `mail:` link names.
function M.linked(uri: string): string
	return core.text.percent_decode(string.sub(uri, #"mail:" + 1))
end

--- What a todo made from `message` says to start with: who sent it and
--- what about.
function M.todo_text(message: Summary): string
	return `{M.who(message.from)}: {message.subject}`
end

greed.command({
	name = "mail-todo",
	doc = "Add a todo about the message (or the thread being read) to your inbox note, linking back to it",
	run = function(ctx: greed.Context)
		local message = answering(ctx)
		if message == nil then
			return
		end
		local text = core.prompt.ask("Todo for your inbox", M.todo_text(message))
		if text == nil or not string.match(text, "%S") then
			return
		end
		local id = message.message_id
		local link = if id then M.link(id) else nil
		local said = notes.todos.capture(if link then `{text} {link}` else text, "inbox")
		if link then
			said = string.gsub(said, " " .. string.gsub(link, "%p", "%%%0"), "")
		end
		greed.echo(`added to your inbox: {said}`)
	end,
})

-- A mail: link, in a note or anywhere, reads its thread.
core.file.link_scheme("mail", function(uri: string)
	local key, err = backend.get().find(M.linked(uri))
	if key == nil then
		greed.echo(err or "that mail isn't here: it may not have synced yet")
		return
	end
	M.read(key)
end)

--- A rule for new mail: a query, and what to do with the new mail it
--- finds: `read`, `flag`, `tag` (a tag to put on), then `archive` or
--- `trash`.
export type Rule = {
	query: string,
	read: boolean?,
	flag: boolean?,
	tag: string?,
	archive: boolean?,
	trash: boolean?,
	--- Over all mail its query finds, not only new mail: after a round of
	--- syncing, at most hourly, as for keeping mail an age
	--- (`in:inbox list:news date:..30d`, archive).
	all: boolean?,
}

--- Rules for new mail, run in the mail session as it arrives, in order,
--- and never over mail that was there before unless a rule says `all`.
--- Set them in your config:
--- `require("@mail").rules = { { query = "from:github.com", tag = "github", archive = true } }`.
M.rules = {} :: { Rule }

--- The most a rule over all mail changes at once on its own; more waits
--- for `:mail-rule-run`, so a query that finds more than it should can't
--- move a mailbox's worth of mail unseen.
M.MANY = 100

--- What `rule` does, as the actions greed-mail takes, in the order made:
--- marks first, a move last.
function M.rule_actions(rule: Rule): { { action: string, tag: string? } }
	local out: { { action: string, tag: string? } } = {}
	if rule.read then
		table.insert(out, { action = "read" })
	end
	if rule.flag then
		table.insert(out, { action = "flag" })
	end
	if rule.tag then
		table.insert(out, { action = "tag", tag = rule.tag })
	end
	if rule.trash then
		table.insert(out, { action = "trash" })
	elseif rule.archive then
		table.insert(out, { action = "archive" })
	end
	return out
end

--- What `rule` does, in words: "tag github, archive".
function M.rule_text(rule: Rule): string
	local words: { string } = {}
	for _, act in M.rule_actions(rule) do
		table.insert(words, if act.tag then `{act.action} {act.tag}` else act.action)
	end
	return if #words > 0 then table.concat(words, ", ") else "nothing"
end

--- The keys of the messages `rule`'s query finds, newest first, up to
--- `most`; nil and why when its query won't read.
function M.rule_finds(rule: Rule, most: number): ({ string }?, string?)
	local parsed = core.search_box.read(rule.query, { source = M.source })
	if not parsed.ok then
		local problem = parsed.problems[1]
		return nil, `{rule.query}: {if problem then problem.message else "it won't read"}`
	end
	parsed.view.limit = most
	return M.found(parsed)
end

--- Does what `rule` says to the mail with `keys`; says what went wrong.
function M.apply_rule(rule: Rule, keys: { string })
	if #keys == 0 then
		return
	end
	for _, act in M.rule_actions(rule) do
		local _, err = backend.get().act(keys, act.action, act.tag)
		if err then
			greed.echo(`a mail rule ({rule.query}): {err}`)
		end
	end
end

--- Runs the rules over the mail with `keys`, just arrived: each rule's
--- query finds what it does to among them.
function M.run_rules(keys: { string })
	if #M.rules == 0 or #keys == 0 then
		return
	end
	local new: { [string]: boolean } = {}
	for _, key in keys do
		new[key] = true
	end
	for _, rule in M.rules do
		-- New mail is the newest, so it's among the first found.
		local found, err = M.rule_finds(rule, math.max(LIMIT, #keys * 4))
		if found == nil then
			greed.echo(`a mail rule can't run: {err}`)
			continue
		end
		local hit: { string } = {}
		for _, key in found do
			if new[key] then
				table.insert(hit, key)
			end
		end
		M.apply_rule(rule, hit)
	end
end

--- Runs the rules that say `all` over all the mail they find, each doing
--- at most `MANY` on its own; for more it says so, and `:mail-rule-run`
--- does it.
function M.run_standing()
	for _, rule in M.rules do
		if not rule.all then
			continue
		end
		local found, err = M.rule_finds(rule, M.MANY + 1)
		if found == nil then
			greed.echo(`a mail rule can't run: {err}`)
		elseif #found > M.MANY then
			greed.echo(
				`the mail rule {rule.query} finds more than {M.MANY}: :mail-rule-run does it, once you've looked`
			)
		else
			M.apply_rule(rule, found)
		end
	end
end

backend.on_arrived(function(keys: { string })
	if backend.here() then
		M.run_standing()
		M.run_rules(keys)
	end
end)

-- When rules over all mail last ran, as os.time().
local standing_ran = 0

backend.on_synced(function()
	if backend.here() and os.time() - standing_ran >= 3600 then
		standing_ran = os.time()
		M.run_standing()
	end
end)

-- Asks which of the rules, by query and what it does; says so when
-- there are none.
local function pick_rule(title: string, chosen: (rule: Rule) -> ())
	if #M.rules == 0 then
		greed.echo('no mail rules: require("@mail").rules sets them')
		return
	end
	local items: { { label: string, value: any, kind: string? } } = {}
	for i, rule in M.rules do
		local all = if rule.all then ", on all mail" else ""
		table.insert(items, { label = `{i}. {rule.query}  {M.rule_text(rule)}{all}`, value = rule })
	end
	require("@picker").pick(title, items, function(item)
		chosen(item.value)
	end)
end

-- As many as a rule may find when it's run by hand: all, for any mailbox
-- one has.
local ALL = 1000000

greed.command({
	name = "mail-rule-try",
	doc = "Show what a mail rule finds in the mail you have, changing nothing",
	run = function()
		pick_rule("Try a rule", function(rule: Rule)
			local found, err = M.rule_finds(rule, ALL)
			if found == nil then
				greed.echo(err or "it won't read")
				return
			end
			M.go(rule.query)
			greed.echo(
				`{rule.query} finds {#found} now; it would {M.rule_text(rule)}: :mail-rule-run does it`
			)
		end)
	end,
})

greed.command({
	name = "mail-rule-run",
	doc = "Run a mail rule over all the mail it finds, asking first",
	run = function()
		pick_rule("Run a rule", function(rule: Rule)
			local found, err = M.rule_finds(rule, ALL)
			if found == nil then
				greed.echo(err or "it won't read")
				return
			elseif #found == 0 then
				greed.echo(`{rule.query} finds nothing`)
				return
			end
			greed.echo(`{M.rule_text(rule)} {#found} found by {rule.query}? y does it`)
			local yes = greed.next_key() == "y"
			greed.echo("")
			if yes then
				M.apply_rule(rule, found)
				greed.echo(`{M.rule_text(rule)}: {#found}`)
			end
		end)
	end,
})

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
			M.read(row.thread or row.key, row.found)
		end
	end,
})

greed.command({
	name = "mail-sync",
	doc = "Sync your mail now",
	run = function()
		backend.get().sync()
		greed.echo("syncing mail")
	end,
})

greed.command({
	name = "mail-undo",
	doc = "Undo the last change to your mail, or take back the mail just sent while it waits",
	run = function()
		local undone, err = backend.get().undo()
		if undone == "sent" then
			local path = sent_draft
			sent_draft = nil
			if path then
				M.open_draft(path)
			end
			greed.echo("taken back: it wasn't sent")
		elseif undone then
			greed.echo("undone")
		else
			greed.echo(err or "nothing to undo")
		end
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

-- How a draft shows: its subject, who it's to and how old it is.
local function draft_label(kept: Kept): string
	local draft = M.parse_draft(kept.text)
	local subject = if draft.subject ~= "" then draft.subject else "(no subject)"
	local to = if draft.to ~= "" then draft.to else "no one yet"
	return `{subject}  to {to}  {core.time.ago(os.time() - kept.saved)}`
end

greed.command({
	name = "mail-drafts",
	doc = "Pick a draft to go on writing; alt-. on one discards it",
	run = function()
		local items: { { label: string, value: any, kind: string? } } = {}
		for _, d in M.drafts() do
			table.insert(
				items,
				{ label = draft_label(d.kept), value = d.path, kind = "mail-draft" }
			)
		end
		if #items == 0 then
			greed.echo("no drafts: mail being written is kept as one")
			return
		end
		require("@picker").pick("Drafts", items, function(item)
			M.open_draft(item.value)
		end, {
			preview = function(item)
				local kept = read_kept(item.value)
				return if kept then { text = kept.text } else nil
			end,
		})
	end,
})

core.actions.action({
	kind = "mail-draft",
	name = "open",
	doc = "Go on writing it",
	run = function(target)
		M.open_draft(target.value)
	end,
})
core.actions.set_default("mail-draft", "open")

core.actions.action({
	kind = "mail-draft",
	name = "discard",
	doc = "Throw the draft away",
	danger = true,
	run = function(target)
		M.discard_draft(target.value)
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
	name = "mail-from",
	doc = "Pick which of your addresses the mail being written is from, with its signature",
	run = function(ctx: greed.Context)
		if ctx.buffer:kind() ~= "mail-compose" then
			greed.echo("there's no mail being written here")
			return
		end
		M.pick_from(ctx.buffer)
	end,
})

greed.command({
	name = "mail-attach",
	doc = "Attach a file to the mail being written",
	args = { { name = "path", doc = "The file", complete = "file", type = "string" } },
	run = function(ctx: greed.Context)
		M.attach(core.project.resolve(ctx.values.path))
	end,
})

-- The header lines addresses go on, and whether they're yours (From).
local ADDRESSED = { from = true, to = false, cc = false, bcc = false }

--- What could go at the cursor on an address line of mail being written:
--- people you've had mail with, or on From your own addresses; nil
--- anywhere else.
function M.addressed(view: greed.View): { core.CompletionItem }?
	local buffer = view:buffer()
	if buffer:kind() ~= "mail-compose" then
		return nil
	end
	local pos = view:cursor()
	local line = buffer:line_of(pos)
	for i = 0, line - 1 do
		if buffer:line_text(i) == "" then
			return nil
		end
	end
	local before = buffer:slice(buffer:line_start(line), pos)
	local field = string.lower(string.match(before, "^([%a]+):") or "")
	local own = ADDRESSED[field]
	if own == nil then
		return nil
	end
	local typed = string.match(before, "[:,]%s*([^,:]*)$") or ""
	local mail = backend.get()
	local offered: { string } = {}
	if own then
		for _, account in mail.accounts() do
			table.insert(offered, account.address)
			for _, alias in account.aliases do
				table.insert(offered, alias)
			end
		end
	elseif typed ~= "" then
		offered = mail.contacts(typed)
	end
	local items: { core.CompletionItem } = {}
	for _, address in offered do
		if string.find(string.lower(address), string.lower(typed), 1, true) then
			table.insert(items, { label = address, text = address, from = pos - #typed })
		end
	end
	return items
end

-- The completion menu is the lsp plugin's: asked while it's loaded.
local function complete_addresses()
	local completion = require("@lsp").completion
	completion.source(M.addressed, { first = true })
	completion.keys_over("mail-compose")
end

if table.find(greed.plugin.list(), "lsp") then
	complete_addresses()
end

greed.on("plugin.loaded", function(event: greed.PluginLoaded)
	if event.name == "lsp" then
		complete_addresses()
	end
end)

greed.command({
	name = "mail-send",
	doc = "Send the mail being written",
	run = function(ctx: greed.Context)
		local w = writing
		if ctx.buffer:kind() ~= "mail-compose" or w == nil then
			greed.echo("there's no mail being written here")
			return
		end
		local d: { path: string?, replying: string? } = drafts[ctx.buffer:id()] or {}
		local draft = M.parse_draft(ctx.buffer:text())
		draft.replying = d.replying
		draft.markdown = greed.option.get("mail-markdown") == true
		-- Kept until it's gone for sure: taken back, it's written again.
		keep(ctx.buffer)
		local ok, err, seconds = backend.get().send(draft)
		if not ok then
			greed.echo(err or "it couldn't be sent")
			return
		end
		greed.echo(if seconds then `sending in {seconds} s: z takes it back` else "sending")
		drafts[ctx.buffer:id()] = nil
		leave(ctx)
		local path = d.path
		if path then
			sent_draft = path
			greed.spawn(function()
				greed.sleep(((seconds or 0) + 5) * 1000)
				if sent_draft == path then
					sent_draft = nil
				end
				if writing_draft(path) == nil then -- not taken back and written again
					greed.fs.remove(path)
				end
			end)
		end
	end,
})

-- :w in mail being written keeps its draft now; :mail-send sends it.
core.file.on_save("mail-compose", function(buffer: greed.Buffer)
	keep(buffer)
	greed.echo("kept as a draft (:mail-drafts): :mail-send sends it")
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

greed.command({
	name = "mail-open-all",
	doc = "Show all of the thread: every message opened and every quote, or folded again",
	run = function()
		local r = reading
		if r then
			r.shown.all = not r.shown.all
			r.view:redraw()
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
		core.file.open_page(path)
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
	local all = M.attached_in(r.thread)
	return if #all == 1 then all[1] else nil
end

--- Everything attached to the messages of `thread`, in order.
function M.attached_in(thread: Thread): { Attached }
	local all: { Attached } = {}
	for _, message in thread.messages do
		for i, attached in message.attachments do
			table.insert(all, { key = message.key, index = i - 1, name = attached.name })
		end
	end
	return all
end

-- The folder things attached are saved in to start with: the one last
-- saved in, else Downloads.
local saved_in = "~/Downloads"

--- Saves `which` where you say, offering the folder last saved in.
function M.save_attachment(which: Attached)
	local to = core.prompt.ask("Save as", `{saved_in}/{which.name}`)
	if to == nil or to == "" then
		return
	end
	greed.echo(`getting {which.name}`)
	local path, err = backend.get().attachment(which.key, which.index, to)
	if path then
		saved_in = string.match(to, "^(.*)/[^/]*$") or saved_in
	end
	greed.echo(if path then `saved {path}` else err or `{which.name} didn't come`)
end

--- Saves everything attached to `thread` in a folder you say, each by its
--- name; says how many, and what didn't come.
function M.save_all_attached(thread: Thread)
	local all = M.attached_in(thread)
	if #all == 0 then
		greed.echo("nothing's attached here")
		return
	end
	local given = core.prompt.ask(`Save {#all} in`, saved_in)
	if given == nil or given == "" then
		return
	end
	local folder = string.gsub(given, "/+$", "")
	saved_in = folder
	local saved, missed = 0, {}
	for _, which in all do
		greed.echo(`getting {which.name}`)
		local path, err = backend.get().attachment(which.key, which.index, `{folder}/{which.name}`)
		if path then
			saved += 1
		else
			table.insert(missed, `{which.name}: {err or "didn't come"}`)
		end
	end
	greed.echo(
		`saved {saved} of {#all} in {folder}`
			.. (if #missed > 0 then ` ({table.concat(missed, "; ")})` else "")
	)
end

greed.command({
	name = "mail-save-attachment",
	doc = "Save what's attached under the cursor (or the thread's only attachment) where you say",
	run = function(ctx: greed.Context)
		local which = attachment_at(ctx)
		if which == nil then
			greed.echo("put the cursor on what's attached, on its line under the header")
			return
		end
		M.save_attachment(which)
	end,
})

-- Goes `by` saved searches on from the one shown (the first when it's
-- none of them), around.
local function step(by: number)
	local o = open
	if o == nil or #M.searches == 0 then
		return
	end
	local at = 0
	for i, saved in M.searches do
		if saved.query == o.query then
			at = i
		end
	end
	local to = if at == 0 then 1 else (at - 1 + by) % #M.searches + 1
	M.go(M.searches[to].query)
end

for i = 1, 9 do
	greed.command({
		name = `mail-search-{i}`,
		doc = `Show what saved search {i} finds (require("@mail").searches)`,
		run = function()
			local saved = M.searches[i]
			if saved then
				M.go(saved.query)
			end
		end,
	})
end

greed.command({
	name = "mail-searches",
	doc = "Pick a saved search to show, however many there are, with how many unread each finds",
	run = function()
		local o = open
		local items: { { label: string, value: any, kind: string? } } = {}
		for _, saved in M.searches do
			local unread = if o then o.unread[saved.query] else nil
			local count = if unread and unread > 0 then `  {unread} unread` else ""
			table.insert(
				items,
				{ label = `{saved.name}  {saved.query}{count}`, value = saved.query }
			)
		end
		if #items == 0 then
			greed.echo('no saved searches: require("@mail").searches sets them')
			return
		end
		require("@picker").pick("Saved searches", items, function(item)
			M.go(item.value)
		end)
	end,
})

greed.command({
	name = "mail-search-next",
	doc = "Show what the next saved search finds",
	run = function()
		step(1)
	end,
})

greed.command({
	name = "mail-search-previous",
	doc = "Show what the saved search before finds",
	run = function()
		step(-1)
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
	T = "mail-todo",
	z = "mail-undo",
	b = "mail-browser",
	q = "mail-close",
	esc = "mail-close",
}

-- Mail is written by whoever sent it, so an agent reading it is told so;
-- mail being written quotes what it answers.
core.outside.kind("mail", "the list of mail you received")
core.outside.kind("mail-thread", "mail you received")
core.outside.kind("mail-compose", "mail being written, quoting mail you received")
-- Mail sent is out of your hands, so an agent sending it asks you.
core.risk.editor_command("mail-send", "sends the mail being written")

greed.keymap.bind({ kind = "mail" }, ACTIONS)
-- The saved searches show as tabs over the list, so they go as tabs do:
-- tab and shift-tab through them, alt and a number to one, as in a
-- browser (a plain number is a count).
for i = 1, 9 do
	greed.keymap.bind({ kind = "mail" }, { [`alt-{i}`] = `mail-search-{i}` })
end
greed.keymap.bind({ kind = "mail" }, {
	enter = "mail-read",
	["/"] = "mail-search",
	["$"] = "mail-sync",
	["g s"] = "mail-searches",
	tab = "mail-search-next",
	["shift-tab"] = "mail-search-previous",
	["]"] = "mail-search-next",
	["["] = "mail-search-previous",
})
greed.keymap.bind({ kind = "mail-thread" }, ACTIONS)
-- In every mode, as Hoard's box has it.
greed.keymap.bind({ kind = "mail-compose" }, {
	["alt-enter"] = "mail-send",
	["ctrl-enter"] = "mail-send",
})
greed.keymap.bind(
	{ kind = "mail-thread" },
	{ h = "mail-plain", o = "mail-open-all", S = "mail-save-attachment" }
)

-- What `space .` finds: the row under the cursor in a list, the thread
-- being read, or the draft being written. Each acts as its keys do.
core.actions.finder({
	name = "mail",
	find = function(view: greed.View, range: greed.Range): { core.Target }?
		local buffer = view:buffer()
		local kind = buffer:kind()
		local o, r = open, reading
		if kind == "mail" and o and o.buffer == buffer then
			local row: Summary? = o.view:value_at(range.head)
			if row then
				return { { kind = "mail", label = row.subject, value = row.key, buffer = buffer } }
			end
		elseif kind == "mail-thread" and r and r.buffer == buffer then
			local found: { core.Target } = {}
			-- What's attached under the cursor comes before its thread.
			local value = r.view:value_at(range.head)
			if type(value) == "table" and value.attached then
				local which: Attached = value.attached
				table.insert(
					found,
					{ kind = "mail-attachment", label = which.name, value = which, buffer = buffer }
				)
			end
			table.insert(
				found,
				{ kind = "mail", label = r.thread.subject, value = r.thread.key, buffer = buffer }
			)
			return found
		elseif kind == "mail-compose" then
			local d = drafts[buffer:id()]
			if d and d.path then
				local subject = M.parse_draft(buffer:text()).subject
				return {
					{
						kind = "mail-draft",
						label = if subject ~= "" then subject else "(no subject)",
						value = d.path,
						buffer = buffer,
					},
				}
			end
		end
		return nil
	end,
})

-- The actions on mail, each running its command on what's under the
-- cursor, as its key does; `in_list` ones only from a list.
local MAIL_ACTIONS: { { name: string, command: string, doc: string, in_list: boolean? } } = {
	{ name = "read", command = "mail-read", doc = "Read the thread", in_list = true },
	{ name = "reply", command = "mail-reply", doc = "Reply to who sent it" },
	{ name = "reply-all", command = "mail-reply-all", doc = "Reply to everyone it went to" },
	{ name = "archive", command = "mail-archive", doc = "Move it to the archive" },
	{ name = "trash", command = "mail-trash", doc = "Move it to the trash" },
	{ name = "toggle-read", command = "mail-toggle-read", doc = "Mark it read, or unread" },
	{ name = "toggle-flag", command = "mail-toggle-flag", doc = "Flag it, or take the flag off" },
	{ name = "tag", command = "mail-tag", doc = "Put a tag on it, or take one off" },
	{ name = "todo", command = "mail-todo", doc = "Make a todo of it" },
	{ name = "browser", command = "mail-browser", doc = "Open it in a web browser" },
}

for _, a in MAIL_ACTIONS do
	core.actions.action({
		kind = "mail",
		name = a.name,
		doc = a.doc,
		offers = function(target: core.Target): boolean
			return not a.in_list or (target.buffer ~= nil and target.buffer:kind() == "mail")
		end,
		run = function()
			greed.run(a.command)
		end,
	})
end
core.actions.set_default("mail", "read")

core.actions.action({
	kind = "mail-attachment",
	name = "open",
	doc = "Open it as its kind of file opens: in Greed, or with the program that opens it",
	run = function(target: core.Target)
		M.open_attachment(target.value)
	end,
})
core.actions.set_default("mail-attachment", "open")

core.actions.action({
	kind = "mail-attachment",
	name = "open-outside",
	doc = "Open it with the program your system opens it with (never a program itself)",
	run = function(target: core.Target)
		local path = M.kept_attachment(target.value)
		if path then
			core.file.open_outside(path)
		end
	end,
})

core.actions.action({
	kind = "mail-attachment",
	name = "save",
	doc = "Save it where you say",
	run = function(target: core.Target)
		M.save_attachment(target.value)
	end,
})

core.actions.action({
	kind = "mail-attachment",
	name = "save-all",
	doc = "Save everything attached to the thread in a folder you say",
	run = function()
		local r = reading
		if r then
			M.save_all_attached(r.thread)
		end
	end,
})

core.actions.action({
	kind = "mail-attachment",
	name = "copy-path",
	doc = "Copy the path of the copy kept beside your mail",
	run = function(target: core.Target)
		local path = M.kept_attachment(target.value)
		if path then
			greed.clipboard.set(path)
			greed.echo(`copied {path}`)
		end
	end,
})

core.actions.action({
	kind = "mail-draft",
	name = "send",
	doc = "Send it",
	danger = true,
	offers = function(target: core.Target): boolean
		return target.buffer ~= nil
	end,
	run = function()
		greed.run("mail-send")
	end,
})

core.actions.action({
	kind = "mail-draft",
	name = "from",
	doc = "Pick which of your addresses it's from, with its signature",
	offers = function(target: core.Target): boolean
		return target.buffer ~= nil
	end,
	run = function(target: core.Target)
		M.pick_from(target.buffer :: greed.Buffer)
	end,
})

return M
