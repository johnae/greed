-- A session's transcript: a buffer of what you and the agent said and what
-- it did, with a box at the bottom to write the next message in. The
-- history above the box is redrawn as the agent goes, so edits there don't
-- last; text in the box is yours.
--
--   Claude in ~/src/greed (workspace greed-claude-1)
--
--   ▍ You
--   ▍ Fix the off-by-one in the pager
--
--   ▍ Claude
--   ▍ Found it in pager.rs.
--   ▍ ✓ Edit pager.rs · +1 -1
--   ▍ ✗ Run cargo test · 12 lines ▸
--   ▍ ? Allow Run cargo test?
--
--   ╭─ Claude · Plan · Sonnet ────── alt-enter sends · ctrl-c stops ─╮
--   │ Allow Run cargo test?  [y] Allow once  [n] Reject              │
--   │ now add a test                                                 │
--   ╰─  waiting for you  enter answers · tab moves · esc hides · 12s ─╯
--
-- The box's top line is in the buffer and marks where the history ends,
-- with the row of choices for a question under it (question.luau); its
-- sides and bottom, the bars beside messages and the status in the
-- bottom line are decorations, so copying text leaves them out. The status
-- and running tools animate (with the effects option on) only while the
-- agent works or waits for you.

local greed = require("@greed")
local core = require("@core")
local markdown = require("@markdown")
local session = require("./session")
local question = require("./question")
local code = require("./code")

type Session = session.Session

local M = {}

-- What the transcript draws above the box, and emptying the box once it's
-- sent, are kept out of undo, so undo in the box takes back only typing.
local OUT_OF_UNDO: { undo: boolean? } = { undo = false }

local HINTS = "alt-enter sends · ctrl-c stops"

-- The box's width when no view shows the transcript yet.
local DEFAULT_WIDTH = 60

-- What a running tool's mark turns through, with effects on.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- How often the status redraws while the agent works: each frame of an
-- animation, or each second for the time alone.
local FRAME_MS = 80
local SECOND_MS = 1000

--- The spinner's frame at `now`, on greed.now()'s clock; a frame shows
--- for `FRAME_MS`.
function M.spinner_frame(now: number): string
	return SPINNER[(now // FRAME_MS) % #SPINNER + 1]
end
M.FRAME_MS = FRAME_MS
local spinner_frame = M.spinner_frame

type Style = {
	from: number,
	to: number,
	style: string,
	text: string?,
	overlay: boolean?,
	line: boolean?,
}

-- Each tool status's mark in its row, and the mark's style.
local GLYPH: { [string]: string } = {
	completed = "✓",
	failed = "✗",
	in_progress = "◐",
	pending = "○",
}
local GLYPH_STYLE: { [string]: string } = {
	completed = "agent.done",
	failed = "agent.failed",
	in_progress = "agent.working",
	pending = "agent.hint",
}

local width = core.text.width

--- What the transcript's history looks like and where things are in it.
export type History = {
	text: string,
	styles: { Style },
	--- The tool call on each line, by 0-based line number.
	tools: { [number]: string },
	--- Where each running tool's mark is, to animate it.
	running: { { from: number, to: number } },
	--- The lines that aren't what you or the agent said, by 0-based line
	--- number: headings, tools and their output, plans, questions. They
	--- show as they are; only what was said shows as Markdown.
	plain: { [number]: boolean },
}

--- The history's text and decorations, for `s` as it is now.
function M.history(s: Session): History
	local lines: { string } = {}
	local styles: { Style } = {}
	local running: { { from: number, to: number } } = {}
	local at = 0
	-- Who said the lines being added, for the bar beside them.
	local speaker: ("user" | "agent")? = nil
	local function add(line: string, style: string?, from: number?, to: number?)
		if style then
			table.insert(
				styles,
				{ from = at + (from or 0), to = at + (to or #line), style = style }
			)
		end
		if speaker then
			-- Over the first of the two spaces every line of theirs starts with.
			local bar = if speaker == "user" then "agent.you.bar" else "agent.bar"
			table.insert(
				styles,
				{ from = at, to = at + 1, style = bar, text = "▍", overlay = true }
			)
			if speaker == "user" then
				table.insert(
					styles,
					{ from = at, to = at + #line, style = "agent.you", line = true }
				)
			end
		end
		table.insert(lines, line)
		at += #line + 1
	end
	local function gap()
		speaker = nil
		add("")
	end
	-- The lines of what was said, by 0-based line number.
	local said: { [number]: boolean } = {}
	local function body(text: string, style: string?)
		for _, line in string.split(text, "\n") do
			said[#lines] = true
			add("  " .. line, style)
		end
	end
	local title = `{s.name} in {core.project.tilde(s.root)}`
	if s.workspace then
		title ..= ` (workspace {s.workspace.name})`
	end
	add(title, "markup.heading")
	-- A heading each time the speaker changes; the agent's text, tools and
	-- plans run on under one.
	local function heading(who: "user" | "agent")
		if speaker ~= who then
			gap()
			speaker = who
			add(`  {if who == "user" then "You" else s.name}`, "markup.heading")
		end
	end
	local tools: { [number]: string } = {}
	for _, entry in s.entries do
		local e = entry :: any
		if e.kind == "user" or e.kind == "agent" then
			heading(e.kind)
			body(string.match(e.text, "^(.-)%s*$") or e.text)
		elseif e.kind == "note" then
			gap()
			add(`  {e.text}`, "comment")
		else
			heading("agent")
			if e.kind == "thought" then
				local first = string.match(e.text, "^%s*([^\n]*)") or ""
				add(`  … {first}`, "comment")
			elseif e.kind == "tool" then
				local tool = e.tool
				local status = tool.status or "pending"
				local glyph = GLYPH[status] or GLYPH.pending
				-- A title of several lines, like a script it runs, shows them
				-- all under its first.
				local title_lines = string.split(tool.title, "\n")
				local line = `  {glyph} {title_lines[1]}`
				local named = #line
				local summary = table.concat(tool.detail, " · ")
				if summary ~= "" then
					line ..= ` · {summary}`
				end
				if #tool.output > 1 then
					line ..= if tool.open then " ▾" else " ▸"
				end
				if status == "in_progress" then
					table.insert(running, { from = at + 2, to = at + 2 + #glyph })
				end
				table.insert(styles, {
					from = at + 2,
					to = at + 2 + #glyph,
					style = GLYPH_STYLE[status] or "agent.hint",
				})
				local first = #lines
				add(line, "agent.hint", named)
				for i = 2, #title_lines do
					add(`    {title_lines[i]}`)
				end
				if tool.open then
					for _, output in tool.output do
						-- An edit's change shows as a diff: gone lines and new ones.
						local mark = if tool.kind == "edit" then string.sub(output, 1, 2) else ""
						local style = if mark == "- "
							then "diff.minus"
							elseif mark == "+ " then "diff.plus"
							else "comment"
						add(`    {output}`, style)
					end
				end
				for i = first, #lines - 1 do
					tools[i] = tool.id
				end
			elseif e.kind == "plan" then
				for _, item in e.items do
					local mark = if item.status == "completed"
						then "✓"
						elseif item.status == "in_progress" then "›"
						else "·"
					add(`  {mark} {item.text}`, "comment")
				end
			elseif e.kind == "permission" then
				-- The tool's row above shows the whole of a long title.
				local asked = session.first_line(e.permission.title)
				if e.chosen then
					add(`  ? {asked}: {e.chosen}`, "comment")
				else
					add(`  ? Allow {asked}?`, "agent.working")
				end
			end
		end
	end
	gap()
	local plain: { [number]: boolean } = {}
	for line = 0, #lines - 1 do
		if not said[line] then
			plain[line] = true
		end
	end
	return {
		text = table.concat(lines, "\n") .. "\n",
		styles = styles,
		tools = tools,
		running = running,
		plain = plain,
	}
end

-- The name of the mode or model `id` among `list`.
local function name_in(list: { session.Mode }, id: string?): string?
	for _, item in list do
		if item.id == id then
			return item.name
		end
	end
	return nil
end

--- The box's top line for `s`, `cells` wide, and its decorations from
--- where it starts: the agent, its mode and model on the left, and the
--- keys to send and stop on the right, as far as they fit.
function M.top(s: Session, cells: number): (string, { Style })
	local named = s.name
	local mode, model = name_in(s.modes, s.mode), name_in(s.models, s.model)
	if mode then
		named ..= ` · {mode}`
	end
	if model then
		named ..= ` · {model}`
	end
	local hints = HINTS
	-- The rule between them: "╭─ " and " " around the name, " " and " ─╮"
	-- around the hints, or "─╮" without them.
	local function room(): number
		return cells - width(named) - width(hints) - (if hints == "" then 6 else 8)
	end
	if room() < 1 then
		hints = ""
	end
	if room() < 1 then
		named = s.name
	end
	local line = `╭─ {named} ` .. string.rep("─", math.max(room(), 1))
	local styles: { Style } = {
		{ from = 0, to = #line, style = "agent.box" },
		{ from = #"╭─ ", to = #"╭─ " + #named, style = "agent.box.title" },
	}
	if hints ~= "" then
		local start = #line + 1
		line ..= ` {hints} ─╮`
		table.insert(styles, { from = start, to = start + #hints, style = "agent.hint" })
		table.insert(styles, { from = start + #hints, to = #line, style = "agent.box" })
	else
		local start = #line
		line ..= "─╮"
		table.insert(styles, { from = start, to = #line, style = "agent.box" })
	end
	return line, styles
end

--- A count of tokens in a few characters: 950, 14.2k, 200k, 1.1M.
function M.tokens(count: number): string
	if count < 1000 then
		return tostring(math.floor(count))
	elseif count < 1e6 then
		local k = count / 1000
		return if k < 100 then string.format("%.1fk", k) else string.format("%dk", math.floor(k))
	end
	return string.format("%.1fM", count / 1e6)
end

-- How long since `since` (on greed.now()'s clock): 9s, 2m 05s.
local function elapsed(since: number): string
	local seconds = math.max(0, math.floor((greed.now() - since) / 1000))
	if seconds < 60 then
		return `{seconds}s`
	end
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

-- A theme entry's color, when it's a "#rrggbb" one.
local function color(name: string, key: "fg" | "bg"): { number }?
	local entry = greed.theme.get(name)
	return core.effects.rgb(entry and (entry :: any)[key])
end

-- `text` with light going through it, `t` of the way, as pieces; nil when
-- the theme's colors can't be mixed.
local function shimmer(text: string, t: number): { any }?
	local fore = color("agent.working", "fg")
	if fore == nil then
		return nil
	end
	local glow = color("ui.glow", "fg") or { 255, 255, 255 }
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	local pieces = {}
	for i, level in core.effects.wave(#chars, t) do
		table.insert(
			pieces,
			{ text = chars[i], style = `=fg:{core.effects.mix(fore, glow, level)}` }
		)
	end
	return pieces
end

-- The "waiting for you" chip, its background `level` of the way to the
-- transcript's, for a pulse, when the theme's colors can be mixed.
local function chip(text: string, level: number): { text: string, style: string }
	local back = color("agent.waiting", "bg")
	local fore = color("agent.waiting", "fg")
	local under = color("ui.panel", "bg") or color("ui.text", "bg")
	if level == 0 or back == nil or fore == nil or under == nil then
		return { text = text, style = "agent.waiting" }
	end
	local mix = core.effects.mix
	return { text = text, style = `=fg:{mix(fore, back, level)} bg:{mix(back, under, level)} bold` }
end

local function busy(s: Session): boolean
	return s.status == "working" or s.status == "waiting"
end

--- The box's bottom line for `s`, `cells` wide, as pieces with styles: what
--- the agent is doing and for how long on the left, the tokens it has used
--- on the right. `now` is the clock, for animations; nil draws them still.
--- `hint` says how to answer while the agent waits for you.
function M.bottom(s: Session, cells: number, now: number?, hint: string?): { any }
	local left: { any } = {}
	local function piece(text: string, style: string)
		table.insert(left, { text = text, style = style })
	end
	if s.status == "working" then
		piece(if now then spinner_frame(now) else "●", "agent.working")
		piece(" ", "agent.box")
		local doing = if s.tool then session.first_line(s.tool) else "thinking"
		local lit = if now then shimmer(doing, (now % 1600) / 1600) else nil
		if lit then
			table.move(lit, 1, #lit, #left + 1, left)
		else
			piece(doing, "agent.working")
		end
	elseif s.status == "waiting" then
		local level = if now then (math.sin(now / 250) + 1) / 2 * 0.6 else 0
		table.insert(left, chip(" waiting for you ", level))
		if hint and hint ~= "" then
			piece(` {hint}`, "agent.hint")
		end
	elseif s.status == "starting" then
		piece("starting…", "agent.hint")
	elseif s.status == "exited" then
		piece("exited", "agent.failed")
	elseif s.problem then
		piece(core.text.clip(s.problem, math.max(cells - 8, 10)), "agent.failed")
	else
		piece("ready", "agent.hint")
	end
	if busy(s) and s.since then
		piece(` · {elapsed(s.since)}`, "agent.hint")
	end
	local right = ""
	if s.tokens then
		right = if s.window
			then `{M.tokens(s.tokens)} / {M.tokens(s.window)} tokens`
			else `{M.tokens(s.tokens)} tokens`
	end
	local used = 0
	for _, p in left do
		used += width(p.text)
	end
	-- The rule after the left: "╰─ " and " " around it, then " " and " ─╯"
	-- around the right, or "─╯" without it.
	local function room(): number
		return cells - used - width(right) - (if right == "" then 6 else 8)
	end
	if room() < 1 then
		right = ""
	end
	local out: { any } = { { text = "╰─ ", style = "agent.box" } }
	table.move(left, 1, #left, 2, out)
	table.insert(out, { text = " " .. string.rep("─", math.max(room(), 1)), style = "agent.box" })
	if right ~= "" then
		table.insert(out, { text = ` {right}`, style = "agent.hint" })
		table.insert(out, { text = " ─╯", style = "agent.box" })
	else
		table.insert(out, { text = "─╯", style = "agent.box" })
	end
	return out
end

-- Where the box's top line starts, and where it (with the row of choices
-- under it, if one shows) ends in `buffer`, if it's still there.
local function prompt_head(buffer: greed.Buffer): (number?, number?)
	local mark = buffer:decorations("acp-prompt")[1]
	if mark then
		return mark.from, mark.to
	end
	return nil, nil
end

local function prompt_end(buffer: greed.Buffer): number?
	local _, stop = prompt_head(buffer)
	return stop
end

--- What's written in the box.
function M.prompt(buffer: greed.Buffer): string
	local stop = prompt_end(buffer)
	if stop == nil then
		return ""
	end
	local start = buffer:line_start(buffer:line_of(stop) + 1)
	if start <= stop then
		return ""
	end
	return buffer:slice(start, buffer:len())
end

-- Per transcript buffer: its session, the tool call on each line, the
-- lines nobody said and the running tools' marks as last drawn, and
-- whether its status is ticking.
local shown: { [number]: Session } = {}
local rows: { [number]: { [number]: string } } = {}
local plains: { [number]: { [number]: boolean } } = {}
local spinning: { [number]: { { from: number, to: number } } } = {}
local ticking: { [number]: boolean } = {}

--- The shell code block `pos` in `buffer` is on, if you or the agent wrote
--- it above the box.
function M.code_at(buffer: greed.Buffer, pos: number): code.Code?
	return code.at(buffer, pos, prompt_head(buffer), plains[buffer:id()])
end

--- The id of the tool call drawn on `line` of `buffer`, if any.
function M.tool_at(buffer: greed.Buffer, line: number): string?
	local tools = rows[buffer:id()]
	return tools and tools[line]
end

--- The first line tool call `id` is drawn on in `buffer`, if it is.
function M.line_of_tool(buffer: greed.Buffer, id: string): number?
	local found = nil
	local tools: { [number]: string } = rows[buffer:id()] or {}
	for line, tool in tools do
		if tool == id and (found == nil or line < found) then
			found = line
		end
	end
	return found
end

-- How wide the box is: the widest view of `buffer`, less a cell so it
-- never wraps.
local function box_width(buffer: greed.Buffer): number
	local widest = 0
	for _, view in buffer:views() do
		local _, cols = view:size()
		widest = math.max(widest, cols or 0)
	end
	return if widest > 0 then math.max(widest - 1, 20) else DEFAULT_WIDTH
end

-- Draws what changes without the text changing: the box's sides around
-- what you write, its bottom line with the status, and the running tools'
-- marks. With `now`, animations are drawn at that time.
local function live(buffer: greed.Buffer, s: Session, now: number?)
	local start = prompt_head(buffer)
	if start == nil then
		buffer:decorate("acp-live", {})
		buffer:set_keys(nil)
		return
	end
	local draft = M.prompt(buffer)
	question.bind(buffer, draft)
	local cells = box_width(buffer)
	local marks: { greed.Mark } = {}
	local count = buffer:line_count()
	for line = buffer:line_of(start) + 1, count - 1 do
		local from = buffer:line_start(line)
		local to = if line + 1 < count then buffer:line_start(line + 1) - 1 else buffer:len()
		-- The marks are empty ranges, so their style stays off what you wrote.
		table.insert(marks, { from = from, to = from, style = "agent.box", text = "│ " })
		-- The right side, after a line short enough to have one. Text after
		-- a line's end is drawn a cell from it.
		local pad = cells - 4 - width(buffer:slice(from, to))
		if pad >= 0 then
			table.insert(marks, {
				from = from,
				to = from,
				style = "agent.box",
				text = string.rep(" ", pad) .. "│",
				eol = true,
			})
		end
	end
	local last = buffer:line_start(count - 1)
	table.insert(marks, {
		from = last,
		to = last,
		style = "agent.box",
		lines = { M.bottom(s, cells, now, question.hint(s, draft)) },
	})
	if now then
		local frame = spinner_frame(now)
		local running: { { from: number, to: number } } = spinning[buffer:id()] or {}
		for _, mark in running do
			table.insert(marks, {
				from = mark.from,
				to = mark.to,
				style = "agent.working",
				text = frame,
				overlay = true,
			})
		end
	end
	buffer:decorate("acp-live", marks)
end

-- While `s` works or waits for you, redraws `buffer`'s status as time
-- goes: each frame with effects on, else each second for the time.
local function tick(buffer: greed.Buffer, s: Session)
	local id = buffer:id()
	if ticking[id] or not busy(s) then
		return
	end
	ticking[id] = true
	greed.spawn(function()
		while busy(s) and shown[id] == s do
			local animate = core.effects.enabled()
			pcall(live, buffer, s, if animate then greed.now() else nil)
			greed.sleep(if animate then FRAME_MS else SECOND_MS)
		end
		ticking[id] = nil
		if shown[id] == s then
			pcall(live, buffer, s, nil)
		end
	end)
end

--- Redraws the history of `s` in `buffer`, changing only what changed so a
--- reply streaming in only adds to the end.
function M.render(buffer: greed.Buffer, s: Session)
	local id = buffer:id()
	shown[id] = s
	local history = M.history(s)
	rows[id] = history.tools
	plains[id] = history.plain
	spinning[id] = history.running
	local cells = box_width(buffer)
	local top, top_styles = M.top(s, cells)
	local row, row_marks = question.row(buffer, s, cells)
	local head = if row then `{top}\n{row}` else top
	local wanted = history.text .. head
	-- The box's top line and its row of choices aren't Markdown either;
	-- what you write under them is.
	local plain = table.clone(history.plain)
	local _, lines = string.gsub(history.text, "\n", "")
	plain[lines] = true
	if row then
		plain[lines + 1] = true
	end
	markdown.plain(buffer, plain)
	local stop = prompt_end(buffer)
	if stop == nil then
		-- The box's top went; everything there was is history now.
		buffer:edit(function(e)
			e:replace(0, buffer:len(), wanted .. "\n")
		end, OUT_OF_UNDO)
	else
		local old = buffer:slice(0, stop)
		if old ~= wanted then
			local same = 0
			local shortest = math.min(#old, #wanted)
			while same < shortest and string.byte(old, same + 1) == string.byte(wanted, same + 1) do
				same += 1
			end
			-- Not inside a character.
			while
				same > 0
				and (string.byte(wanted, same + 1) or 0) >= 0x80
				and (string.byte(wanted, same + 1) or 0) < 0xC0
			do
				same -= 1
			end
			buffer:edit(function(e)
				e:replace(same, stop, string.sub(wanted, same + 1))
			end, OUT_OF_UNDO)
		end
	end
	local at = #history.text
	buffer:decorate("acp-prompt", { { from = at, to = at + #head, style = "agent.box" } })
	local styles = history.styles
	for _, style in top_styles do
		local moved = table.clone(style)
		moved.from += at
		moved.to += at
		table.insert(styles, moved)
	end
	buffer:decorate("acp", styles :: any)
	local row_at = at + #top + 1
	for _, mark in row_marks do
		mark.from += row_at
		mark.to += row_at
	end
	buffer:decorate("acp-choices", row_marks)
	code.draw(buffer, at, history.plain)
	live(buffer, s, if busy(s) and core.effects.enabled() then greed.now() else nil)
	tick(buffer, s)
end

--- A new transcript buffer for `s`, with an empty box to write in.
function M.create(s: Session): greed.Buffer
	-- Agents write Markdown, which shows as such, its markup hidden except
	-- on the line you're on.
	local buffer = greed.create_buffer("agent-transcript", "", { language = "markdown" })
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	M.render(buffer, s)
	return buffer
end

--- Empties the box.
function M.clear_prompt(buffer: greed.Buffer)
	local stop = prompt_end(buffer)
	if stop == nil then
		return
	end
	local line = buffer:line_of(stop)
	if line + 1 < buffer:line_count() then
		local start = buffer:line_start(line + 1)
		buffer:edit(function(e)
			e:replace(start, buffer:len(), "")
		end, OUT_OF_UNDO)
	end
end

--- The views of `buffer` showing the box's top line, the end of the
--- history, to keep following it as the agent adds more (`follow`).
function M.following(buffer: greed.Buffer): { greed.View }
	local start = prompt_head(buffer)
	local out: { greed.View } = {}
	if start == nil then
		return out
	end
	for _, view in buffer:views() do
		local _, last = view:visible()
		if last >= start then
			table.insert(out, view)
		end
	end
	return out
end

--- Puts the cursor of each of `views` that's up in the history, and not
--- selecting anything, at the end of the box, so drawing scrolls down to
--- what the agent added.
function M.follow(buffer: greed.Buffer, views: { greed.View })
	local start = prompt_head(buffer)
	if start == nil then
		return
	end
	for _, view in views do
		if view:valid() then
			local ranges = view:selection().ranges
			local only = ranges[1]
			if #ranges == 1 and only.anchor == only.head and only.head < start then
				view:set_cursor(buffer:len())
			end
		end
	end
end

--- Puts the cursor in `view` at the end of what's in the box.
function M.focus_prompt(view: greed.View)
	local pos = view:buffer():len()
	view:set_cursor(pos)
end

-- The box's sides follow what you write.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local s = shown[event.buffer:id()]
	if s then
		live(event.buffer, s, nil)
	end
end)

-- The box fits the view it's in.
greed.on("view.resized", function(event: greed.ViewResized)
	local buffer = event.view:buffer()
	local s = shown[buffer:id()]
	if s then
		M.render(buffer, s)
	end
end)

question.on_redraw(M.render)

-- What answers a question, and the hint saying so, depend on the mode.
greed.on("mode.changed", function()
	for _, buffer in greed.buffers() do
		local s = shown[buffer:id()]
		if s then
			live(buffer, s, nil)
		end
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	shown[event.id] = nil
	rows[event.id] = nil
	plains[event.id] = nil
	spinning[event.id] = nil
end)

return M
