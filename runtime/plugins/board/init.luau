-- Boards: saved, named sets of live shell commands, each a card showing
-- what its command prints now, one after another down a buffer that
-- scrolls like any other. A board is a Markdown file in the project's
-- `.greed/boards`, or in your own config's `boards` folder; its cards run
-- in a shell of the board's own, from the project's root, with the shell's
-- live blocks: a watch, or a command that keeps printing.
--
--   :board [NAME]    open a board, or pick one
--   :board-new NAME  make one in this project (`!` for one of your own)
--   space .          on a shell block: "pin to board"
--
-- On a board, `enter` opens a card's block in a float, `space .` acts on
-- it as on the block in its shell, `space a` adds a command, `space e`
-- (or `i` on a card) edits the file at the card and `space r` runs the
-- cards again. Saving the file
-- shows the board as it says. A board from a file you didn't make asks
-- before it runs anything, as code blocks do, and trusting one trusts the
-- other.

local greed = require("@greed")
local core = require("@core")
local picker = require("@picker")
local shell = require("@shell")
local blocks = require("@blocks")
local file = require("@self/file")
local layout = require("@self/layout")

type Shell = shell.Shell
type Block = shell.Block
type Card = file.Card

local M = {}

M.file = file
M.layout = layout

local KIND = "board"

greed.option.define({
	name = "board-card-width",
	doc = "How wide a board's cards are at least, in columns: a wider board puts more of them side by side",
	default = 50,
})

--- An open board: its file, the shell its cards run in, the block each
--- card shows and the buffer showing them.
export type Board = {
	name: string,
	path: string,
	root: string,
	title: string?,
	cards: { Card },
	shell: Shell,
	blocks: { Block },
	buffer: greed.Buffer,
	--- How wide it's laid out, in columns: as the view showing it last
	--- said.
	width: number,
	--- The cards on each line of the buffer (0-based), by their index.
	at: { [number]: { layout.Spot } },
}

-- The open boards, by their buffer's id.
local boards: { [number]: Board } = {}

--- Where boards are: the project's `.greed/boards`, then your own.
function M.folders(): { string }
	local out = { `{greed.project.current().root}/.greed/boards` }
	local config = greed.fs.dirs().config
	if config then
		table.insert(out, `{config}/boards`)
	end
	return out
end

--- Every board there is, the project's first: its name and file.
function M.list(): { { name: string, path: string } }
	local out = {}
	local seen: { [string]: boolean } = {}
	for _, folder in M.folders() do
		local entries: { greed.DirEntry } = greed.fs.list(folder) or {}
		table.sort(entries, function(a: greed.DirEntry, b: greed.DirEntry): boolean
			return a.name < b.name
		end)
		for _, entry in entries do
			local name = string.match(entry.name, "^(.+)%.md$")
			if name and not seen[name] then
				seen[name] = true
				table.insert(out, { name = name, path = `{folder}/{entry.name}` })
			end
		end
	end
	return out
end

-- The file of the board called `name`, if there's one.
local function path_of(name: string): string?
	for _, found in M.list() do
		if found.name == name then
			return found.path
		end
	end
	return nil
end

-- A board's name: its file's, without `.md`.
local function name_of(path: string): string
	return string.match(path, "([^/]+)%.md$") or path
end

--- The board `buffer` shows, if it shows one.
function M.of(buffer: greed.Buffer): Board?
	return boards[buffer:id()]
end

-- What `block` shows of its output now, as the shell shows it (a filter
-- and a sort included), a line each.
local function output_of(board: Board, block: Block): { string }
	local from, to = shell.log.output_range(board.shell, block)
	if from == nil or to == nil then
		return {}
	end
	local lines = string.split(board.shell.buffer:slice(from, to), "\n")
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- Draws `board` as its cards are now, keeping each view's cursor and
-- scroll where they were.
local function draw(board: Board)
	local buffer = board.buffer
	if not buffer:valid() then
		return
	end
	local pieces: { layout.Piece } = {}
	for i, card in board.cards do
		local block = board.blocks[i]
		local head = if block then `{shell.log.glyph(block)} {card.title}` else card.title
		local status = if block then shell.log.status_text(block) else ""
		local out = if block then output_of(board, block) else {}
		local more = #out - card.height
		table.insert(pieces, {
			head = if status ~= "" then `{head}  {status}` else head,
			title = #head,
			lines = table.move(out, 1, math.min(#out, card.height), 1, {}),
			more = if more > 0 then `… {more} more lines · enter opens it all` else nil,
			section = card.section,
			span = card.span,
		})
	end
	local least = greed.option.get("board-card-width") :: number
	local laid = layout.lay(board.title, pieces, board.width, least)
	local text = laid.text
	if #board.cards == 0 then
		text ..= "\nNo cards yet: space a adds a command, space e edits the file."
	end
	local marks = laid.marks
	-- Lines past the view's edge stay out of sight rather than wrap, as the
	-- cards are lined up.
	table.insert(marks, { from = 0, to = #text, style = "", nowrap = true })
	local kept: { { view: greed.View, line: number, scroll: number } } = {}
	for _, view in buffer:views() do
		table.insert(
			kept,
			{ view = view, line = buffer:line_of(view:cursor()), scroll = view:scroll() }
		)
	end
	buffer:edit(function(e)
		e:replace(0, buffer:len(), text)
	end, { undo = false })
	buffer:decorate("board", marks)
	board.at = laid.at
	local last = buffer:line_count() - 1
	for _, k in kept do
		k.view:set_cursor(buffer:line_start(math.min(k.line, last)))
		k.view:set_scroll(math.min(k.scroll, last))
	end
end

-- The line `card` runs: its command, drawn as a chart as big as its card
-- when it's one, in a watch when it runs again by itself.
local function line_of(board: Board, card: Card): string
	local command = card.command
	if card.chart then
		local least = greed.option.get("board-card-width") :: number
		local width = layout.card_width(board.width, least, card.span)
		command ..= ` | chart {card.chart} --width {width} --height {card.height}`
	end
	return if card.every then `watch -n {card.every} {command}` else command
end

-- The folder `card` runs in.
local function cwd_of(board: Board, card: Card): string
	local dir = card.dir
	if dir == nil then
		return board.root
	end
	return if string.sub(dir, 1, 1) == "/" then dir else `{board.root}/{dir}`
end

-- Runs the cards of `board` in its shell. A card running what a block
-- of the board runs already keeps it as it is, so moving cards or editing
-- one doesn't run the others again, unless `again`. The others run in the
-- blocks left, in their place, so its shell doesn't fill up, and those it
-- no longer needs go. Waits for what ran before to stop.
local function start(board: Board, again: boolean?)
	local free = table.clone(board.blocks)
	local blocks: { Block? } = {}
	for i, card in board.cards do
		local line, cwd = line_of(board, card), cwd_of(board, card)
		for k, block in free do
			if block.command == line and block.cwd == cwd then
				blocks[i] = block
				table.remove(free, k)
				if again then
					shell.change(board.shell, block, line, { cwd = cwd })
				end
				break
			end
		end
	end
	for i, card in board.cards do
		if blocks[i] == nil then
			local line, cwd = line_of(board, card), cwd_of(board, card)
			local before = table.remove(free, 1)
			blocks[i] = if before
				then shell.change(board.shell, before, line, { cwd = cwd })
				else shell.run(board.shell, line, { cwd = cwd })
		end
	end
	board.blocks = blocks :: { Block }
	for _, block in free do
		shell.kill(block)
		shell.wait(block)
		shell.log.remove(board.shell, block)
	end
end

-- Stops what `board`'s cards run.
local function stop(board: Board)
	for _, block in board.blocks do
		shell.kill(block)
	end
end

-- Reads `board`'s file again and runs its cards as it says: those it
-- runs already as they are, unless `again`.
local function load(board: Board, again: boolean?)
	local parsed = file.parse(greed.fs.read(board.path) or "")
	board.title, board.cards = parsed.title, parsed.cards
	start(board, again)
	draw(board)
end

export type OpenOptions = {
	--- The view to show it in; the focused one by default.
	view: greed.View?,
	--- The folder its cards run from; the project's root by default.
	root: string?,
}

--- Opens the board in the file at `path`, running its cards, once you
--- trust the file; shows it if it's open already. Nil when it didn't run.
function M.open(path: string, options: OpenOptions?): Board?
	local opts: OpenOptions = options or {}
	local view = opts.view or greed.view()
	for _, board in boards do
		if board.path == path and board.buffer:valid() then
			view:show(board.buffer)
			return board
		end
	end
	if greed.fs.read(path) == nil then
		greed.echo(`there's no board at {path}`)
		return nil
	end
	if not blocks.allow_file(path, "the commands") then
		return nil
	end
	local name = name_of(path)
	local root = opts.root or greed.project.current().root
	local buffer = greed.create_buffer(KIND, "", { readonly = true })
	buffer:set_name(`board {name}`)
	buffer:set_line_numbers(false)
	-- It stays while another buffer shows in its place, as its file does
	-- when you edit it.
	buffer:set_kept(true)
	local board: Board = {
		name = name,
		path = path,
		root = root,
		title = nil,
		cards = {},
		shell = shell.open({ name = `board {name}`, cwd = root, show = false }),
		blocks = {},
		buffer = buffer,
		width = select(2, view:size()) or 80,
		at = {},
	}
	boards[buffer:id()] = board
	view:show(buffer)
	load(board)
	return board
end

-- Reads the file of each open board at `path` again.
local function reload(path: string)
	for _, board in boards do
		if board.path == path and board.buffer:valid() then
			greed.spawn(load, board)
		end
	end
end

--- Makes a board called `name`, in the project's folder or with
--- `personal` in your own, and opens it. Nil when there's one already.
function M.new(name: string, personal: boolean?): Board?
	if path_of(name) then
		greed.echo(`there's a board called {name} already: :board {name}`)
		return nil
	end
	local folders = M.folders()
	local folder = if personal then folders[2] else folders[1]
	if folder == nil then
		return nil
	end
	greed.fs.mkdir(folder)
	local path = `{folder}/{name}.md`
	greed.fs.write(path, `# {name}\n`)
	blocks.trust(path)
	return M.open(path)
end

--- Adds a card running `command` to the board in the file at `path`, as
--- `card_text` writes it, and shows it on the board if it's open.
function M.add(
	path: string,
	command: string,
	opts: { every: number?, title: string?, dir: string? }?
)
	local text = greed.fs.read(path) or ""
	if text ~= "" and not string.match(text, "\n\n$") then
		local gap: string = if string.match(text, "\n$") then "\n" else "\n\n"
		text = text .. gap
	end
	greed.fs.write(path, text .. file.card_text(command, opts or {}))
	reload(path)
end

-- The board in the focused view, saying so when there's none.
local function here(ctx: greed.Context): Board?
	local board = M.of(ctx.buffer)
	if board == nil then
		greed.echo("this isn't a board: :board opens one")
	end
	return board
end

-- The card under the cursor in `view`, when it shows a board: its index,
-- and the board.
local function card_index(view: greed.View): (number?, Board?)
	local board = M.of(view:buffer())
	if board == nil then
		return nil, nil
	end
	local buffer = board.buffer
	local cursor = view:cursor()
	local line = buffer:line_of(cursor)
	return layout.card(board.at[line], cursor - buffer:line_start(line)), board
end

-- The block of the card under the cursor in `view`, when it shows a
-- board, and the board.
local function card_at(view: greed.View): (Block?, Board?)
	local i, board = card_index(view)
	return if i and board then board.blocks[i] else nil, board
end

-- Puts the cursor in `view` on card `i` of `board`, at its title.
local function go_to_card(board: Board, view: greed.View, i: number)
	for line = 0, board.buffer:line_count() - 1 do
		local spots: { layout.Spot } = board.at[line] or {}
		for _, spot in spots do
			if spot.card == i then
				view:set_cursor(board.buffer:line_start(line) + spot.from)
				return
			end
		end
	end
end

-- Picks a board and calls `pick` with its file; "new board" asks for a
-- name and makes one first.
local function pick_board(title: string, pick: (path: string) -> (), offer_new: boolean)
	local items: { picker.Item } = {}
	for _, found in M.list() do
		table.insert(items, { label = found.name, value = found.path })
	end
	if offer_new then
		table.insert(items, { label = "new board…", value = false })
	end
	if #items == 0 then
		greed.echo("there are no boards yet: :board-new NAME makes one")
		return
	end
	picker.pick(title, items, function(item)
		if item.value then
			pick(item.value)
			return
		end
		greed.spawn(function()
			local name = core.prompt.ask("board name")
			if name and string.match(name, "%S") then
				local board = M.new((string.gsub(name, "[/%s]+", "-")))
				if board then
					pick(board.path)
				end
			end
		end)
	end)
end

greed.command({
	name = "board",
	doc = "Open a board: live shell commands, saved by name; pick one without a name",
	args = { { name = "name", doc = "The board to open" } },
	run = function(ctx)
		local name = ctx.args[1]
		if name == nil then
			pick_board("Boards", function(path)
				greed.spawn(function()
					M.open(path, { view = ctx.view })
				end)
			end, false)
			return
		end
		local path = path_of(name)
		if path == nil then
			greed.echo(`there's no board called {name}: :board-new {name} makes it`)
			return
		end
		M.open(path, { view = ctx.view })
	end,
})

greed.command({
	name = "board-new",
	doc = "Make a board in this project, or with ! one of your own, and open it",
	args = { { name = "name", doc = "What to call it" } },
	run = function(ctx)
		local name = ctx.args[1]
		if name == nil then
			greed.echo("board-new needs a name, e.g. :board-new ops")
			return
		end
		M.new(name, ctx.force)
	end,
})

greed.command({
	name = "board-add",
	doc = "Add a command to this board as a card",
	run = function(ctx)
		local board = here(ctx)
		if board == nil then
			return
		end
		local command = core.prompt.ask("add to the board")
		if command and string.match(command, "%S") then
			local line, every = file.unwatched(command)
			M.add(board.path, line, { every = every })
		end
	end,
})

greed.command({
	name = "board-edit",
	doc = "Open this board's file at the card under the cursor; saving it shows the board as it says",
	run = function(ctx)
		local i, board = card_index(ctx.view)
		if board == nil then
			here(ctx)
			return
		end
		local card = if i then board.cards[i] else nil
		-- At the card's command, the line after its fence.
		core.file.open_at(board.path, if card then card.first else nil)
		-- How to get back, in the keys of the style in use.
		local back: string? = nil
		for _, binding in greed.keymap.find("jump-back") do
			if back == nil and greed.keymap.resolve(binding.keys) == "jump-back" then
				back = binding.keys
			end
		end
		greed.echo(
			`saving puts your changes on the board{if back then `; {back} goes back to it` else ""}`
		)
	end,
})

greed.command({
	name = "board-refresh",
	doc = "Run this board's cards again",
	run = function(ctx)
		local board = here(ctx)
		if board then
			load(board, true)
		end
	end,
})

-- Moves the card under the cursor `step` places along the board, in its
-- file, taking the cursor with it.
local function move_card(ctx: greed.Context, step: number)
	local i, board = card_index(ctx.view)
	if board == nil then
		here(ctx)
		return
	end
	if i == nil then
		return
	end
	local other = i + step
	if board.cards[other] == nil then
		return
	end
	local a, b = board.cards[math.min(i, other)], board.cards[math.max(i, other)]
	greed.fs.write(board.path, file.swap(greed.fs.read(board.path) or "", a, b))
	load(board)
	go_to_card(board, ctx.view, other)
end

greed.command({
	name = "board-move-back",
	doc = "Move the card under the cursor one place back on the board, in its file too",
	run = function(ctx)
		move_card(ctx, -1)
	end,
})

greed.command({
	name = "board-move-forward",
	doc = "Move the card under the cursor one place on along the board, in its file too",
	run = function(ctx)
		move_card(ctx, 1)
	end,
})

greed.command({
	name = "board-open-card",
	doc = "Open the card under the cursor in a float, all of it",
	run = function(ctx)
		local block, board = card_at(ctx.view)
		if board == nil then
			here(ctx)
		elseif block then
			shell.peek.open(board.shell, block)
		end
	end,
})

-- A card is its block, to act on as in its shell.
core.actions.finder({
	name = "board-card",
	find = function(view, _range)
		local block, board = card_at(view)
		if board == nil or block == nil then
			return nil
		end
		local object = core.objects.get(`shell-block:{board.shell.buffer:id()}.{block.number}`)
		return if object then { core.objects.target(object) } else nil
	end,
})

-- `cwd` as a card's `dir`: nil at the project's root, relative under it.
local function dir_from_root(cwd: string): string?
	local root = greed.project.current().root
	if cwd == root then
		return nil
	end
	if string.sub(cwd, 1, #root + 1) == root .. "/" then
		return string.sub(cwd, #root + 2)
	end
	return cwd
end

core.actions.action({
	kind = "shell-block",
	name = "pin to board",
	doc = "Add its command to a board, as a card",
	run = function(target)
		local block: Block = target.value.block
		pick_board("Pin to board", function(path)
			local line, every = file.unwatched(block.command)
			M.add(path, line, { every = every, dir = dir_from_root(block.cwd) })
			greed.echo(`pinned to {name_of(path)}`)
		end, true)
	end,
})

-- A board shows its cards as they change, and as they run and end.
local function redraw(block: Block)
	for _, board in boards do
		if table.find(board.blocks, block) then
			draw(board)
		end
	end
end
shell.log.on_update(redraw)
shell.log.on_status(redraw)

-- A board is laid out as wide as the view showing it.
greed.on("view.resized", function(event: greed.ViewResized)
	local board = M.of(event.view:buffer())
	if board and board.width ~= event.cols then
		board.width = event.cols
		draw(board)
		-- Charts are drawn as wide as their cards.
		for _, card in board.cards do
			if card.chart then
				greed.spawn(load, board)
				break
			end
		end
	end
end)

-- Saving a board's file shows the board as it says now.
greed.on("buffer.saved", function(event: greed.BufferChanged)
	local path = event.buffer:path()
	if path then
		reload(path)
	end
end)

-- Closing a board stops its cards, and its shell goes.
greed.on("buffer.closed", function(event)
	local board = boards[event.id]
	if board then
		boards[event.id] = nil
		stop(board)
		if board.shell.buffer:valid() then
			board.shell.buffer:close()
		end
	end
end)

-- A board can't be typed in, so its keys are the same in every mode.
for _, role in { "command", "typing" } do
	greed.keymap.bind({ role = role, kind = KIND }, {
		enter = "board-open-card",
		["<"] = "board-move-back",
		[">"] = "board-move-forward",
	})
end
-- A board is drawn from its file, so what would change a card's text
-- goes to the card in the file.
greed.keymap.bind(
	{ role = "command", kind = KIND },
	{ i = "board-edit", a = "board-edit", c = "board-edit", o = "board-edit" }
)
greed.keymap.bind(
	{ layer = "leader", kind = KIND },
	{ a = "board-add", e = "board-edit", r = "board-refresh" }
)

return M
