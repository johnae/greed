-- A program's flags and options, read from what documents them: its man
-- page, read straight from the file (the program never runs), or what it
-- prints for `--help`, in the shapes most programs print it: GNU's `-a,
-- --all  what it does`, Go's `-flag value` with the doc on the next line,
-- clap's and argparse's, and Cobra's `Flags:` sections.

local core = require("@core")

local M = {}

--- A flag a program takes, and what it does.
export type Flag = { text: string, detail: string? }

-- The first sentence of `text`, cut short when it's long.
local function short(text: string): string?
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	trimmed = string.gsub(trimmed, "%s+", " ")
	if trimmed == "" then
		return nil
	end
	local sentence = string.match(trimmed, "^(.-%.)%s") or trimmed
	return core.text.clip(sentence, 80)
end

-- The flags named at the start of `head`, like "-a, --all" or "-w,
-- --width=COLS" or "-f FILE": each word starting with a dash, without
-- what it takes.
local function names(head: string): { string }
	local found: { string } = {}
	for word in string.gmatch(head, "[^%s,|]+") do
		local name = string.match(word, "^(%-%-?[%w][%w%-_.]*)")
		if name and name ~= "--" then
			table.insert(found, name)
		end
	end
	return found
end

-- Adds each of `flags` once to `into`, with `detail`.
local function add(into: { Flag }, seen: { [string]: boolean }, flags: { string }, detail: string?)
	for _, flag in flags do
		if not seen[flag] then
			seen[flag] = true
			table.insert(into, { text = flag, detail = detail })
		end
	end
end

--- The flags `text`, what a program printed for `--help`, documents: lines
--- starting with a dash after some spaces, what they do after two spaces
--- or a tab, or on the lines under them.
function M.from_help(text: string): { Flag }
	local lines = string.split(string.gsub(text, "\r", ""), "\n")
	local flags: { Flag } = {}
	local seen: { [string]: boolean } = {}
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local indent, rest = string.match(line, "^(%s*)(%-%-?[%w].*)$")
		if indent and rest and #indent <= 30 then
			-- The flags, then what they do after two spaces or a tab.
			local head, doc = string.match(rest, "^(.-)%s%s+(%S.*)$")
			if head == nil then
				head, doc = string.match(rest, "^(.-)\t+(%S.*)$")
			end
			local tag: string = head or rest
			local detail = if doc then short(doc) else nil
			if detail == nil then
				-- Go's flag package and long clap or argparse flags say what
				-- they do on the next lines, further in.
				local parts: { string } = {}
				local j = i + 1
				while j <= #lines do
					local more = lines[j]
					local inner = string.match(more, "^(%s+)%S")
					if inner == nil or #inner <= #indent or string.match(more, "^%s*%-") then
						break
					end
					table.insert(parts, more)
					j += 1
				end
				detail = short(table.concat(parts, " "))
				i = j - 1
			end
			add(flags, seen, names(tag), detail)
		end
		i += 1
	end
	return flags
end

--- The subcommands `text`, what a program printed for `--help`, lists
--- under a heading like "Commands:", "Available Commands:" or
--- "SUBCOMMANDS:".
function M.commands(text: string): { [string]: string }
	local found: { [string]: string } = {}
	local inside = false
	for _, line in string.split(string.gsub(text, "\r", ""), "\n") do
		if string.match(line, "^%S") then
			inside = string.match(string.lower(line), "commands?:?%s*$") ~= nil
		elseif inside then
			local name, doc = string.match(line, "^%s+([%w][%w%-_]*)%s%s+(.*)$")
			if name then
				found[name] = doc or ""
			else
				local alone = string.match(line, "^%s+([%w][%w%-_]*)%s*$")
				if alone then
					found[alone] = ""
				end
			end
		end
	end
	return found
end

-- `text` from a man page without roff's escapes: fonts, `\-`, `\(em`
-- and the like.
local function unescape(text: string): string
	local out = string.gsub(text, "\\f%[[^%]]*%]", "")
	out = string.gsub(out, "\\f%(..", "")
	out = string.gsub(out, "\\f.", "")
	out = string.gsub(out, "\\%-", "-")
	out = string.gsub(out, "\\%(..", "")
	out = string.gsub(out, "\\%[[^%]]*%]", "")
	out = string.gsub(out, "\\&", "")
	out = string.gsub(out, "\\e", "\\")
	out = string.gsub(out, "\\ ", " ")
	out = string.gsub(out, "\\[%^|0]", "")
	return out
end

-- A request line's arguments, quotes taken off.
local function arguments(rest: string): { string }
	local args: { string } = {}
	local at = 1
	while at <= #rest do
		local quoted = string.match(rest, '^%s*"([^"]*)"()', at)
		if quoted then
			table.insert(args, quoted)
			at = (select(2, string.find(rest, '^%s*"[^"]*"', at)) :: number) + 1
		else
			local from, to = string.find(rest, "%S+", at)
			if from == nil or to == nil then
				break
			end
			table.insert(args, string.sub(rest, from, to))
			at = to + 1
		end
	end
	return args
end

-- Macros whose arguments take turns between two fonts, so they join
-- without spaces.
local ALTERNATING: { [string]: boolean } =
	{ BR = true, BI = true, IR = true, IB = true, RB = true, RI = true }

-- A text line of a man page: a request's arguments as text, or the line.
local function text_of(line: string): string?
	local macro, rest = string.match(line, "^[.'](%a%a?)%s*(.*)$")
	if macro == nil then
		return unescape(line)
	end
	if macro == "B" or macro == "I" or macro == "SM" then
		return unescape(table.concat(arguments(rest or ""), " "))
	elseif ALTERNATING[macro] then
		return unescape(table.concat(arguments(rest or ""), ""))
	end
	return nil
end

-- Macros that end a paragraph: sections and plain paragraphs, and the end
-- of an mdoc list.
local ENDS_PARAGRAPH: { [string]: boolean } =
	{ SH = true, SS = true, PP = true, LP = true, P = true, Sh = true, El = true }

--- The flags `roff`, a man page's source, documents: in man's `.TP` and
--- `.IP` paragraphs whose tag starts with a dash, and mdoc's `.It Fl`.
function M.from_man(roff: string): { Flag }
	local lines = string.split(string.gsub(roff, "\r", ""), "\n")
	local flags: { Flag } = {}
	local seen: { [string]: boolean } = {}
	-- The paragraph being read: its flags, and the text after them.
	local tag: { string }? = nil
	local body: { string } = {}
	local function close()
		if tag then
			add(flags, seen, tag, short(table.concat(body, " ")))
		end
		tag, body = nil, {}
	end
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local macro, rest = string.match(line, "^[.'](%a%a?)%s*(.*)$")
		if macro == "TP" then
			close()
			-- The next text line is the tag.
			local j = i + 1
			while j <= #lines and string.match(lines[j], "^[.']%s*$") do
				j += 1
			end
			local head = if j <= #lines then text_of(lines[j]) else nil
			if head and string.match(head, "^%s*%-") then
				tag = names(head)
			end
			i = j
		elseif macro == "IP" then
			close()
			local head = unescape((arguments(rest or ""))[1] or "")
			if string.match(head, "^%-") then
				tag = names(head)
			end
		elseif macro == "It" then
			close()
			-- mdoc: `.It Fl a`, `.It Fl -all`, `.It Fl b Ar size`.
			local words = arguments(rest or "")
			if words[1] == "Fl" and words[2] then
				tag = { "-" .. unescape(words[2]) }
			end
		elseif macro and ENDS_PARAGRAPH[macro] then
			close()
		elseif tag then
			local text = text_of(line)
			if text and text ~= "" then
				table.insert(body, text)
			end
		end
		i += 1
	end
	close()
	return flags
end

return M
