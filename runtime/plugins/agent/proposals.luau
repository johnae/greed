-- Edits an agent proposes, shown in the buffer for review before they
-- apply. The old text is marked and the new text shows after it, or as
-- lines under it when whole lines change; nothing changes until you
-- accept.
--
--   ] o  [ o   the next or previous proposed change
--   space o a  accept the changes your selections touch
--   space o r  reject them
--   space o A  accept every change in the file
--   space o R  reject every change in the file
--   space o o  pick from every pending change
--   space o d  the file with its changes in, side by side (compare.luau)
--
-- The agent's propose call waits for your decision and then learns which
-- changes went in.

local kern = require("@kern")
local core = require("@core")
local picker = require("@picker")
local operations = require("@operations")

type Span = { from: number, to: number }

type Hunk = {
	old: string,
	new: string,
	id: number,
	-- "pending", "accepted", "rejected", or "gone" if its text was deleted.
	status: string,
}

type Proposal = {
	path: string,
	buffer: kern.Buffer,
	hunks: { Hunk },
	-- The undecided hunks, in the order they appear in the file.
	pending: { Hunk },
	-- Gets the proposal back once every hunk is decided.
	done: kern.Signal,
	-- What Claude Code calls the diff, so it can withdraw it.
	tab: string?,
	-- The operation its accepted changes join, so they undo as one.
	op: operations.Operation,
}

local proposals: { Proposal } = {}
local next_id = 0

-- What wants to hear when a buffer's proposed changes come or go.
local listeners: { (buffer: kern.Buffer) -> () } = {}

local function changed(buffer: kern.Buffer)
	for _, listener in listeners do
		listener(buffer)
	end
end

-- Each hunk has its own marks, so it moves with edits made while it waits
-- and goes away on its own if its text is deleted.
local function ns(hunk: Hunk): string
	return `proposal-{hunk.id}`
end

-- Where the hunk's old text is now, or nil if it was deleted.
local function position(p: Proposal, hunk: Hunk): kern.Mark?
	return p.buffer:decorations(ns(hunk))[1]
end

-- The line to show the hunk's new lines under, when it replaces whole
-- lines with whole lines (as diffs from Claude Code do): its last old
-- line, or the line before where the new ones go in.
local function line_above(buffer: kern.Buffer, hunk: Hunk, at: Span): number?
	local function line_start(pos: number): boolean
		return pos == 0 or buffer:slice(pos - 1, pos) == "\n"
	end
	if not (line_start(at.from) and line_start(at.to) and string.sub(hunk.new, -1) == "\n") then
		return nil
	elseif at.to > at.from then
		return buffer:line_of(at.to - 1)
	elseif at.from > 0 then
		return buffer:line_of(at.from - 1)
	end
	return nil
end

-- Letters, digits, "_" and anything outside ASCII.
local function is_word(byte: number?): boolean
	return byte ~= nil
		and (
			byte >= 0x80
			or byte == 95
			or (byte >= 48 and byte <= 57)
			or (byte >= 65 and byte <= 90)
			or (byte >= 97 and byte <= 122)
		)
end

-- `from`..`to` of `s` (0-based, `to` exclusive) widened to whole words at
-- either end that starts or stops inside one.
local function whole_words(s: string, from: number, to: number): (number, number)
	if is_word(string.byte(s, from + 1)) then
		while from > 0 and is_word(string.byte(s, from)) do
			from -= 1
		end
	end
	if is_word(string.byte(s, to)) then
		while to < #s and is_word(string.byte(s, to + 1)) do
			to += 1
		end
	end
	return from, to
end

-- The words that differ between line `old` and line `new`, as byte ranges
-- of each, or nil when the lines are the same or differ throughout.
local function changed_words(old: string, new: string): (number?, number?, number?, number?)
	if old == new then
		return nil, nil, nil, nil
	end
	local shortest = math.min(#old, #new)
	local prefix = 0
	while prefix < shortest and string.byte(old, prefix + 1) == string.byte(new, prefix + 1) do
		prefix += 1
	end
	local suffix = 0
	while
		suffix < shortest - prefix
		and string.byte(old, #old - suffix) == string.byte(new, #new - suffix)
	do
		suffix += 1
	end
	local old_from, old_to = whole_words(old, prefix, #old - suffix)
	local new_from, new_to = whole_words(new, prefix, #new - suffix)
	if old_from == 0 and old_to == #old and new_from == 0 and new_to == #new then
		return nil, nil, nil, nil
	end
	return old_from, old_to, new_from, new_to
end

-- The marks showing whole new lines under `line`, with the words that
-- changed picked out in old and new lines that pair up one to one.
local function line_marks(buffer: kern.Buffer, hunk: Hunk, at: Span, line: number): { kern.Mark }
	local new_lines = string.split(string.sub(hunk.new, 1, -2), "\n")
	local old_text = buffer:slice(at.from, at.to)
	local old_lines = if old_text == "" then {} else string.split(string.sub(old_text, 1, -2), "\n")
	local marks: { kern.Mark } = {}
	local shown: { any } = table.clone(new_lines)
	if #old_lines == #new_lines then
		local old_start = at.from
		for i, old in old_lines do
			local new = new_lines[i]
			local old_from, old_to, new_from, new_to = changed_words(old, new)
			if old_from and old_to and new_from and new_to then
				table.insert(marks, {
					from = old_start + old_from,
					to = old_start + old_to,
					style = "diff.minus.change",
				})
				shown[i] = {
					{ text = string.sub(new, 1, new_from) },
					{ text = string.sub(new, new_from + 1, new_to), style = "diff.plus.change" },
					{ text = string.sub(new, new_to + 1) },
				}
			end
			old_start += #old + 1
		end
	end
	local start = buffer:line_start(line)
	table.insert(marks, { from = start, to = start, style = "diff.plus", lines = shown })
	return marks
end

-- Buttons after the change's first line, which click the keys' commands
-- with the cursor on the change.
local function buttons(at: Span): { kern.Mark }
	local function button(text: string, action: string): kern.Mark
		return {
			from = at.from,
			to = at.from,
			style = "ui.button",
			text = text,
			eol = true,
			action = action,
		}
	end
	return { button("accept", "proposal-accept"), button("reject", "proposal-reject") }
end

local function draw(p: Proposal, hunk: Hunk, at: Span)
	local buffer = p.buffer
	buffer:decorate(ns(hunk), { { from = at.from, to = at.to, style = "diff.minus" } })
	local line = line_above(buffer, hunk, at)
	local marks = buttons(at)
	if line then
		for _, mark in line_marks(buffer, hunk, at, line) do
			table.insert(marks, mark)
		end
	else
		local shown = string.gsub(hunk.new, "\n", "⏎")
		table.insert(marks, { from = at.to, to = at.to, style = "diff.plus", text = shown })
	end
	buffer:decorate(ns(hunk) .. "-text", marks)
end

local function clear(p: Proposal, hunk: Hunk)
	p.buffer:decorate(ns(hunk), {})
	p.buffer:decorate(ns(hunk) .. "-text", {})
end

-- What the agent hears once every hunk of `p` is decided.
local function summary(p: Proposal): string
	local accepted, rejected, gone = 0, {}, {}
	for i, hunk in p.hunks do
		if hunk.status == "accepted" then
			accepted += 1
		elseif hunk.status == "gone" then
			table.insert(gone, tostring(i))
		else
			table.insert(rejected, tostring(i))
		end
	end
	local text = `accepted {accepted} of {#p.hunks} changes to {p.path}`
	if #rejected > 0 then
		text ..= `; the user rejected change {table.concat(rejected, ", ")}`
	end
	if #gone > 0 then
		text ..= `; the user deleted the text of change {table.concat(gone, ", ")}`
	end
	return text
end

-- Accepts or rejects the pending hunks of `p` for which `chosen(position)`
-- is true, and tells the agent once none are left.
local function decide(p: Proposal, chosen: (at: kern.Mark) -> boolean, accept: boolean)
	local edits, pending = {}, {}
	for _, hunk in p.pending do
		local at = position(p, hunk)
		if at == nil then
			hunk.status = "gone"
			clear(p, hunk)
		elseif chosen(at) then
			hunk.status = if accept then "accepted" else "rejected"
			clear(p, hunk)
			if accept then
				table.insert(edits, { at = at, text = hunk.new })
			end
		else
			table.insert(pending, hunk)
		end
	end
	p.pending = pending
	if #edits > 0 then
		operations.join(p.op, function()
			p.buffer:edit(function(e)
				for _, edit in edits do
					e:replace(edit.at.from, edit.at.to, edit.text)
				end
			end)
		end)
	end
	if #pending == 0 then
		local index = table.find(proposals, p)
		if index then
			table.remove(proposals, index)
		end
	end
	changed(p.buffer)
	if #pending == 0 then
		p.done.send(p)
	end
end

-- The proposals waiting in `buffer`.
local function in_buffer(buffer: kern.Buffer): { Proposal }
	local found = {}
	for _, p in proposals do
		if p.buffer:id() == buffer:id() then
			table.insert(found, p)
		end
	end
	return found
end

local function touches_selection(view: kern.View): (at: kern.Mark) -> boolean
	local ranges = view:selection().ranges
	return function(at)
		for _, range in ranges do
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			if from <= at.to and to >= at.from then
				return true
			end
		end
		return false
	end
end

local function decide_here(ctx: kern.Context, chosen: (at: kern.Mark) -> boolean, accept: boolean)
	local found = in_buffer(ctx.buffer)
	if #found == 0 then
		kern.echo("no proposed changes in this file")
	end
	for _, p in found do
		decide(p, chosen, accept)
	end
end

local function everything(): boolean
	return true
end

kern.command({
	name = "proposal-accept",
	doc = "Accept the proposed changes your selections touch",
	run = function(ctx)
		decide_here(ctx, touches_selection(ctx.view), true)
	end,
})

kern.command({
	name = "proposal-reject",
	doc = "Reject the proposed changes your selections touch",
	run = function(ctx)
		decide_here(ctx, touches_selection(ctx.view), false)
	end,
})

kern.command({
	name = "proposal-accept-all",
	doc = "Accept every proposed change in this file",
	run = function(ctx)
		decide_here(ctx, everything, true)
	end,
})

kern.command({
	name = "proposal-reject-all",
	doc = "Reject every proposed change in this file",
	run = function(ctx)
		decide_here(ctx, everything, false)
	end,
})

local function select_mark(view: kern.View, at: kern.Mark)
	view:set_selection({ ranges = { { anchor = at.from, head = at.to } }, primary = 1 })
end

-- Selects the old text of the next (or previous) proposed change.
local function jump(ctx: kern.Context, forward: boolean)
	local selection = ctx.view:selection()
	local head = selection.ranges[selection.primary].head
	local best: kern.Mark? = nil
	for _, p in in_buffer(ctx.buffer) do
		for _, hunk in p.pending do
			local at = position(p, hunk)
			if at then
				local ahead = if forward then at.from > head else at.to < head
				local closer = best == nil
					or (if forward then at.from < best.from else at.from > best.from)
				if ahead and closer then
					best = at
				end
			end
		end
	end
	if best == nil then
		kern.echo("no more proposed changes")
		return
	end
	select_mark(ctx.view, best)
end

kern.command({
	name = "proposal-next",
	doc = "Select the next proposed change",
	run = function(ctx)
		jump(ctx, true)
	end,
})

kern.command({
	name = "proposal-prev",
	doc = "Select the previous proposed change",
	run = function(ctx)
		jump(ctx, false)
	end,
})

kern.command({
	name = "proposals",
	doc = "Pick a proposed change to review",
	run = function()
		local items = {}
		for _, p in proposals do
			for _, hunk in p.pending do
				local at = position(p, hunk)
				if at then
					local line = p.buffer:line_of(at.from) + 1
					local first = string.match(hunk.old, "^[^\n]*")
					table.insert(
						items,
						{ label = `{p.path}:{line}: {first}`, value = { p = p, at = at } }
					)
				end
			end
		end
		if #items == 0 then
			kern.echo("no proposed changes")
			return
		end
		picker.pick("Proposed changes", items, function(item)
			local p, at = item.value.p, item.value.at
			kern.open(p.path)
			select_mark(kern.view(), at)
		end)
	end,
})

kern.keymap.bind("normal", {
	["] o"] = "proposal-next",
	["[ o"] = "proposal-prev",
	["space o a"] = "proposal-accept",
	["space o r"] = "proposal-reject",
	["space o A"] = "proposal-accept-all",
	["space o R"] = "proposal-reject-all",
	["space o o"] = "proposals",
})

-- Shows `hunks` (at `at`, and in file order as `pending`) for review as
-- part of `op`. Wait on its `done` for the user's decision.
local function start(
	op: operations.Operation,
	path: string,
	buffer: kern.Buffer,
	pending: { Hunk },
	hunks: { Hunk },
	at: { Span },
	tab: string?
): Proposal
	local p: Proposal = {
		path = path,
		buffer = buffer,
		hunks = hunks,
		pending = pending,
		done = kern.signal(),
		tab = tab,
		op = op,
	}
	table.insert(proposals, p)
	for i, hunk in hunks do
		draw(p, hunk, at[i])
	end
	changed(buffer)
	return p
end

local function where(files: { string }): string
	return if #files == 1 then files[1] else `{#files} files`
end

-- Tells the user what came in to review.
local function announce(changes: number, files: { string }, reason: string?)
	local why = if reason then `: {reason}` else ""
	kern.echo(`an agent proposes {changes} changes to {where(files)}{why} - space o o to review`)
end

local M = {}

export type Edit = { old_text: string, new_text: string }
export type FileEdits = { path: string, edits: { Edit } }

type Prepared = {
	path: string,
	buffer: kern.Buffer,
	pending: { Hunk },
	hunks: { Hunk },
	at: { Span },
}

-- The hunks of `edits` to the file at `path`, checked: each `old_text`
-- has to appear exactly once, and no two may overlap.
local function prepare(path: string, edits: { Edit }): Prepared
	local root = core.project.root()
	local full = if string.sub(path, 1, 1) == "/" then path else core.project.path(root, path)
	local buffer = kern.load(full)
	local text = buffer:text()
	local hunks: { Hunk }, at: { Span } = {}, {}
	for i, edit in edits do
		local old = edit.old_text
		if old == "" and text ~= "" then
			error(`change {i}: old_text is empty; quote the text to replace`, 0)
		end
		local from = string.find(text, old, 1, true)
		if from == nil then
			error(`change {i}: old_text isn't in {path}`, 0)
		end
		if old ~= "" and string.find(text, old, from + 1, true) then
			error(
				`change {i}: old_text appears more than once in {path}; include more of the text around it`,
				0
			)
		end
		next_id += 1
		table.insert(hunks, { id = next_id, old = old, new = edit.new_text, status = "pending" })
		table.insert(at, { from = from - 1, to = from - 1 + #old })
	end
	-- Sorted by where they are, so overlaps show up as neighbours.
	local order: { number } = {}
	for i in hunks do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number)
		return at[a].from < at[b].from
	end)
	local pending: { Hunk } = {}
	for n, i in order do
		if n > 1 and at[i].from < at[order[n - 1]].to then
			error(`change {i} overlaps another change`, 0)
		end
		pending[n] = hunks[i]
	end
	return { path = full, buffer = buffer, pending = pending, hunks = hunks, at = at }
end

--- Proposes edits to several files as one operation, then waits until the
--- user has decided on every change and returns what they decided, in
--- words. Nothing shows unless every file's edits check out. What the user
--- accepts undoes in one step, from any of the files.
function M.propose_files(files: { FileEdits }, reason: string?): string
	local prepared: { Prepared } = {}
	local paths, changes = {}, 0
	for _, file in files do
		local checked = prepare(file.path, file.edits)
		table.insert(prepared, checked)
		table.insert(paths, checked.path)
		changes += #checked.hunks
	end
	local op = operations.run(reason or `changes to {where(paths)}`, function() end, "agent")
	local started: { Proposal } = {}
	for _, file in prepared do
		table.insert(started, start(op, file.path, file.buffer, file.pending, file.hunks, file.at))
	end
	announce(changes, paths, reason)
	local answers = {}
	for _, p in started do
		table.insert(answers, summary(p.done.wait()))
	end
	return table.concat(answers, "\n")
end

--- Proposes `edits` to the file at `path`, then waits until the user has
--- decided on every one and returns what they decided, in words. Each
--- `old_text` has to appear exactly once in the file.
function M.propose(path: string, edits: { Edit }, reason: string?): string
	return M.propose_files({ { path = path, edits = edits } }, reason)
end

--- Proposes `changes` (byte ranges of `buffer` and their new text, sorted
--- and apart, as `kern.diff` gives them), then waits for the user. Returns
--- how many they accepted and rejected.
function M.propose_changes(
	buffer: kern.Buffer,
	path: string,
	changes: { { from: number, to: number, text: string } },
	reason: string?,
	tab: string?
): { accepted: number, rejected: number }
	local hunks: { Hunk }, at: { Span } = {}, {}
	for _, change in changes do
		next_id += 1
		local old = buffer:slice(change.from, change.to)
		table.insert(hunks, { id = next_id, old = old, new = change.text, status = "pending" })
		table.insert(at, { from = change.from, to = change.to })
	end
	local op = operations.run(reason or `changes to {path}`, function() end, "agent")
	local p = start(op, path, buffer, table.clone(hunks), hunks, at, tab)
	announce(#hunks, { path }, reason)
	p = p.done.wait()
	local accepted = 0
	for _, hunk in p.hunks do
		accepted += if hunk.status == "accepted" then 1 else 0
	end
	return { accepted = accepted, rejected = #p.hunks - accepted }
end

--- Rejects what's left of the proposal Claude Code called `tab`, e.g.
--- because it gave up waiting.
function M.withdraw(tab: string)
	for _, p in table.clone(proposals) do
		if p.tab == tab then
			decide(p, everything, false)
		end
	end
end

--- Rejects what's left of every proposal Claude Code made. Returns how many
--- there were.
function M.withdraw_all(): number
	local n = 0
	for _, p in table.clone(proposals) do
		if p.tab then
			n += 1
			decide(p, everything, false)
		end
	end
	return n
end

type Change = { from: number, to: number, text: string }

--- The changes waiting in `buffer`, where their old text is now, in the
--- order they appear.
function M.changes(buffer: kern.Buffer): { Change }
	local list: { Change } = {}
	for _, p in in_buffer(buffer) do
		for _, hunk in p.pending do
			local at = position(p, hunk)
			if at then
				table.insert(list, { from = at.from, to = at.to, text = hunk.new })
			end
		end
	end
	table.sort(list, function(a: Change, b: Change)
		return a.from < b.from
	end)
	return list
end

--- Calls `listener` with the buffer whenever its proposed changes come or
--- go.
function M.on_change(listener: (buffer: kern.Buffer) -> ())
	table.insert(listeners, listener)
end

--- How many proposed changes are waiting, across all files.
function M.pending(): number
	local n = 0
	for _, p in proposals do
		n += #p.pending
	end
	return n
end

return M
