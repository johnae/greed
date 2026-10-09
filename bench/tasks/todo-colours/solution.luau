local greed = require("@greed")

local STYLES = { TODO = "diagnostic.warning", FIXME = "diagnostic.error", NOTE = "diagnostic.info" }

local function mark(buffer: greed.Buffer)
	local marks = {}
	for word, style in STYLES do
		local found = buffer:find_all(`\\b{word}\\b`) or {}
		for _, m in found do
			table.insert(marks, { from = m.from, to = m.to, style = style })
		end
	end
	buffer:decorate("todo-colours", marks)
end

for _, buffer in greed.buffers() do
	mark(buffer)
end
greed.on("buffer.opened", function(event)
	mark(event.buffer)
end)
greed.on("buffer.changed", function(event)
	mark(event.buffer)
end)
