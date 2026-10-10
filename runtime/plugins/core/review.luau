-- Reviewing actions that destroy or stop something before they run: a
-- float listing each, what it will do (the command it runs) and a warning
-- where one is due (production), every one ticked. `space` ticks or
-- unticks the one at the cursor, `a` ticks them all, `enter` runs the
-- ticked ones and `esc` (or `q`) runs none.

local greed = require("@greed")

local M = {}

--- One thing to run: what it is, what it will do, and a warning.
export type Item = { label: string, says: string?, warning: string? }

type Open = {
	view: greed.View,
	items: { Item },
	ticked: { boolean },
	done: greed.Signal,
}

-- What each client is reviewing, by its id.
local opened: { [number]: Open } = {}

-- Lines above the items.
local HEADER = 2

local function draw(o: Open)
	local lines = { "enter runs what's ticked · space ticks · a all · esc none", "" }
	for i, item in o.items do
		local line = `{if o.ticked[i] then "[x]" else "[ ]"} {item.label}`
		if item.says then
			line ..= `   {item.says}`
		end
		if item.warning then
			line ..= `   ({item.warning})`
		end
		table.insert(lines, line)
	end
	local buffer = o.view:buffer()
	local cursor = o.view:cursor()
	buffer:set_readonly(false)
	buffer:edit(function(e)
		e:replace(0, buffer:len(), table.concat(lines, "\n"))
	end)
	buffer:set_readonly(true)
	local marks: { greed.Mark } = { { from = 0, to = buffer:line_end(0), style = "comment" } }
	for i, item in o.items do
		if item.warning then
			local line = HEADER + i - 1
			marks[#marks + 1] =
				{ from = buffer:line_start(line), to = buffer:line_end(line), style = "error" }
		end
	end
	buffer:decorate("review", marks)
	o.view:set_cursor(math.clamp(cursor, buffer:line_start(HEADER), buffer:len()))
end

local function mine(): Open?
	return opened[greed.client.id()]
end

local function finish(o: Open, ran: boolean)
	for client, other in opened do
		if other == o then
			opened[client] = nil
		end
	end
	if o.view:valid() then
		o.view:close()
	end
	o.done:send(if ran then o.ticked else false)
end

--- Shows `items` under `title` to review, every one ticked, and waits:
--- which were left ticked when `enter` ran them, by place, or nil when
--- `esc` ran none.
function M.ask(title: string, items: { Item }): { boolean }?
	local current = mine()
	if current then
		finish(current, false)
	end
	local buffer = greed.create_buffer("review", "", { readonly = true })
	local o: Open = {
		view = greed.float(buffer, {
			title = title,
			width = "80%",
			height = math.min(#items + HEADER + 2, 30),
		}),
		items = items,
		ticked = table.create(#items, true),
		done = greed.signal(),
	}
	opened[greed.client.id()] = o
	buffer:set_keys({
		space = "review-tick",
		a = "review-tick-all",
		enter = "review-run",
		esc = "review-none",
		q = "review-none",
	})
	draw(o)
	local answer = o.done:wait()
	return if answer then answer else nil
end

greed.command({
	name = "review-tick",
	doc = "In a review, tick or untick the action at the cursor",
	run = function(ctx)
		local o = mine()
		local at = ctx.buffer:line_of(ctx.view:cursor()) - HEADER + 1
		if o and o.ticked[at] ~= nil then
			o.ticked[at] = not o.ticked[at]
			draw(o)
		end
	end,
})

greed.command({
	name = "review-tick-all",
	doc = "In a review, tick every action, or untick them all when they are",
	run = function()
		local o = mine()
		if o then
			local all = not table.find(o.ticked, false)
			for i in o.ticked do
				o.ticked[i] = not all
			end
			draw(o)
		end
	end,
})

greed.command({
	name = "review-run",
	doc = "In a review, run the ticked actions",
	run = function()
		local o = mine()
		if o then
			finish(o, true)
		end
	end,
})

greed.command({
	name = "review-none",
	doc = "In a review, run none of the actions",
	run = function()
		local o = mine()
		if o then
			finish(o, false)
		end
	end,
})

-- A review whose float closed some other way runs none.
greed.on("view.closed", function(event: greed.ViewClosed)
	for _, o in table.clone(opened) do
		if o.view:id() == event.view then
			finish(o, false)
		end
	end
end)

return M
