-- Select mode, like Helix's: `v` starts it, and moves extend the selection
-- instead of starting a new one. `n` and `N` add the next match of the last
-- search as another selection. Every other key works as in Helix's normal mode, and
-- changing or copying the text (d, c, y, ...) leaves select mode.

local greed = require("@greed")

greed.keymap.inherit("helix-select", "helix")
greed.keymap.bind("helix-select", {
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
greed.keymap.counts("helix-select")

greed.command({
	name = "select-mode",
	doc = "Start select mode, where moves extend the selection, or leave it",
	run = function()
		greed.mode.set(if greed.mode.get() == "helix-select" then "helix" else "helix-select")
	end,
})

-- As in Helix, select mode lasts through anything that only selects (x, s,
-- %, m i (, alt-o, ...) and ends when the text changes or is copied.
greed.on("command.run", function(event: greed.CommandRun)
	if greed.mode.get() == "helix-select" and event.name == "copy" then
		greed.mode.set("helix")
	end
end)

greed.on("buffer.changed", function(event: greed.BufferChanged)
	if greed.mode.get() == "helix-select" and event.buffer:id() == greed.view():buffer():id() then
		greed.mode.set("helix")
	end
end)

return {}
