-- A session's transcript: a buffer of what you and the agent said and what
-- it did, with a box at the bottom to write the next message in. The
-- history above the box is read-only (`buffer:set_readonly_before`): you
-- can move, search and copy there, and typing or pasting there goes in the
-- box (`core.writable`). Text in the box is yours.
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
--   ╰─  waiting for you  enter answers · esc rejects with your message ─╯
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
local compact = require("./compact")
local auto = require("./auto")

type Session = session.Session

local M = {}

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
local ui = core.ui

--- A row you can act on with enter, tab or a click, by 0-based line, and
--- what it stands for: a tool call's id, a thought's (`thought_id`), a
--- question waiting (`question:N`) or a shell block's fence (`code:N`).
export type Row = { line: number, key: string }

--- What stands for the thought at `index` of a session's entries among
--- the tool calls drawn on each line (`tool_at`), to fold it.
function M.thought_id(index: number): string
	return `thought:{index}`
end

--- The index among a session's entries of the thought `id` stands for
--- (`thought_id`), if it's one.
function M.thought_of(id: string): number?
	return tonumber(string.match(id, "^thought:(%d+)$"))
end

-- How many of a thought's newest lines show while it comes in.
local THOUGHT_TAIL = 3

-- The newest lines of `text`, a thought, wrapped to `room` cells less
-- their indent: up to `THOUGHT_TAIL`, leaving out the start of its first
-- line, which shows above them.
local function thought_tail(text: string, room: number): { string }
	local cells = math.max(room - 4, 10)
	-- Enough of the end for the rows shown, in whole characters.
	local from = math.max(#text - THOUGHT_TAIL * cells * 4, 1)
	while from <= #text and bit32.band(string.byte(text, from), 0xC0) == 0x80 do
		from += 1
	end
	local rows: { string } = {}
	for _, line in string.split(string.sub(text, from), "\n") do
		for _, wrapped in string.split(core.text.reflow(line, cells), "\n") do
			if string.find(wrapped, "%S") then
				table.insert(rows, core.text.clip(wrapped, cells))
			end
		end
	end
	if from == 1 then
		table.remove(rows, 1)
	end
	return table.move(rows, math.max(#rows - THOUGHT_TAIL + 1, 1), #rows, 1, {})
end

-- Whether `s` is working on a thought, the newest of its entries.
local function thinking(s: Session): boolean
	local last = s.entries[#s.entries]
	return s.status == "working" and last ~= nil and last.kind == "thought"
end

-- How long since `since` (on greed.now()'s clock): 9s, 2m 05s.
local function elapsed(since: number): string
	return core.time.duration(greed.now() - since, true)
end

-- What a line of the history stands for: the tool call or thought drawn on
-- it (`tool_at`), the row you can act on there (`Row`), and whether it's
-- what you or the agent said. Only what was said shows as Markdown; the
-- rest (headings, tools and their output, plans, questions) shows as it is.
type Value = { tool: string?, row: string?, said: boolean? }

-- A line of the history: its text, its marks counted from its start, what
-- it stands for and where a running tool's mark is, to animate it.
type Said = {
	text: string,
	marks: { greed.Mark },
	value: Value?,
	spin: { from: number, to: number }?,
}

-- Lines being added, and who said them, for the bar beside each: the
-- agent's, or yours with a background too.
type Lines = { lines: { Said }, speaker: ("user" | "agent")? }

local function add(out: Lines, text: string, style: string?, from: number?, to: number?): Said
	local marks: { greed.Mark } = {}
	if style then
		table.insert(marks, { from = from or 0, to = to or #text, style = style })
	end
	local speaker = out.speaker
	if speaker then
		-- Over the first of the two spaces every line of theirs starts with.
		local bar = if speaker == "user" then "agent.you.bar" else "agent.bar"
		table.insert(marks, { from = 0, to = 1, style = bar, text = "▍", overlay = true })
		if speaker == "user" then
			table.insert(marks, { from = 0, to = #text, style = "agent.you", line = true })
		end
	end
	local line: Said = { text = text, marks = marks }
	table.insert(out.lines, line)
	return line
end

local function gap(out: Lines)
	out.speaker = nil
	add(out, "")
end

-- What was said, a line each, shown as Markdown.
local function body(out: Lines, text: string, style: string?)
	for _, line in string.split(text, "\n") do
		add(out, "  " .. line, style).value = { said = true }
	end
end

-- A heading each time the speaker changes; the agent's text, tools and
-- plans run on under one.
local function heading(out: Lines, s: Session, who: "user" | "agent")
	if out.speaker ~= who then
		gap(out)
		out.speaker = who
		add(out, `  {if who == "user" then "You" else s.name}`, "markup.heading")
	end
end

-- The lines of entry `index` of `s`, `e`, drawn `room` cells wide after
-- lines `speaker` said.
local function entry_lines(
	s: Session,
	index: number,
	e: any,
	speaker: ("user" | "agent")?,
	room: number
): { Said }
	local out: Lines = { lines = {}, speaker = speaker }
	if e.kind == "user" or e.kind == "agent" then
		heading(out, s, e.kind)
		body(out, string.match(e.text, "^(.-)%s*$") or e.text)
		return out.lines
	elseif e.kind == "note" then
		gap(out)
		add(out, `  {e.text}`, "comment")
		return out.lines
	end
	heading(out, s, "agent")
	if e.kind == "thought" then
		local id = M.thought_id(index)
		local first_row = true
		local function row(line: string, style: string)
			local value: Value = { tool = id }
			if first_row then
				value.row = id
				first_row = false
			end
			add(out, line, style).value = value
		end
		local text = core.text.trim(e.text)
		local thought = string.split(text, "\n")
		local first = thought[1]
		local tokens = M.tokens(compact.estimate(#e.text))
		if index == #s.entries and thinking(s) and not e.open then
			-- Still coming in: its first line, its newest lines and a count
			-- that goes up, so a long one doesn't look stuck.
			row(`  … {core.text.clip(first, room - 4)}`, "comment")
			for _, line in thought_tail(text, room) do
				row(`    {line}`, "comment")
			end
			local took = elapsed(e.since or s.since or greed.now())
			row(`    thinking · {tokens} tokens · {took}`, "agent.hint")
		else
			-- Folded to its first line, tab shows the rest.
			local about = ` · thought, {tokens} tokens`
			local shown = if e.open then first else core.text.clip(first, room - 4 - width(about))
			local mark = if #thought == 1 and shown == first
				then "…"
				elseif e.open then "▾"
				else "▸"
			row(`  {mark} {shown}{about}`, "comment")
			if e.open then
				for i = 2, #thought do
					row(`    {thought[i]}`, "comment")
				end
			end
		end
	elseif e.kind == "tool" then
		local tool = e.tool
		local id: string = tool.id
		local status = tool.status or "pending"
		local glyph = GLYPH[status] or GLYPH.pending
		-- A title of several lines, like a script it runs, shows them all
		-- under its first.
		local title_lines = string.split(tool.title, "\n")
		local text = `  {glyph} {title_lines[1]}`
		local named = #text
		local summary = table.concat(tool.detail, " · ")
		if summary ~= "" then
			text ..= ` · {summary}`
		end
		-- A helper's call: what it does, and its own transcript.
		if tool.helper then
			text ..= " · enter shows it"
		end
		if #tool.output > 1 then
			text ..= if tool.open then " ▾" else " ▸"
		end
		local glyph_at = { from = 2, to = 2 + #glyph }
		local line = add(out, text, "agent.hint", named)
		table.insert(line.marks, 1, {
			from = glyph_at.from,
			to = glyph_at.to,
			style = GLYPH_STYLE[status] or "agent.hint",
		})
		if status == "in_progress" then
			line.spin = glyph_at
		end
		local value: Value = { tool = id }
		if tool.helper or #tool.output > 1 then
			value.row = id
		end
		line.value = value
		for i = 2, #title_lines do
			add(out, `    {title_lines[i]}`).value = { tool = id }
		end
		if tool.open then
			for _, output in tool.output do
				-- An edit's change shows as a diff: gone lines and new ones.
				local diff = if tool.kind == "edit" then string.sub(output, 1, 2) else ""
				local style = if diff == "- "
					then "diff.minus"
					elseif diff == "+ " then "diff.plus"
					else "comment"
				add(out, `    {output}`, style).value = { tool = id }
			end
		end
	elseif e.kind == "plan" then
		for _, item in e.items do
			local mark = if item.status == "completed"
				then "✓"
				elseif item.status == "in_progress" then "›"
				else "·"
			add(out, `  {mark} {item.text}`, "comment")
		end
	elseif e.kind == "permission" then
		-- The tool's row above shows the whole of a long title.
		local asked = session.first_line(e.permission.title)
		if e.chosen then
			add(out, `  ? {asked}: {e.chosen}`, "comment")
		else
			add(out, `  ? Allow {asked}?`, "agent.working").value = { row = `question:{index}` }
		end
	end
	return out.lines
end

-- What entry `index` of `s`, `e`, draws from, after lines `speaker` said:
-- it's drawn again only when this changes. `e` itself is in it, so a
-- history put in place of another is drawn anew.
local function version(s: Session, index: number, e: any, speaker: string?): string
	local v = `{e}|{speaker}|{e.kind}`
	if e.kind == "thought" then
		local live = index == #s.entries and thinking(s) and not e.open
		v ..= `|{#e.text}|{e.open}|{live}`
		if live then
			-- Its time counts up.
			v ..= `|{greed.now() // SECOND_MS}`
		end
	elseif e.kind == "tool" then
		local tool = e.tool
		local output = tool.output
		v ..= `|{tool.status}|{tool.kind}|{tool.open}|{tool.helper ~= nil}|{tool.title}`
		v ..= `|{table.concat(tool.detail, " · ")}|{#output}|{output[#output]}`
	elseif e.kind == "plan" then
		for _, item in e.items do
			v ..= `|{item.status}:{item.text}`
		end
	elseif e.kind == "permission" then
		v ..= `|{e.chosen}|{e.permission.title}`
	else
		v ..= `|{#e.text}|{string.sub(e.text, -16)}`
	end
	return v
end

-- `lines` as a view's lines: a running tool's mark tagged "spin".
local function laid(lines: { Said }): { core.UiLine }
	local out: { core.UiLine } = {}
	for _, line in lines do
		local spin = line.spin
		if spin then
			local before: core.UiSpan = {
				text = string.sub(line.text, 1, spin.from),
				marks = line.marks,
				value = line.value,
			}
			local mark: core.UiSpan =
				{ text = string.sub(line.text, spin.from + 1, spin.to), tag = "spin" }
			local after: core.UiSpan = { text = string.sub(line.text, spin.to + 1) }
			table.insert(out, { before, mark, after })
		else
			table.insert(out, { { text = line.text, marks = line.marks, value = line.value } })
		end
	end
	return out
end

-- A part of the view laid out by `lines(cells)`.
local function part(lines: (cells: number) -> { Said }): core.UiNode
	return {
		lay = function(cells: number): { core.UiLine }
			return laid(lines(cells))
		end,
	}
end

-- The history of `s`: its title, then each entry a part of its own, so
-- only the one that changed is drawn again, then what you sent while it
-- worked.
local function history(s: Session): { core.UiNode }
	local title = `{s.name} in {core.project.tilde(s.root)}`
	if s.workspace then
		title ..= ` (workspace {s.workspace.name})`
	end
	local parts: { core.UiNode } = {
		part(function()
			local out: Lines = { lines = {} }
			add(out, title, "markup.heading")
			return out.lines
		end),
	}
	local thoughts = greed.option.get("agent-thoughts") ~= false
	local speaker: ("user" | "agent")? = nil
	for index, entry in s.entries do
		local e = entry :: any
		if e.kind == "thought" and (not thoughts or not string.find(e.text or "", "%S")) then
			continue
		end
		local before: ("user" | "agent")? = speaker
		speaker = if e.kind == "user" then "user" elseif e.kind == "note" then nil else "agent"
		-- Everything wraps in the view but thoughts, cut to its width.
		local wraps = e.kind ~= "thought"
		table.insert(
			parts,
			ui.keyed(`entry:{index}`, version(s, index, e, before), function()
				return part(function(cells: number)
					return entry_lines(s, index, e, before, cells)
				end)
			end, { any_width = wraps })
		)
	end
	table.insert(
		parts,
		part(function()
			local out: Lines = { lines = {} }
			-- What you sent while it worked, dimmed at the end until it goes.
			local queued, images = s.queued or {}, s.queued_images
			if #queued > 0 or images then
				gap(out)
				out.speaker = "user"
				add(out, "  You · queued", "comment")
				if #queued > 0 then
					body(out, table.concat(queued, "\n\n"), "comment")
				end
				if images then
					body(out, session.chips(images), "comment")
				end
			end
			gap(out)
			return out.lines
		end)
	)
	return parts
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
function M.top(s: Session, cells: number): (string, { greed.Mark })
	local named = s.name
	local mode, model = name_in(s.modes, s.mode), name_in(s.models, s.model)
	if mode then
		named ..= ` · {mode}`
	end
	if auto.on(s) then
		named ..= " · auto"
	end
	if model then
		named ..= ` · {model}`
	end
	if s.effort then
		named ..= ` · effort {s.effort}`
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
	local styles: { greed.Mark } = {
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

-- The time `s`'s status is drawn at: now while it animates (it works or
-- waits, effects on), else nil to draw it still. Every drawing of it uses
-- this, or one in between would draw it still and it would flicker.
local function moment(s: Session): number?
	return if busy(s) and core.effects.enabled() then greed.now() else nil
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
	-- What follows what it's doing: how many messages wait, and for how long
	-- it's been at it.
	local queued = if s.queued and #s.queued > 0 then #s.queued elseif s.queued_images then 1 else 0
	local after = (if queued > 0 then ` · {queued} queued` else "")
		.. (if busy(s) and s.since then ` · {elapsed(s.since)}` else "")
	local right = ""
	if s.tokens then
		right = if s.window
			then `{M.tokens(s.tokens)} / {M.tokens(s.window)} tokens`
			else `{M.tokens(s.tokens)} tokens`
	end
	if s.status == "working" then
		piece(if now then spinner_frame(now) else "●", "agent.working")
		piece(" ", "agent.box")
		local helpers = if s.helpers then #s.helpers else 0
		local doing = if helpers > 0
			then `waiting for {helpers} {if helpers == 1 then "helper" else "helpers"}`
			elseif s.tool then session.first_line(s.tool)
			else s.doing or "working"
		-- A long command is cut to what fits beside the rest, the tokens
		-- going first when there's little room.
		local spare = cells - 9 - width(after)
		if right ~= "" and spare - width(right) - 2 >= 20 then
			spare -= width(right) + 2
		end
		doing = core.text.clip(doing, math.max(spare, 10))
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
	if after ~= "" then
		piece(after, "agent.hint")
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

--- Where what you write in the box starts, if the box is there and has a
--- line to write in.
function M.prompt_start(buffer: greed.Buffer): number?
	local stop = prompt_end(buffer)
	if stop == nil then
		return nil
	end
	local start = buffer:line_start(buffer:line_of(stop) + 1)
	return if start > stop then start else nil
end

--- What's written in the box.
function M.prompt(buffer: greed.Buffer): string
	local start = M.prompt_start(buffer)
	return if start then buffer:slice(start, buffer:len()) else ""
end

-- Per transcript buffer: its session, the lines nobody said
-- (`plain_lines`), the shell blocks in it as last drawn, the box's head
-- (its top line, the row of choices and their marks) and whether its
-- status is ticking. Its view (`core.ui`) knows what each line is.
local shown: { [number]: Session } = {}
local plains: { [number]: { [number]: boolean } } = {}
local blocks: { [number]: { code.Code } } = {}
local heads: { [number]: { size: number, top: number, marks: { greed.Mark } } } = {}
local ticking: { [number]: boolean } = {}
-- The plugin's own handle on each transcript buffer, for drawing above the
-- box, which is read-only to you.
local owned: { [number]: greed.Buffer } = {}
-- Per transcript buffer: the rows you can act on, worked out when first
-- asked for after a draw, the one highlighted (`M.pick`) by its key, where
-- in the box the cursor was before, counted from the end, and what was in
-- the box when last drawn, so typing drops the highlight.
local actionable: { [number]: { Row } } = {}
local picked: { [number]: string } = {}
local picked_from: { [number]: number } = {}
local drafts: { [number]: string } = {}

-- The view drawing `buffer`, if it's a transcript; other buffers drawn
-- with `core.ui` have values of their own.
local function view_of(buffer: greed.Buffer): core.UiView?
	return if shown[buffer:id()] then ui.of(buffer) else nil
end

-- What `line` of `buffer` stands for, as last drawn.
local function value_at(buffer: greed.Buffer, line: number): Value?
	local view = view_of(buffer)
	return if view then view:value_on(line) else nil
end

-- The lines of `buffer` that aren't what you or the agent said, as
-- `markdown.plain` takes them, looked up as they're asked for: the
-- history's tools and headings and the box's head, but not what you write
-- in the box.
local function plain_lines(buffer: greed.Buffer): { [number]: boolean }
	return setmetatable({}, {
		__index = function(_, line: number): boolean?
			local view = view_of(buffer)
			if view == nil or line >= buffer:line_of(view:input_start()) then
				return nil
			end
			local value = value_at(buffer, line)
			return not (value and value.said)
		end,
	}) :: any
end

--- The shell code block `pos` in `buffer` is on, if you or the agent wrote
--- it above the box.
function M.code_at(buffer: greed.Buffer, pos: number): code.Code?
	return code.at(buffer, pos, prompt_head(buffer), plains[buffer:id()])
end

--- The id of the tool call drawn on `line` of `buffer`, if any.
function M.tool_at(buffer: greed.Buffer, line: number): string?
	local value = value_at(buffer, line)
	return value and value.tool
end

--- The first line tool call `id` is drawn on in `buffer`, if it is.
function M.line_of_tool(buffer: greed.Buffer, id: string): number?
	local view = view_of(buffer)
	return view and view:line_of(function(value: Value): boolean
		return value.tool == id
	end)
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

-- The rows of `buffer` you can act on, as last drawn, top to bottom.
local function rows_of(buffer: greed.Buffer): { Row }
	local id = buffer:id()
	local known = actionable[id]
	if known then
		return known
	end
	local rows: { Row } = {}
	local view = view_of(buffer)
	if view then
		view:each(function(line: number, value: Value)
			if value.row then
				table.insert(rows, { line = line, key = value.row })
			end
		end)
	end
	local drawn_blocks = blocks[id]
	if drawn_blocks then
		for n, block in drawn_blocks do
			table.insert(rows, { line = block.open, key = `code:{n}` })
		end
	end
	table.sort(rows, function(a: Row, b: Row)
		return a.line < b.line
	end)
	actionable[id] = rows
	return rows
end

-- The highlighted row of `buffer`, if one is.
local function picked_row(buffer: greed.Buffer): Row?
	local key = picked[buffer:id()]
	for _, row in rows_of(buffer) do
		if row.key == key then
			return row
		end
	end
	return nil
end

-- Binds the keys of `buffer`, whose box holds `draft`, for the question
-- it shows (question.luau) and, over them, for the highlighted row.
local function bind(buffer: greed.Buffer, draft: string)
	local keys = question.keys(buffer, draft)
	if picked[buffer:id()] then
		local over: { [string]: string } = keys or {}
		over.enter = "agent-answer"
		over.tab = "agent-fold"
		over.esc = "agent-row-drop"
		keys = over
	end
	buffer:set_keys(keys)
end

-- Draws the highlight over the row picked in `buffer`, dropping it when the
-- row went.
local function draw_pick(buffer: greed.Buffer)
	local row = if picked[buffer:id()] then picked_row(buffer) else nil
	if row == nil then
		picked[buffer:id()] = nil
		buffer:decorate("acp-pick", {})
		return
	end
	local from = buffer:line_start(row.line)
	buffer:decorate(
		"acp-pick",
		{ { from = from, to = buffer:line_end(row.line), style = "agent.picked", line = true } }
	)
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
	local id = buffer:id()
	-- Typing in the box drops the highlight.
	if drafts[id] ~= nil and drafts[id] ~= draft and picked[id] then
		picked[id] = nil
		draw_pick(buffer)
	end
	drafts[id] = draft
	bind(buffer, draft)
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
		local view = view_of(buffer)
		local running: { { from: number, to: number } } = if view then view:spots("spin") else {}
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
		-- It starts from a draw, which counted this second.
		local second = greed.now() // SECOND_MS
		while busy(s) and shown[id] == s do
			local animate = core.effects.enabled()
			local now = greed.now()
			-- A thought coming in counts its time in the history.
			if thinking(s) and now // SECOND_MS ~= second then
				second = now // SECOND_MS
				pcall(M.render, buffer, s)
			end
			pcall(live, buffer, s, if animate then now else nil)
			greed.sleep(if animate then FRAME_MS else SECOND_MS)
		end
		ticking[id] = nil
		if shown[id] == s then
			pcall(live, buffer, s, nil)
		end
	end)
end

-- The box's head for `s` in `buffer`, `cells` wide: its top line, the row
-- of choices for a question under it and the images pasted for your next
-- message. What it was is kept for drawing the choices after.
local function head(buffer: greed.Buffer, s: Session, cells: number): { Said }
	local top, top_styles = M.top(s, cells)
	local out: { Said } = { { text = top, marks = top_styles } }
	local size = #top
	local row, row_marks = question.row(buffer, s, cells)
	if row then
		table.insert(out, { text = row, marks = {} })
		size += 1 + #row
	end
	local attached = s.attached
	if attached then
		local chips = `  {session.chips(attached)} · alt-x drops them`
		table.insert(out, { text = chips, marks = {} })
		size += 1 + #chips
	end
	heads[buffer:id()] = { size = size, top = #top, marks = row_marks }
	return out
end

-- What `buffer` shows of the session in its state: the history, then the
-- box's head, what you write coming under it.
local function render(buffer: greed.Buffer, state: { [string]: any }): core.UiNode
	local s: Session = state.s
	local parts = history(s)
	table.insert(
		parts,
		part(function(cells: number)
			return head(buffer, s, cells)
		end)
	)
	return ui.column(parts)
end

-- Draws what goes with the history just drawn in `buffer`: the box's head
-- and its choices, the shell blocks' buttons, the highlight and the box.
local function drawn(buffer: greed.Buffer, view: core.UiView)
	local id = buffer:id()
	local s = shown[id]
	local made = heads[id]
	local stop = view:input_start() - 1
	local at = stop - made.size
	buffer:decorate("acp-prompt", { { from = at, to = stop, style = "agent.box" } })
	local row_at = at + made.top + 1
	local marks: { greed.Mark } = {}
	for _, mark in made.marks do
		local moved = table.clone(mark)
		moved.from += row_at
		moved.to += row_at
		table.insert(marks, moved)
	end
	buffer:decorate("acp-choices", marks)
	blocks[id] = code.draw(buffer, at, plains[id])
	actionable[id] = nil
	draw_pick(buffer)
	live(buffer, s, moment(s))
end

-- Draws `s` in `buffer` (see `M.render`): only the entries that changed.
local function draw(buffer: greed.Buffer, s: Session)
	local id = buffer:id()
	-- Drawn as the plugin, which may change the history, though a command's
	-- handle (yours) may not.
	buffer = owned[id] or buffer
	shown[id] = s
	local view = view_of(buffer)
	if view == nil then
		ui.mount(buffer, function(state)
			return render(buffer, state)
		end, { s = s }, {
			ns = "acp",
			width = box_width,
			input = true,
			keys = false,
			after = function(drawn_view: core.UiView)
				drawn(buffer, drawn_view)
			end,
		})
	else
		view.state.s = s
		view:redraw()
	end
	tick(buffer, s)
end

-- Per transcript buffer being drawn: the session to draw again once that
-- draw is done, if something asked meanwhile, or false.
local drawing: { [number]: Session | false } = {}

--- Redraws the history of `s` in `buffer`, changing only what changed so a
--- reply streaming in only adds to the end.
---
--- A long history takes more than a task's time slice to work out, so a
--- draw can pause before it shows it. Another draw in that pause would have
--- the first show an older history after it. So a buffer is drawn by one
--- call at a time, and a call while it draws has it draw again once it's
--- done.
function M.render(buffer: greed.Buffer, s: Session)
	local id = buffer:id()
	if drawing[id] ~= nil then
		drawing[id] = s
		return
	end
	local pending: Session? = s
	local ok, problem = true, nil
	while ok and pending do
		drawing[id] = false
		ok, problem = pcall(draw, buffer, pending)
		pending = drawing[id] or nil
	end
	drawing[id] = nil
	if not ok then
		error(problem, 0)
	end
end

--- A new transcript buffer for `s`, with an empty box to write in.
function M.create(s: Session): greed.Buffer
	-- Agents write Markdown, which shows as such, its markup hidden except
	-- on the line you're on.
	local buffer = greed.create_buffer("agent-transcript", "", { language = "markdown" })
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	owned[buffer:id()] = buffer
	-- The box's top line, its row of choices and the images' chips aren't
	-- Markdown either; what you write under them is.
	plains[buffer:id()] = plain_lines(buffer)
	markdown.plain(buffer, plains[buffer:id()])
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
		-- Kept out of undo, so undo in the box takes back only typing.
		buffer:edit(function(e)
			e:replace(start, buffer:len(), "")
		end, { undo = false })
	end
end

-- A view follows what the agent adds while its cursor is in the box:
-- drawing keeps the cursor where it is, and the view on it, so a cursor
-- moved up into the history stays there and the view with it.

--- Puts the cursor in `view` at the end of what's in the box.
function M.focus_prompt(view: greed.View)
	local pos = view:buffer():len()
	view:set_cursor(pos)
end

--- The row you can act on that `line` of `buffer` is, if it's one.
function M.row_at(buffer: greed.Buffer, line: number): Row?
	for _, row in rows_of(buffer) do
		if row.line == line then
			return row
		end
	end
	return nil
end

--- The row highlighted in `buffer` (`M.pick`), if one is.
M.picked = picked_row

--- Moves the highlight in the transcript `view` shows over the rows you
--- can act on: `by` -1 to the one above (from the box, the newest), 1 to
--- the one below, and from the newest back to the box. The cursor goes
--- to the row, so the view shows it, and back to where it was in the box
--- after. Returns whether a row is highlighted.
function M.pick(view: greed.View, by: number): boolean
	local buffer = view:buffer()
	local id = buffer:id()
	local rows = rows_of(buffer)
	local current = picked_row(buffer)
	local found = if current then table.find(rows, current) else nil
	local index: number
	if found == nil then
		if by > 0 or #rows == 0 then
			return false
		end
		local head = prompt_head(buffer)
		local cursor = view:cursor()
		picked_from[id] = if head and cursor >= head then buffer:len() - cursor else 0
		index = #rows
	else
		index = found + by
		if index > #rows then
			M.unpick(view, true)
			return false
		end
		index = math.max(index, 1)
	end
	local row = rows[index]
	picked[id] = row.key
	draw_pick(buffer)
	view:set_cursor(buffer:line_start(row.line))
	bind(buffer, M.prompt(buffer))
	return true
end

--- Drops the highlight in the transcript `view` shows; with `back`, the
--- cursor goes back to where it was in the box.
function M.unpick(view: greed.View, back: boolean?)
	local buffer = view:buffer()
	local id = buffer:id()
	if picked[id] == nil then
		return
	end
	picked[id] = nil
	draw_pick(buffer)
	bind(buffer, M.prompt(buffer))
	if back then
		view:set_cursor(math.max(buffer:len() - (picked_from[id] or 0), 0))
	end
end

-- Moving the cursor off the highlighted row drops the highlight.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	local view = event.view
	if not view:valid() or view ~= greed.view() then
		return
	end
	local buffer = view:buffer()
	local row = picked_row(buffer)
	if row and buffer:line_of(view:cursor()) ~= row.line then
		M.unpick(view)
	end
end)

-- The box's sides follow what you write.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local s = shown[event.buffer:id()]
	if s then
		live(event.buffer, s, moment(s))
	end
end)

question.on_redraw(M.render)
question.on_box(M.prompt, M.clear_prompt)

-- What answers a question, and the hint saying so, depend on the mode.
greed.on("mode.changed", function()
	for _, buffer in greed.buffers() do
		local s = shown[buffer:id()]
		if s then
			live(buffer, s, moment(s))
		end
	end
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	shown[event.id] = nil
	plains[event.id] = nil
	blocks[event.id] = nil
	heads[event.id] = nil
	owned[event.id] = nil
	drawing[event.id] = nil
	actionable[event.id] = nil
	picked[event.id] = nil
	picked_from[event.id] = nil
	drafts[event.id] = nil
end)

return M
