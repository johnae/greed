-- Moving by item, the same keys wherever a buffer is made of them: a
-- message in a chat room or a mail thread, a row of the mail list. `] m`
-- goes to the next one's start and `[ m` to the one before (or the start
-- of the one the cursor is in), a count going that many. A plugin says
-- where a kind of buffer's items start:
--
--     core.items.provide("chat-room", function(view)
--         return { 0, 120, 480 } -- where each message starts
--     end)

local greed = require("@greed")
local registry = require("./registry")

local M = {}

--- Where the items in `view` start, in order.
export type Starts = (view: greed.View) -> { number }

local providers: { [string]: Starts } = {}

--- Says where the items of buffers of `kind` start. It goes with the
--- plugin that said so.
function M.provide(kind: string, starts: Starts)
	greed.plugin.cleanup(registry.set(providers, kind, starts))
end

--- Where the item `count` items after (or before, `forward` false) the
--- cursor in `view` starts; nil when there's none that way, or the buffer
--- has no items.
function M.target(view: greed.View, forward: boolean, count: number): number?
	local starts = providers[view:buffer():kind()]
	if starts == nil then
		return nil
	end
	local at = view:cursor()
	local list = starts(view)
	local found: number? = nil
	local left = count
	local from, to, step = 1, #list, 1
	if not forward then
		from, to, step = #list, 1, -1
	end
	for i = from, to, step do
		local start = list[i]
		if (forward and start > at) or (not forward and start < at) then
			found = start
			left -= 1
			if left == 0 then
				break
			end
		end
	end
	return found
end

local function go(ctx: greed.Context, forward: boolean)
	if providers[ctx.buffer:kind()] == nil then
		greed.echo("this isn't made of items to move between")
		return
	end
	local to = M.target(ctx.view, forward, ctx.count or 1)
	if to then
		ctx.view:set_cursor(to)
	end
end

greed.command({
	name = "next-item",
	doc = "Go to the next item: a message in a chat room or a mail thread, a row of a list",
	run = function(ctx)
		go(ctx, true)
	end,
})

greed.command({
	name = "previous-item",
	doc = "Go to the item before, or the start of the one the cursor is in",
	run = function(ctx)
		go(ctx, false)
	end,
})

greed.keymap.bind({ role = "command" }, {
	["] m"] = "next-item",
	["[ m"] = "previous-item",
})

return M
