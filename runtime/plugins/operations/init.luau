-- Operations: work across files taken as one thing. An operation groups
-- the edits it makes in every buffer and the programs it runs, so you can
-- review it in one view and undo it in one step.
--
--   space u o   recent operations, to review one
--   space u u   undo the latest operation (in a review, that one)
--
-- In a review, `space g r` puts back the change under the cursor.
--
-- A plugin or agent makes one with
--
--     local operations = require("@operations")
--     operations.run("rename parse to parse_line", function(op)
--         -- edit buffers, then
--         operations.exec(op, { "cargo", "test" })
--     end)

local kern = require("@kern")
local multibuffer = require("@multibuffer")
local picker = require("@picker")

--- A file an operation changed, and its text before.
export type File = { path: string, before: string }

--- A program an operation ran, and how it went.
export type Command = { argv: { string }, code: number?, output: string }

export type Operation = {
	--- Its undo group, which its edits in every buffer share.
	id: number,
	name: string,
	--- Who did it: "user", "agent" or a plugin's name.
	author: string,
	--- When it started, in seconds since 1970.
	time: number,
	files: { File },
	commands: { Command },
	--- "running", "done" or "undone".
	status: string,
}

-- How many operations are remembered.
local KEEP = 50
-- How much of a program's output is kept.
local OUTPUT = 4000

local M = {}

-- Oldest first.
local operations: { Operation } = {}
-- The group that was open when each running operation started.
local outer: { [number]: number? } = {}
-- The operation each review buffer shows.
local reviews: { [number]: Operation } = {}

--- Starts an operation: edits from here until `finish` belong to it.
function M.start(name: string, author: string?): Operation
	local op: Operation = {
		id = kern.history.new_group(),
		name = name,
		author = author or "user",
		time = os.time(),
		files = {},
		commands = {},
		status = "running",
	}
	outer[op.id] = kern.history.group()
	kern.history.set_group(op.id)
	table.insert(operations, op)
	if #operations > KEEP then
		table.remove(operations, 1)
	end
	return op
end

-- The files `op` changed so far, with their text before it.
local function changed_files(op: Operation): { File }
	local files: { File } = {}
	for _, buffer in kern.buffers() do
		local path = buffer:path()
		local entries = buffer:history({ group = op.id })
		if path and #entries > 0 then
			local before = buffer:text_before(entries[#entries].id) or ""
			table.insert(files, { path = path, before = before })
		end
	end
	table.sort(files, function(a: File, b: File)
		return a.path < b.path
	end)
	return files
end

--- Ends `op`: edits after this are no longer part of it.
function M.finish(op: Operation)
	if kern.history.group() == op.id then
		kern.history.set_group(outer[op.id])
	end
	outer[op.id] = nil
	op.files = changed_files(op)
	op.status = "done"
end

--- Runs `f` as an operation called `name` and returns it. If `f` fails,
--- what it did so far stays (and can be undone) and the error goes on.
function M.run(name: string, f: (op: Operation) -> (), author: string?): Operation
	local op = M.start(name, author)
	local ok, err = pcall(f, op)
	M.finish(op)
	if not ok then
		error(err, 0)
	end
	return op
end

--- Runs `f` with its edits joining `op`, finished or not, so they undo
--- with it, like changes accepted from a proposal one by one.
function M.join(op: Operation, f: () -> ())
	local current = kern.history.group()
	kern.history.set_group(op.id)
	local ok, err = pcall(f)
	kern.history.set_group(current)
	op.files = changed_files(op)
	if not ok then
		error(err, 0)
	end
end

--- Runs a program as part of `op`, like `kern.process.run`, and keeps how
--- it went with the operation.
function M.exec(
	op: Operation,
	argv: { string },
	opts: { stdin: string?, cwd: string? }?
): ({ code: number?, stdout: string, stderr: string }?, string?)
	local done, err = kern.process.run(argv, opts)
	local output = if done then done.stdout .. done.stderr else err or ""
	if #output > OUTPUT then
		output = "..." .. string.sub(output, -OUTPUT)
	end
	table.insert(op.commands, { argv = argv, code = done and done.code, output = output })
	return done, err
end

--- Recent operations, newest first.
function M.list(): { Operation }
	local list = {}
	for i = #operations, 1, -1 do
		table.insert(list, operations[i])
	end
	return list
end

--- Undoes `op` in every file it changed, as one step. Returns false and
--- why not when something was done on top of it since.
function M.undo(op: Operation): (boolean, string?)
	if op.status == "running" then
		M.finish(op)
	end
	local n, why = kern.history.undo_group(op.id)
	if n == nil then
		return false, why
	end
	op.status = "undone"
	return true, nil
end

-- `n` of `word`, with an "s" for more than one.
local function count(n: number, word: string): string
	return `{n} {word}{if n == 1 then "" else "s"}`
end

-- How long ago `time` was, roughly.
local function ago(time: number): string
	local seconds = os.time() - time
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return `{seconds // 60} min ago`
	end
	return `{seconds // 3600} h ago`
end

-- A file's text now: its buffer's if open, otherwise the disk's.
local function text_now(path: string): string
	for _, buffer in kern.buffers() do
		if buffer:path() == path then
			return buffer:text()
		end
	end
	return kern.fs.read(path) or ""
end

--- Shows `op` for review: every change it made, then the programs it ran.
--- Edit it to change the files; `space g r` puts a change back.
function M.review(op: Operation)
	local excerpts: { multibuffer.Excerpt } = {}
	local before: { [string]: string } = {}
	for _, file in op.files do
		before[file.path] = file.before
		for _, excerpt in multibuffer.diff(file.path, nil, file.before, text_now(file.path)) do
			table.insert(excerpts, excerpt)
		end
	end
	local lines = {
		`{op.name}, by {op.author}: {count(#excerpts, "change")} in {count(#op.files, "file")}`
			.. if op.status == "undone" then " (undone)" else "",
	}
	for _, command in op.commands do
		local how = if command.code == 0 then "ok" else `exit {command.code or "?"}`
		table.insert(lines, `ran {table.concat(command.argv, " ")}: {how}`)
	end
	local buffer = multibuffer.open(excerpts, {
		summary = table.concat(lines, "\n"),
		context = 2,
		base = function(path)
			return before[path]
		end,
		refresh = function()
			M.review(op)
		end,
	})
	reviews[buffer:id()] = op
	multibuffer.show(buffer, "Operation")
end

kern.command({
	name = "operations",
	doc = "Pick a recent operation to review: its changes across files and the programs it ran",
	run = function()
		local items = {}
		for _, op in M.list() do
			local status = if op.status == "done" then "" else ` ({op.status})`
			table.insert(items, {
				label = `{op.name}{status}  {op.author}, {count(#op.files, "file")}, {ago(op.time)}`,
				value = op,
			})
		end
		if #items == 0 then
			kern.echo("no operations yet")
			return
		end
		picker.pick("Operations", items, function(item)
			M.review(item.value)
		end)
	end,
})

kern.command({
	name = "operation-undo",
	doc = "Undo the latest operation, or the one being reviewed, in every file at once",
	run = function(ctx)
		local reviewed = reviews[ctx.buffer:id()]
		local op = reviewed
		if op == nil then
			for _, candidate in M.list() do
				if candidate.status ~= "undone" then
					op = candidate
					break
				end
			end
		end
		if op == nil then
			kern.echo("no operation to undo")
			return
		end
		local ok, why = M.undo(op)
		if not ok then
			kern.echo(`can't undo "{op.name}": {why}`)
			return
		end
		kern.echo(`undid "{op.name}" in {count(#op.files, "file")}`)
		if reviewed then
			M.review(op)
		end
	end,
})

kern.on("buffer.closed", function(event)
	reviews[event.id] = nil
end)

kern.keymap.bind("normal", {
	["space u o"] = "operations",
	["space u u"] = "operation-undo",
})

return M
