-- Suggestions as you type at a prompt, as fish makes them: the newest
-- command typed before that starts with what's at the prompt shows dimmed
-- after the cursor, and `right`, `end` or `ctrl-e` there takes it.

local greed = require("@greed")
local state = require("./state")
local log = require("./log")
local history = require("./history")

type Shell = state.Shell

local M = {}

local NAMESPACE = "shell.suggestion"

greed.option.define({
	name = "shell-suggestions",
	doc = "Whether a shell's prompt suggests the rest of a command typed before, after the cursor",
	default = true,
})

-- The rest of the command each shell suggests now, by shell id.
local shown: { [number]: string } = {}

--- Works out what `shell` suggests for what's typed at its prompt in
--- `view`, with the cursor at its end, and shows it.
function M.update(shell: Shell, view: greed.View)
	local buffer = shell.buffer
	local rest: string? = nil
	if greed.option.get("shell-suggestions") and view:cursor() == buffer:len() then
		local typed = log.prompt_text(shell)
		local found = if string.find(typed, "\n", 1, true) then nil else history.suggest(typed)
		rest = if found then string.sub(found, #typed + 1) else nil
	end
	if rest == shown[shell.id] then
		return
	end
	if rest then
		shown[shell.id] = rest
	else
		shown[shell.id] = nil
	end
	local len = buffer:len()
	buffer:decorate(
		NAMESPACE,
		if rest then { { from = len, to = len, style = "shell.suggestion", text = rest } } else {}
	)
end

--- What `shell` suggests after what's typed, if anything.
function M.suggestion(shell: Shell): string?
	return shown[shell.id]
end

--- Puts what `shell` suggests at its prompt in `view`, when the cursor is
--- at the end; false when there's nothing to take.
function M.accept(shell: Shell, view: greed.View): boolean
	local rest = shown[shell.id]
	if rest == nil or view:cursor() ~= shell.buffer:len() then
		return false
	end
	log.set_prompt(shell, log.prompt_text(shell) .. rest, { view })
	M.update(shell, view)
	return true
end

-- Typing and moving at a prompt changes what's suggested.
greed.on("selection.changed", function(event: greed.SelectionChanged)
	-- It may have closed since, as a float a file was opened in does.
	if not event.view:valid() then
		return
	end
	local shell = state.of(event.view:buffer())
	if shell then
		M.update(shell, event.view)
	end
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local shell = state.of(event.buffer)
	if shell then
		for _, view in event.buffer:views() do
			M.update(shell, view)
		end
	end
end)

return M
