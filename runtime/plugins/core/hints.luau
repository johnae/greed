-- Motion hints, with the `motion-hints` option on: right after a word
-- motion, digits label where doing it 1 to 9 more times would land, and
-- typing one goes there (extending the selection where the motion
-- extends). Off by default, since right after a motion a digit is then a
-- hint rather than the start of a count. Styles add their motions by
-- calling `after` at the end of them, as core's word motions and Vim's do.

local greed = require("@greed")

greed.option.define({
	name = "motion-hints",
	doc = "Number the next places a word motion would go, and go there on a digit",
	default = false,
})

local M = {}

-- How many places get a number.
local SHOWN = 9
-- How many of them, the nearest, stand out; the rest are quieter.
local NEAR = 3

--- One more of the motion from `range`: the range it gives and the
--- character the cursor lands on, or nil when it goes nowhere new.
export type Step = (buffer: greed.Buffer, range: greed.Range) -> (greed.Range?, number?)

-- The motion the shown hints are for, and the buffer they're drawn in.
local shown: { command: string, buffer: greed.Buffer }? = nil

local function clear()
	local hints = shown
	if hints then
		shown = nil
		pcall(function()
			hints.buffer:decorate("motion-hints", {})
		end)
	end
end

-- Where the number for a place at `at` goes: there if it's a space, else
-- on the space just before or after it, so it covers none of the text,
-- unless another number already took that space.
local function label_at(buffer: greed.Buffer, at: number, taken: { [number]: boolean }): number
	local function free(pos: number): boolean
		local char = pos >= 0 and buffer:char_at(pos)
		return (char == " " or char == "\t") and not taken[pos]
	end
	if free(at) then
		return at
	end
	local before = if at > 0 then buffer:prev_char(at) else -1
	if free(before) then
		return before
	end
	local after = buffer:next_char(at)
	return if free(after) then after else at
end

--- Shows the hints for motion `command` from the primary selection, each
--- next place found by `step`. Does nothing with the option off.
function M.after(ctx: greed.Context, command: string, step: Step)
	if not greed.option.get("motion-hints") then
		return
	end
	local buffer = ctx.buffer
	local selection = ctx.view:selection()
	local range = selection.ranges[selection.primary]
	local marks: { greed.Mark } = {}
	local keys: { [string]: string } = {}
	local taken: { [number]: boolean } = {}
	for n = 1, SHOWN do
		local next, at = step(buffer, range)
		if
			next == nil
			or at == nil
			or (next.anchor == range.anchor and next.head == range.head)
		then
			break
		end
		range = next
		local label = label_at(buffer, at, taken)
		taken[label] = true
		table.insert(marks, {
			from = label,
			to = math.min(buffer:next_char(label), buffer:len()),
			text = tostring(n),
			overlay = true,
			style = if n <= NEAR then "ui.motion.hint" else "ui.motion.hint.far",
		})
		keys[tostring(n)] = `motion-hint-{n}`
	end
	clear()
	if #marks == 0 then
		return
	end
	buffer:decorate("motion-hints", marks)
	shown = { command = command, buffer = buffer }
	greed.keymap.overlay(keys)
end

-- Any other command takes the hints away; the digits went with the next key.
greed.on("command.run", function(event: greed.CommandRun)
	if not string.match(event.name, "^motion%-hint%-%d$") then
		clear()
	end
end)

for n = 1, SHOWN do
	greed.command({
		name = `motion-hint-{n}`,
		doc = `Do the last motion {n} more times`,
		run = function()
			local hints = shown
			if hints then
				greed.run(hints.command, { count = n })
			end
		end,
	})
end

return M
