-- The prompt's history keys: up and down walk through the commands typed
-- before, and right or end take the rest of what the prompt suggests.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local log = require("./log")
local history = require("./history")
local suggest = require("./suggest")

-- Each shell's walk through the history, while what's at its prompt is
-- what the walk put there.
local walks: { [number]: core.RecallWalk } = {}

-- Puts the command `step` (1 older, -1 newer) from the one at the prompt
-- there, among those starting with what was typed. Away from the prompt,
-- or on a line of it other than the first (going back) or the last, the
-- arrow moves the cursor as usual.
local function walk(ctx: greed.Context, step: number)
	local buffer = ctx.buffer
	local shell = state.of(buffer)
	local pos = ctx.view:cursor()
	local edge = if step > 0
		then shell and buffer:line_of(log.prompt_start(shell))
		else buffer:line_count() - 1
	if shell == nil or not log.in_prompt(shell, pos) or buffer:line_of(pos) ~= edge then
		greed.run(if step > 0 then "move-up" else "move-down")
		return
	end
	local typed = log.prompt_text(shell)
	local current = walks[shell.id]
	if current == nil or current.shown ~= typed then
		current = core.recall.walk(typed, history.commands())
		walks[shell.id] = current
	end
	local found = core.recall.step(current, step)
	if found == nil then
		greed.echo(if typed == "" then "no older command" else `no older command starting {typed}`)
		return
	end
	log.set_prompt(shell, found, { ctx.view })
end

-- Takes what the prompt suggests, or else runs `otherwise`, the key's
-- usual command.
local function accept_or(ctx: greed.Context, otherwise: string)
	local shell = state.of(ctx.buffer)
	if shell == nil or not suggest.accept(shell, ctx.view) then
		greed.run(otherwise)
	end
end

greed.command({
	name = "shell-accept-or-right",
	doc = "At the end of the prompt, take the rest of the command it suggests; elsewhere move right",
	run = function(ctx)
		accept_or(ctx, "move-right")
	end,
})

greed.command({
	name = "shell-accept-or-end",
	doc = "At the end of the prompt, take the rest of the command it suggests; elsewhere go to the end of the line",
	run = function(ctx)
		accept_or(ctx, "line-end")
	end,
})

greed.command({
	name = "shell-history-back",
	doc = "Put the command typed before at the prompt, one starting with what's typed there",
	run = function(ctx)
		walk(ctx, 1)
	end,
})

greed.command({
	name = "shell-history-forward",
	doc = "Put the command typed after at the prompt, or back to what was typed",
	run = function(ctx)
		walk(ctx, -1)
	end,
})

return {}
