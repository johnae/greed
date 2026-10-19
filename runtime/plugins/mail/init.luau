-- Mail: your mail searched and read in Greed. `:mail` opens what a search
-- finds, newest first, with the search box over it (in:inbox to start);
-- `enter` reads a thread, `/` searches again, `r` syncs now, `q` closes.
-- greed-mail syncs the accounts in mail.toml and keeps the index this
-- searches (backend.luau); a search is the query language anywhere in
-- Greed: from:anna is:unread date:2w.. in:work invoice.

local greed = require("@greed")
local core = require("@core")
local backend = require("@self/backend")

local ui = core.ui

type Summary = backend.Summary
type Thread = backend.Thread

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

-- The list, while it's open.
type Open = {
	float: greed.View,
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
local reading: { float: greed.View, key: string }? = nil

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
	o.float:focus()
	local buffer = o.float:buffer()
	if o.view:value_at(o.float:cursor()) == nil and buffer:line_count() > 2 then
		o.float:set_cursor(buffer:line_start(2))
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

--- Opens the list of what `query` (in:inbox to start) finds, and the
--- search box over it.
function M.open(query: string?)
	if open and open.float:valid() then
		open.float:close()
	end
	local buffer = greed.create_buffer("mail", "", { readonly = true })
	buffer:set_line_numbers(false)
	local float = greed.float(buffer, { title = "Mail", width = "90%", height = "80%" })
	local o: Open = {
		float = float,
		query = query or M.START,
		rows = {},
		found = {},
		view = nil :: any,
	}
	open = o
	o.view = ui.mount(buffer, function()
		return render(o)
	end, {}, {
		key = function(row: Summary): string
			return row.key
		end,
	})
	refresh(o)
	M.ask()
end

-- A message's text as it's read: who, when, to whom, then what it says.
local function message_text(message: backend.Message): string
	local day, time = string.match(message.date or "", "^(%d+%-%d+%-%d+)T(%d+:%d+)")
	local date = if day then `{day} {time}` else (message.date or "")
	local lines = { `From: {message.from}`, `Date: {date}`, `To: {message.to}` }
	if message.cc ~= "" then
		table.insert(lines, `Cc: {message.cc}`)
	end
	for _, attached in message.attachments do
		table.insert(lines, `Attached: {attached.name} ({attached.mime})`)
	end
	table.insert(lines, "")
	if message.text == nil then
		table.insert(lines, "(its text is on its way)")
	else
		table.insert(lines, (string.gsub(message.text, "\r\n", "\n")))
		if not message.complete then
			table.insert(lines, "(it goes on: only the start of a big message is in)")
		end
	end
	return table.concat(lines, "\n")
end

--- The thread as it reads: its subject, then each message.
function M.thread_text(thread: Thread): string
	local rule = string.rep("═", math.max(3, core.text.width(thread.subject)))
	local parts = { `{thread.subject}\n{rule}` }
	for i, message in thread.messages do
		if i > 1 then
			table.insert(parts, string.rep("─", 40))
		end
		table.insert(parts, message_text(message))
	end
	return table.concat(parts, "\n\n") .. "\n"
end

--- Reads the thread `key` (a message's or a thread's) in a float.
function M.read(key: string)
	local thread, err = backend.get().thread(key)
	if thread == nil then
		greed.echo(err or "that mail is gone")
		return
	end
	if reading and reading.float:valid() then
		reading.float:close()
	end
	local buffer = greed.create_buffer("mail-thread", M.thread_text(thread), { readonly = true })
	buffer:set_line_numbers(false)
	local float = greed.float(buffer, { title = thread.subject, width = "90%", height = "90%" })
	reading = { float = float, key = thread.key }
end

backend.on_changed(function()
	local o = open
	if o and o.float:valid() then
		refresh(o)
	end
	local r = reading
	if r and r.float:valid() then
		local thread = backend.get().thread(r.key)
		if thread then
			local buffer = r.float:buffer()
			buffer:edit(function(e)
				e:replace(0, buffer:len(), M.thread_text(thread))
			end)
		end
	end
end)

greed.command({
	name = "mail",
	doc = "Search and read your mail",
	run = function()
		M.open()
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
		greed.echo("syncing mail")
	end,
})

greed.command({
	name = "mail-close",
	doc = "Close the mail list, or the thread being read",
	run = function(ctx: greed.Context)
		if ctx.buffer:kind() == "mail-thread" and reading then
			reading.float:close()
			reading = nil
			local o = open
			if o and o.float:valid() then
				o.float:focus()
			end
		elseif open then
			open.float:close()
			open = nil
		end
	end,
})

greed.keymap.bind({ kind = "mail" }, {
	enter = "mail-read",
	["/"] = "mail-search",
	r = "mail-sync",
	q = "mail-close",
	esc = "mail-close",
})
greed.keymap.bind({ kind = "mail-thread" }, {
	q = "mail-close",
	esc = "mail-close",
})

return M
