-- Registers and macros. `"` and a letter picks a register for the next copy,
-- paste, delete or macro; without one, copies go to the clipboard and macros
-- to `@`. `Q` starts and stops recording keys, `q` plays them back.
--
-- A register knows whether it holds whole lines, so lines copied in one
-- editing style paste as lines in every other.

local greed = require("@greed")
local text = require("./text")

local M = {}

--- What a register holds: one piece per selection it came from, and
--- whether the pieces are whole lines, each ending in a line break.
export type Register = { pieces: { string }, linewise: boolean }

-- What's been copied into each register.
local kept: { [string]: Register } = {}
-- What Greed last put on the clipboard. Clipboard text that isn't this was
-- copied in another program, and pastes as plain text.
local copied: Register? = nil
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

--- Picks register `name` for the next operation, as `"` does.
function M.pick(name: string)
	picked = name
end

--- What register `name` holds, if anything.
function M.get(name: string): Register?
	return kept[name]
end

--- Puts `pieces` in register `name`, as whole lines with `linewise`.
function M.set(name: string, pieces: { string }, linewise: boolean?)
	kept[name] = { pieces = pieces, linewise = linewise == true }
end

--- The register's pieces as one text: whole lines one after another, other
--- pieces a line apart.
function M.join(register: Register): string
	return table.concat(register.pieces, if register.linewise then "" else "\n")
end

--- Puts `pieces` on the clipboard, remembering whether they are whole lines
--- for when they're pasted back.
function M.to_clipboard(pieces: { string }, linewise: boolean?)
	greed.clipboard.set(pieces)
	copied = { pieces = pieces, linewise = linewise == true }
end

--- What's on the clipboard: what Greed copied there, with whether it was
--- whole lines, or plain text another program copied.
function M.clipboard(): Register?
	local pieces = greed.clipboard.get()
	if pieces == nil then
		return nil
	elseif copied and table.concat(copied.pieces, "\n") == table.concat(pieces, "\n") then
		return copied
	end
	return { pieces = pieces, linewise = false }
end

-- The clipboard's registers; copies go there when no register is picked.
local CLIPBOARD = { ["+"] = true, ["*"] = true }

--- Whether `name` is the clipboard: no register, `"+` or `"*`.
function M.is_clipboard(name: string?): boolean
	return name == nil or CLIPBOARD[name] == true
end

--- Copies `pieces` (whole lines with `linewise`) to the register picked
--- for this, or the clipboard. `_` throws them away.
function M.copy(pieces: { string }, linewise: boolean?)
	local name = M.take()
	if M.is_clipboard(name) then
		M.to_clipboard(pieces, linewise)
	elseif name ~= "_" then
		M.set(name :: string, pieces, linewise)
	end
end

--- What to paste into `ctx`'s view: the picked register, or the
--- clipboard. Some registers are worked out rather than kept: `%` is the
--- file's name, `.` what each selection holds, `#` each selection's number,
--- and `_` is always empty.
function M.paste(ctx: greed.Context): Register?
	local name = M.take()
	if M.is_clipboard(name) then
		return M.clipboard()
	elseif name == "_" then
		return nil
	elseif name == "%" then
		local path = ctx.buffer:path()
		return if path then { pieces = { path }, linewise = false } else nil
	elseif name == "." or name == "#" then
		local pieces = {}
		for i, range in ctx.view:selection().ranges do
			table.insert(
				pieces,
				if name == "#" then tostring(i) else ctx.buffer:slice(text.span(range))
			)
		end
		return { pieces = pieces, linewise = false }
	end
	return kept[name :: string]
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

greed.command({
	name = "select-register",
	doc = "Pick a register, by the next key typed, for the next copy, paste or macro",
	run = function()
		local key = greed.next_key()
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
		greed.keys.record()
		greed.echo(`recording @{name}`)
		return
	end
	local keys = greed.keys.stop() or {}
	for _ = 1, #string.split(stop_keys or "", " ") do
		table.remove(keys)
	end
	macros[recording_into] = table.concat(keys, " ")
	greed.echo(`recorded @{recording_into}`)
	recording_into = nil
end

--- Plays the macro in register `name`, `count` times.
function M.play(name: string, count: number?)
	local keys = macros[name]
	if keys == nil or keys == "" then
		greed.echo(`no macro in @{name}`)
		return
	end
	if depth >= 100 then
		error("macros nested more than 100 deep", 0)
	end
	depth += 1
	local ok, err = pcall(function()
		for _ = 1, count or 1 do
			greed.keys.feed(keys)
		end
	end)
	depth -= 1
	if not ok then
		error(err, 0)
	end
end

greed.command({
	name = "record-macro",
	doc = "Start recording keys into a macro (@, or the register picked), or stop",
	run = function(ctx)
		M.toggle_recording(recording_into or M.take() or "@", ctx.keys)
	end,
})

greed.command({
	name = "play-macro",
	doc = "Play the macro in @, or the register picked",
	run = function(ctx)
		M.play(M.take() or "@", ctx.count)
	end,
})

return M
