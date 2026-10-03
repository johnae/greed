-- Completion from the language server: a short pause while typing a word
-- (or after a ".") asks the server, and a menu at the cursor lists what
-- matches the word so far. tab or ctrl-n and shift-tab or ctrl-p move
-- through it, enter takes the current one, esc closes it; typing narrows
-- it. ctrl-space asks right away. completion-words fills the same menu
-- with words from open files instead, for Vim's ctrl-n and ctrl-p.
--
-- While the menu is open the editor is in a mode of its own that keeps
-- every key of the mode you were typing in, so nothing else changes.

local kern = require("@kern")
local core = require("@core")
local menu = core.menu

kern.option.define({
	name = "completion-delay",
	doc = "Milliseconds of no typing before completions are asked for; 0 turns asking off",
	default = 150,
})

-- The modes completion works in, and what an unbound key does in each.
local TYPING: { [string]: string } = {
	insert = "insert-char",
	["vim-insert"] = "insert-char",
	edit = "type-char",
}

-- At most this many items are listed.
local SHOWN = 10

type Item = { label: string, detail: string?, text: string, from: number? }

type Open = {
	view: kern.View,
	buffer: kern.Buffer,
	menu: kern.View,
	-- Every item the server sent, and the ones matching what's typed.
	items: { Item },
	matches: { number },
	current: number,
	-- Where the word being completed starts.
	start: number,
	-- The mode to go back to.
	mode: string,
}

local open: Open? = nil
-- Goes up with each keystroke, so a slow answer for older text is dropped.
local generation = 0

local function head(view: kern.View): number
	local selection = view:selection()
	return selection.ranges[selection.primary].head
end

-- Letters, digits, "_" and anything outside ASCII.
local function is_word(ch: string): boolean
	return #ch > 1 or string.match(ch, "[%w_]") ~= nil
end

-- Where the word ending at `pos` starts.
local function word_start(buffer: kern.Buffer, pos: number): number
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
local function items_from(result: any, buffer: kern.Buffer): { Item }
	local list = if result and result.items then result.items else result or {}
	local out = {}
	for _, item in list do
		local text = item.insertText or item.label
		local from = nil
		if item.textEdit and item.textEdit.newText then
			text = item.textEdit.newText
			local range = item.textEdit.range or item.textEdit.replace
			if range then
				from = kern.lsp.offset(buffer, range.start)
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
	local o = open
	if o == nil then
		return
	end
	open = nil
	o.menu:close()
	if kern.mode.get() == `completion-{o.mode}` then
		kern.mode.set(o.mode)
	end
end

-- Draws the matching items and marks the current one.
local function render(o: Open)
	local typed = o.buffer:slice(o.start, head(o.view))
	local labels = {}
	local width = 0
	for i, index in o.matches do
		if i > SHOWN then
			break
		end
		local label = o.items[index].label
		table.insert(labels, label)
		width = math.max(width, #label)
	end
	local lines, marks = {}, {}
	local from = 0
	for i, label in labels do
		local item = o.items[o.matches[i]]
		local line = ` {label}{string.rep(" ", width - #label)}`
		if item.detail then
			line ..= `  {item.detail}`
		end
		menu.mark_row(marks, from, line, i == o.current, kern.fuzzy_positions(typed, label), 1)
		table.insert(lines, line)
		from += #line + 1
	end
	local buffer = o.menu:buffer()
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:decorate("completion", marks)
	local longest = 0
	for _, line in lines do
		longest = math.max(longest, utf8.len(line) or #line)
	end
	o.menu:configure({ width = longest + 3, height = #lines + 2 })
end

-- Narrows the items to what's typed now, closing the menu when nothing's left.
local function refresh(o: Open)
	local typed = o.buffer:slice(o.start, head(o.view))
	local labels = {}
	for i, item in o.items do
		labels[i] = item.label
	end
	o.matches = kern.fuzzy(typed, labels)
	o.current = 1
	if #o.matches == 0 then
		close()
		return
	end
	render(o)
end

-- Opens the menu at the cursor in `view` with what of `items` matches the
-- word being typed. Returns whether anything did.
local function show(view: kern.View, items: { Item }): boolean
	local mode = kern.mode.get()
	local buffer = view:buffer()
	if #items == 0 then
		return false
	end
	close()
	local start = word_start(buffer, head(view))
	for _, item in items do
		if item.from then
			start = math.min(start, item.from)
		end
	end
	local list = kern.create_buffer("completion", "", { readonly = true })
	local float = kern.float(list, { anchor = "cursor", width = 20, height = 3, focus = false })
	local o: Open = {
		view = view,
		buffer = buffer,
		menu = float,
		items = items,
		matches = {},
		current = 1,
		start = start,
		mode = mode,
	}
	open = o
	kern.mode.set(`completion-{mode}`)
	refresh(o)
	return open ~= nil
end

-- Asks the server what could go at the cursor in `view`, and opens the menu
-- if anything matches. `wanted` is the generation the ask was for.
local function ask(view: kern.View, wanted: number)
	local mode = kern.mode.get()
	local buffer = view:buffer()
	if TYPING[mode] == nil or buffer:path() == nil then
		return
	end
	local ok, result = pcall(kern.lsp.request, buffer, "textDocument/completion", {
		textDocument = { uri = kern.lsp.uri(buffer) },
		position = kern.lsp.position(buffer, head(view)),
	})
	if not ok or result == nil or wanted ~= generation or kern.mode.get() ~= mode then
		return
	end
	show(view, items_from(result, buffer))
end

-- Typing a word character or "." asks again once typing pauses; anything
-- else closes the menu.
kern.on("buffer.changed", function(event: kern.BufferChanged)
	local view = kern.view()
	if event.buffer:id() ~= view:buffer():id() then
		return
	end
	local mode = kern.mode.get()
	local typing = TYPING[mode] ~= nil or (open ~= nil and mode == `completion-{open.mode}`)
	if not typing then
		return
	end
	generation += 1
	local wanted = generation
	local buffer = view:buffer()
	local pos = head(view)
	local ch = if pos > 0 then buffer:char_at(buffer:prev_char(pos)) or "" else ""
	local in_word = is_word(ch)
	if open then
		if in_word and pos > open.start then
			refresh(open)
		else
			close()
		end
		return
	end
	local delay = kern.option.get("completion-delay") :: number
	if delay <= 0 or not (in_word or ch == ".") then
		return
	end
	kern.sleep(delay)
	-- The view typed into may have closed meanwhile, like the command line
	-- on enter; only the one still focused gets asked about.
	if wanted == generation and open == nil and kern.view():id() == view:id() then
		ask(view, wanted)
	end
end)

kern.command({
	name = "completion-ask",
	doc = "Ask the language server what could go at the cursor",
	run = function(ctx)
		generation += 1
		ask(ctx.view, generation)
	end,
})

local function move(delta: number)
	local o = open
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
local function words(view: kern.View): { Item }
	local buffer = view:buffer()
	local pos = head(view)
	local typed = buffer:slice(word_start(buffer, pos), pos)
	local texts = { buffer:slice(pos, buffer:len()), buffer:slice(0, pos) }
	for _, other in kern.buffers() do
		if other:id() ~= buffer:id() then
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
	kern.command({
		name = if back then "completion-words-back" else "completion-words",
		doc = if back
			then "Complete the word being typed from words in open files, starting with the last"
			else "Complete the word being typed from words in open files",
		run = function(ctx)
			if not show(ctx.view, words(ctx.view)) then
				kern.echo("no words to complete")
			elseif back then
				move(-1)
			end
		end,
	})
end

kern.command({
	name = "completion-next",
	doc = "Move to the next completion",
	run = function()
		move(1)
	end,
})

kern.command({
	name = "completion-prev",
	doc = "Move to the previous completion",
	run = function()
		move(-1)
	end,
})

kern.command({
	name = "completion-accept",
	doc = "Put the current completion in place of the word being typed",
	run = function()
		local o = open
		if o == nil then
			return
		end
		local item = o.items[o.matches[o.current]]
		local to = head(o.view)
		close()
		o.buffer:edit(function(e)
			e:replace(o.start, to, item.text)
			local at = o.start + #item.text
			e:select({ ranges = { { anchor = at, head = at } }, primary = 1 })
		end)
		-- What was just put in isn't something to complete again.
		generation += 1
	end,
})

kern.command({
	name = "completion-close",
	doc = "Close the completion menu and do what esc does where you were typing",
	run = function()
		close()
		kern.keys.feed("esc")
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

for mode, fallback in TYPING do
	local completing = `completion-{mode}`
	kern.keymap.inherit(completing, mode)
	kern.keymap.bind(completing, KEYS)
	kern.keymap.fallback(completing, fallback)
	kern.mode.cursor(completing, "bar")
	core.style.shown_as[completing] = mode
	kern.keymap.bind(mode, { ["ctrl-space"] = "completion-ask" })
end
-- Helix's own key for it; edit mode keeps ctrl-x for cut.
kern.keymap.bind("insert", { ["ctrl-x"] = "completion-ask" })

return {}
