-- How a shell's buffer shows its blocks. The text is only what was typed
-- and what came out:
--
--   ls src                  ← the command (❯ 1 before it is a decoration)
--   main.rs                 ← its output, one buffer line per line printed
--   lib.rs
--   cargo test              ← the next block
--   ...
--   git st                  ← the prompt, after the last block
--
-- Everything else is decorations per block, in `shell.block.N`: the prompt
-- glyph and the block's number, the status after the command's line (✓ ✗
-- ◐ ↗ ■, or ? for a question to a model that brought no command, the exit
-- code, how long it took, where cd went), the sign beside it, the blank
-- line after it, and how many lines were left out. Output styles (errors, a
-- program's colors) are in `shell.out.N`, and links on the places in files
-- it names (`src/main.rs:12`) in `shell.ref.N`. Nothing is laid out to a
-- view's width, so every client wraps the text at its own.
--
-- A block's output is stable lines, which only grow, then volatile ones
-- drawn again on every update: a line still being printed, or a pseudo
-- terminal's screen. Past `shell-max-lines`, the first half stays and the
-- oldest of the rest go.

local greed = require("@greed")
local core = require("@core")
local terminal = require("@terminal")
local state = require("./state")

type Shell = state.Shell
type Block = state.Block
type Ref = state.Ref

local M = {}

greed.option.define({
	name = "shell-max-lines",
	doc = "How many lines of a block's output a shell shows: the first half and the latest half",
	default = 5000,
})

greed.option.define({
	name = "shell-confirm-lines",
	doc = "Running a prompt of more lines than this asks first, as after pasting a transcript",
	default = 5,
})

--- A line of output, with styles from its start, e.g. errors or colors.
export type Line = {
	text: string,
	marks: { greed.Mark }?,
}

-- What each block shows, by its uid: how many stable and volatile output
-- lines are in the buffer, and how many lines its command takes.
type Shown = {
	command: number,
	stable: number,
	volatile: number,
}

local shown: { [number]: Shown } = {}

-- The most output lines a block shows, and how many of them are its head,
-- which stays.
local function cap(): (number, number)
	local max = math.max(greed.option.get("shell-max-lines") :: number, 2)
	return max, max // 2
end

local GLYPH: { [string]: string } = {
	running = "◐",
	done = "✓",
	failed = "✗",
	killed = "■",
	error = "✗",
	asked = "?",
}

local STYLE: { [string]: string } = {
	running = "shell.running",
	done = "shell.done",
	failed = "shell.failed",
	killed = "shell.failed",
	error = "shell.failed",
	asked = "shell.status",
}

-- The shell's own edits (blocks, their output, what it puts at the prompt)
-- are kept out of undo, so undo at the prompt takes back only typing, while
-- output streams in above it.
local OUT_OF_UNDO: { undo: boolean? } = { undo = false }

local function ns_block(block: Block): string
	return `shell.block.{block.uid}`
end

local function ns_out(block: Block): string
	return `shell.out.{block.uid}`
end

local function ns_ref(block: Block): string
	return `shell.ref.{block.uid}`
end

--- Where the prompt starts.
function M.prompt_start(shell: Shell): number
	return shell.prompt:pos() or shell.buffer:len()
end

--- What's typed at the prompt.
function M.prompt_text(shell: Shell): string
	local buffer = shell.buffer
	return buffer:slice(M.prompt_start(shell), buffer:len())
end

-- Follows the prompt from `pos`; typing at its start goes into it.
local function track_prompt(shell: Shell, pos: number)
	shell.prompt:forget()
	shell.prompt = shell.buffer:track(pos, { gravity = "left" })
end

--- Where the blocks end: where the strip starts, or else the prompt.
function M.blocks_end(shell: Shell): number
	local strip = shell.strip
	local at = strip and strip.at:pos()
	return at or M.prompt_start(shell)
end

-- The last block ends at `pos` now, so the strip, or else the prompt,
-- starts there.
local function end_blocks(shell: Shell, pos: number)
	local strip = shell.strip
	if strip then
		strip.at:forget()
		strip.at = shell.buffer:track(pos)
	else
		track_prompt(shell, pos)
	end
end

--- Puts `text` at the prompt, in place of what's there, with the cursor
--- of each of `views` at its end.
function M.set_prompt(shell: Shell, text: string, views: { greed.View }?)
	local buffer = shell.buffer
	local start = M.prompt_start(shell)
	buffer:edit(function(e)
		e:replace(start, buffer:len(), text)
	end, OUT_OF_UNDO)
	track_prompt(shell, start)
	if views then
		for _, view in views do
			view:set_cursor(buffer:len())
		end
	end
	M.draw_prompt(shell)
end

--- Whether `pos` is in the prompt.
function M.in_prompt(shell: Shell, pos: number): boolean
	return pos >= M.prompt_start(shell)
end

--- Where `block` is in the buffer: from its command to the start of the
--- next block (or the prompt); nil once its text was deleted.
function M.range(block: Block): (number?, number?)
	local range = block.range
	if range == nil or range:deleted() then
		return nil, nil
	end
	return range:range()
end

-- The first line of `block`'s output.
local function first_output_line(shell: Shell, block: Block, from: number): number
	return shell.buffer:line_of(from) + shown[block.uid].command
end

--- Where `block`'s output is: from its first line to the end of its last,
--- or nil when it has none or its text went.
function M.output_range(shell: Shell, block: Block): (number?, number?)
	local from, to = M.range(block)
	local s = shown[block.uid]
	if from == nil or to == nil or s == nil or s.stable + s.volatile == 0 then
		return nil, nil
	end
	local buffer = shell.buffer
	local first = first_output_line(shell, block, from)
	return buffer:line_start(first), math.max(buffer:line_start(first), to - 1)
end

--- The block whose text holds `pos`, if any; nil in the strip and the
--- prompt.
function M.block_at(shell: Shell, pos: number): Block?
	for _, block in shell.blocks do
		local from, to = M.range(block)
		if from and to and pos >= from and pos < to then
			return block
		end
	end
	return nil
end

--- The block whose line in the strip `pos` is on, if it's on one.
function M.strip_block(shell: Shell, pos: number): Block?
	local strip = shell.strip
	local at = strip and strip.at:pos()
	if strip == nil or at == nil or pos < at or pos >= M.prompt_start(shell) then
		return nil
	end
	local buffer = shell.buffer
	return strip.blocks[buffer:line_of(pos) - buffer:line_of(at) + 1]
end

--- The block whose text holds `pos`, or whose line in the strip it's on.
function M.block_for(shell: Shell, pos: number): Block?
	return M.strip_block(shell, pos) or M.block_at(shell, pos)
end

-- How long `ms` milliseconds is, shortly: 0.04s, 3.2s, 2m 05s.
local function duration(ms: number): string
	local seconds = ms / 1000
	if seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return string.format("%.1fs", seconds)
	end
	local whole = math.floor(seconds)
	return string.format("%dm %02ds", whole // 60, whole % 60)
end

--- What a block's status says after its command, e.g. "exit 1 · 0.31s".
function M.status_text(block: Block): string
	local parts: { string } = {}
	if block.status == "running" then
		table.insert(parts, duration(greed.now() - block.started))
	else
		if block.signal then
			table.insert(parts, block.signal)
		elseif block.code and block.code ~= 0 then
			table.insert(parts, `exit {block.code}`)
		end
		if block.finished then
			table.insert(parts, duration(block.finished - block.started))
		end
	end
	if block.cwd_after and block.cwd_after ~= block.cwd then
		table.insert(parts, `→ {core.project.tilde(block.cwd_after)}`)
	end
	if block.env_changed and next(block.env_changed) then
		local names: { string } = {}
		for name, value in block.env_changed do
			table.insert(names, if value == false then `-{name}` else name)
		end
		table.sort(names)
		table.insert(parts, table.concat(names, " "))
	end
	if block.into then
		table.insert(parts, `> {block.into}`)
	end
	local value = block.value
	if type(value) == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		local unit = if count > 0 and #value == 0 then "keys" else "items"
		table.insert(parts, `JSON · {count} {unit}`)
	end
	local tbl = block.table
	local view = block.shown
	if view then
		table.insert(parts, `{#view.rows} of {view.total} {if tbl then "rows" else "lines"}`)
		if view.filter ~= "" then
			table.insert(parts, `/ {view.filter}`)
		end
		if view.sort then
			table.insert(parts, `by {view.sort} {if view.desc then "↓" else "↑"}`)
		end
	elseif tbl and value == nil then
		local rows = #tbl.rows
		local called = block.called or { one = "row", many = "rows" }
		table.insert(parts, `table · {rows} {if rows == 1 then called.one else called.many}`)
	end
	if block.note then
		table.insert(parts, block.note)
	end
	if block.change and block.status == "running" then
		table.insert(parts, block.change)
	end
	if block.notify and block.status == "running" then
		table.insert(parts, "notifies")
	end
	if block.waiting and block.status == "running" then
		table.insert(parts, "waiting for input? ctrl-t types into it")
	end
	return table.concat(parts, " · ")
end

--- The glyph a block's status starts with.
function M.glyph(block: Block): string
	if block.handed and block.status ~= "running" then
		return "↗"
	end
	return GLYPH[block.status] or "?"
end

--- Draws `block`'s decorations again: its glyph, status and sign, the
--- blank line after it, and how many lines it leaves out.
function M.draw_block(shell: Shell, block: Block)
	local buffer = shell.buffer
	local from, to = M.range(block)
	if from == nil or to == nil then
		buffer:decorate(ns_block(block), {})
		return
	end
	local s = shown[block.uid]
	local line = buffer:line_of(from)
	local last = math.max(line, buffer:line_of(to) - 1)
	local style = STYLE[block.status] or "shell.status"
	local glyph = M.glyph(block)
	local status = M.status_text(block)
	-- Every mark here is empty, at a line's start or end, so none styles
	-- the command or the output: only its own text and lines.
	local line_end = buffer:line_end(line)
	local marks: { greed.Mark } = {
		{
			from = from,
			to = from,
			style = if block.by == "agent" then "shell.agent" else "shell.prompt",
			text = if block.by == "agent" then "◆ " else "❯ ",
		},
		-- Its number, for `$3`.
		{ from = from, to = from, style = "shell.number", text = `{block.number} ` },
		{
			from = line_end,
			to = line_end,
			style = style,
			sign = glyph,
			text = if status ~= "" then `{glyph} {status}` else glyph,
			eol = true,
		},
	}
	if block.omitted > 0 and s then
		local first = first_output_line(shell, block, from)
		local _, head = cap()
		local at = buffer:line_end(math.min(first + head - 1, last))
		local said = `… {block.omitted} lines not shown; :shell-output-open shows them all`
		table.insert(marks, { from = at, to = at, style = "shell.status", lines = { said } })
	end
	local after = buffer:line_end(last)
	table.insert(marks, { from = after, to = after, style = "shell.separator", lines = { "" } })
	buffer:decorate(ns_block(block), marks)
	M.draw_strip(shell)
end

-- What a live block shows now, in a few words: how many rows its table
-- shows (the ones its filter keeps) and what they are, or its first line.
local function summary(block: Block): string
	local tbl = block.table
	if tbl then
		local count = if block.shown then #block.shown.rows else #tbl.rows
		local called = block.called or { one = "row", many = "rows" }
		return `{count} {if count == 1 then called.one else called.many}`
	end
	local first = string.match(block.stdout, "^%s*([^\n]*)") or ""
	return if #first > 40 then string.sub(first, 1, 39) .. "…" else first
end

-- What the strip says of a running block: for a live one, what it shows
-- and what changed in it last; else how long it has run.
local function strip_status(block: Block): string
	if block.watching then
		local now = summary(block)
		return if block.change then `{now} · {block.change}` else now
	end
	return duration(greed.now() - block.started)
end

--- Draws the strip: a line between the blocks and the prompt for each
--- running block but the last, whose status shows right above the prompt
--- anyway, so the ones that scrolled up stay in reach. On its line, a
--- block's keys act on it, and `enter` (or a click on its number) opens it
--- in a float.
function M.draw_strip(shell: Shell)
	local buffer = shell.buffer
	local blocks: { Block } = {}
	local lines: { string } = {}
	for i, block in shell.blocks do
		if i < #shell.blocks and block.status == "running" and M.range(block) then
			table.insert(blocks, block)
			table.insert(lines, string.match(block.command, "^[^\n]*") or "")
		end
	end
	local text = if #lines > 0 then table.concat(lines, "\n") .. "\n" else ""
	local strip = shell.strip
	if text ~= (if strip then strip.text else "") then
		local start = M.blocks_end(shell)
		local prompt = M.prompt_start(shell)
		-- A cursor at the prompt stays where it was in what's typed.
		local views = buffer:views()
		local typed: { [number]: number } = {}
		for i, view in views do
			local cursor = view:cursor()
			if cursor >= prompt then
				typed[i] = cursor - prompt
			end
		end
		buffer:edit(function(e)
			e:replace(start, prompt, text)
		end, OUT_OF_UNDO)
		if strip then
			strip.at:forget()
		end
		shell.strip = if text == ""
			then nil
			else { at = buffer:track(start), blocks = blocks, text = text }
		track_prompt(shell, start + #text)
		for i, view in views do
			local offset = typed[i]
			if offset and view:valid() then
				view:set_cursor(start + #text + offset)
			end
		end
		M.draw_prompt(shell)
	elseif strip then
		strip.blocks = blocks
	end
	local marks: { greed.Mark } = {}
	local now = shell.strip
	local at = now and now.at:pos()
	if now and at then
		local first = buffer:line_of(at)
		for i, block in now.blocks do
			local from = buffer:line_start(first + i - 1)
			local to = buffer:line_end(first + i - 1)
			local glyph = M.glyph(block)
			table.insert(marks, {
				from = from,
				to = from,
				style = STYLE[block.status] or "shell.status",
				text = `{glyph} {block.number} `,
				action = "shell-peek",
			})
			table.insert(marks, { from = from, to = to, style = "shell.strip" })
			table.insert(marks, {
				from = to,
				to = to,
				style = "shell.status",
				text = `· {strip_status(block)}`,
				eol = true,
			})
		end
	end
	buffer:decorate("shell.strip", marks)
end

--- `path` short, as fish writes it: from "~" under the home folder, with
--- every folder but the last cut to its first letter, "~/D/greed".
function M.short_folder(path: string): string
	local parts = string.split(core.project.tilde(path), "/")
	for i = 1, #parts - 1 do
		local part = parts[i]
		-- A dot folder keeps its dot and first letter.
		local keep = if string.sub(part, 1, 1) == "." then 2 else 1
		parts[i] = string.sub(part, 1, (utf8.offset(part, keep + 1) or #part + 1) - 1)
	end
	return table.concat(parts, "/")
end

--- Draws the prompt: its segments (segments.luau), the shell's folder and
--- the glyph before what's typed, red after a warning segment, and in a
--- shell with no blocks yet, a line under it saying where help is.
function M.draw_prompt(shell: Shell)
	local buffer = shell.buffer
	local start = M.prompt_start(shell)
	local marks: { greed.Mark } = {}
	local warning = false
	local folder = true
	local segments = shell.segments
	if segments then
		for _, segment in segments do
			table.insert(marks, {
				from = start,
				to = start,
				style = segment.style or "shell.segment",
				text = if segment.tight then segment.text else segment.text .. " ",
			})
			warning = warning or segment.warning == true
			folder = folder and not segment.folder
		end
	end
	if folder then
		table.insert(marks, {
			from = start,
			to = start,
			style = "shell.cwd",
			text = M.short_folder(shell.cwd) .. " ",
		})
	elseif segments and #segments > 0 and segments[#segments].tight then
		table.insert(marks, { from = start, to = start, style = "shell.segment", text = " " })
	end
	table.insert(marks, {
		from = start,
		to = start,
		style = if warning then "shell.prompt.warning" else "shell.prompt",
		text = "❯ ",
	})
	if #shell.blocks == 0 then
		local stop = buffer:len()
		table.insert(marks, {
			from = stop,
			to = stop,
			style = "shell.status",
			lines = { "type help for what works here" },
		})
	end
	buffer:decorate("shell.prompt", marks)
end

-- Follows `block` from `from` to `to`.
local function track_block(shell: Shell, block: Block, from: number, to: number)
	if block.range then
		block.range:forget()
	end
	block.range = shell.buffer:track_range(from, to)
end

--- Adds `block` after the others, before the strip, and empties the
--- prompt. Its command is its text for now.
function M.add(shell: Shell, block: Block)
	local buffer = shell.buffer
	local start = M.blocks_end(shell)
	local text = block.command .. "\n"
	local strip = if shell.strip then shell.strip.text else ""
	buffer:edit(function(e)
		e:replace(start, buffer:len(), text .. strip)
	end, OUT_OF_UNDO)
	local _, breaks = string.gsub(block.command, "\n", "")
	shown[block.uid] = { command = breaks + 1, stable = 0, volatile = 0 }
	track_block(shell, block, start, start + #text)
	end_blocks(shell, start + #text)
	track_prompt(shell, start + #text + #strip)
	table.insert(shell.blocks, block)
	M.draw_block(shell, block)
	M.draw_prompt(shell)
end

-- The text of `lines`, each followed by a line break.
local function joined(lines: { Line }): string
	local parts: { string } = {}
	for _, line in lines do
		table.insert(parts, line.text)
	end
	if #parts == 0 then
		return ""
	end
	return table.concat(parts, "\n") .. "\n"
end

-- Adds `lines`' marks to `into`, placed as if the lines start at `pos`.
local function placed(lines: { Line }, pos: number, into: { greed.Mark })
	local at = pos
	for _, line in lines do
		if line.marks then
			for _, mark in line.marks do
				local moved: greed.Mark = table.clone(mark)
				moved.from += at
				moved.to += at
				table.insert(into, moved)
			end
		end
		at += #line.text + 1
	end
end

--- Of `count` lines `block` printed next, how many fill its head, and how
--- many after those it would leave out at once, past the cap: only the
--- rest need making into lines for `update`.
function M.room(block: Block, count: number): (number, number)
	local s = shown[block.uid]
	local max, head = cap()
	local stable = if s then s.stable else 0
	local fill = math.min(math.max(head - stable, 0), count)
	return fill, math.max(count - fill - (max - head), 0)
end

--- Shows more of `block`'s output: `add` joins the stable lines, and
--- `volatile` replaces the volatile ones (nil keeps them). `skipped` lines
--- came between `add`'s first `room` and the rest, already left out. Lines
--- past `shell-max-lines` are left out, oldest first after the first half;
--- `block.lines` and `block.omitted` count them.
function M.update(shell: Shell, block: Block, add: { Line }, volatile: { Line }?, skipped: number?)
	local s = shown[block.uid]
	local from, to = M.range(block)
	local skip = skipped or 0
	if s == nil or from == nil or to == nil or (volatile == nil and #add == 0 and skip == 0) then
		return
	end
	local buffer = shell.buffer
	local max, head = cap()
	local first = first_output_line(shell, block, from)
	local last_block = M.blocks_end(shell) == to
	-- Lines going into the head, which stays, then the rest; past the cap,
	-- the oldest after the head go, from those shown and then from `add`.
	local total = s.stable + #add + skip
	local excess = math.max(total - max, 0)
	local drop_shown = math.min(excess, math.max(s.stable - head, 0))
	local fill = math.max(head - s.stable, 0)
	local drop_added = math.max(excess - drop_shown - skip, 0)
	-- `add` without the lines that go: those after the ones filling the
	-- head.
	local kept: { Line } = {}
	for i, line in add do
		if i <= fill or i > fill + drop_added then
			table.insert(kept, line)
		end
	end
	block.lines += #add + skip
	block.omitted += excess
	local volatile_from = if s.stable + s.volatile == 0
		then to
		else buffer:line_start(first + s.stable)
	local replace_to = if volatile then to else volatile_from
	local dropped = if drop_shown > 0
		then buffer:line_start(first + head + drop_shown) - buffer:line_start(first + head)
		else 0
	local stable_text = joined(kept)
	local text = stable_text .. (if volatile then joined(volatile) else "")
	buffer:edit(function(e)
		if drop_shown > 0 then
			e:delete(buffer:line_start(first + head), buffer:line_start(first + head + drop_shown))
		end
		e:replace(volatile_from, replace_to, text)
	end, OUT_OF_UNDO)
	s.stable = s.stable - drop_shown + #kept
	if volatile then
		s.volatile = #volatile
	end
	-- Where `text` went, and where the block ends now.
	local start = buffer:line_start(first + s.stable - #kept)
	local stop = to - dropped - (replace_to - volatile_from) + #text
	track_block(shell, block, from, stop)
	if last_block then
		end_blocks(shell, stop)
	end
	local marks: { greed.Mark } = {}
	placed(kept, start, marks)
	if volatile then
		placed(volatile, start + #stable_text, marks)
	end
	buffer:decorate(ns_out(block), marks, {
		from = start,
		to = if volatile then nil else start + #stable_text,
	})
	M.draw_block(shell, block)
	if last_block then
		M.draw_prompt(shell)
	end
end

--- The lines of `block`'s output as the buffer shows them, with their
--- styles, for a finished block.
function M.output_lines(shell: Shell, block: Block): { Line }
	local from, to = M.output_range(shell, block)
	if from == nil or to == nil then
		return {}
	end
	local buffer = shell.buffer
	local first, last = buffer:line_of(from), buffer:line_of(to)
	local lines: { Line } = {}
	for line = first, last do
		lines[line - first + 1] = { text = buffer:line_text(line), marks = {} }
	end
	for _, mark in buffer:decorations(ns_out(block)) do
		local line = buffer:line_of(mark.from)
		local into = lines[line - first + 1]
		local marks = into and into.marks
		if marks then
			local start = buffer:line_start(line)
			local moved: greed.Mark = table.clone(mark)
			moved.from -= start
			moved.to = math.min(mark.to, buffer:line_end(line)) - start
			table.insert(marks, moved)
		end
	end
	return lines
end

--- Shows `lines` as `block`'s output in place of what it shows, for a
--- finished block, like the rows a filter kept of its table, or a live
--- one (`watch`) showing what it got this time.
function M.replace_output(shell: Shell, block: Block, lines: { Line })
	local s = shown[block.uid]
	local from, to = M.range(block)
	local streaming = block.status == "running" and block.watching == nil
	if s == nil or from == nil or to == nil or streaming then
		return
	end
	local buffer = shell.buffer
	local last_block = M.blocks_end(shell) == to
	local start = if s.stable + s.volatile == 0
		then to
		else buffer:line_start(first_output_line(shell, block, from))
	local text = joined(lines)
	buffer:edit(function(e)
		e:replace(start, to, text)
	end, OUT_OF_UNDO)
	s.stable, s.volatile = #lines, 0
	local stop = start + #text
	track_block(shell, block, from, stop)
	if last_block then
		end_blocks(shell, stop)
	end
	local marks: { greed.Mark } = {}
	placed(lines, start, marks)
	buffer:decorate(ns_out(block), marks)
	M.draw_refs(shell, block)
	M.draw_block(shell, block)
	if last_block then
		M.draw_prompt(shell)
	end
end

--- The places in files `block`'s output names, like `src/main.rs:12:5`,
--- with paths from the folder it ran in, as the buffer has them now.
function M.references(shell: Shell, block: Block): { terminal.Reference }
	local from, to = M.output_range(shell, block)
	if from == nil or to == nil then
		return {}
	end
	return terminal.references(shell.buffer, { from = from, to = to, cwd = block.cwd })
end

--- Shows the places in files `block`'s output names as links, and returns
--- them.
function M.draw_refs(shell: Shell, block: Block): { Ref }
	local marks: { greed.Mark } = {}
	local refs: { Ref } = {}
	for _, ref in M.references(shell, block) do
		table.insert(marks, { from = ref.from, to = ref.to, style = "markup.link" })
		table.insert(refs, { path = ref.path, line = ref.line, col = ref.col, text = ref.text })
	end
	shell.buffer:decorate(ns_ref(block), marks)
	return refs
end

--- The places in files every block's output in `shell` names, in order.
function M.all_references(shell: Shell): { terminal.Reference }
	local list: { terminal.Reference } = {}
	for _, block in shell.blocks do
		for _, ref in M.references(shell, block) do
			table.insert(list, ref)
		end
	end
	return list
end

--- Takes `block` out of the buffer, with its decorations.
function M.remove(shell: Shell, block: Block)
	local from, to = M.range(block)
	local buffer = shell.buffer
	if from and to then
		local was_last = M.blocks_end(shell) == to
		buffer:edit(function(e)
			e:delete(from, to)
		end, OUT_OF_UNDO)
		if was_last then
			end_blocks(shell, from)
		end
	end
	if block.range then
		block.range:forget()
		block.range = nil
	end
	buffer:decorate(ns_block(block), {})
	buffer:decorate(ns_out(block), {})
	buffer:decorate(ns_ref(block), {})
	shown[block.uid] = nil
	local index = table.find(shell.blocks, block)
	if index then
		table.remove(shell.blocks, index)
	end
	M.draw_strip(shell)
	M.draw_prompt(shell)
end

--- Forgets what's shown for blocks of a buffer that closed.
function M.forget(shell: Shell)
	for _, block in shell.blocks do
		shown[block.uid] = nil
	end
end

--- The first and last line of the block around `line` in `shell`, for
--- folding its output under its command; nil without output.
function M.fold(shell: Shell, line: number): (number?, number)
	local buffer = shell.buffer
	local pos = buffer:line_start(line)
	local block = M.block_at(shell, pos)
	if block == nil then
		return nil, line
	end
	local from, to = M.range(block)
	if from == nil or to == nil then
		return nil, line
	end
	local top = buffer:line_of(from)
	local bottom = buffer:line_of(to) - 1
	if bottom <= top then
		return nil, line
	end
	return top, bottom
end

--- Where the block before (`back`) or after the cursor's line starts.
function M.neighbor(shell: Shell, pos: number, back: boolean): number?
	local buffer = shell.buffer
	local line = buffer:line_of(pos)
	local found: number? = nil
	for _, block in shell.blocks do
		local from = M.range(block)
		if from then
			local at = buffer:line_of(from)
			if back and at < line then
				found = from
			elseif not back and at > line then
				return from
			end
		end
	end
	if not back and found == nil and M.prompt_start(shell) > pos then
		return M.prompt_start(shell)
	end
	return found
end

return M
