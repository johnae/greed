-- A one-line prompt at the bottom of the screen, for search and other
-- commands that ask for a bit of text. Enter accepts, esc cancels.

local kern = require("@kern")

export type Options = {
	title: string,
	--- Called with the text as it's typed.
	on_change: ((text: string) -> ())?,
	on_submit: (text: string) -> (),
	on_cancel: (() -> ())?,
}

type Open = {
	view: kern.View,
	buffer: kern.Buffer,
	options: Options,
	-- The mode to go back to.
	mode: string,
}

local open: Open? = nil

local function text(o: Open): string
	return (string.gsub(o.buffer:text(), "\n", ""))
end

-- Closes the prompt, then calls `finish` with its options and what was
-- typed, read first since closing the view drops the buffer.
local function close(finish: (options: Options, typed: string) -> ())
	local o = open
	if o == nil then
		return
	end
	local typed = text(o)
	open = nil
	o.view:close()
	kern.mode.set(o.mode)
	finish(o.options, typed)
end

kern.on("buffer.changed", function(event: kern.BufferChanged)
	local o = open
	if o and event.buffer:id() == o.buffer:id() and o.options.on_change then
		o.options.on_change(text(o))
	end
end)

kern.command({
	name = "prompt-submit",
	doc = "Accept what's typed in the prompt",
	run = function()
		close(function(options, typed)
			options.on_submit(typed)
		end)
	end,
})

kern.command({
	name = "prompt-cancel",
	doc = "Close the prompt without accepting",
	run = function()
		close(function(options)
			if options.on_cancel then
				options.on_cancel()
			end
		end)
	end,
})

kern.keymap.bind({ mode = "insert", kind = "prompt" }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
})

local M = {}

--- Asks for a line of text at the bottom of the screen.
function M.open(options: Options)
	if open then
		kern.run("prompt-cancel")
	end
	local buffer = kern.create_buffer("prompt", "")
	local view =
		kern.float(buffer, { title = options.title, width = "100%", height = 3, anchor = "bottom" })
	open = { view = view, buffer = buffer, options = options, mode = kern.mode.get() }
	kern.mode.set("insert")
end

return M
