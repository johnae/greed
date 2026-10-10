-- What the rows of a block's table are, so they're things to act on like
-- any other (core.actions, `space .`): an `ls -l` row is a file, a `ps`
-- row a process, a `kubectl get pods` row a pod. A kind says which
-- commands' rows it reads, what to keep from a block when it finishes (the
-- kubernetes context it ran against, say), and what a row is; what can be
-- done with a thing is its kind's actions, the same wherever it shows up.
--
-- What ran isn't changed: the rows are read from what it printed. Actions
-- that run a command run it as a block in the shell, spelled out from the
-- thing, so what happens is there to read, run again and edit.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local rows = require("./rows")
local tables = require("./tables")
local parse = require("./parse")
local segments = require("./segments")
local aliases = require("./aliases")

type Shell = state.Shell
type Block = state.Block

local M = {}

--- A thing to act on, as core.actions has them: its kind ("file",
--- "process", "pod"), how to show it, and the value its actions get. Its
--- `key` names it as an object, `kind:key` ("pod:prod/payments/api-7d9f"):
--- the same for the same thing in any block, so the newest row showing it
--- is the one found. Without one, a value that's a string (a file's path)
--- names it. `cells` are the things some of its cells are, by column: a
--- pod's node, a container's image.
export type Thing = {
	kind: string,
	label: string,
	value: any,
	key: string?,
	cells: { [string]: Thing }?,
}

export type Kind = {
	--- What it's called, for replacing it.
	name: string,
	--- The commands whose rows it reads: a program's name ("kubectl"), or a
	--- Luau pattern for the command line ("^docker ps").
	match: string?,
	--- The columns a table must have for it to read the rows, in any case
	--- ("PID"). Without `match`, whatever printed them: kinds naming the
	--- command are asked first.
	columns: { string }?,
	--- What to keep from `block` as it finishes, for `row`: what the rows
	--- can't say themselves, like the context a command ran against. Nil
	--- when the block's rows aren't this kind's after all.
	capture: ((block: Block, shell: Shell) -> any)?,
	--- What `row` (its cells by column) is, given what `capture` kept.
	row: (row: { [string]: string }, captured: any, block: Block) -> Thing?,
	--- What one of its rows is called and what several are, for the
	--- block's status ("pod", "pods").
	called: ((captured: any, block: Block) -> (string, string))?,
	--- Which of its things fit the word being completed, by the program
	--- being completed ("kubectl", "kill"): given the command's words (the
	--- word being completed last), what to put there for a thing that
	--- fits, or nil when none do there.
	complete: { [string]: (words: { string }, shell: Shell) -> ((value: any) -> string?)? }?,
	--- Whether a command line of its (as words) keeps printing rows again
	--- as they change, like `kubectl get pods -w`: the shell shows such a
	--- stream as its rows, each in place, rather than every line it prints.
	streams: ((words: { string }) -> boolean)?,
}

local kinds: { Kind } = {}

--- Whether `line` keeps printing rows again as they change, as a kind
--- whose commands it names says.
function M.streams(line: string): boolean
	local words = parse.words(line, greed.fs.dirs().home)
	if words == nil then
		return false
	end
	for _, kind in kinds do
		local streams, match = kind.streams, kind.match
		if streams and match and tables.matches(match, line) then
			local ok, yes = pcall(streams, words)
			if ok and yes then
				return true
			end
		end
	end
	return false
end

--- Says what the rows of the commands `kind.match` names are, or of
--- tables with `kind.columns`. The latest added is asked first. It goes
--- when the plugin that added it does.
function M.kind(kind: Kind)
	greed.plugin.tie(core.registry.put(kinds, kind, function(other: Kind): boolean
		return other.name == kind.name
	end))
end

--- The command whose output `block` shows: what it ran, or for a live
--- block (`watch`) what it runs each time.
function M.command_line(block: Block): string
	return block.watching or block.command
end

-- What each block's rows are: the kind and what it kept, once the block
-- finished with a table.
type Read = { kind: Kind, captured: any }
local read: { [Block]: Read } = setmetatable({}, { __mode = "k" }) :: any

-- Whether `kind` reads the rows of `block`'s table `tbl`: on the pass by
-- command, its `match` names the command; on the other, it has columns and
-- no `match`. Either way the table has its columns.
local function reads(kind: Kind, block: Block, tbl: tables.Table, by_command: boolean): boolean
	local match = kind.match
	local columns: { string } = kind.columns or {}
	if by_command then
		if match == nil or not tables.matches(match, M.command_line(block)) then
			return false
		end
	elseif match ~= nil or #columns == 0 then
		return false
	end
	for _, column in columns do
		if tables.column(tbl, column) == nil then
			return false
		end
	end
	return true
end

--- Works out what `block`'s rows are, as it finishes, or each time a live
--- block shows new output: the first kind that reads them and whose
--- `capture` keeps something, those naming the command first.
function M.finished(shell: Shell, block: Block)
	read[block] = nil
	block.called = nil
	local tbl = block.table
	if tbl == nil then
		return
	end
	for _, by_command in { true, false } do
		for i = #kinds, 1, -1 do
			local kind = kinds[i]
			if reads(kind, block, tbl, by_command) then
				local ok, captured = true, true
				if kind.capture then
					ok, captured = pcall(kind.capture, block, shell)
				end
				if ok and captured ~= nil then
					read[block] = { kind = kind, captured = captured }
					block.called = M.called(block)
					if block.called then
						log.draw_block(shell, block)
					end
					return
				end
			end
		end
	end
end

--- What one of `block`'s rows is called and what several are, when a
--- kind reads them.
function M.called(block: Block): { one: string, many: string }?
	local r = read[block]
	local called = if r then r.kind.called else nil
	if not r or called == nil then
		return nil
	end
	local ok, one, many = pcall(called, r.captured, block)
	return if ok and one and many then { one = one, many = many } else nil
end

--- The thing row `index` of `block`'s table is, if a kind reads it.
function M.thing(block: Block, index: number): Thing?
	local r = read[block]
	local tbl = block.table
	if not r or tbl == nil or tbl.rows[index] == nil then
		return nil
	end
	local ok, thing = pcall(r.kind.row, tbl.rows[index], r.captured, block)
	return if ok then thing else nil
end

--- Something the rows of a block offer to complete a word: what goes in,
--- and what it is and where it's from.
export type Offer = { text: string, detail: string }

-- The program `word`, a command's first, runs: its name without its
-- folder, or what an alias of one word stands for.
local function program_of(word: string): string
	local name = string.match(word, "([^/]+)$") or word
	local alias = aliases.loaded()[name]
	if alias and string.match(alias, "^%S+$") then
		return string.match(alias, "([^/]+)$") or alias
	end
	return name
end

--- What the rows of `shell`'s blocks offer to complete the last of
--- `words`, the newest blocks' first, each once: the things kinds say fit
--- there, like the pods above for `kubectl logs`.
function M.complete(shell: Shell, words: { string }): { Offer }
	local out: { Offer } = {}
	local seen: { [string]: boolean } = {}
	local program = program_of(words[1] or "")
	for _, kind in kinds do
		local ask = if kind.complete then kind.complete[program] else nil
		local ok, fits = false, nil
		if ask then
			ok, fits = pcall(ask, words, shell)
		end
		if ok and fits then
			for i = #shell.blocks, 1, -1 do
				local block = shell.blocks[i]
				local r = read[block]
				local tbl = block.table
				if r and r.kind == kind and tbl then
					for index in tbl.rows do
						local thing = M.thing(block, index)
						local found, text = false, nil
						if thing then
							found, text = pcall(fits, thing.value)
						end
						if thing and found and type(text) == "string" and not seen[text] then
							seen[text] = true
							local what = if thing.label == text then thing.kind else thing.label
							table.insert(out, { text = text, detail = `{what} · ${block.number}` })
						end
					end
				end
			end
		end
	end
	return out
end

--- The thing on the line at `pos` in `shell`, and the line's start and
--- end, if a row of a table there is one.
function M.at(shell: Shell, pos: number): (Thing?, number?, number?)
	local block = log.block_at(shell, pos)
	local index = if block then rows.row_at(shell, block, pos) else nil
	local thing = if block and index then M.thing(block, index) else nil
	if thing == nil then
		return nil, nil, nil
	end
	local buffer = shell.buffer
	local line = buffer:line_of(pos)
	return thing, buffer:line_start(line), buffer:line_end(line)
end

-- Where each object's value came from, to inspect and relate it: the
-- block and row it's in, and the column for a cell's. Values that are
-- strings (a file's path) have none.
type Origin = { shell: Shell, block: Block, index: number, column: string? }
local origins: { [any]: Origin } = setmetatable({}, { __mode = "k" }) :: any

-- What a plain row is called: its first cell with something in it.
local function row_label(tbl: tables.Table, cells: { [string]: string }, index: number): string
	for _, column in tbl.columns do
		local cell = cells[column]
		if cell and cell ~= "" then
			return cell
		end
	end
	return `row {index}`
end

-- `thing`'s id, by its key or else its value.
local function id_of(thing: Thing): string?
	return if thing.key
		then `{thing.kind}:{thing.key}`
		else core.objects.id_of(thing.kind, thing.value)
end

-- An object on row `index` of `block`, saying where the row shows in the
-- buffer, if it does, and where it came from.
local function placed(
	shell: Shell,
	block: Block,
	index: number,
	column: string?,
	kind: string,
	id: string,
	label: string,
	value: any
): core.Object
	if type(value) == "table" then
		origins[value] = { shell = shell, block = block, index = index, column = column }
	end
	local buffer = shell.buffer
	local line = rows.row_line(shell, block, index)
	return {
		kind = kind,
		id = id,
		label = label,
		value = value,
		buffer = if line then buffer else nil,
		from = if line then buffer:line_start(line) else nil,
		to = if line then buffer:line_end(line) else nil,
	}
end

--- Row `index` of `block`'s table as an object: the thing its kind says it
--- is, else a plain row of the table (`row:BUFFER.BLOCK.INDEX`), whose
--- value is its cells. It says where it shows in the buffer, if it does.
function M.row_object(shell: Shell, block: Block, index: number): core.Object?
	local tbl = block.table
	local cells = if tbl then tbl.rows[index] else nil
	if tbl == nil or cells == nil then
		return nil
	end
	local thing = M.thing(block, index)
	local id = if thing then id_of(thing) else nil
	if thing and id then
		return placed(shell, block, index, nil, thing.kind, id, thing.label, thing.value)
	end
	local key = `{shell.buffer:id()}.{block.number}.{index}`
	return placed(
		shell,
		block,
		index,
		nil,
		"row",
		`row:{key}`,
		row_label(tbl, cells, index),
		table.clone(cells)
	)
end

--- The things cells of row `index` of `block` are, as objects by their
--- column: a pod's node, a container's image.
function M.cell_objects(shell: Shell, block: Block, index: number): { [string]: core.Object }
	local out: { [string]: core.Object } = {}
	local thing = M.thing(block, index)
	local cells = if thing then thing.cells else nil
	if cells then
		for column, cell in cells do
			local id = id_of(cell)
			if id then
				out[column] =
					placed(shell, block, index, column, cell.kind, id, cell.label, cell.value)
			end
		end
	end
	return out
end

--- Every row of `block`'s table as an object.
function M.row_objects(shell: Shell, block: Block): { core.Object }
	local out: { core.Object } = {}
	local tbl = block.table
	if tbl then
		for index in tbl.rows do
			local object = M.row_object(shell, block, index)
			if object then
				table.insert(out, object)
			end
		end
	end
	return out
end

-- The rows and cells of every shell's blocks that are objects of `kind`,
-- the newest block's first, each id once; with `id`, only the newest
-- that's it.
local function rows_of(kind: string, id: string?): { core.Object }
	local out: { core.Object } = {}
	local seen: { [string]: boolean } = {}
	local function take(object: core.Object): boolean
		if object.kind ~= kind or seen[object.id] or (id ~= nil and object.id ~= id) then
			return false
		end
		seen[object.id] = true
		table.insert(out, object)
		return id ~= nil
	end
	for _, shell in state.list() do
		for i = #shell.blocks, 1, -1 do
			local block = shell.blocks[i]
			local tbl = block.table
			-- Only a block some kind reads has rows of a kind.
			if read[block] and tbl then
				for index in tbl.rows do
					local object = M.row_object(shell, block, index)
					if object and take(object) then
						return out
					end
					for _, cell in M.cell_objects(shell, block, index) do
						if take(cell) then
							return out
						end
					end
				end
			end
		end
	end
	return out
end

-- An object's state: its value, with its row's cells when it's a row.
local function inspect_row(value: any): { [string]: any }
	local out: { [string]: any } = if type(value) == "table"
		then table.clone(value)
		else { value = value }
	local origin = origins[value]
	local tbl = if origin then origin.block.table else nil
	if origin and tbl and origin.column == nil then
		out.row = table.clone(tbl.rows[origin.index])
	end
	return out
end

-- The block an object is in; for a row, the things its cells are, by
-- their column, and for a cell, its row.
local function row_relations(value: any): { [string]: { core.Object } }
	local origin = origins[value]
	if origin == nil then
		return {}
	end
	local shell, block, index = origin.shell, origin.block, origin.index
	local out: { [string]: { core.Object } } = {}
	local here = core.objects.get(`shell-block:{shell.buffer:id()}.{block.number}`)
	if here then
		out.block = { here }
	end
	if origin.column then
		local row = M.row_object(shell, block, index)
		if row then
			out.row = { row }
		end
	else
		for column, cell in M.cell_objects(shell, block, index) do
			out[string.lower(column)] = { cell }
		end
	end
	return out
end

--- Makes the rows that are things of `kind` objects, by their key, and
--- the cells that are: listed from every shell's blocks, the newest first,
--- inspected as their value (a row's with its cells), and related to the
--- block they're in. It goes when the plugin that made it does.
function M.object_kind(kind: string, doc: string)
	core.objects.kind({
		name = kind,
		doc = doc,
		list = function()
			return rows_of(kind)
		end,
		get = function(key)
			return rows_of(kind, `{kind}:{key}`)[1]
		end,
		inspect = inspect_row,
		relations = row_relations,
	})
end

core.objects.kind({
	name = "row",
	doc = "A row of a table a shell block printed, by its cells",
	get = function(key)
		local buffer, number, index = string.match(key, "^(%d+)%.(%d+)%.(%d+)$")
		for _, shell in state.list() do
			if tostring(shell.buffer:id()) == buffer then
				local block = state.block(shell, tonumber(number) :: number)
				local object = if block
					then M.row_object(shell, block, tonumber(index) :: number)
					else nil
				return if object and object.kind == "row" then object else nil
			end
		end
		return nil
	end,
	relations = row_relations,
})

-- The row at the cursor, and before it the thing the cell under the
-- cursor is, when it's one.
core.actions.finder({
	name = "shell-row",
	find = function(view, range)
		local shell = state.of(view:buffer())
		local block = if shell then log.block_at(shell, range.head) else nil
		if shell == nil or block == nil then
			return nil
		end
		local index = rows.row_at(shell, block, range.head)
		local object = if index then M.row_object(shell, block, index) else nil
		if index == nil or object == nil then
			return nil
		end
		local found = { core.objects.target(object) }
		local column = rows.column_at(shell, block, range.head)
		local cell = if column then M.cell_objects(shell, block, index)[column] else nil
		if cell then
			table.insert(found, 1, core.objects.target(cell))
		end
		return found
	end,
})

-- Runs a command line in a shell, as typed: init.luau gives it.
local runner: ((shell: Shell, line: string, view: greed.View) -> ())? = nil

--- How actions run their commands, given by the plugin once it's set up.
function M.runs_with(run: (shell: Shell, line: string, view: greed.View) -> ())
	runner = run
end

-- Each kind's default action, by kind: what `enter` on such a row does.
local defaults: { [string]: string } = {}

export type CommandOptions = {
	doc: string,
	--- It destroys or stops something: it asks first, and says when the
	--- thing is in a production context (`shell-production-contexts`).
	danger: boolean?,
	--- What `enter` on such a row does.
	default: boolean?,
}

--- The production context a thing belongs to, when its value names one
--- (`context`) that matches `shell-production-contexts`.
local function production(value: any): string?
	local context = if type(value) == "table" then value.context else nil
	if type(context) ~= "string" then
		return nil
	end
	return if segments.production(context) then context else nil
end

-- `template` with each `{field}` the field of `value`, quoted for a shell;
-- fields it doesn't have stay as they are.
local function fill(template: string, value: any): string
	return (
		string.gsub(template, "{([%w_]+)}", function(field: string): string
			local found = if type(value) == "table" then value[field] else nil
			return if found == nil then `\{{field}\}` else parse.quote(tostring(found))
		end)
	)
end

--- Adds the action `name` to things of `kind`: it runs the command
--- `command` makes from the thing's value (or a template whose `{field}`s
--- are its fields, quoted) as a block in the shell the thing is in, or the
--- project's first. It goes when the plugin that added it does.
function M.command(
	kind: string,
	name: string,
	command: string | (value: any) -> string,
	opts: CommandOptions
)
	core.actions.action({
		kind = kind,
		name = name,
		doc = opts.doc,
		run = function(target)
			local line = if type(command) == "string"
				then fill(command, target.value)
				else command(target.value)
			local view = greed.view()
			local shell = state.of(view:buffer()) or state.list(greed.project.current().id)[1]
			local runs = runner
			if shell == nil or runs == nil then
				greed.echo("no shell to run it in: space o s opens one")
				return
			end
			if opts.danger then
				local where = production(target.value)
				local warning = if where then ` - in PRODUCTION ({where})` else ""
				greed.echo(`{name} {target.label}{warning}? y/n`)
				local yes = greed.next_key() == "y"
				greed.echo("")
				if not yes then
					return
				end
			end
			if shell.buffer:views()[1] == nil then
				view:show(shell.buffer)
			end
			local in_view = if view:buffer() == shell.buffer then view else shell.buffer:views()[1]
			runs(shell, line, in_view)
		end,
	})
	if opts.default then
		M.default_action(kind, name)
	end
end

--- Does the default action of the thing on the line at `pos` in `shell`,
--- if it's one whose kind has a default. Says whether it did.
function M.default(shell: Shell, pos: number): boolean
	local thing = M.at(shell, pos)
	local name = if thing then defaults[thing.kind] else nil
	if thing == nil or name == nil then
		return false
	end
	for _, action in core.actions.for_kind(thing.kind) do
		if action.name == name then
			action.run({ kind = thing.kind, label = thing.label, value = thing.value })
			return true
		end
	end
	return false
end

--- Makes `name` the default action of things of `kind`, for those added
--- with `core.actions.action`.
function M.default_action(kind: string, name: string)
	greed.plugin.tie(core.registry.set(defaults, kind, name))
end

-- `ls -l`'s rows are files and folders, in the folder it listed.

-- The folder `ls` listed for `block`: the one it ran in, or the folder
-- named after its flags when there's one.
local function listed(block: Block): string?
	local words = parse.words(M.command_line(block), greed.fs.dirs().home)
	if words == nil then
		return nil
	end
	local dir = block.cwd
	for i = 2, #words do
		local word = words[i]
		if string.sub(word, 1, 1) ~= "-" then
			local path = core.project.resolve(word, block.cwd)
			local info = greed.fs.stat(path)
			if info == nil or info.kind ~= "dir" then
				return nil
			end
			dir = path
		end
	end
	return dir
end

M.kind({
	name = "ls",
	match = "ls",
	capture = function(block: Block): any
		local tbl = block.table
		if tbl == nil or tbl.columns[1] ~= "MODE" then
			return nil
		end
		return listed(block)
	end,
	row = function(row: { [string]: string }, dir: any): Thing?
		local name = string.match(row.NAME or "", "^(.-) %-> ") or row.NAME
		if name == nil or name == "" or type(dir) ~= "string" then
			return nil
		end
		local folder = string.sub(row.MODE or "", 1, 1) == "d"
		return {
			kind = if folder then "folder" else "file",
			label = name,
			value = core.project.clean(`{dir}/{name}`),
		}
	end,
	called = function(): (string, string)
		return "file", "files"
	end,
})

-- The types a listing gives files and folders, as nu's `ls` does: what
-- each is, by its type.
local FILE_TYPES: { [string]: string } = { file = "file", dir = "folder", symlink = "file" }

-- Rows with a name and a type that are all files and folders, as nu's `ls`
-- prints them, are those, by their names from the folder the block ran in.
M.kind({
	name = "files",
	columns = { "name", "type" },
	capture = function(block: Block): any
		local tbl = assert(block.table)
		local column = assert(tables.column(tbl, "type"))
		for _, row in tbl.rows do
			if FILE_TYPES[row[column]] == nil then
				return nil
			end
		end
		return block.cwd
	end,
	row = function(row: { [string]: string }, dir: any, block: Block): Thing?
		local tbl = assert(block.table)
		local name = row[tables.column(tbl, "name") or "name"]
		local kind = FILE_TYPES[row[tables.column(tbl, "type") or "type"]]
		if name == nil or name == "" or kind == nil then
			return nil
		end
		return { kind = kind, label = name, value = core.project.resolve(name, dir) }
	end,
	called = function(): (string, string)
		return "file", "files"
	end,
})

M.default_action("file", "open")
M.command("folder", "cd", function(path: any): string
	return "cd " .. parse.quote(tostring(path))
end, { doc = "Go there in the shell", default = true })

return M
