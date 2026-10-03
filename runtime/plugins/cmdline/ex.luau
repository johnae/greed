-- Vim's Ex commands that work on lines: :s, :d, :y, :m, :t, :norm. They
-- act on the lines the selection touches, which a range before them
-- (`:%s/a/b/g`, `:5,10d`) sets.

local greed = require("@greed")
local core = require("@core")

local M = {}

-- The first and last line the primary selection touches.
function M.selected_lines(view: greed.View): (number, number)
	local buffer, selection = view:buffer(), view:selection()
	local range = selection.ranges[selection.primary]
	local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
	return buffer:line_of(from), buffer:line_of(math.max(from, to - 1))
end

-- Lines `first` to `last` and the line break after them (or before them,
-- at the end of the buffer), as a byte range.
local function whole_lines(buffer: greed.Buffer, first: number, last: number): (number, number)
	local from, to = buffer:line_start(first), buffer:line_end(last)
	if to < buffer:len() then
		to += 1
	elseif from > 0 then
		from -= 1
	end
	return from, to
end

-- The text of lines `first` to `last`, without the last line break.
local function lines_text(buffer: greed.Buffer, first: number, last: number): string
	return buffer:slice(buffer:line_start(first), buffer:line_end(last))
end

-- Puts the cursor on the first non-blank of `line`.
local function go_to_line(view: greed.View, line: number)
	local buffer = view:buffer()
	local start = buffer:line_start(line)
	local text = buffer:slice(start, buffer:line_end(line))
	local pos = start + #(string.match(text, "^%s*") :: string)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end
M.go_to_line = go_to_line

-- `replacement` with Vim's escapes filled in from a match: `&` and `\0`
-- are the whole match, `\1` to `\9` its groups, `\n` a line break, `\t` a
-- tab, and a backslash before anything else takes it as is.
local function expand(
	replacement: string,
	buffer: greed.Buffer,
	groups: { { from: number, to: number } | false }
): string
	local out = {}
	local function group(n: number): string
		local span = groups[n + 1]
		return if span then buffer:slice(span.from, span.to) else ""
	end
	local i = 1
	while i <= #replacement do
		local c = string.sub(replacement, i, i)
		if c == "\\" and i < #replacement then
			local after = string.sub(replacement, i + 1, i + 1)
			table.insert(
				out,
				if string.match(after, "%d")
					then group(tonumber(after) :: number)
					elseif after == "n" then "\n"
					elseif after == "t" then "\t"
					else after
			)
			i += 2
		else
			table.insert(out, if c == "&" then group(0) else c)
			i += 1
		end
	end
	return table.concat(out)
end

greed.command({
	name = "substitute",
	doc = "Replace a regex with text on the selected lines (:s/regex/text/flags)",
	args = { { name = "regex" }, { name = "replacement" }, { name = "flags" } },
	run = function(ctx)
		local buffer = ctx.buffer
		local pattern = ctx.args[1] or ""
		local replacement = ctx.args[2] or ""
		local flags = ctx.args[3] or ""
		if pattern == "" then
			pattern = core.search.last() or ""
			if pattern == "" then
				error("no pattern to substitute", 0)
			end
		end
		local all = string.find(flags, "g", 1, true) ~= nil
		local regex = "(?m)"
			.. (
				if string.find(flags, "i", 1, true)
					then "(?i)" .. pattern
					elseif string.find(flags, "I", 1, true) then pattern
					else core.search.smart_case(pattern)
			)
		local first, last = M.selected_lines(ctx.view)
		local edits: { { from: number, to: number, text: string } } = {}
		local changed_lines, last_changed = 0, first
		for line = first, last do
			local found, err =
				buffer:find_groups(regex, buffer:line_start(line), buffer:line_end(line))
			if found == nil then
				error(err, 0)
			end
			for i, groups in found do
				local whole = groups[1]
				if whole and (all or i == 1) then
					table.insert(edits, {
						from = whole.from,
						to = whole.to,
						text = expand(replacement, buffer, groups),
					})
				end
			end
			if #found > 0 then
				changed_lines += 1
				last_changed = line
			end
		end
		if #edits == 0 then
			error(`pattern not found: {pattern}`, 0)
		end
		if string.find(flags, "n", 1, true) then
			greed.echo(`{#edits} matches on {changed_lines} lines`)
			return
		end
		buffer:edit(function(e)
			for _, edit in edits do
				e:replace(edit.from, edit.to, edit.text)
			end
		end)
		-- Line breaks put in move the last changed line down.
		for _, edit in edits do
			local _, breaks = string.gsub(edit.text, "\n", "")
			last_changed += breaks
		end
		go_to_line(ctx.view, math.min(last_changed, buffer:line_count() - 1))
		if changed_lines > 2 then
			greed.echo(`{#edits} substitutions on {changed_lines} lines`)
		end
	end,
})

greed.command({
	name = "delete-lines",
	doc = "Delete the selected lines, copying them (:d)",
	run = function(ctx)
		local buffer = ctx.buffer
		local first, last = M.selected_lines(ctx.view)
		local from, to = whole_lines(buffer, first, last)
		greed.clipboard.set(lines_text(buffer, first, last) .. "\n")
		buffer:edit(function(e)
			e:delete(from, to)
		end)
		go_to_line(ctx.view, math.min(first, buffer:line_count() - 1))
	end,
})

greed.command({
	name = "yank-lines",
	doc = "Copy the selected lines (:y)",
	run = function(ctx)
		local first, last = M.selected_lines(ctx.view)
		greed.clipboard.set(lines_text(ctx.buffer, first, last) .. "\n")
	end,
})

-- The text of lines `first` to `last` put below line `after` (-1 for the
-- top), as an insert position and text.
local function lines_below(
	buffer: greed.Buffer,
	first: number,
	last: number,
	after: number
): (number, string)
	local text = lines_text(buffer, first, last)
	if after < 0 then
		return 0, text .. "\n"
	end
	return buffer:line_end(after), "\n" .. text
end

-- The line number argument of :m and :t, 0-based, -1 for "0" (the top).
local function target_line(ctx: greed.Context): number
	local arg = ctx.args[1] or ""
	if arg == "$" then
		return ctx.buffer:line_count() - 1
	elseif arg == "." then
		return (M.selected_lines(ctx.view))
	end
	local n = tonumber(arg)
	if n == nil then
		error("give a line number to put them after, 0 for the top", 0)
	end
	return math.clamp(n - 1, -1, ctx.buffer:line_count() - 1)
end

greed.command({
	name = "copy-lines",
	doc = "Copy the selected lines below a line, 0 for the top (:t)",
	args = { { name = "line" } },
	run = function(ctx)
		local buffer = ctx.buffer
		local first, last = M.selected_lines(ctx.view)
		local after = target_line(ctx)
		local at, text = lines_below(buffer, first, last, after)
		buffer:edit(function(e)
			e:insert(at, text)
		end)
		go_to_line(ctx.view, after + 1 + last - first)
	end,
})

greed.command({
	name = "move-lines",
	doc = "Move the selected lines below a line, 0 for the top (:m)",
	args = { { name = "line" } },
	run = function(ctx)
		local buffer = ctx.buffer
		local first, last = M.selected_lines(ctx.view)
		local after = target_line(ctx)
		if after >= first and after <= last then
			if after == last then
				return
			end
			error("can't move lines into themselves", 0)
		end
		local at, text = lines_below(buffer, first, last, after)
		local from, to = whole_lines(buffer, first, last)
		buffer:edit(function(e)
			if at < from then
				e:insert(at, text)
				e:delete(from, to)
			else
				e:delete(from, to)
				e:insert(at, text)
			end
		end)
		local count = last - first + 1
		go_to_line(ctx.view, if after < first then after + count else after)
	end,
})

greed.command({
	name = "normal",
	doc = "Type keys in normal mode on each selected line (:norm)",
	args = { { name = "keys" } },
	run = function(ctx)
		local keys = table.concat(ctx.args, " ")
		if keys == "" then
			return
		end
		-- Each character typed is a key, as in Vim; spaces too.
		local sequence = {}
		for _, code in utf8.codes(keys) do
			local char = utf8.char(code)
			table.insert(sequence, if char == " " then "space" else char)
		end
		local typed = table.concat(sequence, " ")
		local mode = greed.mode.get()
		local view, buffer = ctx.view, ctx.buffer
		local first, last = M.selected_lines(view)
		-- Marks keep each line's place as earlier lines change.
		local marks: { greed.Mark } = {}
		for line = first, last do
			local start = buffer:line_start(line)
			table.insert(marks, { from = start, to = start, style = tostring(line) })
		end
		buffer:decorate("cmdline-normal", marks)
		greed.history.start_group()
		for line = first, last do
			for _, mark in buffer:decorations("cmdline-normal") do
				if mark.style == tostring(line) then
					local start = buffer:line_start(buffer:line_of(mark.from))
					view:set_selection({
						ranges = { { anchor = start, head = start } },
						primary = 1,
					})
				end
			end
			greed.keys.feed(typed)
			-- A command left unfinished, like insert mode, ends with the line.
			if greed.mode.get() ~= mode then
				greed.keys.feed("esc")
			end
		end
		greed.history.end_group()
		buffer:decorate("cmdline-normal", {})
	end,
})

return M
