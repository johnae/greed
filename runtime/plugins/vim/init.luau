-- Vim-style editing, written only against the plugin API. It has modes of
-- its own (vim, vim-insert, vim-replace and the three visual modes), beside
-- Helix's, and says which plays each role: keys other plugins bind for the
-- command role (the language server's, the next change) and the leader
-- (`space`) work here as in every style.
--
-- Switch to it with `:style vim`, or put this in ~/.config/greed/init.luau:
--
--     require("@greed").option.set("editing-style", "vim")
--
-- It reads in this order: common.luau, text helpers; motions.luau, the
-- motions (one table, each saying how an operator takes its range) and
-- marks; objects.luau, ranges and text objects; operators.luau, operators
-- applied through `apply` and the line and case tables; visual.luau, the
-- visual modes (block mode keeps a selection per line), with the commands
-- for motions and operators; then this file, with insert, replace, the
-- change list and U; keys.luau last. Ex commands (:s, :g, ranges) are the
-- command line plugin's, and `.` is core's.

local greed = require("@greed")
local core = require("@core")
local common = require("@self/common")
local motions_module = require("@self/motions")
local objects = require("@self/objects")
local operators = require("@self/operators")
local visual_module = require("@self/visual")

type Buffer = greed.Buffer
type Kind = common.Kind

local command, cursor, on_char, point = common.command, common.cursor, common.on_char, common.point
local line_bounds = common.line_bounds
local motions, set_mark, mark_place =
	motions_module.motions, motions_module.set_mark, motions_module.mark_place
local motion_range, select_word = objects.motion_range, objects.select_word
local apply, enter_insert, insert_repeat =
	operators.apply, operators.enter_insert, operators.insert_repeat
local to_paste = operators.to_paste
local block = visual_module.block

-- Shorthands for an operator and a motion: x is dl, D is d$, and so on.
local function shorthand(name: string, op: string, key: string, doc: string)
	command(name, doc, function(ctx)
		local buffer, pos = ctx.buffer, cursor(ctx)
		local target: number?, kind: Kind = motions[key](buffer, pos, ctx.count or 1)
		if target == nil or (target == pos and kind == "exclusive") then
			return
		end
		apply(ctx, op, motion_range(buffer, pos, target :: number, kind))
	end)
end
shorthand("delete-char", "d", "l", "Delete the character under the cursor")
shorthand("delete-char-before", "d", "h", "Delete the character before the cursor")
shorthand("delete-to-end", "d", "$", "Delete to the end of the line")
shorthand("change-to-end", "c", "$", "Change to the end of the line")
shorthand("substitute", "c", "l", "Change the character under the cursor")

command("change-line", "Change the whole line", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local line = buffer:line_of(pos)
	greed.history.start_group()
	local from, to =
		core.text.first_non_blank(buffer, buffer:line_start(line)), buffer:line_end(line)
	buffer:edit(function(e)
		e:delete(from, to)
	end)
	enter_insert(ctx, from)
end)

local function paste(ctx: greed.Context, after: boolean)
	local from = to_paste(ctx)
	if from == nil then
		return
	end
	local buffer, pos = ctx.buffer, cursor(ctx)
	local text = string.rep(from.text, ctx.count or 1)
	local at: number
	if from.linewise then
		local line = buffer:line_of(pos)
		if after then
			at = if line + 1 < buffer:line_count()
				then buffer:line_start(line + 1)
				else buffer:len()
			local br = string.match(text, "\r?\n$")
			if br and at == buffer:len() and buffer:char_at(at - 1) ~= "\n" then
				text = br .. string.sub(text, 1, -#br - 1)
			end
		else
			at = buffer:line_start(line)
		end
	else
		at = if after
			then math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos)))
			else pos
	end
	buffer:edit(function(e)
		e:insert(at, text)
	end)
	if from.linewise then
		local br = string.match(text, "^\r?\n") or ""
		ctx.view:set_cursor(core.text.first_non_blank(buffer, at + #br))
	else
		ctx.view:set_cursor(buffer:prev_char(at + #text))
	end
end

command("paste-after", "Paste after the cursor, or below the line", function(ctx)
	paste(ctx, true)
end)
command("paste-before", "Paste before the cursor, or above the line", function(ctx)
	paste(ctx, false)
end)

-- Starts typing at `pos` as one undo step, typed the count's times over.
local function start_insert(ctx: greed.Context, pos: number)
	greed.history.start_group()
	enter_insert(ctx, pos)
	insert_repeat.count = ctx.count or 1
end

command("insert", "Insert before the cursor", function(ctx)
	start_insert(ctx, cursor(ctx))
end)
command("append", "Insert after the cursor", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	start_insert(ctx, math.min(buffer:next_char(pos), buffer:line_end(buffer:line_of(pos))))
end)
command("insert-line-start", "Insert at the first non-blank of the line", function(ctx)
	start_insert(ctx, core.text.first_non_blank(ctx.buffer, cursor(ctx)))
end)
command("append-line-end", "Insert at the end of the line", function(ctx)
	start_insert(ctx, ctx.buffer:line_end(ctx.buffer:line_of(cursor(ctx))))
end)
command("insert-last", "Insert where insert mode was last left", function(ctx)
	start_insert(ctx, mark_place(ctx.buffer, "^") or cursor(ctx))
end)

local function open_line(ctx: greed.Context, below: boolean)
	greed.history.start_group()
	core.indent.open(ctx.view, below)
	enter_insert(ctx, cursor(ctx))
	insert_repeat.count, insert_repeat.open = ctx.count or 1, true
end
command("open-below", "Open a line below and insert", function(ctx)
	open_line(ctx, true)
end)
command("open-above", "Open a line above and insert", function(ctx)
	open_line(ctx, false)
end)

command("insert-one", "Run one normal mode command, then go on typing", function(ctx)
	local before = ctx.view:selection()
	greed.mode.set("vim")
	local keys: string?, count: number? = nil, nil
	while true do
		local key = greed.next_key()
		if keys == nil and string.match(key, "^%d$") and (count or key ~= "0") then
			count = (count or 0) * 10 + (tonumber(key) :: number)
		else
			keys = if keys then keys .. " " .. key else key
			local name, more = greed.keymap.resolve(keys :: string)
			if name then
				greed.run(name, { count = count })
				break
			elseif not more then
				break
			end
		end
	end
	-- Back to typing, unless the command went to another mode. A command that
	-- didn't move leaves the cursor where typing was, even past the line's end.
	if greed.mode.get() == "vim" then
		local after = ctx.view:selection()
		local moved = after.ranges[1].head ~= before.ranges[1].head
			or after.ranges[1].anchor ~= before.ranges[1].anchor
		greed.mode.set("vim-insert")
		ctx.view:set_selection(if moved then point(cursor(ctx)) else before)
	end
end)

-- R's replace mode: what each typed character took the place of, put back
-- by backspace.
local replaced: { { pos: number, text: string } } = {}

command("replace-mode", "Type over the text", function(ctx)
	greed.history.start_group()
	replaced = {}
	ctx.view:set_cursor(cursor(ctx))
	greed.mode.set("vim-replace")
end)

command("replace-typed", "Type over the character under the cursor", function(ctx)
	local char = ctx.char
	if char == nil then
		return
	end
	local buffer, pos = ctx.buffer, cursor(ctx)
	local _, _, finish = line_bounds(buffer, pos)
	local to = if pos < finish then buffer:next_char(pos) else pos
	table.insert(replaced, { pos = pos, text = buffer:slice(pos, to) })
	buffer:edit(function(e)
		e:replace(pos, to, char)
		e:select(point(pos + #char))
	end)
end)

command("replace-back", "Put back the character typed over last, or move left", function(ctx)
	local buffer, pos = ctx.buffer, cursor(ctx)
	local last = table.remove(replaced)
	if last == nil then
		local _, start = line_bounds(buffer, pos)
		if pos > start then
			ctx.view:set_cursor(buffer:prev_char(pos))
		end
		return
	end
	buffer:edit(function(e)
		e:replace(last.pos, pos, last.text)
		e:select(point(last.pos))
	end)
end)

-- U puts back the line changes were last made on as it was before them.
-- Before each command the cursor's line is noted; a change that keeps to
-- that line, after others on it, keeps the first note.
type LineNote = { buffer: number, line: number, text: string, lines: number }
local before: LineNote? = nil
local line_undo: LineNote? = nil
-- Set while U changes the line, which isn't a change for it to note.
local undoing_line = false

local function cursor_line_note(view: greed.View): LineNote
	local buffer = view:buffer()
	local line = buffer:line_of(math.min(view:cursor(), buffer:len()))
	return {
		buffer = buffer:id(),
		line = line,
		text = buffer:line_text(line),
		lines = buffer:line_count(),
	}
end

greed.on("command.run", function()
	before = cursor_line_note(greed.view())
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	if undoing_line or view:buffer() ~= event.buffer then
		return
	end
	local now = cursor_line_note(view)
	local b = before
	if b == nil or b.buffer ~= now.buffer or b.line ~= now.line or b.lines ~= now.lines then
		line_undo = nil
	elseif line_undo == nil or line_undo.buffer ~= b.buffer or line_undo.line ~= b.line then
		line_undo = b
	end
end)

command("undo-line", "Put back the line last changed as it was before (U)", function(ctx)
	local u, buffer = line_undo, ctx.buffer
	if u == nil or u.buffer ~= buffer:id() or u.line >= buffer:line_count() then
		return
	end
	local from, to = buffer:line_start(u.line), buffer:line_end(u.line)
	-- U again puts the changes back.
	line_undo = { buffer = u.buffer, line = u.line, text = buffer:slice(from, to), lines = u.lines }
	undoing_line = true
	buffer:edit(function(e)
		e:replace(from, to, u.text)
	end)
	undoing_line = false
	ctx.view:set_cursor(from)
end)

-- The change list for g; and g,: where the last changes in each buffer
-- were, by buffer id, tracked so they move with edits, oldest first.
local CHANGES = 100
local change_lists: { [number]: { greed.Anchor } } = {}
-- How far back g; has gone in each buffer, by its id; 0 is past the newest.
local changes_back: { [number]: number } = {}

local function changes(buffer: Buffer): { greed.Anchor }
	local list = change_lists[buffer:id()] or {}
	change_lists[buffer:id()] = list
	return list
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	local buffer = event.buffer
	if view:buffer() ~= buffer then
		return
	end
	local pos = math.min(view:cursor(), buffer:len())
	local list = changes(buffer)
	-- Another change on the same line takes the place of the last one.
	local newest = list[#list]
	local newest_pos = newest and newest:pos()
	local dropped = if newest_pos and buffer:line_of(newest_pos) == buffer:line_of(pos)
		then table.remove(list)
		elseif #list >= CHANGES then table.remove(list, 1)
		else nil
	if dropped then
		dropped:forget()
	end
	table.insert(list, buffer:track(pos))
	changes_back[buffer:id()] = 0
end)

greed.on("buffer.closed", function(event: greed.BufferClosed)
	change_lists[event.id], changes_back[event.id] = nil, nil
end)

-- g; and g,: to an older change, or back to a newer one.
for _, newer in { false, true } do
	command(
		if newer then "change-newer" else "change-older",
		if newer
			then "Go to a newer place in the change list"
			else "Go to an older place in the change list",
		function(ctx)
			local buffer = ctx.buffer
			local list = changes(buffer)
			local back = (changes_back[buffer:id()] or 0)
				+ (ctx.count or 1) * (if newer then -1 else 1)
			local change = list[#list - back + 1]
			local pos = change and change:pos()
			if back < 1 or pos == nil then
				greed.echo(if newer then "at the newest change" else "at the oldest change")
				return
			end
			changes_back[buffer:id()] = back
			ctx.view:set_cursor(on_char(buffer, pos))
		end
	)
end

-- Types what 3i or 3o typed twice more, ending at `pos`. Returns where the
-- cursor goes.
local function repeat_insert(buffer: Buffer, pos: number): number
	local times, start = insert_repeat.count - 1, insert_repeat.start
	insert_repeat.count = 1
	if times < 1 or pos <= start then
		return pos
	end
	local text = if insert_repeat.open
		then "\n" .. buffer:slice(buffer:line_start(buffer:line_of(start)), pos)
		else buffer:slice(start, pos)
	local typed = string.rep(text, times)
	buffer:edit(function(e)
		e:insert(pos, typed)
	end)
	return pos + #typed
end

-- Whether insert mode was entered from ctrl-n's cursors, which esc goes
-- back to, as in vim-visual-multi.
local typing_from_multi = false

-- Leaving insert mode steps back onto the last character typed.
local function step_back(buffer: Buffer, pos: number): number
	local _, start = line_bounds(buffer, pos)
	return if pos > start then buffer:prev_char(pos) else pos
end

command("normal", "Back to normal mode", function(ctx)
	local mode = greed.mode.get()
	local buffer = ctx.buffer
	local selection = ctx.view:selection()
	if mode == "vim-insert" and typing_from_multi and #selection.ranges > 1 then
		typing_from_multi = false
		greed.history.end_group()
		for i, range in selection.ranges do
			local at = on_char(buffer, step_back(buffer, range.head))
			selection.ranges[i] = { anchor = at, head = at }
		end
		ctx.view:set_selection(selection)
		greed.mode.set("vim-multi")
		return
	end
	typing_from_multi = false
	local pos = if mode == "vim-visual-block" then block.cursor else cursor(ctx)
	if mode == "vim-insert" or mode == "vim-replace" then
		if mode == "vim-insert" then
			pos = repeat_insert(buffer, pos)
		end
		set_mark(buffer, "^", pos)
		pos = step_back(buffer, pos)
	end
	greed.history.end_group()
	greed.mode.set("vim")
	ctx.view:set_cursor(on_char(buffer, pos))
end)

-- alt-o and alt-i: Helix's growing and shrinking by syntax node, which
-- goes on in visual mode.
for _, grow in { true, false } do
	command(
		if grow then "expand-selection" else "shrink-selection",
		if grow
			then "Select the syntax node around the cursor or selection, in visual mode"
			else "Shrink the selection back, or to the first syntax node inside it",
		function()
			greed.run(if grow then "expand-selection" else "shrink-selection")
			if greed.mode.get() == "vim" then
				greed.mode.set("vim-visual")
			end
		end
	)
end

command("jump-to-word", "Label every word on screen and jump to the one typed", function(ctx)
	local from = core.jump.pick(ctx.view)
	if from then
		ctx.view:set_cursor(from)
	end
end)

-- ctrl-n's multiple cursors, as vim-visual-multi has them: ctrl-n selects
-- the word under the cursor, then adds its next match each time; c d y i a
-- I A act on every selection, esc after typing keeps the cursors, and esc
-- with them goes back to one cursor.
command("multi-next", "Select the word under the cursor, or add its next match", function(ctx)
	if greed.mode.get() ~= "vim-multi" then
		select_word(ctx)
		greed.run("search-selection")
		greed.mode.set("vim-multi")
		return
	end
	greed.run("search-next-add")
end)

command("multi-skip", "Drop this match and add the next one instead", function(ctx)
	local skipped = ctx.view:selection()
	local old = skipped.ranges[skipped.primary]
	greed.run("search-next-add")
	local selection = ctx.view:selection()
	if #selection.ranges == #skipped.ranges then
		return
	end
	for i, range in selection.ranges do
		if range.anchor == old.anchor and range.head == old.head then
			table.remove(selection.ranges, i)
			if selection.primary > i then
				selection.primary -= 1
			end
			break
		end
	end
	ctx.view:set_selection(selection)
end)

command("multi-back", "Drop the match added last", function(ctx)
	if #ctx.view:selection().ranges == 1 then
		greed.run("vim-normal")
		return
	end
	greed.run("remove-primary")
end)

-- Back to one cursor, at the primary selection's start.
local function leave_multi(ctx: greed.Context)
	local selection = ctx.view:selection()
	local range = selection.ranges[selection.primary]
	greed.mode.set("vim")
	ctx.view:set_cursor(on_char(ctx.buffer, (core.text.span(range))))
end

command("multi-change", "Delete every selection and type in each place", function()
	greed.history.start_group()
	greed.run("delete")
	typing_from_multi = true
	greed.mode.set("vim-insert")
end)
command("multi-delete", "Delete every selection", function(ctx)
	greed.run("delete")
	leave_multi(ctx)
end)
command("multi-copy", "Copy every selection", function(ctx)
	greed.run("copy")
	leave_multi(ctx)
end)

for _, at_end in { false, true } do
	command(
		if at_end then "multi-append" else "multi-insert",
		if at_end then "Type after every selection" else "Type before every selection",
		function(ctx)
			local selection = ctx.view:selection()
			for i, range in selection.ranges do
				local from, to = core.text.span(range)
				-- A cursor, as esc after typing leaves, appends after its character.
				if at_end and to == from then
					local _, _, finish = line_bounds(ctx.buffer, from)
					to = math.min(ctx.buffer:next_char(from), finish)
				end
				local pos = if at_end then to else from
				selection.ranges[i] = { anchor = pos, head = pos }
			end
			greed.history.start_group()
			ctx.view:set_selection(selection)
			typing_from_multi = true
			greed.mode.set("vim-insert")
		end
	)
end

-- ctrl-a and ctrl-x: core's, leaving the cursor on the number's last digit.
for _, down in { false, true } do
	local name = if down then "decrement" else "increment"
	local doc = if down
		then "Subtract the count (or 1) from the number at or after the cursor"
		else "Add the count (or 1) to the number at or after the cursor"
	command(name, doc, function(ctx)
		greed.run(name, { count = ctx.count })
		local from, to = core.text.span(ctx.view:selection().ranges[1])
		if to > from then
			ctx.view:set_cursor(ctx.buffer:prev_char(to))
		end
	end)
end

command("quit-unsaved", "Close without saving (ZQ)", function()
	greed.run("quit", { force = true })
end)

command(
	"mark",
	"Set the mark typed next (a to z here, A to Z across files) at the cursor",
	function(ctx)
		local name = greed.next_key()
		if string.match(name, "^%a$") then
			set_mark(ctx.buffer, name, cursor(ctx))
		end
	end
)

-- The register the last macro played from, for @@.
local last_macro: string? = nil

command("macro", "Record a macro into the register typed next, or stop recording", function(ctx)
	if core.registers.recording() then
		core.registers.toggle_recording("", ctx.keys)
		return
	end
	local name = greed.next_key()
	if utf8.len(name) == 1 then
		core.registers.toggle_recording(name)
	end
end)

command(
	"play-macro",
	"Play the macro in the register typed next; @@ plays the last one again",
	function(ctx)
		local name = greed.next_key()
		if name == "@" then
			name = last_macro or ""
		end
		if utf8.len(name) ~= 1 then
			return
		end
		last_macro = name
		core.registers.play(name, ctx.count)
	end
)

command(
	"replace-char",
	"Replace the character under the cursor with the next one typed",
	function(ctx)
		local char = greed.next_key()
		if utf8.len(char) ~= 1 then
			return
		end
		local buffer, pos = ctx.buffer, cursor(ctx)
		local count = ctx.count or 1
		local _, _, finish = line_bounds(buffer, pos)
		local to = pos
		for _ = 1, count do
			if to >= finish then
				return
			end
			to = buffer:next_char(to)
		end
		buffer:edit(function(e)
			e:replace(pos, to, string.rep(char, count))
		end)
		ctx.view:set_cursor(pos + (count - 1) * #char)
	end
)

command(
	"switch-case",
	"Switch the case of the character under the cursor and move on",
	function(ctx)
		local buffer, pos = ctx.buffer, cursor(ctx)
		local _, _, finish = line_bounds(buffer, pos)
		local stop = pos
		for _ = 1, ctx.count or 1 do
			if stop < finish then
				stop = buffer:next_char(stop)
			end
		end
		-- One edit, so it undoes in one step.
		local swapped = string.gsub(buffer:slice(pos, stop), "%a", function(c)
			return if string.match(c, "%l") then string.upper(c) else string.lower(c)
		end)
		buffer:edit(function(e)
			e:replace(pos, stop, swapped)
		end)
		pos = stop
		ctx.view:set_cursor(on_char(buffer, pos))
	end
)

-- Joins `times` lines onto `line`, each with one space, or as they are
-- with `raw` (gJ).
local function join(ctx: greed.Context, line: number, times: number, raw: boolean?)
	local buffer = ctx.buffer
	local at = cursor(ctx)
	-- One undo step however many lines it joins.
	greed.history.start_group()
	for _ = 1, times do
		if line + 1 >= buffer:line_count() then
			break
		end
		local stop = buffer:line_end(line)
		local next_start = buffer:line_start(line + 1)
		local next_text = buffer:slice(next_start, buffer:line_end(line + 1))
		local lead = if raw then 0 else #(string.match(next_text, "^%s*") :: string)
		buffer:edit(function(e)
			e:replace(stop, next_start + lead, if raw then "" else " ")
		end)
		at = stop
	end
	greed.history.end_group()
	ctx.view:set_cursor(at)
end

for _, raw in { false, true } do
	command(
		if raw then "join-raw" else "join",
		if raw
			then "Join the next line onto this one as it is"
			else "Join the next line onto this one, with one space",
		function(ctx)
			join(ctx, ctx.buffer:line_of(cursor(ctx)), math.max((ctx.count or 2) - 1, 1), raw)
		end
	)
end

-- The first and last line the selection touches.
local function selected_lines(ctx: greed.Context): (number, number)
	local buffer, ranges = ctx.buffer, ctx.view:selection().ranges
	local from = core.text.span(ranges[1])
	local _, to = core.text.span(ranges[#ranges])
	return buffer:line_of(from), buffer:line_of(math.max(from, to - 1))
end

command("visual-join", "Join the selected lines, with one space", function(ctx)
	local first, last = selected_lines(ctx)
	greed.mode.set("vim")
	join(ctx, first, math.max(last - first, 1))
end)

-- * and # search for the word under the cursor, forward or back.
for _, back in { false, true } do
	command(
		if back then "search-word-back" else "search-word",
		"Search for the word under the cursor",
		function(ctx)
			select_word(ctx)
			greed.run("search-selection")
			greed.run(if back then "search-prev" else "search-next")
			local range = ctx.view:selection().ranges[1]
			ctx.view:set_cursor((core.text.span(range)))
		end
	)
end

command("undo", "Undo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:undo()
	end
	ctx.view:set_cursor(on_char(ctx.buffer, cursor(ctx)))
end)
command("redo", "Redo", function(ctx)
	for _ = 1, ctx.count or 1 do
		ctx.view:redo()
	end
end)

-- `.` is core's, which types the last change's keys again.
core.commands.tag(
	"no-repeat",
	{ "vim-undo", "vim-redo", "vim-undo-line", "vim-macro", "vim-play-macro" }
)
core.commands.tag("typing", { "vim-replace-typed" })
core.search.start_at_match("vim")
for _, name in
	{
		"vim-motion-G",
		"vim-motion-gg",
		"vim-motion-%",
		"vim-motion-'",
		"vim-motion-`",
		"vim-search-word",
		"vim-search-word-back",
	}
do
	core.jumps.add(name)
end

require("@self/keys")

return {}
