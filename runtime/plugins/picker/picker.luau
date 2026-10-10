-- The picker itself: a floating buffer, kept in sync with what's typed.

local greed = require("@greed")
local core = require("@core")
local menu = core.menu

export type Item = {
	label: string,
	value: any,
	--- What the item is, for `alt-.` to list its actions (see core's
	--- actions): "file" for a path, "command" for a command's name, ...
	kind: string?,
}

--- What to show beside the picker for the current item.
export type Preview = {
	text: string,
	--- The language to highlight it as, e.g. from `greed.language_of(path)`.
	language: string?,
	--- A 0-based line to scroll to.
	line: number?,
}

type Paths = { dirs: boolean?, choose: (path: string) -> () }

export type Options = {
	--- Shows a preview of the current item beside the list. Returning nil
	--- leaves the preview empty.
	preview: ((item: Item) -> Preview?)?,
	--- More keys for this picker, e.g. `["ctrl-e"] = ...`. Each closes the
	--- picker and gets the items matching what was typed, best first, and
	--- the current one.
	keys: { [string]: (items: { Item }, current: Item?) -> () }?,
	--- Asks for the items as the query changes, instead of filtering a fixed
	--- list, for searches too big to list up front. It runs `delay` ms after
	--- typing stops and can wait, e.g. on `greed.fs.grep`; answers for a query
	--- that has since changed are dropped. `items` can be empty then.
	source: ((query: string) -> { Item })?,
	--- Milliseconds without typing before `source` runs; 100 by default.
	delay: number?,
	--- Called with what was typed when enter is pressed and nothing matches,
	--- e.g. to open a folder that isn't in the list.
	fallback: ((query: string) -> ())?,
	--- Called with the current item whenever it changes, e.g. to try it out
	--- as you move, as the theme picker does.
	on_move: ((item: Item) -> ())?,
	--- Called when the picker ends without choosing: esc, another picker
	--- opening, or its view closing.
	on_cancel: (() -> ())?,
	--- Lets you type a path: a query starting with "/", "~", "./" or "../"
	--- lists what's in that folder instead of the items, narrowed by what's
	--- typed after the last "/" (only folders with `dirs`). tab completes
	--- the current one into the query, and enter gives `choose` its full path.
	paths: Paths?,
	--- Words of the query starting with `@` (`@shell`) keep the items it says
	--- have them, and aren't matched against the labels. `word` comes
	--- without its `@`, and may be only part of one, while it's typed.
	tags: ((item: Item, word: string) -> boolean)?,
}

-- At most this many matches are shown.
local LIMIT = 200

type Open = {
	-- The client it's open for; each has its own picker.
	client: number,
	buffer: greed.Buffer,
	view: greed.View,
	items: { Item },
	labels: { string },
	query: string?,
	matches: { number },
	current: number,
	choose: (item: Item) -> (),
	float: core.TypingFloat,
	-- Closing because an item was chosen.
	chosen: boolean?,
	preview: ((item: Item) -> Preview?)?,
	keys: { [string]: (items: { Item }, current: Item?) -> () },
	source: ((query: string) -> { Item })?,
	delay: number,
	fallback: ((query: string) -> ())?,
	-- Goes up with each query, so a source's late answer can tell it's stale.
	generation: number,
	searching: boolean,
	preview_view: greed.View?,
	-- The item the preview shows.
	previewed: Item?,
	on_move: ((item: Item) -> ())?,
	-- The item `on_move` last heard of.
	moved_to: Item?,
	on_cancel: (() -> ())?,
	paths: Paths?,
	tags: ((item: Item, word: string) -> boolean)?,
	-- The query without its `@` words, as matched against the labels.
	matched: string?,
	-- The items and their labels as given, while a path's folder is listed
	-- instead.
	given: { items: { Item }, labels: { string } }?,
}

-- Shows the current item in the preview, if it changed.
local function update_preview(o: Open)
	local view, preview = o.preview_view, o.preview
	if view == nil or preview == nil then
		return
	end
	local index = o.matches[o.current]
	local item = if index then o.items[index] else nil
	if item == o.previewed then
		return
	end
	o.previewed = item
	local shown = if item then preview(item) else nil
	local text = if shown then shown.text else ""
	view:show(
		greed.create_buffer(
			"preview",
			text,
			{ readonly = true, language = shown and shown.language }
		)
	)
	view:configure({ title = if shown then (item :: Item).label else "" })
	if shown and shown.line then
		local buffer = view:buffer()
		local line = math.clamp(shown.line, 0, buffer:line_count() - 1)
		local at = buffer:line_start(line)
		view:set_cursor(at)
	end
end

-- The picker open for each client, by its id.
local opened: { [number]: Open } = {}

-- The acting client's picker, if it has one open.
local function mine(): Open?
	return opened[greed.client.id()]
end

-- Whether `o` is still its client's open picker.
local function still_open(o: Open): boolean
	return opened[o.client] == o
end

local function query(o: Open): string
	return o.buffer:slice(0, o.buffer:line_end(0))
end

-- Rewrites the lines below the query to show the matches, keeping the
-- cursor where it is in the query.
local function render(o: Open)
	local lines = {}
	local marks: { greed.Mark } = {}
	local from = o.buffer:line_end(0) + 1
	for i, index in o.matches do
		if i > LIMIT then
			break
		end
		local line = " " .. o.labels[index]
		menu.mark_row(
			marks,
			from,
			line,
			i == o.current,
			if o.source
				then {}
				else greed.fuzzy_positions(
					o.matched or o.query or "",
					o.labels[index],
					{ case = core.search.case() }
				),
			1
		)
		table.insert(lines, line)
		from += #line + 1
	end
	-- Typing that matches nothing says so, rather than leaving the list blank.
	if #o.matches == 0 and (o.query or "") ~= "" then
		local at = o.buffer:line_end(0)
		table.insert(
			marks,
			{ from = at, to = at, text = "  nothing matches", eol = true, style = "comment" }
		)
	end
	local selection = o.view:selection()
	o.buffer:edit(function(e)
		e:replace(o.buffer:line_end(0), o.buffer:len(), "\n" .. table.concat(lines, "\n"))
		e:select(selection)
	end)
	o.buffer:decorate("picker", marks)
	update_preview(o)
	local index = o.matches[o.current]
	local item = if index then o.items[index] else nil
	if o.on_move and item and item ~= o.moved_to then
		o.moved_to = item
		o.on_move(item)
	end
end

-- Puts `items` in the list, as a source's answer.
local function set_items(o: Open, items: { Item })
	o.items = items
	o.labels = {}
	o.matches = {}
	for i, item in items do
		o.labels[i] = item.label
		o.matches[i] = i
	end
	o.current = 1
	render(o)
end

-- Asks the source for items until the answer is for the latest query.
-- Typing while it works makes it go again; answers in between are dropped.
local function search(o: Open, source: (query: string) -> { Item })
	o.searching = true
	while still_open(o) do
		local generation = o.generation
		local ok, items = pcall(source, o.query or "")
		if not still_open(o) then
			break
		end
		if generation == o.generation then
			set_items(o, if ok then items else {})
			break
		end
	end
	o.searching = false
end

-- Whether `q` is a path to list rather than something to look for.
local function is_path(q: string): boolean
	return string.match(q, "^[~/]") ~= nil or string.match(q, "^%.%.?/") ~= nil
end

-- Lists what's in the folder `q` names, narrowed by what's typed after its
-- last "/", in place of the items. Labels are paths as typed, so tab can
-- put them in the query.
local function list_path(o: Open, q: string, paths: Paths)
	local dir, typed = string.match(q, "^(.*/)(.*)$")
	if dir == nil then
		-- "~" alone is the home folder.
		dir, typed = q .. "/", ""
	end
	local found: { greed.DirEntry } = greed.fs.list(core.project.expand(dir :: string), {
		hidden = string.sub(typed :: string, 1, 1) == ".",
		ignored = true,
	}) or {}
	local items, labels, names = {}, {}, {}
	for _, entry in found do
		if entry.dir or not paths.dirs then
			local label = `{dir}{entry.name}{if entry.dir then "/" else ""}`
			table.insert(items, { label = label, value = label })
			table.insert(labels, label)
			table.insert(names, entry.name)
		end
	end
	o.given = o.given or { items = o.items, labels = o.labels }
	o.items, o.labels = items, labels
	o.matches = greed.fuzzy(typed :: string, names, { case = core.search.case() })
	o.current = 1
	render(o)
end

-- The items matching `q`, best first: its `@` words keep those `o.tags`
-- says have them, and the rest of it is matched against their labels.
local function matching(o: Open, q: string): { number }
	local tags = o.tags
	o.matched = q
	if tags == nil then
		return greed.fuzzy(q, o.labels, { case = core.search.case() })
	end
	local words: { string } = {}
	local rest = string.gsub(q, "%s*@(%S*)", function(word: string): string
		table.insert(words, word)
		return ""
	end)
	o.matched = rest
	local out = {}
	for _, index in greed.fuzzy(rest, o.labels, { case = core.search.case() }) do
		local keep = true
		for _, word in words do
			if word ~= "" and not tags(o.items[index], word) then
				keep = false
				break
			end
		end
		if keep then
			table.insert(out, index)
		end
	end
	return out
end

-- Filters the items again if the query changed, or with a source, asks it
-- once typing pauses.
local function refresh(o: Open)
	local q = query(o)
	if q == o.query then
		return
	end
	o.query = q
	local paths = o.paths
	if paths and is_path(q) then
		list_path(o, q, paths)
		return
	end
	local given = o.given
	if given then
		o.items, o.labels, o.given = given.items, given.labels, nil
	end
	local source = o.source
	if source == nil then
		o.matches = matching(o, q)
		o.current = 1
		render(o)
		return
	end
	o.generation += 1
	local generation = o.generation
	if q == "" then
		set_items(o, {})
		return
	end
	greed.sleep(o.delay)
	if still_open(o) and generation == o.generation and not o.searching then
		search(o, source)
	end
end

-- Closes the acting client's picker. Unless an item was chosen,
-- `on_cancel` hears that it ended, however it did: esc, another picker, or
-- its view closing (see `pick`).
local function close(chosen: boolean?)
	local o = mine()
	if o then
		o.chosen = chosen
		o.float.close()
	end
end

local function move(delta: number)
	local o = mine()
	if o and #o.matches > 0 then
		local count = math.min(#o.matches, LIMIT)
		o.current = (o.current - 1 + delta) % count + 1
		render(o)
	end
end

-- The keys every picker has.
local KEYS: { [string]: string } = {
	down = "picker-next",
	up = "picker-prev",
	["ctrl-n"] = "picker-next",
	["ctrl-p"] = "picker-prev",
	enter = "picker-choose",
	esc = "picker-close",
	tab = "picker-complete",
	["alt-."] = "picker-act",
}

greed.command({
	name = "picker-next",
	doc = "Move to the next item in the picker",
	run = function()
		move(1)
	end,
})

greed.command({
	name = "picker-prev",
	doc = "Move to the previous item in the picker",
	run = function()
		move(-1)
	end,
})

greed.command({
	name = "picker-choose",
	doc = "Choose the current item and close the picker",
	run = function()
		local o = mine()
		if o == nil then
			return
		end
		local index = o.matches[o.current]
		local typed = if o.fallback and o.query and o.query ~= "" then o.query else nil
		close(index ~= nil or typed ~= nil)
		local paths = o.paths
		if index and paths and o.given then
			-- Folders are listed with a "/" to show what they are.
			local path = string.gsub(core.project.expand(o.items[index].value), "(.)/$", "%1")
			paths.choose(path)
		elseif index then
			o.choose(o.items[index])
		elseif typed and o.fallback then
			o.fallback(typed)
		end
	end,
})

greed.command({
	name = "picker-complete",
	doc = "Put the current path in the picker's query, to go on from there",
	run = function()
		local o = mine()
		local index = o and o.matches[o.current]
		if o == nil or index == nil or o.given == nil then
			return
		end
		local label = o.labels[index]
		o.buffer:edit(function(e)
			e:replace(0, o.buffer:line_end(0), label)
			e:select({ ranges = { { anchor = #label, head = #label } }, primary = 1 })
		end)
	end,
})

greed.command({
	name = "picker-close",
	doc = "Close the picker without choosing",
	run = function()
		close()
	end,
})

greed.command({
	name = "picker-key",
	doc = "Run what the open picker does for the key pressed",
	run = function(ctx)
		local o = mine()
		local key = ctx.keys or ""
		local action = o and o.keys[key]
		if o == nil or action == nil then
			-- Another picker bound this key; in this one it does what it
			-- usually does.
			local usual = KEYS[key]
			if usual then
				greed.run(usual)
			end
			return
		end
		local items = {}
		for _, index in o.matches do
			table.insert(items, o.items[index])
		end
		local current = items[o.current]
		-- A key of its own is another way of choosing.
		close(true)
		action(items, current)
	end,
})

-- The keys bound to picker-key so far, for any picker.
local bound: { [string]: boolean } = {}

local M = {}

M.KEYS = KEYS

type Last = { title: string, items: { Item }, choose: (item: Item) -> (), options: Options? }

-- The last picker each client opened, for `resume`.
local last: { [number]: Last } = {}

-- Opens a picker over `items`, for the acting client alone. `choose` gets
-- the item picked with enter; `options.preview` shows the current item
-- beside the list, and `options.source` makes the items follow the query.
function M.pick(title: string, items: { Item }, choose: (item: Item) -> (), options: Options?)
	local client = greed.client.id()
	last[client] = { title = title, items = items, choose = choose, options = options }
	close()
	local labels = {}
	for i, item in items do
		labels[i] = item.label
	end
	local preview = options and options.preview
	-- With a preview, the list takes the left half and the preview the right.
	local preview_view = if preview
		then greed.float(
			greed.create_buffer("preview", "", { readonly = true }),
			{ x = "50%", width = "46%", height = "70%", focus = false }
		)
		else nil
	local o: Open
	local float = core.floats.typing(
		greed.create_buffer("picker"),
		if preview
			then { title = title, x = "4%", width = "46%", height = "70%" }
			else { title = title, width = "60%", height = "60%" },
		{
			on_change = function()
				if opened[client] == o then
					refresh(o)
				end
			end,
			on_close = function()
				if preview_view and preview_view:valid() then
					preview_view:close()
				end
				if opened[client] == o then
					opened[client] = nil
				end
				if o.on_cancel and not o.chosen then
					o.on_cancel()
				end
			end,
		}
	)
	o = {
		client = client,
		buffer = float.buffer,
		view = float.view,
		float = float,
		items = items,
		labels = labels,
		matches = {},
		current = 1,
		choose = choose,
		preview = preview,
		preview_view = preview_view,
		keys = options and options.keys or {},
		source = options and options.source,
		delay = options and options.delay or 100,
		fallback = options and options.fallback,
		on_move = options and options.on_move,
		on_cancel = options and options.on_cancel,
		paths = options and options.paths,
		tags = options and options.tags,
		generation = 0,
		searching = false,
	} :: Open
	for key in o.keys do
		if not bound[key] then
			bound[key] = true
			greed.keymap.bind({ kind = "picker" }, { [key] = "picker-key" })
		end
	end
	opened[client] = o
	refresh(o)
end

--- Opens the acting client's last picker again, as Helix's space '. False
--- if there's none.
function M.resume(): boolean
	local again = last[greed.client.id()]
	if again == nil then
		return false
	end
	M.pick(again.title, again.items, again.choose, again.options)
	return true
end

--- Lists the actions for `targets` (see core's actions) and runs the one
--- chosen. With several things, each action says which it's for.
function M.act(targets: { core.Target })
	-- Things of a kind found together (`group`), like a selection over five
	-- pods, offer each action once, for all of them.
	local groups: { { core.Target } } = {}
	local together: { [string]: { core.Target } } = {}
	for _, target in targets do
		local key = if target.group then `{target.kind}\0{target.group}` else nil
		local found = if key then together[key] else nil
		if found then
			table.insert(found, target)
		else
			local group = { target }
			if key then
				together[key] = group
			end
			table.insert(groups, group)
		end
	end
	-- Each group's own actions, in the order the things came, then those
	-- every kind has (pin to context), which would crowd the rest.
	local items, everywhere = {}, {}
	for _, group in groups do
		local first = group[1]
		local names = {}
		for _, target in group do
			table.insert(names, target.label)
		end
		local what = if #group > 1
			then `{#group} × {first.kind}: {table.concat(names, ", ")}`
			else `{first.kind}: {first.label}`
		for _, action in core.actions.for_kind(first.kind) do
			local label = action.name
			if #targets > 1 then
				label ..= `  {what}`
			end
			if action.doc then
				label ..= `  {action.doc}`
			end
			local item = { label = label, value = { action = action, targets = group } }
			table.insert(if action.kind == "*" then everywhere else items, item)
		end
	end
	table.move(everywhere, 1, #everywhere, #items + 1, items)
	if #items == 0 then
		greed.echo("nothing here to act on")
		return
	end
	local title = if #targets == 1 then `{targets[1].kind}: {targets[1].label}` else "Act on"
	M.pick(title, items, function(item)
		core.actions.run_all(item.value.action, item.value.targets)
	end)
end

greed.command({
	name = "picker-act",
	doc = "List what you can do with the current item, and do it",
	run = function()
		local o = mine()
		local index = o and o.matches[o.current]
		local item = o and index and o.items[index]
		if item == nil or item.kind == nil then
			greed.echo("no actions for this item")
			return
		end
		close()
		M.act({ { kind = item.kind, label = item.label, value = item.value } })
	end,
})

--- Like `pick`, but waits for the answer and returns the chosen item, or
--- nil when the picker ends without one. Works in commands and handlers:
---
---     local item = picker.choose("Model", items)
---     if item then ... end
function M.choose(title: string, items: { Item }, options: Options?): Item?
	local done = greed.signal()
	local given: Options = if options then table.clone(options) else {}
	local cancel = given.on_cancel
	given.on_cancel = function()
		if cancel then
			cancel()
		end
		done:send(false)
	end
	M.pick(title, items, function(item)
		done:send(item)
	end, given)
	local item = done:wait()
	return if item then item else nil
end

return M
