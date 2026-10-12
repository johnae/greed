-- The list of the repository's agent sessions, running and kept from
-- before, in a floating view, the newest first and this workspace's
-- before the others':
--
--   Agent sessions
--   enter shows · r resume · m mark · p t w s pane, tab, float, panel · ...
--
--   Claude    Fix the off-by-one in the pager  ⠋ working  just now   14.2k tokens
--   Greed     Add a test for the pager         idle       4 min ago  3.1k tokens
--   Claude 2  Look at the parser               saved      2 h ago                 in greed-b
--
-- Drawn with `core.ui`, again as sessions change, the cursor staying on its
-- session as the rows change places; the commands acting on it are in
-- init.luau.

local greed = require("@greed")
local core = require("@core")
local session = require("./session")
local saved = require("./saved")
local transcript = require("./transcript")
local terminal = require("@terminal")

type Session = session.Session

local ui = core.ui

local M = {}

--- A line of the list: a session running or that ran (`session`), one
--- kept from before (`saved`), or an agent running in a terminal
--- (`terminal`), as its hooks say.
export type Row = {
	--- Tells it apart while the list is redrawn, for marks.
	key: string,
	session: Session?,
	saved: saved.Saved?,
	terminal: terminal.Term?,
	agent: string,
	title: string,
	--- A session's status, "failed" after a turn that failed, or "saved".
	status: string,
	--- Why it failed or exited, when it says.
	reason: string?,
	--- When it last did something, in seconds since 1970.
	time: number,
	tokens: number?,
	--- The folder it works in: this project, or another workspace of the
	--- repository.
	root: string,
	--- The name of its agent's workspace of its own, if it has one.
	workspace: string?,
}

local HINTS = "enter shows · r resume · h resume here · m mark · p t w s pane, tab, float, panel · "
	.. "n new · f fork · d diff · b bring in · R review · ctrl-c stop · x close · / filter · q quit"

local STATUS: { [string]: string } = {
	starting = "starting",
	idle = "idle",
	working = "● working",
	waiting = "waiting for you",
	exited = "exited",
	failed = "failed",
	saved = "saved",
}

local STATUS_STYLE: { [string]: string } = {
	working = "diff.plus",
	waiting = "diagnostic.warning",
	exited = "comment",
	failed = "diagnostic.error",
	saved = "comment",
}

-- The most of what you asked first that a line shows, in characters.
local TITLE_WIDTH = 40

-- The most of why a session failed that a line shows, in characters.
local REASON_WIDTH = 50

type Open = {
	view: core.UiView,
	float: greed.View,
	--- The project it lists the repository's sessions for.
	root: string,
	marked: { [string]: boolean },
	filter: string,
	ticking: boolean,
}

local open: Open? = nil
local source: (root: string) -> { Row } = function()
	return {}
end

--- Sets what the list shows: its rows as they are now.
function M.source(rows: (root: string) -> { Row })
	source = rows
end

local function where(row: Row, root: string): string
	local parts = {}
	if row.root ~= root then
		table.insert(parts, `in {core.project.basename(row.root) or row.root}`)
	end
	if row.workspace then
		table.insert(parts, `workspace {row.workspace}`)
	end
	return table.concat(parts, ", ")
end

local function matches(cells: { string }, filter: string): boolean
	if filter == "" then
		return true
	end
	local text = string.lower(table.concat(cells, " "))
	return string.find(text, string.lower(filter), 1, true) ~= nil
end

-- The list as widgets: its heading, the keys, and a line for each session
-- the filter lets through, the row as its value.
local function render(o: Open): core.UiNode
	local heading: { core.UiSpan } = { ui.span("Agent sessions", "markup.heading") }
	if o.filter ~= "" then
		table.insert(heading, ui.span(`   / {o.filter}`))
	end
	local now = os.time()
	local lines: { core.UiGridRow } = {}
	for _, row in source(o.root) do
		local status = (STATUS[row.status] or row.status)
			.. if row.reason then `: {core.text.clip(row.reason, REASON_WIDTH)}` else ""
		local cells = {
			row.agent,
			core.text.clip(row.title, TITLE_WIDTH),
			status,
			core.time.ago(now - row.time),
			if row.tokens then `{transcript.tokens(row.tokens)} tokens` else "",
			where(row, o.root),
		}
		if matches(cells, o.filter) then
			local marked = o.marked[row.key]
			table.insert(lines, {
				value = row,
				line = if marked then "ui.selection" else nil,
				cells = {
					{ ui.span(if marked then "* " else "  "), ui.span(cells[1], "keyword") },
					{ ui.span(cells[2]) },
					{
						{
							text = cells[3],
							style = STATUS_STYLE[row.status],
							tag = if row.status == "working" then "spin" else nil,
						},
					},
					{ ui.span(cells[4], "comment") },
					{ ui.span(cells[5], "comment") },
					{ ui.span(cells[6], "comment") },
				},
			})
		end
	end
	local body: core.UiNode = if #lines > 0
		then ui.grid(lines)
		else ui.line({
			ui.span(
				if o.filter ~= ""
					then "Nothing matches the filter."
					else "No sessions yet: n starts one."
			),
		})
	return ui.column({ ui.line(heading), ui.line({ ui.span(HINTS, "comment") }), ui.gap(), body })
end

-- Spins the working rows' marks while there are any and effects are on.
local function tick(o: Open)
	if o.ticking then
		return
	end
	o.ticking = true
	greed.spawn(function()
		while open == o and #o.view:spots("spin") > 0 and core.effects.enabled() do
			local frame = transcript.spinner_frame(greed.now())
			local marks: { greed.Mark } = {}
			for _, spot in o.view:spots("spin") do
				table.insert(marks, {
					from = spot.from,
					to = spot.from + #"●",
					style = "diff.plus",
					text = frame,
					overlay = true,
				})
			end
			pcall(function()
				o.view.buffer:decorate("agents-spin", marks)
			end)
			greed.sleep(transcript.FRAME_MS)
		end
		o.ticking = false
		if open == o then
			pcall(function()
				o.view.buffer:decorate("agents-spin", {})
			end)
		end
	end)
end

--- Redraws the list, if it's open.
function M.render()
	local o = open
	if o == nil then
		return
	end
	if not o.view.buffer:valid() then
		open = nil
		return
	end
	o.view:redraw()
	tick(o)
end

--- Whether `buffer` is the list.
function M.is(buffer: greed.Buffer): boolean
	return open ~= nil and open.view.buffer == buffer
end

--- The folder the open list is for, if it's open.
function M.root(): string?
	return if open then open.root else nil
end

--- Closes the list.
function M.close()
	local o = open
	open = nil
	if o and o.float:valid() then
		o.float:close()
	end
end

-- Puts the cursor on the list's first session.
local function to_first(o: Open)
	local buffer = o.view.buffer
	o.float:set_cursor(buffer:line_start(math.min(3, buffer:line_count() - 1)))
end

--- Opens the list in a floating view, in place of one open already, and
--- puts the cursor on its first session.
function M.open(root: string)
	M.close()
	local buffer = greed.create_buffer("agents", "", { readonly = true })
	buffer:set_line_numbers(false)
	local float = greed.float(buffer, { title = "Agent sessions", width = "90%", height = "60%" })
	local o: Open = {
		float = float,
		root = root,
		marked = {},
		filter = "",
		ticking = false,
		view = nil :: any,
	}
	open = o
	o.view = ui.mount(buffer, function()
		return render(o)
	end, {}, {
		key = function(row: Row): string
			return row.key
		end,
	})
	to_first(o)
	tick(o)
end

--- The row under the cursor in the list.
function M.at_cursor(ctx: greed.Context): Row?
	local o = open
	if o == nil or o.view.buffer ~= ctx.buffer then
		return nil
	end
	return o.view:value_at(ctx.view:cursor())
end

--- The marked rows, in the order shown, or the one under the cursor.
function M.chosen(ctx: greed.Context): { Row }
	local o = open
	if o == nil or o.view.buffer ~= ctx.buffer then
		return {}
	end
	local out: { Row } = {}
	for _, row in o.view:values() do
		if o.marked[row.key] then
			table.insert(out, row)
		end
	end
	local here = M.at_cursor(ctx)
	if #out == 0 and here then
		table.insert(out, here)
	end
	return out
end

--- Marks the row under the cursor, or unmarks it, and moves to the next.
function M.mark(ctx: greed.Context)
	local o = open
	local row = M.at_cursor(ctx)
	if o == nil or row == nil then
		return
	end
	o.marked[row.key] = not o.marked[row.key]
	M.render()
	local next = ctx.buffer:line_of(ctx.view:cursor()) + 1
	if next < ctx.buffer:line_count() and o.view:value_at(ctx.buffer:line_start(next)) then
		ctx.view:set_cursor(ctx.buffer:line_start(next))
	end
end

--- Asks for text to narrow the list to the sessions that have it, as it's
--- typed; esc puts back the filter there was.
function M.filter()
	local o = open
	if o == nil then
		return
	end
	local before = o.filter
	local function set(text: string)
		o.filter = text
		M.render()
		to_first(o)
	end
	core.prompt.open({
		title = "Filter sessions",
		text = before,
		on_change = set,
		on_submit = set,
		on_cancel = function()
			set(before)
		end,
	})
end

greed.on("buffer.closed", function(event: greed.BufferClosed)
	if open and open.view.buffer:id() == event.id then
		open = nil
	end
end)

return M
