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
--
-- The agent's propose call waits for your decision and then learns which
-- changes went in.

local kern = require("@kern")
local core = require("@core")
local picker = require("@picker")

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
}

local proposals: { Proposal } = {}
local next_id = 0

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

local function draw(p: Proposal, hunk: Hunk, at: Span)
	local buffer = p.buffer
	buffer:decorate(ns(hunk), { { from = at.from, to = at.to, style = "diff.minus" } })
	local line = line_above(buffer, hunk, at)
	if line then
		local start = buffer:line_start(line)
		local lines = string.split(string.sub(hunk.new, 1, -2), "\n")
		buffer:decorate(
			ns(hunk) .. "-text",
			{ { from = start, to = start, style = "diff.plus", lines = lines } }
		)
	else
		local shown = string.gsub(hunk.new, "\n", "⏎")
		buffer:decorate(
			ns(hunk) .. "-text",
			{ { from = at.to, to = at.to, style = "diff.plus", text = shown } }
		)
	end
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
		p.buffer:edit(function(e)
			for _, edit in edits do
				e:replace(edit.at.from, edit.at.to, edit.text)
			end
		end)
	end
	if #pending == 0 then
		local index = table.find(proposals, p)
		if index then
			table.remove(proposals, index)
		end
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

-- Shows `hunks` (at `at`, and in file order as `pending`) for review, and
-- waits until every one is decided.
local function start(
	path: string,
	buffer: kern.Buffer,
	pending: { Hunk },
	hunks: { Hunk },
	at: { Span },
	reason: string?,
	tab: string?
): Proposal
	local p: Proposal = {
		path = path,
		buffer = buffer,
		hunks = hunks,
		pending = pending,
		done = kern.signal(),
		tab = tab,
	}
	table.insert(proposals, p)
	for i, hunk in hunks do
		draw(p, hunk, at[i])
	end
	local why = if reason then `: {reason}` else ""
	kern.echo(`an agent proposes {#hunks} changes to {path}{why} - space o o to review`)
	return p.done.wait()
end

local M = {}

export type Edit = { old_text: string, new_text: string }

--- Proposes `edits` to the file at `path`, then waits until the user has
--- decided on every one and returns what they decided, in words. Each
--- `old_text` has to appear exactly once in the file.
function M.propose(path: string, edits: { Edit }, reason: string?): string
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
	return summary(start(full, buffer, pending, hunks, at, reason, nil))
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
	local p = start(path, buffer, table.clone(hunks), hunks, at, reason, tab)
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

--- How many proposed changes are waiting, across all files.
function M.pending(): number
	local n = 0
	for _, p in proposals do
		n += #p.pending
	end
	return n
end

return M
