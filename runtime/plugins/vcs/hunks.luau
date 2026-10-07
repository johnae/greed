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
-- goes without any lines changing, the file as a whole.
type Item = {
	file: File,
	hunk: { from: number, to: number, text: string }?,
	picked: boolean,
}

type Picker = {
	options: Options,
	items: { Item },
	view: greed.View,
	buffer: greed.Buffer,
	previous: greed.Buffer,
	was_kept: boolean,
	-- The item on each line, by 0-based line number.
	rows: { [number]: number },
}

local pickers: { [number]: Picker } = {}

local function items_of(files: { File }): { Item }
	local items: { Item } = {}
	for _, file in files do
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

-- The lines of `text`, without the empty one after a final line break.
local function lines(text: string): { string }
	local out = string.split(text, "\n")
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

local function render(picker: Picker)
	local title, help = picker.options.title, "space picks, a picks all, enter goes on, q cancels"
	local text: { string } = { title, help, "" }
	local marks: { greed.Mark } = {
		{ from = 0, to = #title, style = "markup.heading" },
		{ from = #title + 1, to = #title + 1 + #help, style = "comment" },
	}
	local at = #title + #help + 3
	local function add(line: string, style: string, from: number)
		table.insert(marks, { from = at + from, to = at + #line, style = style })
		table.insert(text, line)
		at += #line + 1
	end
	picker.rows = {}
	for i, item in picker.items do
		local first = #text
		local box = if item.picked then "[x] " else "[ ] "
		local hunk = item.hunk
		if hunk then
			local old = lines(string.sub(item.file.old or "", hunk.from + 1, hunk.to))
			local new = lines(hunk.text)
			local _, before = string.gsub(string.sub(item.file.old or "", 1, hunk.from), "\n", "")
			add(`{box}{item.file.path}  line {before + 1}  +{#new} -{#old}`, "markup.heading", 4)
			for _, line in old do
				add(`    -{line}`, "diff.minus", 4)
			end
			for _, line in new do
				add(`    +{line}`, "diff.plus", 4)
			end
		else
			local what = if item.file.old == nil then "new file" else "deleted"
			add(`{box}{item.file.path}  {what}`, "markup.heading", 4)
		end
		for line = first, #text - 1 do
			picker.rows[line] = i
		end
	end
	local buffer = picker.buffer
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(text, "\n"))
	end)
	buffer:set_readonly(true)
	buffer:decorate("hunks", marks)
end

-- The first line of item `i`.
local function line_of_item(picker: Picker, i: number): number?
	local found = nil
	for line, item in picker.rows do
		if item == i and (found == nil or line < found) then
			found = line
		end
	end
	return found
end

local function go_to(picker: Picker, line: number)
	local pos = picker.buffer:line_start(line)
	picker.view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
end

--- Shows the hunks between each file's two versions in `view` to pick from.
--- Enter calls `options.done` and q cancels; either puts back what `view`
--- showed.
function M.pick(view: greed.View, options: Options)
	local buffer = greed.create_buffer("hunk-picker", "", { readonly = true })
	buffer:set_line_numbers(false)
	buffer:set_kept(true)
	local previous = view:buffer()
	local picker: Picker = {
		options = options,
		items = items_of(options.files),
		view = view,
		buffer = buffer,
		previous = previous,
		was_kept = previous:kept(),
		rows = {},
	}
	previous:set_kept(true)
	pickers[buffer:id()] = picker
	view:show(buffer)
	render(picker)
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
	return picker, picker.rows[ctx.buffer:line_of(ctx.view:selection().ranges[1].head)]
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
		render(picker)
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
		local line = ctx.buffer:line_of(ctx.view:selection().ranges[1].head)
		render(picker)
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

for _, mode in { "normal", "vim", "edit" } do
	greed.keymap.bind({ mode = mode, kind = "hunk-picker" }, {
		space = "hunk-picker-toggle",
		a = "hunk-picker-all",
		enter = "hunk-picker-done",
		q = "hunk-picker-cancel",
		esc = "hunk-picker-cancel",
	})
end

return M
