-- Completion from the language server: a short pause while typing a word
-- (or after a ".") asks the server, and a menu at the cursor lists what
-- matches the word so far. tab or ctrl-n and shift-tab or ctrl-p move
-- through it, enter takes the current one, esc closes it; typing narrows
-- it. ctrl-space asks right away. completion-words fills the same menu
-- with words from open files instead, for Vim's ctrl-n and ctrl-p.
--
-- While the menu is open the editor is in a mode of its own that keeps
-- every key of the mode you were typing in, so nothing else changes.

local greed = require("@greed")
local core = require("@core")
local menu = core.menu

greed.option.define({
	name = "completion-delay",
	doc = "Milliseconds of no typing before completions are asked for; 0 turns asking off",
	default = 150,
})

-- The modes completion works in: every style's typing modes.
local TYPING: { [string]: boolean } = {}

-- At most this many items are listed.
local SHOWN = 10

local M = {}

--- Something that could go at the cursor: `label` in the menu, `text` put
--- in place of what's typed from `from` (the start of the word typed, by
--- default) to the cursor. `detail` says what it is, dimmed after the
--- label, and `badge`, a word before the detail, whose it is, like a
--- shell's "greed" for its own commands.
export type Item = { label: string, detail: string?, badge: string?, text: string, from: number? }

--- How the menu was asked for: `explicit` when you asked (tab,
--- ctrl-space), not by a pause in typing.
export type Ask = { explicit: boolean }

--- Says what could go at the cursor in a view, or nil to leave it to the
--- next source and then the language server. It can wait, as for a
--- program's answer; one that comes after more typing is dropped.
export type Source = (view: greed.View, ask: Ask) -> { Item }?

local sources: { Source } = {}

--- Asks `source` what could go at the cursor before the language server is
--- asked, in any buffer, a file or not: the first source to answer (even
--- with nothing) decides. It goes when the plugin that added it does.
function M.source(source: Source)
	greed.plugin.tie(core.registry.put(sources, source))
end

type Open = {
	view: greed.View,
	buffer: greed.Buffer,
	float: core.TypingFloat,
	-- Every item the server sent, and the ones matching what's typed.
	items: { Item },
	matches: { number },
	current: number,
	-- Where the word being completed starts, following edits elsewhere,
	-- like a shell's output above its prompt.
	start: greed.Anchor,
	-- The mode to go back to.
	mode: string,
}

-- Where the word `o` completes starts now.
local function start_of(o: Open): number
	return o.start:pos() or o.view:cursor()
end

-- The menu open for each client, by its id: each types on its own.
local opened: { [number]: Open } = {}
-- Each client's count of keystrokes, which goes up with each, so a slow
-- answer for older text is dropped.
local generations: { [number]: number } = {}

-- The acting client's menu, if it has one open.
local function mine(): Open?
	return opened[greed.client.id()]
end

-- The acting client's count of keystrokes.
local function generation(): number
	return generations[greed.client.id()] or 0
end

-- Counts a keystroke of the acting client's, returning the new count.
local function next_generation(): number
	local client = greed.client.id()
	local count = (generations[client] or 0) + 1
	generations[client] = count
	return count
end

-- Letters, digits, "_" and anything outside ASCII.
local function is_word(ch: string): boolean
	return #ch > 1 or string.match(ch, "[%w_]") ~= nil
end

-- Where the word ending at `pos` starts.
local function word_start(buffer: greed.Buffer, pos: number): number
	local at = pos
	while at > 0 do
		local before = buffer:prev_char(at)
		if not is_word(buffer:char_at(before) or "") then
			break
		end
		at = before
	end
	return at
end

-- A snippet's text without its placeholders: "f(${1:x})$0" is "f(x)".
local function plain(snippet: string): string
	local text = string.gsub(snippet, "%${%d+:([^}]*)}", "%1")
	text = string.gsub(text, "%${%d+}", "")
	text = string.gsub(text, "%$%d+", "")
	return text
end

-- The server's items in a form the menu uses.
local function items_from(result: any, buffer: greed.Buffer): { Item }
	local list = if result and result.items then result.items else result or {}
	local out = {}
	for _, item in list do
		local text = item.insertText or item.label
		local from = nil
		if item.textEdit and item.textEdit.newText then
			text = item.textEdit.newText
			local range = item.textEdit.range or item.textEdit.replace
			if range then
				from = greed.lsp.offset(buffer, range.start)
			end
		end
		if item.insertTextFormat == 2 then
			text = plain(text)
		end
		table.insert(out, { label = item.label, detail = item.detail, text = text, from = from })
	end
	return out
end

local function close()
	local o = mine()
	if o then
		o.float.close()
	end
end

-- Draws the matching items and marks the current one.
local function render(o: Open)
	local typed = o.buffer:slice(start_of(o), o.view:cursor())
	local labels = {}
	local width, badges = 0, 0
	for i, index in o.matches do
		if i > SHOWN then
			break
		end
		local item = o.items[index]
		table.insert(labels, item.label)
		width = math.max(width, core.text.width(item.label))
		badges = math.max(badges, if item.badge then core.text.width(item.badge) else 0)
	end
	local lines, marks = {}, {}
	local from = 0
	for i, label in labels do
		local item = o.items[o.matches[i]]
		local line = ` {label}{string.rep(" ", width - core.text.width(label))}`
		local badge = item.badge
		if badges > 0 then
			local at = #line + 2
			local shown = badge or ""
			line ..= `  {shown}{string.rep(" ", badges - core.text.width(shown))}`
			if badge then
				table.insert(
					marks,
					{ from = from + at, to = from + at + #badge, style = "ui.menu.badge" }
				)
			end
		end
		if item.detail then
			local at = #line + 2
			line ..= `  {item.detail}`
			table.insert(marks, { from = from + at, to = from + #line, style = "ui.menu.doc" })
		end
		menu.mark_row(marks, from, line, i == o.current, greed.fuzzy_positions(typed, label), 1)
		table.insert(lines, line)
		from += #line + 1
	end
	local buffer = o.float.buffer
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:decorate("completion", marks)
	local longest = 0
	for _, line in lines do
		longest = math.max(longest, core.text.width(line))
	end
	o.float.view:configure({ width = longest + 3, height = #lines + 2 })
end

-- Narrows the items to what's typed now, closing the menu when nothing's left.
local function refresh(o: Open)
	local typed = o.buffer:slice(start_of(o), o.view:cursor())
	local labels = {}
	for i, item in o.items do
		labels[i] = item.label
	end
	o.matches = greed.fuzzy(typed, labels)
	o.current = 1
	if #o.matches == 0 then
		close()
		return
	end
	render(o)
end

-- Opens the menu at the cursor in `view` with what of `items` matches the
-- word being typed. Returns whether anything did.
local function show(view: greed.View, items: { Item }): boolean
	local buffer = view:buffer()
	if #items == 0 then
		return false
	end
	close()
	local mode = greed.mode.get()
	local start = word_start(buffer, view:cursor())
	for _, item in items do
		if item.from then
			start = math.min(start, item.from)
		end
	end
	local client = greed.client.id()
	local o: Open
	local float = core.floats.typing(
		greed.create_buffer("completion", "", { readonly = true }),
		{ anchor = "cursor", width = 20, height = 3, focus = false },
		{
			mode = `completion-{mode}`,
			on_close = function()
				o.start:forget()
				if opened[client] == o then
					opened[client] = nil
				end
			end,
		}
	)
	o = {
		view = view,
		buffer = buffer,
		float = float,
		items = items,
		matches = {},
		current = 1,
		start = buffer:track(start, { gravity = "left" }),
		mode = mode,
	}
	opened[client] = o
	refresh(o)
	return opened[client] ~= nil
end

-- Asks the sources, then the server, what could go at the cursor in
-- `view`, and opens the menu if anything matches. `wanted` is the
-- generation the ask was for, and `explicit` whether it was asked for.
local function ask(view: greed.View, wanted: number, explicit: boolean)
	local mode = greed.mode.get()
	local buffer = view:buffer()
	if not TYPING[mode] then
		return
	end
	-- What's before the cursor on its line: when a source took a while and
	-- that's still the same, nothing was typed meanwhile, though the
	-- buffer may have changed around it, like a shell's output above,
	-- moving the cursor along.
	local function before_cursor(): string
		local pos = view:cursor()
		return buffer:slice(buffer:line_start(buffer:line_of(pos)), pos)
	end
	local typed, asked_at = before_cursor(), view:cursor()
	for _, source in table.clone(sources) do
		local answered, items = pcall(source, view, { explicit = explicit })
		if answered and items then
			local current = wanted == generation() or (mine() == nil and before_cursor() == typed)
			if current and greed.mode.get() == mode and view:valid() then
				local moved = view:cursor() - asked_at
				if moved ~= 0 then
					for _, item in items do
						if item.from then
							item.from += moved
						end
					end
				end
				show(view, items)
			end
			return
		end
	end
	if buffer:path() == nil then
		return
	end
	local ok, result = pcall(greed.lsp.request, buffer, "textDocument/completion", {
		textDocument = { uri = greed.lsp.uri(buffer) },
		position = greed.lsp.position(buffer, view:cursor()),
	})
	if not ok or result == nil or wanted ~= generation() or greed.mode.get() ~= mode then
		return
	end
	show(view, items_from(result, buffer))
end

-- Typing a word character or "." asks again once typing pauses; anything
-- else closes the menu.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	if event.buffer ~= view:buffer() then
		return
	end
	local mode = greed.mode.get()
	local open = mine()
	local typing = TYPING[mode] == true or (open ~= nil and mode == `completion-{open.mode}`)
	if not typing then
		return
	end
	local buffer = view:buffer()
	local pos = view:cursor()
	-- Text changing away from the cursor's line, like a program's output
	-- in a shell, isn't typing.
	local line = buffer:line_of(pos)
	if event.from_line and event.to_line and (line < event.from_line or line > event.to_line) then
		return
	end
	local wanted = next_generation()
	local ch = if pos > 0 then buffer:char_at(buffer:prev_char(pos)) or "" else ""
	local in_word = is_word(ch)
	if open then
		if in_word and pos > start_of(open) then
			refresh(open)
		else
			close()
		end
		return
	end
	local delay = greed.option.get("completion-delay") :: number
	if delay <= 0 or not (in_word or ch == ".") then
		return
	end
	greed.sleep(delay)
	-- The view typed into may have closed meanwhile, like the command line
	-- on enter; only the one still focused gets asked about.
	if wanted == generation() and mine() == nil and greed.view() == view then
		ask(view, wanted, false)
	end
end)

greed.command({
	name = "completion-ask",
	doc = "Ask the language server what could go at the cursor",
	run = function(ctx)
		ask(ctx.view, next_generation(), true)
	end,
})

local function move(delta: number)
	local o = mine()
	if o == nil then
		return
	end
	local count = math.min(#o.matches, SHOWN)
	o.current = (o.current - 1 + delta) % count + 1
	render(o)
end

-- At most this many words are offered.
local WORDS = 200

-- The words in open buffers that start with what's typed before the cursor
-- in `view`: this buffer's from the cursor on, then the rest of it, then
-- the other buffers'.
local function words(view: greed.View): { Item }
	local buffer = view:buffer()
	local pos = view:cursor()
	local typed = buffer:slice(word_start(buffer, pos), pos)
	local texts = { buffer:slice(pos, buffer:len()), buffer:slice(0, pos) }
	for _, other in greed.buffers() do
		if other ~= buffer then
			table.insert(texts, other:text())
		end
	end
	local seen: { [string]: boolean } = {}
	local found: { Item } = {}
	for _, text in texts do
		for word in string.gmatch(text, "[%w_\128-\255]+") do
			if #word > #typed and not seen[word] and string.sub(word, 1, #typed) == typed then
				seen[word] = true
				table.insert(found, { label = word, text = word })
				if #found >= WORDS then
					return found
				end
			end
		end
	end
	return found
end

-- completion-words and completion-words-back: Vim's ctrl-n and ctrl-p.
for _, back in { false, true } do
	greed.command({
		name = if back then "completion-words-back" else "completion-words",
		doc = if back
			then "Complete the word being typed from words in open files, starting with the last"
			else "Complete the word being typed from words in open files",
		run = function(ctx)
			if not show(ctx.view, words(ctx.view)) then
				greed.echo("no words to complete")
			elseif back then
				move(-1)
			end
		end,
	})
end

greed.command({
	name = "completion-next",
	doc = "Move to the next completion",
	run = function()
		move(1)
	end,
})

greed.command({
	name = "completion-prev",
	doc = "Move to the previous completion",
	run = function()
		move(-1)
	end,
})

greed.command({
	name = "completion-accept",
	doc = "Put the current completion in place of the word being typed",
	run = function()
		local o = mine()
		if o == nil then
			return
		end
		local item = o.items[o.matches[o.current]]
		local from, to = start_of(o), o.view:cursor()
		close()
		o.buffer:edit(function(e)
			e:replace(from, to, item.text)
			local at = from + #item.text
			e:select({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end)
		-- What was just put in isn't something to complete again.
		next_generation()
	end,
})

greed.command({
	name = "completion-close",
	doc = "Close the completion menu and do what esc does where you were typing",
	run = function()
		close()
		greed.keys.feed("esc")
	end,
})

local KEYS = {
	tab = "completion-next",
	["ctrl-n"] = "completion-next",
	down = "completion-next",
	["shift-tab"] = "completion-prev",
	["ctrl-p"] = "completion-prev",
	up = "completion-prev",
	enter = "completion-accept",
	esc = "completion-close",
}

-- The typing modes the menu has a mode for, and the kinds of buffer its
-- keys go ahead of.
local typing_modes: { string } = {}
local kinds: { [string]: boolean } = {}

-- Binds the menu's keys in its mode for `mode`, for buffers of `kind`.
local function keys_for(mode: string, kind: string)
	greed.keymap.bind({ mode = `completion-{mode}`, kind = kind }, KEYS)
end

--- Keeps the menu's keys (tab, the arrows, enter, esc) its own in buffers
--- of `kind` whose plugin binds those keys for typing: keys bound for a
--- kind of buffer come before a mode's own.
function M.keys_over(kind: string)
	kinds[kind] = true
	for _, mode in typing_modes do
		keys_for(mode, kind)
	end
end

-- The menu's mode keeps the typing mode's keys, and what it does with
-- an unbound key.
core.style.each_typing(function(mode)
	TYPING[mode] = true
	table.insert(typing_modes, mode)
	local completing = `completion-{mode}`
	greed.keymap.inherit(completing, mode)
	greed.keymap.bind(completing, KEYS)
	for kind in kinds do
		keys_for(mode, kind)
	end
	greed.mode.set_cursor(completing, greed.mode.cursor_of(mode))
	core.style.show_as(completing, mode)
end)
-- ctrl-space asks in every style (in vscode's it opens the leader), and
-- Helix has ctrl-x too; vscode keeps ctrl-x for cut.
greed.keymap.bind({ role = "typing" }, { ["ctrl-space"] = "completion-ask" })
greed.keymap.bind({ style = "helix", role = "typing" }, { ["ctrl-x"] = "completion-ask" })

return M
