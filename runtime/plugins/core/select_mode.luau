-- Select mode, like Helix's: `v` starts it, and moves extend the selection
-- instead of starting a new one. `n` and `N` add the next match of the last
-- search as another selection. Every other key works as in normal mode, and
-- changing or copying the text (d, c, y, ...) leaves select mode.

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

-- As in Helix, select mode lasts through anything that only selects (x, s,
-- %, m i (, alt-o, ...) and ends when the text changes or is copied.
kern.on("command.run", function(event: kern.CommandRun)
	if kern.mode.get() == "select" and event.name == "copy" then
		kern.mode.set("normal")
	end
end)

kern.on("buffer.changed", function(event: kern.BufferChanged)
	if kern.mode.get() == "select" and event.buffer:id() == kern.view():buffer():id() then
		kern.mode.set("normal")
	end
end)

return {}
