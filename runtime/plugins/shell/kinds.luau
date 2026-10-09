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
--- "process", "pod"), how to show it, and the value its actions get.
export type Thing = { kind: string, label: string, value: any }

export type Kind = {
	--- What it's called, for replacing it.
	name: string,
	--- The commands whose rows it reads: a program's name ("kubectl"), or a
	--- Luau pattern for the command line ("^docker ps").
	match: string,
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
}

local kinds: { Kind } = {}

--- Says what the rows of the commands `kind.match` names are. The latest
--- added is asked first. It goes when the plugin that added it does.
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

--- Works out what `block`'s rows are, as it finishes, or each time a live
--- block shows new output: the first kind whose `match` names its command
--- and whose `capture` keeps something.
function M.finished(shell: Shell, block: Block)
	read[block] = nil
	block.called = nil
	if block.table == nil then
		return
	end
	for i = #kinds, 1, -1 do
		local kind = kinds[i]
		if tables.matches(kind.match, M.command_line(block)) then
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

core.actions.finder({
	name = "shell-row",
	find = function(view, range)
		local shell = state.of(view:buffer())
		if shell == nil then
			return nil
		end
		local thing, from, to = M.at(shell, range.head)
		if thing == nil then
			return nil
		end
		return {
			{ kind = thing.kind, label = thing.label, value = thing.value, from = from, to = to },
		}
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

M.default_action("file", "open")
M.command("folder", "cd", function(path: any): string
	return "cd " .. parse.quote(tostring(path))
end, { doc = "Go there in the shell", default = true })

return M
