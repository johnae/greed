-- Brackets and quotes typed in pairs, as Helix and VS Code have them: an
-- opener brings its closer when what follows is blank or a closer, a
-- closer typed next to the same one steps over it, and backspace between
-- an empty pair takes both. A quote pairs only after something that isn't
-- a letter or digit, so "don't" stays as typed. Where typing replaces the
-- selection (the vscode style), an opener goes around it instead.
--
-- Each language may have pairs of its own, which the languages plugin
-- sets; Rust's leave ' alone, for lifetimes. The `auto-pairs` option turns
-- it on or off, or leaves it to the editing style: on in helix and vscode,
-- off in vim, where `.` and macros replay what was typed.

local greed = require("@greed")
local motions = require("./motions")
local registry = require("./registry")
local style = require("./style")
local text = require("./text")

--- Closers by their openers, e.g. { ["("] = ")" }.
export type Pairs = { [string]: string }

local DEFAULT: Pairs = {
	["("] = ")",
	["["] = "]",
	["{"] = "}",
	['"'] = '"',
	["'"] = "'",
	["`"] = "`",
}

greed.option.define({
	name = "auto-pairs",
	doc = "Type brackets and quotes in pairs: style (as the editing style does: on in helix "
		.. "and vscode, off in vim), on or off",
	default = "style",
	choices = { "style", "on", "off" },
})

local by_language: { [string]: Pairs } = {}

local M = {}

--- The kinds of buffer typed in pairs: files, and others a plugin adds
--- with `kind`. Prompts and pickers aren't, so `/f(` searches for `f(`.
M.kinds = { file = true, multibuffer = true } :: { [string]: boolean }

--- Types brackets and quotes in pairs in buffers of `kind` too, until the
--- plugin that said so goes.
function M.kind(kind: string)
	greed.plugin.cleanup(registry.set(M.kinds, kind, true))
end

--- Sets `language`'s pairs, or with nil goes back to the usual ones:
--- brackets, quotes and backticks.
function M.set(language: string, closers: Pairs?)
	if closers then
		greed.plugin.cleanup(registry.set(by_language, language, closers))
	else
		by_language[language] = nil
	end
end

--- The pairs typed in `buffer`'s language.
function M.of(buffer: greed.Buffer): Pairs
	local language = buffer:language()
	return (language and by_language[language]) or DEFAULT
end

--- Whether typing pairs is on in `buffer`, by its kind, the option and the
--- editing style.
function M.enabled(buffer: greed.Buffer): boolean
	if not M.kinds[buffer:kind()] then
		return false
	end
	local option = greed.option.get("auto-pairs")
	if option == "on" or option == "off" then
		return option == "on"
	end
	return style.current().pairs == true
end

-- The character after `pos`, or "" at the end.
local function after(buffer: greed.Buffer, pos: number): string
	return buffer:char_at(pos) or ""
end

-- The character before `pos`, or "" at the start.
local function before(buffer: greed.Buffer, pos: number): string
	return if pos > 0 then buffer:char_at(buffer:prev_char(pos)) or "" else ""
end

-- Whether `char` is a closer in `known`.
local function closes(known: Pairs, char: string): boolean
	for _, closer in known do
		if closer == char then
			return true
		end
	end
	return false
end

-- Whether an opener typed between `prev` and `next` should bring its
-- closer: what follows is blank, the end or a closer, and a quote doesn't
-- come straight after a word.
local function pairs_here(known: Pairs, opener: string, prev: string, next: string): boolean
	if not (next == "" or string.match(next, "^%s") or closes(known, next)) then
		return false
	end
	if known[opener] == opener then
		-- Bytes from 0x80 start letters in other scripts.
		return not string.match(prev, "^[%w_\128-\255]")
	end
	return true
end

-- What typing `char` does at `range`, and whether that's a pair's doing.
local function typed(
	buffer: greed.Buffer,
	known: Pairs,
	char: string,
	range: greed.Range,
	replacing: boolean
): (motions.Replacement, boolean)
	local lo, hi = text.span(range)
	local selected = replacing and lo ~= hi
	local head = if replacing then lo else range.head
	local closer = known[char]
	if selected and closer then
		local inner = buffer:slice(lo, hi)
		return { text = char .. inner .. closer, place = { #char, #char + #inner } }, true
	elseif not selected and closes(known, char) and after(buffer, head) == char then
		-- Typed over, not just stepped past, so what follows typing (a
		-- call's signature help closing, say) sees it typed.
		return { text = char, from = head, to = head + #char, place = "end" }, true
	elseif
		not selected
		and closer
		and pairs_here(known, char, before(buffer, head), after(buffer, head))
	then
		return { text = char .. closer, from = head, to = head, place = #char }, true
	elseif replacing then
		return { text = char, place = "end" }, false
	end
	return { text = char, from = head, to = head, place = "end" }, false
end

--- Types `char` at each of `view`'s cursors with pairs, if it calls for
--- any: brings an opener's closer, steps over a closer, and with
--- `replacing` (typing replaces the selection) puts an opener around the
--- selection. Returns false, having done nothing, when no cursor needs a
--- pair, so the caller types it as usual.
function M.type(view: greed.View, char: string, replacing: boolean): boolean
	local buffer = view:buffer()
	if not M.enabled(buffer) then
		return false
	end
	local known = M.of(buffer)
	if known[char] == nil and not closes(known, char) then
		return false
	end
	local changes: { motions.Replacement } = {}
	local any = false
	for i, range in view:selection().ranges do
		local change, paired = typed(buffer, known, char, range, replacing)
		changes[i] = change
		any = any or paired
	end
	if not any then
		return false
	end
	motions.replace_each(view, function(i)
		return changes[i]
	end)
	return true
end

--- How far past `pos` backspace should delete too: the closer's length when
--- `pos` sits inside an empty pair, otherwise 0.
function M.closer_after(buffer: greed.Buffer, pos: number): number
	if not M.enabled(buffer) then
		return 0
	end
	local closer = M.of(buffer)[before(buffer, pos)]
	return if closer and after(buffer, pos) == closer then #closer else 0
end

return M
