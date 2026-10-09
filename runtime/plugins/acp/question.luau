-- The question an agent waits on, as a row of choices at the top of the
-- transcript's box, answered from there in any mode:
--
--   ╭─ Claude · Plan ───────────────── alt-enter sends · ctrl-c stops ─╮
--   │ Allow Run cargo test?  [y] Allow once  [a] Allow always  [n] Reject │
--   │ now add a test                                                   │
--
-- Enter picks the highlighted choice, tab and the arrows move it, a
-- choice's letter picks it and esc hides the row, leaving the question in
-- the transcript. Letters answer unless you're typing with something in
-- the box already, so a message you're writing never answers by accident;
-- what's in the box stays as it was.
--
-- The keys are bound for the transcript buffer alone (`buffer:set_keys`)
-- and only while the row shows, so every style's keys work as always
-- otherwise.

local greed = require("@greed")
local core = require("@core")
local session = require("./session")

type Session = session.Session
type Permission = session.Permission
type Option = { id: string, name: string, kind: string }

local M = {}

-- The keys for each kind of answer.
local KEYS: { [string]: string } =
	{ allow_once = "y", allow_always = "a", reject_once = "n", reject_always = "N" }

--- The key that picks each of `permission`'s options: its kind's letter,
--- or its number when the letter is taken or it has none.
local function keys_of(permission: Permission): { string }
	local keys: { string } = {}
	local used: { [string]: boolean } = {}
	for i, option in permission.options do
		local key = KEYS[option.kind] or tostring(i)
		if used[key] then
			key = tostring(i)
		end
		used[key] = true
		keys[i] = key
	end
	return keys
end

-- Per session: the question shown, its highlighted option, and whether
-- you hid the row.
type State = { permission: Permission, index: number, hidden: boolean }
local states: { [number]: State } = {}

-- Each transcript buffer's session, as last drawn.
local sessions: { [number]: Session } = {}

-- Redraws a transcript; transcript.luau sets it.
local redraw: (buffer: greed.Buffer, s: Session) -> () = function() end

--- Sets what redraws a transcript when the row changes.
function M.on_redraw(call: (buffer: greed.Buffer, s: Session) -> ())
	redraw = call
end

-- The state for `s`'s first pending question, fresh when that question is
-- new; nil when there's none.
local function state_of(s: Session): State?
	local permission = session.pending(s)[1]
	if permission == nil then
		states[s.id] = nil
		return nil
	end
	local state = states[s.id]
	if state == nil or state.permission ~= permission then
		state = { permission = permission, index = 1, hidden = false }
		states[s.id] = state
	end
	return state
end

-- The state for the row shown in `buffer`, if one is.
local function shown_in(buffer: greed.Buffer): (Session?, State?)
	local s = sessions[buffer:id()]
	local state = if s then state_of(s) else nil
	if s and state and not state.hidden then
		return s, state
	end
	return nil, nil
end

--- The row for `s` in `buffer`, at most `cells` wide where the title can
--- give way, and its marks from the row's start: each choice a button
--- drawn over its own text, the highlighted one picked out. Nil when no
--- question shows.
function M.row(buffer: greed.Buffer, s: Session, cells: number): (string?, { greed.Mark })
	sessions[buffer:id()] = s
	local state = state_of(s)
	if state == nil or state.hidden then
		return nil, {}
	end
	local permission = state.permission
	local keys = keys_of(permission)
	local choices = ""
	for i, option in permission.options do
		choices ..= `  [{keys[i]}] {option.name}`
	end
	local room = cells - 4 - core.text.width(choices) - #"Allow ?"
	local text = `Allow {core.text.clip(session.first_line(permission.title), room)}?`
	local marks: { greed.Mark } = { { from = 0, to = #text, style = "agent.working" } }
	for i, option in permission.options do
		local choice = `[{keys[i]}] {option.name}`
		text ..= "  "
		local button: greed.Mark = {
			from = #text,
			to = #text + #choice,
			style = if i == state.index then "ui.menu.selected" else "agent.hint",
			text = choice,
			conceal = true,
			reveal = "never",
			action = "agent-choice-click",
			data = i,
		}
		table.insert(marks, button)
		text ..= choice
	end
	return text, marks
end

-- Whether letters answer now: not while you're typing with something in
-- the box.
local function letters_answer(draft: string): boolean
	return not core.style.is_typing() or string.match(draft, "^%s*$") ~= nil
end

--- Binds the row's keys for `buffer`, whose box holds `draft`, while it
--- shows, and drops them when it doesn't.
function M.bind(buffer: greed.Buffer, draft: string)
	local _, state = shown_in(buffer)
	if state == nil then
		buffer:set_keys(nil)
		return
	end
	local keys: { [string]: string } = {
		enter = "agent-choice-pick",
		tab = "agent-choice-next",
		right = "agent-choice-next",
		["shift-tab"] = "agent-choice-prev",
		left = "agent-choice-prev",
		esc = "agent-choice-hide",
	}
	if letters_answer(draft) then
		for _, key in keys_of(state.permission) do
			keys[key] = "agent-choice-key"
		end
	end
	buffer:set_keys(keys)
end

--- What the box's bottom line says works for the question `s` waits on.
function M.hint(s: Session, draft: string): string
	local state = state_of(s)
	local typing = core.style.is_typing()
	if state == nil then
		return ""
	elseif state.hidden then
		return if typing then "alt-q shows the question" else "enter shows the question"
	elseif letters_answer(draft) then
		return `{table.concat(keys_of(state.permission), "/")} or enter answers · esc hides`
	end
	return "enter answers · tab moves · esc hides"
end

--- Shows the row for the question `s` waits on again, after esc hid it.
--- Returns whether there's a question.
function M.show(s: Session): boolean
	local state = state_of(s)
	if state then
		state.hidden = false
	end
	return state ~= nil
end

-- Answers with option `index` of the row in `buffer`.
local function answer(buffer: greed.Buffer, index: number)
	local _, state = shown_in(buffer)
	local option: Option? = state and state.permission.options[index]
	if state == nil or option == nil then
		return
	end
	-- A cursor on the row (a click puts it there) goes to the end of the
	-- box, so typing after the row goes doesn't land in the transcript.
	local first = buffer:decorations("acp-choices")[1]
	if first then
		local line = buffer:line_of(first.from)
		local from, to = buffer:line_start(line), buffer:line_end(line)
		for _, view in buffer:views() do
			local cursor = view:cursor()
			if cursor >= from and cursor <= to then
				view:set_cursor(buffer:len())
			end
		end
	end
	-- At once, so a key pressed before the agent hears doesn't answer again.
	state.hidden = true
	buffer:set_keys(nil)
	state.permission.answer:send(option.id)
end

-- Changes the row in `buffer` with `change` and redraws it.
local function change(buffer: greed.Buffer, call: (state: State) -> ())
	local s, state = shown_in(buffer)
	if s and state then
		call(state)
		redraw(buffer, s)
	end
end

local function move(buffer: greed.Buffer, by: number)
	change(buffer, function(state)
		local count = #state.permission.options
		state.index = (state.index - 1 + by) % count + 1
	end)
end

greed.command({
	name = "agent-choice-pick",
	doc = "Answer the agent's question with the highlighted choice",
	run = function(ctx)
		local _, state = shown_in(ctx.buffer)
		if state then
			answer(ctx.buffer, state.index)
		end
	end,
})

greed.command({
	name = "agent-choice-key",
	doc = "Answer the agent's question with the choice of the key pressed",
	run = function(ctx)
		local _, state = shown_in(ctx.buffer)
		local index = state and table.find(keys_of(state.permission), ctx.char or ctx.keys or "")
		if index then
			answer(ctx.buffer, index)
		end
	end,
})

greed.command({
	name = "agent-choice-next",
	doc = "Highlight the next choice of the agent's question",
	run = function(ctx)
		move(ctx.buffer, 1)
	end,
})

greed.command({
	name = "agent-choice-prev",
	doc = "Highlight the previous choice of the agent's question",
	run = function(ctx)
		move(ctx.buffer, -1)
	end,
})

greed.command({
	name = "agent-choice-hide",
	doc = "Hide the agent's question from the box; it still waits in the transcript",
	run = function(ctx)
		change(ctx.buffer, function(state)
			state.hidden = true
		end)
	end,
})

-- The row's choices are buttons: clicking one puts the cursor on it and
-- runs this.
greed.command({
	name = "agent-choice-click",
	doc = "Answer the agent's question with the choice under the cursor",
	run = function(ctx)
		local cursor = ctx.view:cursor()
		for _, mark in ctx.buffer:decorations("acp-choices") do
			if mark.from <= cursor and cursor < mark.to and mark.data then
				answer(ctx.buffer, mark.data :: number)
				return
			end
		end
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	sessions[event.id] = nil
end)

return M
