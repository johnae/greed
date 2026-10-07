-- Text pasted into the client from the system clipboard (a terminal's paste,
-- or ctrl-shift-v in the window) goes in at the cursors in one edit, in any
-- mode: in normal mode it would otherwise run as keys. In edit mode it
-- replaces what's selected, as typing does there. Terminal panes take their
-- pastes themselves.

local greed = require("@greed")
local motions = require("./motions")
local span = require("./text").span

local M = {}

-- The modes where typing replaces the selection, and so does a paste.
M.replacing = { edit = true }

--- Puts `text` at each cursor of `view`.
function M.paste(view: greed.View, text: string)
	local buffer = view:buffer()
	if buffer:readonly() then
		return
	end
	text = string.gsub(text, "\r\n?", "\n")
	local replace = M.replacing[greed.mode.get()]
	-- Each cursor ends up after its text.
	motions.replace_each(view, function(_, range)
		local from, to = span(range)
		return { text = text, place = "end", from = from, to = if replace then to else from }
	end)
end

greed.on("client.paste", function(event: greed.ClientPaste)
	local view = greed.view()
	if view:buffer():kind() ~= "terminal" then
		M.paste(view, event.text)
	end
end)

return M
