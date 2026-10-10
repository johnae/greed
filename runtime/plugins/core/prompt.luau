-- A one-line prompt at the bottom of the screen, for search and other
-- commands that ask for a bit of text. Enter accepts, esc cancels.

local greed = require("@greed")
local floats = require("./floats")
local style = require("./style")
local width = require("./text").width

export type Options = {
	title: string,
	--- What it starts with, the cursor at its end.
	text: string?,
	--- Starts with `text` selected, so typing at once replaces it, as a
	--- find or rename field does.
	selected: boolean?,
	--- Called with the text as it's typed.
	on_change: ((text: string) -> ())?,
	on_submit: (text: string) -> (),
	on_cancel: (() -> ())?,
	--- Shows a dot for each character typed, for passwords and keys.
	secret: boolean?,
	--- The kind of buffer it's typed in, for keys of its own, like the find
	--- bar's; "prompt" by default.
	kind: string?,
}

type Open = {
	float: floats.Typing,
	options: Options,
	-- What to do once it's closed; cancelling if nothing else.
	finish: (() -> ())?,
}

-- The prompt open for each client, by its id.
local opened: { [number]: Open } = {}

local function text(o: Open): string
	return (string.gsub(o.float.buffer:text(), "\n", ""))
end

-- Closes the acting client's prompt, then calls `finish` with its options
-- and what was typed, read first since closing the view drops the buffer.
local function close(finish: (options: Options, typed: string) -> ())
	local o = opened[greed.client.id()]
	if o == nil then
		return
	end
	local typed = text(o)
	function o.finish()
		finish(o.options, typed)
	end
	o.float.close()
end

-- Dots over what's typed in a secret prompt, so it never shows.
local function mask(o: Open)
	if o.options.secret then
		local typed = text(o)
		local dots = string.rep("•", width(typed))
		o.float.buffer:decorate(
			"prompt-secret",
			{ { from = 0, to = #typed, text = dots, overlay = true, style = "ui.text" } }
		)
	end
end

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

greed.command({
	name = "prompt-cancel",
	doc = "Close the prompt without accepting",
	run = function()
		close(cancel)
	end,
})

style.typing_kind("prompt")
style.label_kind("prompt", "prompt")
greed.keymap.bind({ kind = "prompt" }, {
	enter = "prompt-submit",
	esc = "prompt-cancel",
	["ctrl-c"] = "prompt-cancel",
})

local M = {}

--- Asks for a line of text at the bottom of the screen, of the acting
--- client alone. Returns its view, e.g. to put a label on its border.
function M.open(options: Options): greed.View
	local client = greed.client.id()
	if opened[client] then
		greed.run("prompt-cancel")
	end
	local start = options.text or ""
	-- Nothing typed yet over a selected start.
	local pristine = options.selected == true and start ~= ""
	local o: Open
	o = {
		float = floats.typing(
			greed.create_buffer(options.kind or "prompt", start),
			{ title = options.title, width = "100%", height = 3, anchor = "bottom" },
			{
				on_change = function()
					-- Typing at once after a selected start replaces it, in
					-- styles whose typing mode would add to it instead.
					if pristine then
						pristine = false
						local now = text(o)
						-- Typed after it (Vim's insert) or before it (Helix's).
						local typed: string? = nil
						if #now > #start and string.sub(now, 1, #start) == start then
							typed = string.sub(now, #start + 1)
						elseif #now > #start and string.sub(now, -#start) == start then
							typed = string.sub(now, 1, #now - #start)
						end
						if typed then
							local replacement: string = typed
							o.float.buffer:edit(function(e)
								e:replace(0, o.float.buffer:len(), replacement)
							end)
							o.float.view:set_cursor(#replacement)
							return
						end
					end
					mask(o)
					if options.on_change then
						options.on_change(text(o))
					end
				end,
				-- Closed some other way, it counts as cancelled.
				on_close = function()
					if opened[client] == o then
						opened[client] = nil
					end
					local finish = o.finish
					if finish then
						finish()
					else
						cancel(options)
					end
				end,
			}
		),
		options = options,
	} :: Open
	opened[client] = o
	if options.selected and start ~= "" then
		o.float.view:set_selection({ ranges = { { anchor = 0, head = #start } }, primary = 1 })
	else
		o.float.view:set_cursor(#start)
	end
	mask(o)
	return o.float.view
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
			done:send(typed)
		end,
		on_cancel = function()
			done:send(false)
		end,
	})
	local typed = done:wait()
	return if typed then typed else nil
end

return M
