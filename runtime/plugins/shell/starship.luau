-- The prompt as starship draws it, with `shell-prompt` set to "starship":
-- what `starship prompt` prints for the shell's folder and variables, the
-- last block's exit code and how long it took, and how many blocks run,
-- with its colors, in place of the shell's own segments and folder. The
-- shell keeps its own ❯, red for a production context, so starship's
-- prompt character (its last line) is left out.

local greed = require("@greed")
local state = require("./state")

type Shell = state.Shell
type Segment = state.Segment

local M = {}

local NAMES = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }

-- Color `n` of the 256 a terminal has, as a style names it.
local function color256(n: number): string
	if n < 8 then
		return NAMES[n + 1]
	elseif n < 16 then
		return `bright-{NAMES[n - 7]}`
	elseif n < 232 then
		local levels = { 0, 95, 135, 175, 215, 255 }
		local i = n - 16
		return string.format(
			"#%02x%02x%02x",
			levels[i // 36 + 1],
			levels[(i // 6) % 6 + 1],
			levels[i % 6 + 1]
		)
	end
	local grey = 8 + (n - 232) * 10
	return string.format("#%02x%02x%02x", grey, grey, grey)
end

-- How text is drawn, as SGR codes set it.
type Look = {
	fg: string?,
	bg: string?,
	bold: boolean?,
	dim: boolean?,
	italic: boolean?,
	underline: boolean?,
}

-- `look` after the SGR codes `params` ("1;38;5;208"), as a new look.
local function apply(look: Look, params: string): Look
	local out: Look = table.clone(look)
	local codes: { number } = {}
	for part in string.gmatch(params .. ";", "([^;]*);") do
		table.insert(codes, tonumber(part) or 0)
	end
	local i = 1
	while i <= #codes do
		local code = codes[i]
		if code == 0 then
			out = {} :: Look
		elseif code == 1 then
			out.bold = true
		elseif code == 2 then
			out.dim = true
		elseif code == 3 then
			out.italic = true
		elseif code == 4 then
			out.underline = true
		elseif code == 22 then
			out.bold, out.dim = nil, nil
		elseif code == 23 then
			out.italic = nil
		elseif code == 24 then
			out.underline = nil
		elseif code >= 30 and code <= 37 then
			out.fg = NAMES[code - 29]
		elseif code >= 90 and code <= 97 then
			out.fg = `bright-{NAMES[code - 89]}`
		elseif code >= 40 and code <= 47 then
			out.bg = NAMES[code - 39]
		elseif code >= 100 and code <= 107 then
			out.bg = `bright-{NAMES[code - 99]}`
		elseif code == 39 then
			out.fg = nil
		elseif code == 49 then
			out.bg = nil
		elseif (code == 38 or code == 48) and codes[i + 1] == 5 then
			local color = color256(codes[i + 2] or 0)
			if code == 38 then
				out.fg = color
			else
				out.bg = color
			end
			i += 2
		elseif (code == 38 or code == 48) and codes[i + 1] == 2 then
			local color = string.format(
				"#%02x%02x%02x",
				math.clamp(codes[i + 2] or 0, 0, 255),
				math.clamp(codes[i + 3] or 0, 0, 255),
				math.clamp(codes[i + 4] or 0, 0, 255)
			)
			if code == 38 then
				out.fg = color
			else
				out.bg = color
			end
			i += 4
		end
		i += 1
	end
	return out
end

-- `look` as a style name, written out inline: "=fg:#ff8700 bold".
local function style_of(look: Look): string
	local words: { string } = {}
	if look.fg then
		table.insert(words, `fg:{look.fg}`)
	end
	if look.bg then
		table.insert(words, `bg:{look.bg}`)
	end
	for _, flag in { "bold", "dim", "italic", "underline" } do
		if (look :: any)[flag] then
			table.insert(words, flag)
		end
	end
	return "=" .. table.concat(words, " ")
end

local SGR = "\27%[([%d;]*)m"

-- Whether `line` has nothing but spaces and colors.
local function blank(line: string): boolean
	return string.match(string.gsub(line, SGR, ""), "^%s*$") ~= nil
end

local function drop_blank_end(segments: { Segment })
	while #segments > 0 and blank(segments[#segments].text) do
		table.remove(segments)
	end
end

--- `text`, what `starship prompt` printed, as segments: each run of text in
--- one look, in order, with its lines run together. Its last line, where
--- its prompt character is, is left out, as is a lone character ending a
--- prompt of one line.
function M.read(text: string): { Segment }
	-- Escapes other than colors, like a window title or a link, go.
	local clean = string.gsub(text, "\27%][^\7\27]*\7", "")
	clean = string.gsub(clean, "\27%][^\27]*\27\\", "")
	clean = string.gsub(clean, "\r", "")
	local lines = string.split(clean, "\n")
	while #lines > 0 and blank(lines[1]) do
		table.remove(lines, 1)
	end
	while #lines > 0 and blank(lines[#lines]) do
		table.remove(lines)
	end
	local single = #lines == 1
	if not single then
		table.remove(lines)
	end
	local segments: { Segment } = {}
	local look: Look = {}
	for n, line in lines do
		local at = 1
		while at <= #line do
			local from, to, params = string.find(line, SGR, at)
			local stop = if from then from - 1 else #line
			local piece = string.sub(line, at, stop)
			if piece ~= "" then
				table.insert(segments, { text = piece, style = style_of(look), tight = true })
			end
			if from == nil or to == nil then
				break
			end
			look = apply(look, params or "")
			at = to + 1
		end
		if n < #lines then
			table.insert(segments, { text = " ", tight = true })
		end
	end
	-- A prompt of one line ends with its character, like "❯ ".
	drop_blank_end(segments)
	if single then
		local last = segments[#segments]
		if last and utf8.len(string.match(last.text, "^(.-)%s*$") or "") == 1 then
			table.remove(segments)
			drop_blank_end(segments)
		end
	end
	local last = segments[#segments]
	if last then
		last.text = string.match(last.text, "^(.-)%s*$") or last.text
	end
	return segments
end

--- Runs `starship prompt` for `shell`, in its folder `cwd` with its
--- variables `env`: its segments, or nil when starship isn't there or
--- failed.
function M.prompt(shell: Shell, cwd: string, env: { [string]: string }): { Segment }?
	local argv = { "starship", "prompt", "--terminal-width", "200", "--path", cwd }
	local last = shell.blocks[#shell.blocks]
	if last and last.status ~= "running" then
		table.insert(argv, "--status")
		table.insert(argv, tostring(last.code or (if last.status == "done" then 0 else 1)))
		if last.finished then
			table.insert(argv, "--cmd-duration")
			table.insert(argv, tostring(math.floor(last.finished - last.started)))
		end
	end
	table.insert(argv, "--jobs")
	table.insert(argv, tostring(#state.running(shell)))
	local vars: { [string]: string | false } = table.clone(env) :: any
	-- Without a shell named, starship prints plain colors.
	vars.STARSHIP_SHELL = false
	local child = greed.process.spawn(argv, { cwd = cwd, env = vars })
	if child == nil then
		return nil
	end
	local parts: { string } = {}
	while true do
		local piece = child:read()
		if piece == nil then
			break
		end
		table.insert(parts, piece)
	end
	if child:wait() ~= 0 then
		return nil
	end
	local segments = M.read(table.concat(parts))
	return if #segments > 0 then segments else nil
end

return M
