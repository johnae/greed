-- Completion from the language server: a short pause while typing a word
-- (or after a "." or "/") asks the server, and a menu at the cursor lists
-- what matches the word so far. tab or ctrl-n and shift-tab or ctrl-p move
-- through it, enter takes the current one, esc closes it; typing narrows
-- it. ctrl-space asks right away. Words from open files come after what
-- the server offers, once two letters are typed; completion-words offers
-- them alone, for Vim's ctrl-n and ctrl-p. A path being typed, starting
-- "./", "../", "~/" or "/", completes from its folder instead.
--
-- Sources ask before the server and say how their menu behaves: whether
-- enter takes the first item or only one moved to (completion-enter),
-- whether tab completes in place as a shell's does, and whether a menu
-- that opened by itself leaves up and down to the buffer. A source that
-- adds (like the words) puts its items after the server's instead of
-- deciding alone.
--
-- While the menu is open the editor is in a mode of its own that keeps
-- every key of the mode you were typing in, so nothing else changes.

local greed = require("@greed")
local core = require("@core")
local ui = core.ui

greed.option.define({
	name = "completion-delay",
	doc = "Milliseconds of no typing before a completion menu opens by itself; 0 opens it only when asked",
	default = 150,
})

greed.option.define({
	name = "completion-enter",
	doc = 'What enter does in a completion menu: "first" puts in the first item, "selected" only '
		.. "one moved to with tab or the arrows (otherwise enter does what it does without a menu, "
		.. 'like running a shell\'s line), "auto" lets each source say: the shell "selected", '
		.. 'language servers "first"',
	default = "auto",
	choices = { "auto", "first", "selected" },
})

-- The modes completion works in: every style's typing modes.
local TYPING: { [string]: boolean } = {}

-- At most this many items are listed.
local SHOWN = 10

local M = {}

--- Something that could go at the cursor (see `core.CompletionItem`).
export type Item = core.CompletionItem

--- How the menu was asked for: `explicit` when you asked (tab,
--- ctrl-space), not by a pause in typing.
export type Ask = { explicit: boolean }

--- Says what could go at the cursor in a view, or nil to leave it to the
--- next source and then the language server. It can wait, as for a
--- program's answer; one that comes after more typing is dropped.
export type Source = (view: greed.View, ask: Ask) -> { Item }?

--- How a source's menu behaves.
export type SourceOptions = {
	--- What enter does while completion-enter is "auto": "first" (the
	--- default) puts in the first item, "selected" only one moved to.
	enter: ("first" | "selected")?,
	--- "insert" makes tab complete in place, as a shell does: the only
	--- match or what all matches start with at once, else the menu, and
	--- tab again puts each item in place in turn. "next" (the default)
	--- moves through the menu.
	tab: ("next" | "insert")?,
	--- "after-tab" leaves up and down to the buffer (a shell's history)
	--- while a menu that opened by itself hasn't been moved into with tab;
	--- "menu" (the default) moves through it.
	arrows: ("menu" | "after-tab")?,
	--- Adds its items to the language server's, after them, rather than
	--- deciding alone; the menu then behaves as the server's does.
	adds: boolean?,
}

type Registered = { source: Source, options: SourceOptions }

local sources: { Registered } = {}

--- Asks `source` what could go at the cursor before the language server is
--- asked, in any buffer, a file or not: the first source to answer (even
--- with nothing) decides, and `options` say how its menu behaves. With
--- `adds`, it doesn't decide: what it offers goes after the server's
--- items. It goes when the plugin that added it does.
function M.source(source: Source, options: SourceOptions?)
	greed.plugin.tie(core.registry.put(sources, { source = source, options = options or {} }))
end

type Open = {
	view: greed.View,
	buffer: greed.Buffer,
	float: core.TypingFloat,
	-- What draws the menu in the float.
	drawn: core.UiView,
	-- Every item the server sent, and the ones matching what's typed.
	items: { Item },
	matches: { number },
	-- How many of the items come first, before what adding sources offer.
	first: number?,
	-- The highlighted match, 0 for none.
	current: number,
	-- Where the word being completed starts, following edits elsewhere,
	-- like a shell's output above its prompt.
	start: greed.Anchor,
	-- The mode to go back to.
	mode: string,
	options: SourceOptions,
	-- Whether it was asked for (tab, ctrl-space), and whether it was moved
	-- through since.
	explicit: boolean,
	moved: boolean,
	-- With tab "insert": whether the current item is in place, what was
	-- typed from `start` before one was, and whether the menu is putting
	-- one there now.
	placed: boolean,
	original: string?,
	placing: boolean,
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

-- The acting client's menu, for a command `ctx` runs on it: the view typed
-- into is taken through `ctx` from here on, so what you pick goes in as
-- your own edit rather than the plugin's.
local function picked(ctx: greed.Context): Open?
	local o = mine()
	if o and ctx.view == o.view then
		o.view, o.buffer = ctx.view, ctx.buffer
	end
	return o
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

-- What enter does in `options`' menu: "first" or "selected".
local function enter_mode(options: SourceOptions): string
	local set = greed.option.get("completion-enter")
	if set == "first" or set == "selected" then
		return set
	end
	return options.enter or "first"
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

--- The indexes of `labels` matching `typed`, best first: those starting
--- with it, then those holding it, then the other fuzzy matches, each in
--- the fuzzy match's order.
function M.rank(typed: string, labels: { string }): { number }
	local order = greed.fuzzy(typed, labels, { case = core.search.case() })
	if typed == "" then
		return order
	end
	local lower = string.lower(typed)
	local starting, holding, rest = {}, {}, {}
	for _, index in order do
		local label = string.lower(labels[index])
		if string.sub(label, 1, #lower) == lower then
			table.insert(starting, index)
		elseif string.find(label, lower, 1, true) then
			table.insert(holding, index)
		else
			table.insert(rest, index)
		end
	end
	table.move(holding, 1, #holding, #starting + 1, starting)
	table.move(rest, 1, #rest, #starting + 1, starting)
	return starting
end

local function close()
	local o = mine()
	if o then
		o.float.close()
	end
end

-- The matching items, a row each: the label with what's typed picked out,
-- its badge and its detail, the current one marked.
local function draw(o: Open): core.UiNode
	local typed = o.original or o.buffer:slice(start_of(o), o.view:cursor())
	local width, badges = 0, 0
	for i, index in o.matches do
		if i > SHOWN then
			break
		end
		local item = o.items[index]
		width = math.max(width, core.text.width(item.label))
		badges = math.max(badges, if item.badge then core.text.width(item.badge) else 0)
	end
	local shown = table.move(o.matches, 1, math.min(#o.matches, SHOWN), 1, {})
	return ui.list(shown, function(index: number): { core.UiSpan }
		local item = o.items[index]
		local label = item.label
		local spans: { core.UiSpan } = { ui.span(" ") }
		local matched = greed.fuzzy_positions(typed, label, { case = core.search.case() })
		for _, span in ui.matched(label, matched) do
			table.insert(spans, span)
		end
		table.insert(spans, ui.span(string.rep(" ", width - core.text.width(label))))
		if badges > 0 then
			local badge = item.badge or ""
			table.insert(spans, ui.span("  "))
			table.insert(spans, ui.span(badge, "ui.menu.badge"))
			table.insert(spans, ui.span(string.rep(" ", badges - core.text.width(badge))))
		end
		if item.detail then
			table.insert(spans, ui.span("  "))
			table.insert(spans, ui.span(item.detail, "ui.menu.doc"))
		end
		return spans
	end, { current = o.current })
end

-- Draws the matching items and marks the current one, the float as big
-- as they are.
local function render(o: Open)
	o.drawn:redraw()
	local buffer = o.float.buffer
	local longest = 0
	for line = 0, buffer:line_count() - 1 do
		longest = math.max(longest, core.text.width(buffer:line_text(line)))
	end
	o.float.view:configure({ width = longest + 3, height = buffer:line_count() + 2 })
end

--- The indexes of `items` matching `typed`, best first; with `first`, the
--- matches among the first that many items come before the rest, however
--- well those match, as an adding source's come after the server's.
function M.matching(items: { Item }, typed: string, first: number?): { number }
	local labels = {}
	for i, item in items do
		labels[i] = item.label
	end
	local ahead, after = {}, {}
	for _, index in M.rank(typed, labels) do
		table.insert(if first and index > first then after else ahead, index)
	end
	table.move(after, 1, #after, #ahead + 1, ahead)
	return ahead
end
local matching = M.matching

-- Narrows the items to what's typed now, closing the menu when nothing's left.
local function refresh(o: Open)
	o.matches = matching(o.items, o.buffer:slice(start_of(o), o.view:cursor()), o.first)
	o.current = if enter_mode(o.options) == "first" then 1 else 0
	if #o.matches == 0 then
		close()
		return
	end
	render(o)
end

-- Puts `text` from `start` to the cursor of `view` in `buffer`, with the
-- cursor after it; what's put in isn't something to complete again.
local function put(buffer: greed.Buffer, start: number, view: greed.View, text: string)
	local to = view:cursor()
	buffer:edit(function(e)
		e:replace(start, to, text)
		local at = start + #text
		e:select({ ranges = { { anchor = at, head = at } }, primary = 1 })
	end)
	next_generation()
end

-- What `typed` (from `start`) becomes with `item` in place: the item's
-- text from where it starts.
local function with_item(typed: string, start: number, item: Item): string
	local offset = math.clamp((item.from or start) - start, 0, #typed)
	return string.sub(typed, 1, offset) .. item.text
end

-- The longest start all of `texts` share.
local function common_start(texts: { string }): string
	local common = texts[1] or ""
	for i = 2, #texts do
		local text = texts[i]
		local n = 0
		while
			n < #common
			and n < #text
			and string.byte(common, n + 1) == string.byte(text, n + 1)
		do
			n += 1
		end
		common = string.sub(common, 1, n)
	end
	-- Not in the middle of a character.
	while #common > 0 and utf8.len(common) == nil do
		common = string.sub(common, 1, -2)
	end
	return common
end

-- What tab puts in at once in place of `typed` (from `start`), as a shell
-- completes: the only match, or what all those starting with what's typed
-- share, when that's more than what's typed. Nil when it's the menu's to
-- show.
local function completed(
	items: { Item },
	matches: { number },
	typed: string,
	start: number
): string?
	local starting: { string } = {}
	for _, index in matches do
		local text = with_item(typed, start, items[index])
		if string.sub(text, 1, #typed) == typed then
			table.insert(starting, text)
		end
	end
	if #starting == 1 or (#starting == 0 and #matches == 1) then
		return starting[1] or with_item(typed, start, items[matches[1]])
	end
	local common = common_start(starting)
	return if #common > #typed then common else nil
end

-- Opens the menu at the cursor in `view` with what of `items` matches the
-- word being typed, asked for or not (`explicit`), as `options` say. With
-- tab "insert", asking puts the only match in place at once, or what the
-- matches share. With `first`, the first that many items come before the
-- rest. Returns whether anything matched.
local function show(
	view: greed.View,
	items: { Item },
	options: SourceOptions,
	explicit: boolean,
	first: number?
): boolean
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
	if explicit and options.tab == "insert" then
		local typed = buffer:slice(start, view:cursor())
		local matches = matching(items, typed, first)
		if #matches == 0 then
			return false
		end
		local text = completed(items, matches, typed, start)
		if text then
			put(buffer, start, view, text)
			return true
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
		first = first,
		current = 0,
		start = buffer:track(start, { gravity = "left" }),
		mode = mode,
		options = options,
		explicit = explicit,
		moved = false,
		placed = false,
		original = nil :: string?,
		placing = false,
		drawn = ui.mount(float.buffer, function()
			return draw(o)
		end, nil, { ns = "completion", keys = false, draw = false }),
	}
	opened[client] = o
	refresh(o)
	if opened[client] == o and explicit and options.tab == "insert" then
		-- Asked for with tab: nothing's chosen until tab moves.
		o.current = 0
		render(o)
	end
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
	local adding: { Registered } = {}
	for _, registered in table.clone(sources) do
		if registered.options.adds then
			table.insert(adding, registered)
			continue
		end
		local answered, items = pcall(registered.source, view, { explicit = explicit })
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
				show(view, items, registered.options, explicit)
			end
			return
		end
	end
	-- What the adding sources offer, before the server's answer moves the
	-- cursor on.
	local added: { Item } = {}
	for _, registered in adding do
		local answered, items = pcall(registered.source, view, { explicit = explicit })
		if answered and items then
			table.move(items, 1, #items, #added + 1, added)
		end
	end
	local items: { Item } = {}
	if buffer:path() ~= nil then
		-- Where the cursor is takes the server's encoding: a buffer with no
		-- server fails there as much as at the request.
		local ok, result = pcall(function()
			return greed.lsp.request(buffer, "textDocument/completion", {
				textDocument = { uri = greed.lsp.uri(buffer) },
				position = greed.lsp.position(buffer, view:cursor()),
			})
		end)
		if ok and result ~= nil then
			items = items_from(result, buffer)
		end
	end
	if wanted ~= generation() or greed.mode.get() ~= mode or not view:valid() then
		return
	end
	local first = #items
	local offered: { [string]: boolean } = {}
	for _, item in items do
		offered[item.label] = true
	end
	for _, item in added do
		if not offered[item.label] then
			offered[item.label] = true
			table.insert(items, item)
		end
	end
	show(view, items, { enter = "first" }, explicit, first)
end

-- Typing a word character, "." or "/" asks again once typing pauses;
-- anything else closes the menu, and so does typing after an item tab put
-- in place. A "/" closes it too, then asks for what's in that folder.
greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	if event.buffer ~= view:buffer() then
		return
	end
	local mode = greed.mode.get()
	local open = mine()
	if open and open.placing then
		return
	end
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
		if in_word and pos > start_of(open) and not open.placed then
			refresh(open)
			return
		end
		close()
		if ch ~= "/" then
			return
		end
	end
	local delay = greed.option.get("completion-delay") :: number
	if delay <= 0 or not (in_word or ch == "." or ch == "/") then
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
	doc = "Ask what could go at the cursor: a source like the shell's, or the language server",
	run = function(ctx)
		ask(ctx.view, next_generation(), true)
	end,
})

-- Puts `o`'s current item in place of what was typed, keeping the menu.
local function place(o: Open)
	local start = start_of(o)
	local original = o.original or o.buffer:slice(start, o.view:cursor())
	o.original = original
	o.placing = true
	put(o.buffer, start, o.view, with_item(original, start, o.items[o.matches[o.current]]))
	o.placing = false
	o.placed = true
end

-- Moves `delta` items through the menu; with tab "insert", putting each in
-- place, starting with the highlighted one when none is yet.
local function move(delta: number)
	local o = mine()
	if o == nil then
		return
	end
	local count = math.min(#o.matches, SHOWN)
	local inserting = o.options.tab == "insert"
	if o.current == 0 then
		o.current = if delta > 0 then 1 else count
	elseif not (inserting and not o.placed and delta > 0) then
		o.current = (o.current - 1 + delta) % count + 1
	end
	o.moved = true
	if inserting then
		place(o)
	end
	render(o)
end

-- At most this many words are offered.
local WORDS = 200
-- How many bytes of each buffer are looked through for words, either side
-- of the cursor in the one typed in, so a huge file costs no more than a
-- big one.
local SCAN = 200000

-- The words in open buffers that start with what's typed before the cursor
-- in `view`: this buffer's from the cursor on, then before it, then the
-- other buffers'.
local function words(view: greed.View): { Item }
	local buffer = view:buffer()
	local pos = view:cursor()
	local typed = buffer:slice(word_start(buffer, pos), pos)
	local texts = {
		buffer:slice(pos, math.min(buffer:len(), pos + SCAN)),
		buffer:slice(math.max(0, pos - SCAN), pos),
	}
	for _, other in greed.buffers() do
		if other ~= buffer and other:kind() == "file" then
			table.insert(texts, other:slice(0, math.min(other:len(), SCAN)))
		end
	end
	local seen: { [string]: boolean } = {}
	local found: { Item } = {}
	for _, text in texts do
		for word in string.gmatch(text, "[%a_\128-\255][%w_\128-\255]*") do
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

-- The kinds of buffer words and paths are offered in by themselves: files,
-- not prompts or a shell, whose sources have their own.
local TEXT_KINDS = { file = true, multibuffer = true }

-- Words come after what the server offers, once two letters are typed.
M.source(function(view: greed.View, asked: Ask): { Item }?
	local buffer = view:buffer()
	if not TEXT_KINDS[buffer:kind()] then
		return nil
	end
	local pos = view:cursor()
	if not asked.explicit and pos - word_start(buffer, pos) < 2 then
		return nil
	end
	return words(view)
end, { adds = true })

-- The path being typed before `pos` on its line, if it looks like one:
-- starting "./", "../", "~/" or "/" (but not "//", a comment).
local function typed_path(buffer: greed.Buffer, pos: number): string?
	local line = buffer:slice(buffer:line_start(buffer:line_of(pos)), pos)
	local path = string.match(line, "[%w_%.%-~/+@]*$") or ""
	local looks = string.match(path, "^%.%.?/") or string.match(path, "^~/")
	if looks or (string.match(path, "^/") and not string.match(path, "^//")) then
		return path
	end
	return nil
end

-- A path being typed completes from its folder: the file's for "./" and
-- "../", the home folder for "~/".
M.source(function(view: greed.View): { Item }?
	local buffer = view:buffer()
	if not TEXT_KINDS[buffer:kind()] then
		return nil
	end
	local pos = view:cursor()
	local path = typed_path(buffer, pos)
	if path == nil then
		return nil
	end
	local folder, name = string.match(path, "^(.*/)([^/]*)$")
	if folder == nil or name == nil then
		return nil
	end
	local file = buffer:path()
	local here = if file then string.match(file, "^(.*)/[^/]*$") else nil
	local entries = greed.fs.list(
		core.project.resolve(folder, here),
		{ hidden = string.sub(name, 1, 1) == ".", ignored = true }
	)
	if entries == nil then
		return nil
	end
	local items: { Item } = {}
	for _, entry in entries do
		local label = if entry.dir then entry.name .. "/" else entry.name
		table.insert(items, { label = label, text = label, from = pos - #name })
	end
	return items
end)

-- completion-words and completion-words-back: Vim's ctrl-n and ctrl-p.
for _, back in { false, true } do
	greed.command({
		name = if back then "completion-words-back" else "completion-words",
		doc = if back
			then "Complete the word being typed from words in open files, starting with the last"
			else "Complete the word being typed from words in open files",
		run = function(ctx)
			if not show(ctx.view, words(ctx.view), { enter = "first" }, true) then
				greed.echo("no words to complete")
			else
				local o = mine()
				if o and o.current == 0 then
					o.current = 1
					render(o)
				end
				if back then
					move(-1)
				end
			end
		end,
	})
end

greed.command({
	name = "completion-next",
	doc = "Move to the next completion",
	run = function(ctx)
		picked(ctx)
		move(1)
	end,
})

greed.command({
	name = "completion-prev",
	doc = "Move to the previous completion",
	run = function(ctx)
		picked(ctx)
		move(-1)
	end,
})

greed.command({
	name = "completion-tab",
	doc = "Move to the next completion; where tab completes in place, as in a shell, first put in "
		.. "what every match starts with",
	run = function(ctx)
		local o = picked(ctx)
		if o == nil then
			return
		end
		o.explicit = true
		if o.options.tab == "insert" and not o.moved then
			local start = start_of(o)
			local typed = o.buffer:slice(start, o.view:cursor())
			local text = completed(o.items, o.matches, typed, start)
			if text then
				put(o.buffer, start, o.view, text)
				if #o.matches == 1 then
					close()
				end
				return
			end
		end
		move(1)
	end,
})

-- up and down: through the menu, unless it leaves them to the buffer until
-- it's been moved into.
for _, key in { "up", "down" } do
	greed.command({
		name = `completion-{key}`,
		doc = if key == "up"
			then "Move to the previous completion, or in a shell's menu that opened by itself, the command before"
			else "Move to the next completion, or in a shell's menu that opened by itself, the command after",
		run = function(ctx)
			local o = picked(ctx)
			if o == nil then
				return
			end
			if o.options.arrows == "after-tab" and not (o.explicit or o.moved) then
				close()
				greed.keys.feed(key)
				return
			end
			move(if key == "up" then -1 else 1)
		end,
	})
end

greed.command({
	name = "completion-accept",
	doc = "Put the current completion in place of the word being typed; with none chosen, "
		.. "close the menu and do what enter does",
	run = function(ctx)
		local o = picked(ctx)
		if o == nil then
			return
		end
		if o.placed then
			close()
			next_generation()
			return
		end
		if o.current == 0 then
			close()
			greed.keys.feed("enter")
			return
		end
		local item = o.items[o.matches[o.current]]
		local start = start_of(o)
		local typed = o.buffer:slice(start, o.view:cursor())
		close()
		put(o.buffer, start, o.view, with_item(typed, start, item))
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
	tab = "completion-tab",
	["ctrl-n"] = "completion-next",
	down = "completion-down",
	["shift-tab"] = "completion-prev",
	["ctrl-p"] = "completion-prev",
	up = "completion-up",
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
