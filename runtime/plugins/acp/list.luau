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
-- It's redrawn as sessions change; the commands acting on it are in
-- init.luau.

local greed = require("@greed")
local core = require("@core")
local session = require("./session")
local saved = require("./saved")
local transcript = require("./transcript")

type Session = session.Session

local M = {}

--- A line of the list: a session running or that ran (`session`), or one
--- kept from before (`saved`).
export type Row = {
	--- Tells it apart while the list is redrawn, for marks.
	key: string,
	session: Session?,
	saved: saved.Saved?,
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

-- Where a working row's mark is, to spin it.
type Spot = { from: number, to: number }

type Open = {
	buffer: greed.Buffer,
	view: greed.View,
	--- The project it lists the repository's sessions for.
	root: string,
	--- The row on each 0-based line.
	rows: { [number]: Row },
	marked: { [string]: boolean },
	filter: string,
	--- Where the working rows' marks are.
	spinning: { Spot },
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

-- The list's lines, their decorations, the row on each line and where the
-- working rows' marks are.
local function draw(
	o: Open,
	all: { Row }
): ({ string }, { greed.Mark }, { [number]: Row }, { Spot })
	local root = o.root
	local heading = "Agent sessions"
	if o.filter ~= "" then
		heading ..= `   / {o.filter}`
	end
	local lines = { heading, HINTS, "" }
	local marks: { greed.Mark } = {
		{ from = 0, to = #"Agent sessions", style = "markup.heading" },
		{ from = #heading + 1, to = #heading + 1 + #HINTS, style = "comment" },
	}
	local now = os.time()
	local shown: { { row: Row, cells: { string } } } = {}
	local widths = { 0, 0, 0, 0, 0 }
	for _, row in all do
		local cells = {
			row.agent,
			core.text.clip(row.title, TITLE_WIDTH),
			(STATUS[row.status] or row.status)
				.. if row.reason then `: {core.text.clip(row.reason, REASON_WIDTH)}` else "",
			core.time.ago(now - row.time),
			if row.tokens then `{transcript.tokens(row.tokens)} tokens` else "",
			where(row, root),
		}
		if matches(cells, o.filter) then
			table.insert(shown, { row = row, cells = cells })
			for i = 1, #widths do
				widths[i] = math.max(widths[i], core.text.width(cells[i]))
			end
		end
	end
	if #shown == 0 then
		table.insert(
			lines,
			if o.filter ~= ""
				then "Nothing matches the filter."
				else "No sessions yet: n starts one."
		)
	end
	local rows: { [number]: Row } = {}
	local spinning: { Spot } = {}
	local at = #heading + #HINTS + 3
	for _, item in shown do
		local row, cells = item.row, item.cells
		local line = if o.marked[row.key] then "* " else "  "
		-- Adds cell `i` to the line and returns where it starts.
		local function cell(i: number, style: string?): number
			local from = at + #line
			line ..= cells[i]
			if style and cells[i] ~= "" then
				table.insert(marks, { from = from, to = from + #cells[i], style = style })
			end
			if i < #cells then
				line ..= string.rep(" ", widths[i] - core.text.width(cells[i]) + 2)
			end
			return from
		end
		cell(1, "keyword")
		cell(2)
		local status = cell(3, STATUS_STYLE[row.status])
		if row.status == "working" then
			table.insert(spinning, { from = status, to = status + #"●" })
		end
		cell(4, "comment")
		cell(5, "comment")
		cell(6, "comment")
		line = string.match(line, "^(.-)%s*$") or line
		if o.marked[row.key] then
			table.insert(marks, { from = at, to = at + #line, style = "ui.selection", line = true })
		end
		rows[#lines] = row
		table.insert(lines, line)
		at += #line + 1
	end
	return lines, marks, rows, spinning
end

-- Spins the working rows' marks while there are any and effects are on.
local function tick(o: Open)
	if o.ticking then
		return
	end
	o.ticking = true
	greed.spawn(function()
		while open == o and #o.spinning > 0 and core.effects.enabled() do
			local frame = transcript.spinner_frame(greed.now())
			local marks: { greed.Mark } = {}
			for _, spot in o.spinning do
				table.insert(marks, {
					from = spot.from,
					to = spot.to,
					style = "diff.plus",
					text = frame,
					overlay = true,
				})
			end
			pcall(function()
				o.buffer:decorate("agents-spin", marks)
			end)
			greed.sleep(transcript.FRAME_MS)
		end
		o.ticking = false
		if open == o then
			pcall(function()
				o.buffer:decorate("agents-spin", {})
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
	if not o.buffer:valid() then
		open = nil
		return
	end
	local lines, marks, rows, spinning = draw(o, source(o.root))
	local buffer = o.buffer
	local line = buffer:line_of(o.view:cursor())
	-- The cursor stays on its session as the rows change places.
	local here = o.rows[line]
	for at, row in rows do
		if here and row.key == here.key then
			line = at
		end
	end
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:set_readonly(true)
	buffer:decorate("agents", marks)
	o.rows = rows
	o.spinning = spinning
	o.view:set_cursor(buffer:line_start(math.min(line, buffer:line_count() - 1)))
	tick(o)
end

--- Whether `buffer` is the list.
function M.is(buffer: greed.Buffer): boolean
	return open ~= nil and open.buffer == buffer
end

--- The folder the open list is for, if it's open.
function M.root(): string?
	return if open then open.root else nil
end

--- Closes the list.
function M.close()
	local o = open
	open = nil
	if o and o.view:valid() then
		o.view:close()
	end
end

local function to_first(o: Open)
	o.view:set_cursor(o.buffer:line_start(math.min(3, o.buffer:line_count() - 1)))
end

--- Opens the list in a floating view, in place of one open already, and
--- puts the cursor on its first session.
function M.open(root: string)
	M.close()
	local buffer = greed.create_buffer("agents", "", { readonly = true })
	buffer:set_line_numbers(false)
	local view = greed.float(buffer, { title = "Agent sessions", width = "90%", height = "60%" })
	local o: Open = {
		buffer = buffer,
		view = view,
		root = root,
		rows = {},
		marked = {},
		filter = "",
		spinning = {},
		ticking = false,
	}
	open = o
	M.render()
	to_first(o)
end

--- The row under the cursor in the list.
function M.at_cursor(ctx: greed.Context): Row?
	local o = open
	if o == nil or o.buffer ~= ctx.buffer then
		return nil
	end
	return o.rows[ctx.buffer:line_of(ctx.view:cursor())]
end

--- The marked rows, in the order shown, or the one under the cursor.
function M.chosen(ctx: greed.Context): { Row }
	local o = open
	if o == nil or o.buffer ~= ctx.buffer then
		return {}
	end
	local out: { Row } = {}
	for line = 0, ctx.buffer:line_count() - 1 do
		local row = o.rows[line]
		if row and o.marked[row.key] then
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
	if o.rows[next] then
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
	if open and open.buffer:id() == event.id then
		open = nil
	end
end)

return M
