-- Select mode, like Helix's: `v` starts it, and moves extend the selection
-- instead of starting a new one. `n` and `N` add the next match of the last
-- search as another selection. Every other key works as in normal mode, and
-- anything that acts on the selection (d, c, y, ...) leaves select mode.

local kern = require("@kern")

kern.keymap.inherit("select", "normal")
kern.keymap.bind("select", {
	h = "extend-left",
	l = "extend-right",
	j = "extend-down",
	k = "extend-up",
	left = "extend-left",
	right = "extend-right",
	down = "extend-down",
	up = "extend-up",
	w = "extend-word-right",
	b = "extend-word-left",
	e = "extend-word-end",
	W = "extend-big-word-right",
	B = "extend-big-word-left",
	E = "extend-big-word-end",
	f = "extend-find-next-char",
	t = "extend-till-next-char",
	F = "extend-find-prev-char",
	T = "extend-till-prev-char",
	home = "extend-line-start",
	["end"] = "extend-line-end",
	["g h"] = "extend-line-start",
	["g l"] = "extend-line-end",
	["g s"] = "extend-first-non-blank",
	["g g"] = "extend-start",
	["g e"] = "extend-end",
	G = "extend-goto-line",
	n = "search-next-add",
	N = "search-prev-add",
	v = "select-mode",
	esc = "select-mode",
})
kern.keymap.counts("select")

kern.command({
	name = "select-mode",
	doc = "Start select mode, where moves extend the selection, or leave it",
	run = function()
		kern.mode.set(if kern.mode.get() == "select" then "normal" else "select")
	end,
})

-- Commands that keep select mode going; anything else leaves it first.
local STAYS = {
	["select-mode"] = true,
	["search-next-add"] = true,
	["search-prev-add"] = true,
	["collapse"] = true,
	["flip"] = true,
	["keep-primary"] = true,
	["remove-primary"] = true,
	["rotate-primary"] = true,
	["rotate-primary-back"] = true,
	["page-down"] = true,
	["page-up"] = true,
	["half-page-down"] = true,
	["half-page-up"] = true,
	["center-view"] = true,
}

kern.on("command.run", function(event: kern.CommandRun)
	if
		kern.mode.get() == "select"
		and not STAYS[event.name]
		and string.sub(event.name, 1, 7) ~= "extend-"
	then
		kern.mode.set("normal")
	end
end)

return {}
