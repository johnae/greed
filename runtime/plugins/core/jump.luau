-- Jump to any word on screen, like Helix's g w: every word gets a two
-- letter label, closest first, and typing a label selects that word. Any
-- other key cancels.
--
-- The letters labels use can be changed:
--
--     require("@kern").option.set("jump-label-alphabet", "fjdkslaghrueiwoqptyvbcnxmz")

local kern = require("@kern")

kern.option.define({
	name = "jump-label-alphabet",
	doc = "The letters jump labels are made of, most comfortable first",
	default = "abcdefghijklmnopqrstuvwxyz",
})

type Match = { from: number, to: number }
type Target = { from: number, to: number, label: string }

local function letters(): { string }
	local out = {}
	for _, code in utf8.codes(kern.option.get("jump-label-alphabet") :: string) do
		table.insert(out, utf8.char(code))
	end
	return out
end

-- The words of two or more characters on screen, nearest to `head` first
-- (earlier ones on a tie), each with a label.
local function targets(view: kern.View, head: number): { Target }
	local from, to = view:visible()
	local words: { Match } = view:buffer():find_all("\\w{2,}", from, to) or {}
	table.sort(words, function(a: Match, b: Match)
		local da, db = math.abs(a.from - head), math.abs(b.from - head)
		return da < db or (da == db and a.from < b.from)
	end)
	local alphabet = letters()
	local out = {}
	for i, word in words do
		local first, second = (i - 1) // #alphabet + 1, (i - 1) % #alphabet + 1
		if first > #alphabet then
			break
		end
		local label = alphabet[first] .. alphabet[second]
		table.insert(out, { from = word.from, to = word.to, label = label })
	end
	return out
end

-- Shows what's left of each label of `targets` starting with `typed`.
local function show(buffer: kern.Buffer, targets: { Target }, typed: string)
	local marks = {}
	for _, target in targets do
		if string.sub(target.label, 1, #typed) == typed then
			local rest = string.sub(target.label, #typed + 1)
			table.insert(marks, {
				from = target.from,
				to = buffer:next_char(target.from),
				text = rest,
				overlay = true,
				above = true,
				style = "ui.jump.label",
			})
		end
	end
	buffer:decorate("jump", marks)
end

kern.command({
	name = "jump-to-word",
	doc = "Label the words on screen and select the one whose label is typed",
	run = function(ctx)
		if #letters() == 0 then
			kern.echo("jump-label-alphabet is empty")
			return
		end
		local selection = ctx.view:selection()
		local found = targets(ctx.view, selection.ranges[selection.primary].head)
		if #found == 0 then
			kern.echo("no words to jump to")
			return
		end
		-- Two keys, whatever their length in bytes.
		local typed = ""
		for _ = 1, 2 do
			show(ctx.buffer, found, typed)
			typed ..= kern.next_key()
		end
		ctx.buffer:decorate("jump", {})
		for _, target in found do
			if target.label == typed then
				ctx.view:set_selection({
					ranges = { { anchor = target.from, head = target.to } },
					primary = 1,
				})
				return
			end
		end
	end,
})

return {}
