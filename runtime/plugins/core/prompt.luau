-- A one-line prompt at the bottom of the screen, for search and other
-- commands that ask for a bit of text. Enter accepts, esc cancels.

local greed = require("@greed")
local style = require("./style")

export type Options = {
	title: string,
	--- What it starts with, the cursor at its end.
	text: string?,
	--- Called with the text as it's typed.
	on_change: ((text: string) -> ())?,
	on_submit: (text: string) -> (),
	on_cancel: (() -> ())?,
	--- Shows a dot for each character typed, for passwords and keys.
	secret: boolean?,
}

type Open = {
	view: greed.View,
	buffer: greed.Buffer,
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
	greed.mode.set(o.mode)
	finish(o.options, typed)
end

-- Dots over what's typed in a secret prompt, so it never shows.
local function mask(o: Open)
	if o.options.secret then
		local typed = text(o)
		local dots = string.rep("•", utf8.len(typed) or #typed)
		o.buffer:decorate(
			"prompt-secret",
			{ { from = 0, to = #typed, text = dots, overlay = true, style = "ui.text" } }
		)
	end
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local o = open
	if o == nil or event.buffer:id() ~= o.buffer:id() then
		return
	end
	mask(o)
	if o.options.on_change then
		o.options.on_change(text(o))
	end
end)

greed.command({
	name = "prompt-submit",
	doc = "Accept what's typed in the prompt",
	run = function()
		close(function(options, typed)
			options.on_submit(typed)
		end)
	end,
})

local function cancel(options: Options)
	if options.on_cancel then
		options.on_cancel()
	end
end

-- Closed some other way, it counts as cancelled.
greed.on("view.closed", function(event: greed.ViewClosed)
	local o = open
	if o and o.view:id() == event.view then
		open = nil
		greed.mode.set(o.mode)
		cancel(o.options)
	end
end)

greed.command({
	name = "prompt-cancel",
	doc = "Close the prompt without accepting",
	run = function()
		close(cancel)
	end,
})

style.kind_mode("prompt", "insert")
greed.keymap.bind({ mode = "insert", kind = "prompt" }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
})

local M = {}

--- Asks for a line of text at the bottom of the screen.
function M.open(options: Options)
	if open then
		greed.run("prompt-cancel")
	end
	local text = options.text or ""
	local buffer = greed.create_buffer("prompt", text)
	local view = greed.float(
		buffer,
		{ title = options.title, width = "100%", height = 3, anchor = "bottom" }
	)
	open = { view = view, buffer = buffer, options = options, mode = greed.mode.get() }
	greed.mode.set("insert")
	view:set_selection({ ranges = { { anchor = #text, head = #text } }, primary = 1 })
	mask(open :: Open)
end

--- Like `open`, but waits for the answer and returns what was typed, or
--- nil when the prompt is cancelled. Works in commands and handlers. With
--- `secret`, dots show instead of what's typed.
function M.ask(title: string, text: string?, options: { secret: boolean? }?): string?
	local done = greed.signal()
	M.open({
		title = title,
		text = text,
		secret = options and options.secret,
		on_submit = function(typed)
			done.send(typed)
		end,
		on_cancel = function()
			done.send(false)
		end,
	})
	local typed = done.wait()
	return if typed then typed else nil
end

return M
