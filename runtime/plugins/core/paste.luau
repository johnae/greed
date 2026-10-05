-- Text pasted into the client from the system clipboard (a terminal's paste,
-- or ctrl-shift-v in the window) goes in at the cursors in one edit, in any
-- mode: in normal mode it would otherwise run as keys. In edit mode it
-- replaces what's selected, as typing does there. Terminal panes take their
-- pastes themselves.

local greed = require("@greed")

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
	local selection = view:selection()
	buffer:edit(function(e)
		-- Each cursor ends up after its text; `shift` is how far the text
		-- pasted at the cursors before it moved it.
		local cursors = {}
		local shift = 0
		for _, range in selection.ranges do
			local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
			if replace then
				e:replace(from, to, text)
			else
				e:insert(from, text)
				to = from
			end
			local at = from + shift + #text
			table.insert(cursors, { anchor = at, head = at })
			shift += #text - (to - from)
		end
		e:select({ ranges = cursors, primary = selection.primary })
	end)
end

greed.on("client.paste", function(event: greed.ClientPaste)
	local view = greed.view()
	if view:buffer():kind() ~= "terminal" then
		M.paste(view, event.text)
	end
end)

return M
