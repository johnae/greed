-- Going back through what was typed before, as `up` and `down` do at a
-- shell's prompt or in an agent's box: each step puts an earlier entry
-- there, among those starting with what was typed, and stepping back past
-- the newest gives what was typed again.

local M = {}

--- Where a walk through earlier entries is: the text typed before it
--- started, the entries it goes through (newest first), the one shown and
--- the text it put there.
export type Walk = {
	typed: string,
	matches: { string },
	index: number,
	shown: string,
}

--- A walk through `earlier` (newest first) starting with `typed`, each
--- once.
function M.walk(typed: string, earlier: { string }): Walk
	local matches: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, entry in earlier do
		if entry ~= typed and not seen[entry] and string.sub(entry, 1, #typed) == typed then
			seen[entry] = true
			table.insert(matches, entry)
		end
	end
	return { typed = typed, matches = matches, index = 0, shown = typed }
end

--- The entry `step` (1 older, -1 newer) from where `walk` is, or what was
--- typed past the newest; nil past the oldest.
function M.step(walk: Walk, step: number): string?
	local index = walk.index + step
	if index > #walk.matches then
		return nil
	end
	walk.index = math.max(index, 0)
	walk.shown = if walk.index == 0 then walk.typed else walk.matches[walk.index]
	return walk.shown
end

return M
