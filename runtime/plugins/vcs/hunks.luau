-- Picking hunks: a buffer listing the changes between two versions of some
-- files, where space picks hunks and enter hands back each file as it would
-- be with only the picked ones. Splitting a change uses it.
--
--   Split qpvuntsm: pick what goes in the first change
--   space picks, a picks all, enter goes on, q cancels
--
--   [x] src/main.rs  line 12  +1 -1
--       -    let x = 1;
--       +    let x = 2;
--   [ ] notes.md  new file

local greed = require("@greed")
local core = require("@core")

local ui = core.ui

local M = {}

--- A file in two versions; nil where it doesn't exist.
export type File = { path: string, old: string?, new: string? }

--- Each file as it would be with only the picked hunks: its text, or false
--- where it wouldn't exist.
export type Picked = { [string]: string | false }

export type Options = {
	--- The first line.
	title: string,
	files: { File },
	--- Called with the files as picked, how many hunks were picked and how
	--- many there are, once enter is pressed; not called when cancelled.
	done: (picked: Picked, count: number, total: number) -> (),
	--- Called when cancelled.
	cancel: (() -> ())?,
}

-- One thing to pick: a hunk of a file, or, for a file that only appears or
-- goes without any lines changing, the file as a whole. A file that isn't
-- text, like an image, is one hunk replacing all of it.
type Item = {
	file: File,
	hunk: { from: number, to: number, text: string }?,
	picked: boolean,
	whole: boolean?,
}

type Picker = {
	options: Options,
	items: { Item },
	view: greed.View,
	buffer: greed.Buffer,
	previous: greed.Buffer,
	was_kept: boolean,
	-- What draws it, each item's lines' value its index.
	drawn: core.UiView,
}

local pickers: { [number]: Picker } = {}

local function is_text(text: string?): boolean
	return text == nil or utf8.len(text) ~= nil
end

local function items_of(files: { File }): { Item }
	local items: { Item } = {}
	for _, file in files do
		if not (is_text(file.old) and is_text(file.new)) then
			local hunk = { from = 0, to = #(file.old or ""), text = file.new or "" }
			table.insert(items, { file = file, hunk = hunk, picked = false, whole = true })
			continue
		end
		local hunks = greed.diff(file.old or "", file.new or "")
		for _, hunk in hunks do
			table.insert(items, { file = file, hunk = hunk, picked = false })
		end
		if #hunks == 0 and (file.old == nil) ~= (file.new == nil) then
			table.insert(items, { file = file, picked = false })
		end
	end
	return items
end

-- Item `i`'s lines: its box, its file and where, and the lines a hunk
-- takes away and adds; each line's value `i`.
local function item_lines(i: number, item: Item): core.UiNode
	local lines: { core.UiNode } = {}
	local function add(head: string, text: string, style: string)
		table.insert(lines, ui.line({ { text = head, value = i }, ui.span(text, style) }))
	end
	local box = if item.picked then "[x] " else "[ ] "
	local hunk = item.hunk
	if item.whole then
		add(box, `{item.file.path}  not text`, "markup.heading")
	elseif hunk then
		local old = core.text.split_lines(string.sub(item.file.old or "", hunk.from + 1, hunk.to))
		local new = core.text.split_lines(hunk.text)
		local _, before = string.gsub(string.sub(item.file.old or "", 1, hunk.from), "\n", "")
		add(box, `{item.file.path}  line {before + 1}  +{#new} -{#old}`, "markup.heading")
		for _, line in old do
			add("    ", `-{line}`, "diff.minus")
		end
		for _, line in new do
			add("    ", `+{line}`, "diff.plus")
		end
	else
		local what = if item.file.old == nil then "new file" else "deleted"
		add(box, `{item.file.path}  {what}`, "markup.heading")
	end
	return ui.column(lines)
end

-- The picker: its title and keys, then each item, drawn again only when
-- it's picked or put back.
local function draw(picker: Picker): core.UiNode
	local parts: { core.UiNode } = {
		ui.line({ ui.span(picker.options.title, "markup.heading") }),
		ui.line({ ui.span("space picks, a picks all, enter goes on, q cancels", "comment") }),
		ui.gap(),
	}
	for i, item in picker.items do
		table.insert(
			parts,
			ui.keyed(`item:{i}`, item.picked, function()
				return item_lines(i, item)
			end)
		)
	end
	return ui.column(parts)
end

-- The first line of item `i`.
local function line_of_item(picker: Picker, i: number): number?
	return picker.drawn:line_of(function(item: number): boolean
		return item == i
	end)
end

local function go_to(picker: Picker, line: number)
	local pos = picker.buffer:line_start(line)
	picker.view:set_cursor(pos)
end

--- Shows the hunks between each file's two versions in `view` to pick from.
--- Enter calls `options.done` and q cancels; either puts back what `view`
--- showed.
function M.pick(view: greed.View, options: Options)
	local buffer = greed.create_buffer("hunk-picker", "", { readonly = true })
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	local previous = view:buffer()
	local picker: Picker
	picker = {
		options = options,
		items = items_of(options.files),
		view = view,
		buffer = buffer,
		previous = previous,
		was_kept = previous:kept(),
		drawn = ui.mount(buffer, function()
			return draw(picker)
		end, nil, { ns = "hunks", keys = false, draw = false }),
	}
	previous:set_kept(true)
	pickers[buffer:id()] = picker
	view:show(buffer)
	picker.drawn:redraw()
	go_to(picker, line_of_item(picker, 1) or 0)
end

-- Each file with only the picked hunks made.
local function picked_files(picker: Picker): (Picked, number)
	local out: Picked = {}
	local count = 0
	for _, file in picker.options.files do
		local text = file.old or ""
		local shift = 0
		local any, all = false, true
		for _, item in picker.items do
			if item.file == file then
				local hunk = item.hunk
				if item.picked then
					any = true
					count += 1
					if hunk then
						local from, to = hunk.from + shift, hunk.to + shift
						text = string.sub(text, 1, from) .. hunk.text .. string.sub(text, to + 1)
						shift += #hunk.text - (hunk.to - hunk.from)
					end
				else
					all = false
				end
			end
		end
		local absent = if file.old == nil then not any elseif file.new == nil then all else false
		out[file.path] = if absent then false else text
	end
	return out, count
end

local function close(picker: Picker)
	pickers[picker.buffer:id()] = nil
	picker.buffer:set_kept(false)
	picker.view:show(picker.previous)
	picker.previous:set_kept(picker.was_kept)
end

local function here(ctx: greed.Context): (Picker?, number?)
	local picker = pickers[ctx.buffer:id()]
	if picker == nil then
		return nil, nil
	end
	picker.view = ctx.view
	return picker, picker.drawn:value_at(ctx.view:cursor())
end

greed.command({
	name = "hunk-picker-toggle",
	doc = "Pick the hunk under the cursor, or put it back, and go to the next",
	run = function(ctx)
		local picker, i = here(ctx)
		if picker == nil or i == nil then
			return
		end
		picker.items[i].picked = not picker.items[i].picked
		picker.drawn:redraw()
		go_to(picker, line_of_item(picker, i + 1) or line_of_item(picker, i) or 0)
	end,
})

greed.command({
	name = "hunk-picker-all",
	doc = "Pick every hunk, or none if all are picked",
	run = function(ctx)
		local picker = here(ctx)
		if picker == nil then
			return
		end
		local all = true
		for _, item in picker.items do
			all = all and item.picked
		end
		for _, item in picker.items do
			item.picked = not all
		end
		local line = ctx.buffer:line_of(ctx.view:cursor())
		picker.drawn:redraw()
		go_to(picker, line)
	end,
})

greed.command({
	name = "hunk-picker-done",
	doc = "Go on with the hunks picked",
	run = function(ctx)
		local picker = here(ctx)
		if picker == nil then
			return
		end
		local picked, count = picked_files(picker)
		close(picker)
		picker.options.done(picked, count, #picker.items)
	end,
})

greed.command({
	name = "hunk-picker-cancel",
	doc = "Put back what was shown, picking nothing",
	run = function(ctx)
		local picker = here(ctx)
		if picker then
			close(picker)
			if picker.options.cancel then
				picker.options.cancel()
			end
		end
	end,
})

greed.on("buffer.closed", function(event: greed.BufferClosed)
	local picker = pickers[event.id]
	if picker then
		pickers[event.id] = nil
		if picker.previous:valid() then
			picker.previous:set_kept(picker.was_kept)
		end
	end
end)

greed.keymap.bind({ kind = "hunk-picker" }, {
	space = "hunk-picker-toggle",
	a = "hunk-picker-all",
	enter = "hunk-picker-done",
	q = "hunk-picker-cancel",
	esc = "hunk-picker-cancel",
})

return M
