-- Registers and macros. `"` and a letter picks a register for the next copy,
-- paste, delete or macro; without one, copies go to the clipboard and macros
-- to `@`. `Q` starts and stops recording keys, `q` plays them back.

local kern = require("@kern")

local M = {}

-- What's been copied into each register.
local texts: { [string]: { string } } = {}
-- The keys of each recorded macro, as a key sequence.
local macros: { [string]: string } = {}
-- The register the next copy, paste or macro uses, if one was picked.
local picked: string? = nil
-- Where the macro being recorded goes.
local recording_into: string? = nil
-- How deep macros are playing other macros, to stop one that plays itself.
local depth = 0

--- The register picked for the next operation, which this uses up.
function M.take(): string?
	local name = picked
	picked = nil
	return name
end

--- What register `name` holds, if anything.
function M.get(name: string): { string }?
	return texts[name]
end

function M.set(name: string, pieces: { string })
	texts[name] = pieces
end

--- Copies `pieces` to the register picked for this, or the clipboard.
function M.copy(pieces: { string })
	local name = M.take()
	if name then
		texts[name] = pieces
	else
		kern.clipboard.set(pieces)
	end
end

--- What to paste: the picked register's text, or the clipboard's.
function M.paste(): { string }?
	local name = M.take()
	if name then
		return texts[name]
	end
	return kern.clipboard.get()
end

--- The register a macro is being recorded into, while one is.
function M.recording(): string?
	return recording_into
end

--- The keys of the macro in register `name`.
function M.macro(name: string): string?
	return macros[name]
end

function M.set_macro(name: string, keys: string)
	macros[name] = keys
end

kern.command({
	name = "select-register",
	doc = "Pick a register, by the next key typed, for the next copy, paste or macro",
	run = function()
		local key = kern.next_key()
		if utf8.len(key) == 1 then
			picked = key
		end
	end,
})

--- Starts recording a macro into `name`, or stops and keeps the keys,
--- leaving out `stop_keys` (the keys that stopped it).
function M.toggle_recording(name: string, stop_keys: string?)
	if recording_into == nil then
		recording_into = name
		kern.keys.record()
		kern.echo(`recording @{name}`)
		return
	end
	local keys = kern.keys.stop() or {}
	for _ = 1, #string.split(stop_keys or "", " ") do
		table.remove(keys)
	end
	macros[recording_into] = table.concat(keys, " ")
	kern.echo(`recorded @{recording_into}`)
	recording_into = nil
end

--- Plays the macro in register `name`, `count` times.
function M.play(name: string, count: number?)
	local keys = macros[name]
	if keys == nil or keys == "" then
		kern.echo(`no macro in @{name}`)
		return
	end
	if depth >= 100 then
		error("macros nested more than 100 deep", 0)
	end
	depth += 1
	local ok, err = pcall(function()
		for _ = 1, count or 1 do
			kern.keys.feed(keys)
		end
	end)
	depth -= 1
	if not ok then
		error(err, 0)
	end
end

kern.command({
	name = "record-macro",
	doc = "Start recording keys into a macro (@, or the register picked), or stop",
	run = function(ctx)
		M.toggle_recording(recording_into or M.take() or "@", ctx.keys)
	end,
})

kern.command({
	name = "play-macro",
	doc = "Play the macro in @, or the register picked",
	run = function(ctx)
		M.play(M.take() or "@", ctx.count)
	end,
})

return M
