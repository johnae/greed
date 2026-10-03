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

local greed = require("@greed")
local multibuffer = require("@multibuffer")
local picker = require("@picker")

--- A file an operation changed: its text before, and right after.
export type File = { path: string, before: string, after: string }

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
	--- "running", "done", "undone" or "partly undone".
	status: string,
	--- Saved before Greed last restarted: its undo group is gone, so undo
	--- puts its changes back by comparing texts.
	restored: boolean?,
}

-- How many operations are remembered.
local KEEP = 50
-- How much of a program's output is kept.
local OUTPUT = 4000
-- Files bigger than this aren't saved for after a restart.
local SAVED_FILE = 512 * 1024

local M = {}

-- Oldest first.
local operations: { Operation } = {}
-- The group that was open when each running operation started.
local outer: { [number]: number? } = {}
-- The operation each review buffer shows.
local reviews: { [number]: Operation } = {}

-- Where operations are kept for after a restart.
local function saved_path(): string?
	local cache = greed.fs.dirs().cache
	return cache and `{cache}/operations.json`
end

-- Keeps the finished operations for after a restart.
local function save()
	local path = saved_path()
	if path == nil then
		return
	end
	local list: { any } = {}
	for _, op in operations do
		if op.status ~= "running" then
			local files = {}
			for _, file in op.files do
				if #file.before + #file.after <= SAVED_FILE then
					table.insert(files, file)
				end
			end
			table.insert(list, {
				name = op.name,
				author = op.author,
				time = op.time,
				status = op.status,
				files = greed.json.array(files),
				commands = greed.json.array(op.commands),
			})
		end
	end
	greed.fs.write(path, greed.json.encode(greed.json.array(list)))
end

--- Loads the operations saved before a restart, in place of the ones
--- known now. Greed does this when it starts.
function M.restore()
	local path = saved_path()
	local text = path and greed.fs.read(path)
	local list = if text then greed.json.decode(text) else nil
	operations = {}
	for _, saved in list or {} do
		table.insert(operations, {
			id = 0,
			name = saved.name,
			author = saved.author,
			time = saved.time,
			files = saved.files or {},
			commands = saved.commands or {},
			status = saved.status,
			restored = true,
		})
	end
end

--- Starts an operation: edits from here until `finish` belong to it.
function M.start(name: string, author: string?): Operation
	local op: Operation = {
		id = greed.history.new_group(),
		name = name,
		author = author or "user",
		time = os.time(),
		files = {},
		commands = {},
		status = "running",
	}
	outer[op.id] = greed.history.group()
	greed.history.set_group(op.id)
	table.insert(operations, op)
	if #operations > KEEP then
		table.remove(operations, 1)
	end
	return op
end

-- The files `op` changed so far, with their text before it and now.
local function changed_files(op: Operation): { File }
	local files: { File } = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		local entries = buffer:history({ group = op.id })
		if path and #entries > 0 then
			local before = buffer:text_before(entries[#entries].id) or ""
			table.insert(files, { path = path, before = before, after = buffer:text() })
		end
	end
	table.sort(files, function(a: File, b: File)
		return a.path < b.path
	end)
	return files
end

--- Ends `op`: edits after this are no longer part of it.
function M.finish(op: Operation)
	if greed.history.group() == op.id then
		greed.history.set_group(outer[op.id])
	end
	outer[op.id] = nil
	op.files = changed_files(op)
	op.status = "done"
	save()
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
	local current = greed.history.group()
	greed.history.set_group(op.id)
	local ok, err = pcall(f)
	greed.history.set_group(current)
	op.files = changed_files(op)
	save()
	if not ok then
		error(err, 0)
	end
end

--- Runs a program as part of `op`, like `greed.process.run`, and keeps how
--- it went with the operation.
function M.exec(
	op: Operation,
	argv: { string },
	opts: { stdin: string?, cwd: string? }?
): ({ code: number?, stdout: string, stderr: string }?, string?)
	local done, err = greed.process.run(argv, opts)
	local output = if done then done.stdout .. done.stderr else err or ""
	if #output > OUTPUT then
		output = "..." .. string.sub(output, -OUTPUT)
	end
	table.insert(op.commands, { argv = argv, code = done and done.code, output = output })
	return done, err
end

--- Drops `op` from the recent operations, e.g. one that changed nothing.
function M.forget(op: Operation)
	local index = table.find(operations, op)
	if index then
		table.remove(operations, index)
		save()
	end
end

--- Recent operations, newest first.
function M.list(): { Operation }
	local list = {}
	for i = #operations, 1, -1 do
		table.insert(list, operations[i])
	end
	return list
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
	for _, buffer in greed.buffers() do
		if buffer:path() == path then
			return buffer:text()
		end
	end
	return greed.fs.read(path) or ""
end

type Revert = { from: number, to: number, text: string }

-- What puts `file`'s changes back in `now`, its text now, leaving those
-- that were edited since: where each change's text is in `now`, and the
-- text it replaced. Also how many were left.
local function reverts(file: File, now: string): ({ Revert }, number)
	-- Changes since the operation, by where they are in its text after.
	local later = greed.diff(file.after, now)
	local out: { Revert }, left = {}, 0
	local shift = 0
	for _, change in greed.diff(file.before, file.after) do
		local old = string.sub(file.before, change.from + 1, change.to)
		-- Where its text is in the operation's text after.
		local from = change.from + shift
		local to = from + #change.text
		shift += #change.text - #old
		local moved, edited = 0, false
		for _, l in later do
			if l.from < to and l.to > from then
				edited = true
			elseif l.to <= from then
				moved += #l.text - (l.to - l.from)
			end
		end
		if edited then
			left += 1
		else
			table.insert(out, { from = from + moved, to = to + moved, text = old })
		end
	end
	return out, left
end

-- Puts back what's left of `op`'s changes that nobody edited since, all
-- as one undo step. Returns how many changes it put back and left.
local function revert_what_remains(op: Operation): (number, number)
	local put, left = 0, 0
	local group = greed.history.new_group()
	local current = greed.history.group()
	greed.history.set_group(group)
	for _, file in op.files do
		local buffer = greed.load(file.path)
		local list, kept = reverts(file, buffer:text())
		left += kept
		put += #list
		if #list > 0 then
			buffer:edit(function(e)
				for _, r in list do
					e:replace(r.from, r.to, r.text)
				end
			end)
		end
	end
	greed.history.set_group(current)
	return put, left
end

--- Undoes `op` in every file it changed, as one step. When something was
--- done on top of it since (or Greed restarted), it puts back the changes
--- nobody edited since and leaves the rest. Returns whether it changed
--- anything, and a word on what it left or why it couldn't.
function M.undo(op: Operation): (boolean, string?)
	if op.status == "running" then
		M.finish(op)
	end
	if not op.restored and op.status == "done" and greed.history.undo_group(op.id) then
		op.status = "undone"
		save()
		return true, nil
	end
	local put, left = revert_what_remains(op)
	if put == 0 then
		return false,
			if left > 0 then "every change it made was edited since" else "nothing left to undo"
	end
	op.status = if left == 0 then "undone" else "partly undone"
	save()
	return true, if left > 0 then `left {count(left, "change")} edited since` else nil
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

greed.command({
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
			greed.echo("no operations yet")
			return
		end
		picker.pick("Operations", items, function(item)
			M.review(item.value)
		end)
	end,
})

--- The operation commands act on from `buffer`: the one it reviews, or
--- the latest one not undone.
function M.target(buffer: greed.Buffer): Operation?
	local reviewed = reviews[buffer:id()]
	if reviewed then
		return reviewed
	end
	for _, op in M.list() do
		if op.status ~= "undone" then
			return op
		end
	end
	return nil
end

greed.command({
	name = "operation-undo",
	doc = "Undo the latest operation, or the one being reviewed, in every file at once",
	run = function(ctx)
		local op = M.target(ctx.buffer)
		if op == nil then
			greed.echo("no operation to undo")
			return
		end
		local ok, why = M.undo(op)
		if not ok then
			greed.echo(`can't undo "{op.name}": {why}`)
			return
		end
		local what = if why then `; {why}` else ` in {count(#op.files, "file")}`
		greed.echo(`undid "{op.name}"{what}`)
		if reviews[ctx.buffer:id()] then
			M.review(op)
		end
	end,
})

greed.on("buffer.closed", function(event)
	reviews[event.id] = nil
end)

greed.keymap.bind("normal", {
	["space u o"] = "operations",
	["space u u"] = "operation-undo",
})

M.restore()

return M
