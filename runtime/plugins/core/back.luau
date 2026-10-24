-- Back, the same everywhere: in anything you read rather than edit (a
-- picture, the mail list, a chat room, the file tree), `q` and `esc` go
-- back. A kind of buffer with steps of its own takes one back (a mail
-- thread goes to the list); otherwise back goes where you came from, as
-- ctrl-o does, and a float or panel with nowhere to go closes. In text you
-- edit, `q` and `esc` stay the style's.
--
--     core.back.provide("tree", "tree-close")

local greed = require("@greed")
local jumps = require("./jumps")
local registry = require("./registry")

local M = {}

--- What back does in a kind of buffer: a command to run, or a function
--- that goes back a step in `view` and says whether it went anywhere.
export type Step = string | (view: greed.View) -> boolean

local steps: { [string]: { step: Step? } } = {}

--- Makes `q` and `esc` go back in buffers of `kind`, with `step` for what
--- that kind does first, if anything. It goes with the plugin that said so.
function M.provide(kind: string, step: Step?)
	greed.plugin.cleanup(registry.set(steps, kind, { step = step }))
	greed.keymap.bind({ role = "command", kind = kind }, { q = "back", esc = "back" })
end

--- Goes back in `view`: its kind's step, else where it came from, else
--- closing it if it's a float or a panel.
function M.go(view: greed.View)
	local known = steps[view:buffer():kind()]
	local step = if known then known.step else nil
	if type(step) == "string" then
		greed.run(step)
		return
	elseif type(step) == "function" and step(view) then
		return
	end
	if jumps.back(view) then
		return
	elseif not view:is_pane() then
		view:close()
	else
		greed.echo("nothing to go back to")
	end
end

greed.command({
	name = "back",
	doc = "Go back: a step in what's shown, else where you came from (q and esc where you read rather than edit)",
	run = function(ctx)
		M.go(ctx.view)
	end,
})

return M
