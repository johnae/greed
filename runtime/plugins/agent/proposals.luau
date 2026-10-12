-- Edits an agent proposes, shown in the buffer for review before they
-- apply. The old text is marked and the new text shows after it, or as
-- lines under it when whole lines change; nothing changes until you
-- accept.
--
--   ] o  [ o   the next or previous proposed change
--   space o a  accept the changes your selections touch
--   space o r  reject them
--   space o n  reject them, telling the agent what to do instead
--   space o A  accept every change in the file
--   space o R  reject every change in the file
--   space o o  pick from every pending change
--   space o d  the file with its changes in, side by side (compare.luau)
--
-- The agent's propose call waits for your decision and then learns which
-- changes went in.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local operations = require("@operations")
local problems = require("./problems")
local registry = require("./registry")

type Span = { from: number, to: number }

type Hunk = {
	old: string,
	new: string,
	id: number,
	-- "pending", "accepted", "rejected", or "gone" if its text was deleted.
	status: string,
	-- What the user said about it, for the agent.
	note: string?,
}

type Proposal = {
	path: string,
	buffer: greed.Buffer,
	hunks: { Hunk },
	-- The undecided hunks, in the order they appear in the file.
	pending: { Hunk },
	-- Gets the proposal back once every hunk is decided.
	done: greed.Signal,
	-- What Claude Code calls the diff, so it can withdraw it.
	tab: string?,
	-- The operation its accepted changes join, so they undo as one.
	op: operations.Operation,
	-- The MCP connection whose tool call proposed it, if one did.
	connection: number?,
}

local proposals: { Proposal } = {}
local next_id = 0

-- What wants to hear when a buffer's proposed changes come or go.
local listeners: { (buffer: greed.Buffer) -> () } = {}

local function changed(buffer: greed.Buffer)
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
local function position(p: Proposal, hunk: Hunk): greed.Mark?
	return p.buffer:decorations(ns(hunk))[1]
end

-- The line to show the hunk's new lines under, when it replaces whole
-- lines with whole lines (as diffs from Claude Code do): its last old
-- line, or the line before where the new ones go in. The second result
-- says whether the old and new text end with their last line's newline;
-- Claude Code sends both kinds.
local function line_above(buffer: greed.Buffer, hunk: Hunk, at: Span): (number?, boolean)
	local function line_start(pos: number): boolean
		return pos == 0 or buffer:slice(pos - 1, pos) == "\n"
	end
	local function line_end(pos: number): boolean
		return pos == buffer:len() or buffer:slice(pos, pos + 1) == "\n"
	end
	if not line_start(at.from) or hunk.new == "" then
		return nil, false
	elseif string.sub(hunk.new, -1) ~= "\n" then
		-- Up to the end of a line, without its newline.
		if at.to > at.from and line_end(at.to) then
			return buffer:line_of(at.to), false
		end
		return nil, false
	elseif not line_start(at.to) then
		return nil, false
	elseif at.to > at.from then
		return buffer:line_of(at.to - 1), true
	elseif at.from > 0 then
		return buffer:line_of(at.from - 1), true
	end
	return nil, false
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
-- `newline` says whether both texts end with their last line's newline.
local function line_marks(
	buffer: greed.Buffer,
	hunk: Hunk,
	at: Span,
	line: number,
	newline: boolean
): { greed.Mark }
	local function lines(text: string): { string }
		if text == "" then
			return {}
		end
		return string.split(if newline then string.sub(text, 1, -2) else text, "\n")
	end
	local new_lines = lines(hunk.new)
	local old_lines = lines(buffer:slice(at.from, at.to))
	local marks: { greed.Mark } = {}
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
local function buttons(at: Span): { greed.Mark }
	local function button(text: string, action: string): greed.Mark
		return {
			from = at.from,
			to = at.from,
			style = "ui.button",
			text = text,
			eol = true,
			action = action,
		}
	end
	return {
		button("accept", "proposal-accept"),
		button("reject", "proposal-reject"),
		button("note", "proposal-note"),
	}
end

local function draw(p: Proposal, hunk: Hunk, at: Span)
	local buffer = p.buffer
	buffer:decorate(ns(hunk), { { from = at.from, to = at.to, style = "diff.minus" } })
	local line, newline = line_above(buffer, hunk, at)
	local marks = buttons(at)
	if line then
		for _, mark in line_marks(buffer, hunk, at, line, newline) do
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
	for i, hunk in p.hunks do
		if hunk.note then
			text ..= `\nabout change {i}, the user said: {hunk.note}`
		end
	end
	return text
end

-- Accepts or rejects the pending hunks of `p` for which `chosen(position)`
-- is true, a rejection with the user's `note` if they gave one, and tells
-- the agent once none are left.
local function decide(
	p: Proposal,
	chosen: (at: greed.Mark) -> boolean,
	accept: boolean,
	note: string?
)
	local edits, pending = {}, {}
	-- Hunks whose text you changed since the agent proposed them: taking
	-- one would lose your change, so it stays pending.
	local changed_since = 0
	for _, hunk in p.pending do
		local at = position(p, hunk)
		if at == nil then
			hunk.status = "gone"
			clear(p, hunk)
		elseif accept and chosen(at) and p.buffer:slice(at.from, at.to) ~= hunk.old then
			changed_since += 1
			table.insert(pending, hunk)
		elseif chosen(at) then
			hunk.status = if accept then "accepted" else "rejected"
			hunk.note = if accept then nil else note
			clear(p, hunk)
			if accept then
				table.insert(edits, { at = at, text = hunk.new })
			end
		else
			table.insert(pending, hunk)
		end
	end
	p.pending = pending
	if changed_since > 0 then
		greed.echo(
			`{changed_since} change{if changed_since == 1 then "" else "s"} not taken: you edited `
				.. "that text since it was proposed; undo your edit, or reject it"
		)
	end
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
		p.done:send(p)
	end
end

-- The proposals waiting in `buffer`.
local function in_buffer(buffer: greed.Buffer): { Proposal }
	local found = {}
	for _, p in proposals do
		if p.buffer == buffer then
			table.insert(found, p)
		end
	end
	return found
end

local function touches_selection(view: greed.View): (at: greed.Mark) -> boolean
	local ranges = view:selection().ranges
	return function(at)
		for _, range in ranges do
			local from, to = core.text.span(range)
			if from <= at.to and to >= at.from then
				return true
			end
		end
		return false
	end
end

local function decide_here(
	ctx: greed.Context,
	chosen: (at: greed.Mark) -> boolean,
	accept: boolean,
	note: string?
)
	-- Proposals are for you to decide: not an agent's tool call, an action
	-- it ran or a plugin's code, which can't type as you (`commands`).
	if not greed.plugin.started_within("commands") then
		error("only you decide on proposed changes", 0)
	end
	local found = in_buffer(ctx.buffer)
	if #found == 0 then
		greed.echo("no proposed changes in this file")
	end
	for _, p in found do
		decide(p, chosen, accept, note)
	end
end

local function everything(): boolean
	return true
end

greed.command({
	name = "proposal-accept",
	doc = "Accept the proposed changes your selections touch",
	run = function(ctx)
		decide_here(ctx, touches_selection(ctx.view), true)
	end,
})

greed.command({
	name = "proposal-reject",
	doc = "Reject the proposed changes your selections touch",
	run = function(ctx)
		decide_here(ctx, touches_selection(ctx.view), false)
	end,
})

greed.command({
	name = "proposal-note",
	doc = "Reject the proposed changes your selections touch, telling the agent what to do instead",
	run = function(ctx)
		local chosen = touches_selection(ctx.view)
		local function any_chosen(): boolean
			for _, p in in_buffer(ctx.buffer) do
				for _, hunk in p.pending do
					local at = position(p, hunk)
					if at and chosen(at) then
						return true
					end
				end
			end
			return false
		end
		if not any_chosen() then
			greed.echo("no proposed change here")
			return
		end
		local note = core.prompt.ask("Tell the agent")
		if note == nil or note == "" then
			return
		end
		decide_here(ctx, chosen, false, note)
	end,
})

greed.command({
	name = "proposal-accept-all",
	doc = "Accept every proposed change in this file",
	run = function(ctx)
		decide_here(ctx, everything, true)
	end,
})

greed.command({
	name = "proposal-reject-all",
	doc = "Reject every proposed change in this file",
	run = function(ctx)
		decide_here(ctx, everything, false)
	end,
})

local function select_mark(view: greed.View, at: greed.Mark)
	view:set_selection({ ranges = { { anchor = at.from, head = at.to } }, primary = 1 })
end

-- Selects the old text of the next (or previous) proposed change.
local function jump(ctx: greed.Context, forward: boolean)
	local head = ctx.view:cursor()
	local best: greed.Mark? = nil
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
		greed.echo("no more proposed changes")
		return
	end
	select_mark(ctx.view, best)
end

greed.command({
	name = "proposal-next",
	doc = "Select the next proposed change",
	run = function(ctx)
		jump(ctx, true)
	end,
})

greed.command({
	name = "proposal-prev",
	doc = "Select the previous proposed change",
	run = function(ctx)
		jump(ctx, false)
	end,
})

greed.command({
	name = "proposals",
	doc = "Pick a proposed change to review",
	run = function()
		local items = {}
		for _, p in proposals do
			for _, hunk in p.pending do
				local at = position(p, hunk)
				if at then
					local line = p.buffer:line_of(at.from) + 1
					-- What it replaces, or for text it adds, the text.
					local first = if hunk.old == ""
						then "+ " .. (string.match(hunk.new, "^[^\n]*") or "")
						else string.match(hunk.old, "^[^\n]*")
					table.insert(items, {
						label = `{core.project.short(p.path)}:{line}: {first}`,
						value = { p = p, at = at },
					})
				end
			end
		end
		if #items == 0 then
			greed.echo("no proposed changes")
			return
		end
		picker.pick("Proposed changes", items, function(item)
			local p, at = item.value.p, item.value.at
			greed.open(p.path)
			select_mark(greed.view(), at)
		end)
	end,
})

greed.keymap.bind({ role = "command" }, {
	["] o"] = "proposal-next",
	["[ o"] = "proposal-prev",
})

greed.keymap.bind({ layer = "leader" }, {
	["o a"] = "proposal-accept",
	["o r"] = "proposal-reject",
	["o n"] = "proposal-note",
	["o A"] = "proposal-accept-all",
	["o R"] = "proposal-reject-all",
	["o o"] = "proposals",
})

-- Shows `hunks` (at `at`, and in file order as `pending`) for review as
-- part of `op`. Wait on its `done` for the user's decision.
local function start(
	op: operations.Operation,
	path: string,
	buffer: greed.Buffer,
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
		done = greed.signal(),
		tab = tab,
		op = op,
		connection = registry.connection(),
	}
	table.insert(proposals, p)
	for i, hunk in hunks do
		draw(p, hunk, at[i])
	end
	changed(buffer)
	return p
end

-- `files` as messages name them: the one file's path, short, or how many.
local function where(files: { string }): string
	return if #files == 1 then core.project.short(files[1]) else `{#files} files`
end

-- The keys that run `command` where you are, like "space o a", or else
-- the command to type.
local function keys_for(command: string): string
	for _, binding in greed.keymap.active() do
		if binding.command == command then
			return binding.keys
		end
	end
	return `:{command}`
end

-- Tells the user what came in to review, and the keys that review it: in
-- a file on screen, the keys that go to each change and decide on it;
-- otherwise the list of every change, which opens its file.
local function announce(changes: number, files: { string }, reason: string?)
	local count = if changes == 1 then "1 change" else `{changes} changes`
	local why = if reason then ` ({reason})` else ""
	local buffer = if #files == 1 then greed.buffer_for(files[1]) else nil
	local how = if buffer and #buffer:views() > 0
		then `{keys_for("proposal-next")} goes to each, {keys_for("proposal-accept")} accepts, `
			.. `{keys_for("proposal-reject")} rejects`
		else `{keys_for("proposals")} lists them`
	greed.echo(`an agent proposes {count} in {where(files)}{why}: {how}`)
end

local M = {}

export type Edit = { old_text: string, new_text: string }
export type FileEdits = { path: string, edits: { Edit } }

type Prepared = {
	path: string,
	buffer: greed.Buffer,
	pending: { Hunk },
	hunks: { Hunk },
	at: { Span },
}

-- The hunks of `edits` to the file at `path`, checked: each `old_text`
-- has to appear exactly once, and no two may overlap.
local function prepare(path: string, edits: { Edit }): Prepared
	local full = core.project.resolve(path)
	local buffer = greed.load(full)
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
		table.insert(
			hunks,
			{ id = next_id, old = edit.old_text, new = edit.new_text, status = "pending" }
		)
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

-- Shows `prepared` for review as one operation, announced, and waits for
-- the user. Returns each file's proposal once it's decided.
local function offer(prepared: { Prepared }, reason: string?, tab: string?): { Proposal }
	local paths, changes = {}, 0
	for _, file in prepared do
		table.insert(paths, file.path)
		changes += #file.hunks
	end
	local op = operations.run(reason or `changes to {where(paths)}`, function() end, "agent")
	local started: { Proposal } = {}
	for _, file in prepared do
		table.insert(
			started,
			start(op, file.path, file.buffer, file.pending, file.hunks, file.at, tab)
		)
	end
	announce(changes, paths, reason)
	local decided: { Proposal } = {}
	for _, p in started do
		table.insert(decided, p.done:wait())
	end
	return decided
end

-- What the user decided on each of `decided`, in words.
local function summaries(decided: { Proposal }): string
	local answers = {}
	local changed: { greed.Buffer } = {}
	for _, p in decided do
		table.insert(answers, summary(p))
		for _, hunk in p.hunks do
			if hunk.status == "accepted" then
				table.insert(changed, p.buffer)
				break
			end
		end
	end
	-- What the language server makes of what went in.
	local found = problems.after_edits(changed)
	if found then
		table.insert(answers, found)
	end
	return table.concat(answers, "\n")
end

export type Change = { from: number, to: number, text: string }
export type FileChanges = { buffer: greed.Buffer, path: string, changes: { Change } }

-- The hunks of `file`'s changes, which are byte ranges, sorted and apart.
local function ranged(file: FileChanges): Prepared
	local hunks: { Hunk }, at: { Span } = {}, {}
	for _, change in file.changes do
		next_id += 1
		local old = file.buffer:slice(change.from, change.to)
		table.insert(hunks, { id = next_id, old = old, new = change.text, status = "pending" })
		table.insert(at, { from = change.from, to = change.to })
	end
	return {
		path = file.path,
		buffer = file.buffer,
		pending = table.clone(hunks),
		hunks = hunks,
		at = at,
	}
end

--- Proposes edits to several files as one operation, then waits until the
--- user has decided on every change and returns what they decided, in
--- words. Nothing shows unless every file's edits check out. What the user
--- accepts undoes in one step, from any of the files.
function M.propose_files(files: { FileEdits }, reason: string?): string
	local prepared: { Prepared } = {}
	for _, file in files do
		table.insert(prepared, prepare(file.path, file.edits))
	end
	return summaries(offer(prepared, reason))
end

--- Proposes `edits` to the file at `path`, then waits until the user has
--- decided on every one and returns what they decided, in words. Each
--- `old_text` has to appear exactly once in the file.
function M.propose(path: string, edits: { Edit }, reason: string?): string
	return M.propose_files({ { path = path, edits = edits } }, reason)
end

--- Proposes `changes` (byte ranges of `buffer` and their new text, sorted
--- and apart, as `greed.diff` gives them), then waits for the user. Returns
--- how many they accepted and rejected.
function M.propose_changes(
	buffer: greed.Buffer,
	path: string,
	changes: { Change },
	reason: string?,
	tab: string?
): { accepted: number, rejected: number }
	local p = offer({ ranged({ buffer = buffer, path = path, changes = changes }) }, reason, tab)[1]
	local accepted = 0
	for _, hunk in p.hunks do
		accepted += if hunk.status == "accepted" then 1 else 0
	end
	return { accepted = accepted, rejected = #p.hunks - accepted }
end

--- Proposes changes by byte range to several files as one operation, as
--- `propose_changes` does for one, and returns what the user decided, in
--- words, as `propose_files` does. Each file's changes are sorted and apart.
function M.propose_ranges(files: { FileChanges }, reason: string?): string
	local prepared: { Prepared } = {}
	for _, file in files do
		table.insert(prepared, ranged(file))
	end
	return summaries(offer(prepared, reason))
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

-- An agent whose connection closed waits for no answer, so what's left of
-- its proposals is rejected.
greed.on("control.closed", function(event: greed.ControlClosed)
	for _, p in table.clone(proposals) do
		if p.connection == event.connection then
			decide(p, everything, false)
		end
	end
end)

--- The changes waiting in `buffer`, where their old text is now, in the
--- order they appear.
function M.changes(buffer: greed.Buffer): { Change }
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
--- go, until the plugin that called this goes.
function M.on_change(listener: (buffer: greed.Buffer) -> ())
	greed.plugin.tie(core.registry.put(listeners, listener))
end

--- How many proposed changes are waiting, across all files.
function M.pending(): number
	local n = 0
	for _, p in proposals do
		n += #p.pending
	end
	return n
end

-- Proposals as objects, by the buffer they're in: what's proposed and
-- what's left to decide.
local function proposal_object(proposal: Proposal): core.Object
	local first = proposal.pending[1] or proposal.hunks[1]
	local at = if first then position(proposal, first) else nil
	return {
		kind = "proposal",
		id = `proposal:{proposal.buffer:id()}`,
		label = `changes to {proposal.path}`,
		value = proposal,
		buffer = proposal.buffer,
		from = if at then at.from else nil,
	}
end

core.objects.kind({
	name = "proposal",
	doc = "Changes an agent proposed to a file, for you to accept or reject",
	list = function()
		local out = {}
		for _, proposal in proposals do
			table.insert(out, proposal_object(proposal))
		end
		return out
	end,
	get = function(key)
		for _, proposal in proposals do
			if tostring(proposal.buffer:id()) == key then
				return proposal_object(proposal)
			end
		end
		return nil
	end,
	inspect = function(proposal: Proposal)
		local decided: { [string]: number } = {}
		for _, hunk in proposal.hunks do
			decided[hunk.status] = (decided[hunk.status] or 0) + 1
		end
		return { path = proposal.path, changes = #proposal.hunks, by_status = decided }
	end,
	relations = function(proposal: Proposal)
		return { buffer = { assert(core.objects.get(`buffer:{proposal.buffer:id()}`)) } }
	end,
})
core.actions.command("proposal", "accept", "proposal-accept", "Accept its first undecided change")
core.actions.command("proposal", "reject", "proposal-reject", "Reject its first undecided change")
core.actions.command("proposal", "accept all", "proposal-accept-all", "Accept every change in it")

return M
