-- `.` repeats the last change by typing its keys again, as Vim does: the
-- keys of the command that made it, the ones it read (a motion, a
-- character) and, if it went into insert or visual mode, everything up to
-- coming back. That works the same for every style and for commands from
-- any plugin, with nothing to declare.
--
-- Each command run from a style's own mode (normal, vim) starts a run of
-- keys; the next one ends it. A run that changed the buffer it started in
-- becomes the last change. Undo, redo, macros and `.` itself don't start
-- runs.

local kern = require("@kern")
local style = require("./style")

local M = {}

-- Commands that never count as changes, by name.
local ignored: { [string]: boolean } = {}

--- Leaves the commands `names` out of what `.` repeats, like undo.
function M.ignore(names: { string })
	for _, name in names do
		ignored[name] = true
	end
end

M.ignore({ "undo", "redo", "repeat-change", "play-macro", "record-macro" })

-- The run being recorded: what started it and whether it changed its buffer.
type Run = { keys: string, count: number?, buffer: number, changed: boolean }
local run: Run? = nil

-- The last change: its keys after the count, and the count it had.
local last: { keys: string, count: number? }? = nil

-- Ends the run being recorded, dropping the last `extra` keys, which belong
-- to the command that ended it, and keeps it if it changed something.
local function finish(extra: number)
	local ended = run
	if ended == nil then
		return
	end
	run = nil
	local keys = kern.keys.stop("again") or {}
	for _ = 1, extra do
		table.remove(keys)
	end
	if ended.changed then
		local typed = table.concat(keys, " ")
		last = {
			keys = if typed == "" then ended.keys else `{ended.keys} {typed}`,
			count = ended.count,
		}
	end
end

kern.on("command.run", function(event: kern.CommandRun)
	if not style.is_home(kern.mode.get()) then
		return
	end
	-- The keys of this command, with its count's digits, came in before it ran.
	local extra = if event.keys then #string.split(event.keys, " ") else 0
	if event.count then
		extra += #tostring(event.count)
	end
	finish(extra)
	if ignored[event.name] or event.keys == nil then
		return
	end
	run = {
		keys = event.keys,
		count = event.count,
		buffer = kern.view():buffer():id(),
		changed = false,
	}
	kern.keys.record("again", { fed = true })
end)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	if run and event.buffer:id() == run.buffer then
		run.changed = true
	end
end)

kern.command({
	name = "repeat-change",
	doc = "Repeat the last change, at the cursors; a count replaces the one it had",
	run = function(ctx)
		local change = last
		if change == nil then
			return
		end
		local count = ctx.count or change.count
		kern.keys.feed(if count then `{count} {change.keys}` else change.keys)
	end,
})

return M
