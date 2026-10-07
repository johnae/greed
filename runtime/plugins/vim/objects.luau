-- Ranges and text objects: the text a motion or an object covers.

local greed = require("@greed")
local core = require("@core")
local common = require("./common")

type Buffer = greed.Buffer
type Kind = common.Kind

local cursor = common.cursor

-- The text a motion covers from `pos`, as `from, to, linewise`.
local function motion_range(
	buffer: Buffer,
	pos: number,
	target: number,
	kind: Kind
): (number, number, boolean)
	local from, to = math.min(pos, target), math.max(pos, target)
	if kind == "inclusive" then
		to = math.min(buffer:next_char(to), buffer:len())
	elseif kind == "line" then
		local last = buffer:line_of(to)
		from = buffer:line_start(buffer:line_of(from))
		if last + 1 < buffer:line_count() then
			to = buffer:line_start(last + 1)
		else
			-- Deleting the last lines takes the line break before them instead.
			to = buffer:len()
			if from > 0 then
				from = buffer:prev_char(from)
			end
		end
		return from, to, true
	end
	return from, to, false
end

-- Vim's keys for text objects core names differently: b and B for ( and
-- {, t for a tag.
local OBJECT_KEYS = { b = "(", B = "{", t = "x" }

-- The text object for `key` around `pos` ("w", "(", '"', "p", ...), inside
-- it or around it: `from, to, linewise`, or nil.
local function text_object(
	buffer: Buffer,
	pos: number,
	key: string,
	around: boolean
): (number?, number?, boolean)
	return core.objects.find(buffer, pos, OBJECT_KEYS[key] or key, around, { vim = true })
end

local function select_word(ctx: greed.Context)
	local from, to = text_object(ctx.buffer, cursor(ctx), "w", false)
	if from and to then
		ctx.view:set_selection({ ranges = { { anchor = from, head = to } }, primary = 1 })
	end
end

return {
	motion_range = motion_range,
	text_object = text_object,
	select_word = select_word,
}
