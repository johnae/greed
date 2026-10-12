-- Running a few changes with no frame drawn in between.

--- Runs `f(...)` to its end and returns what it returns, with no frame
--- drawn while it runs: a command or handler that has worked its time slice
--- is otherwise paused wherever it is, and the editor draws what's half
--- done, like a buffer's new text with its old decorations. Keep `f` short
--- (the work before it can be paused as usual); it can't wait
--- (greed.sleep and the like), which is an error.
local function atomic(f: (...any) -> ...any, ...: any): ...any
	-- The editor pauses only the task's own coroutine, never one it made.
	local thread = coroutine.create(f)
	local results = table.pack(coroutine.resume(thread, ...))
	if not results[1] then
		error(results[2], 0)
	elseif coroutine.status(thread) ~= "dead" then
		error("core.atomic: the function waited, which it can't", 2)
	end
	return table.unpack(results, 2, results.n)
end

return atomic
