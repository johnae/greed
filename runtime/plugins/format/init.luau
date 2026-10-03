-- Formatting: `:format`, and on every save unless `format-on-save` is off.
-- A language's formatter program (see the languages plugin) is used when
-- it's installed; otherwise the language server is asked. Only what changed
-- is replaced, so the cursor and selections stay where they were.
--
-- To stop formatting on save:
--
--     require("@greed").option.set("format-on-save", false)

local greed = require("@greed")
local core = require("@core")
local languages = require("@languages")

greed.option.define({
	name = "format-on-save",
	doc = "Format files when they're saved",
	default = true,
})

local function continuation_byte(text: string, at: number): boolean
	local byte = string.byte(text, at)
	return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

-- How many bytes `old` and `new` have in common at the start and at the
-- end, backing off so neither splits a UTF-8 character.
local function common_ends(old: string, new: string): (number, number)
	local head = 0
	while
		head < #old
		and head < #new
		and string.byte(old, head + 1) == string.byte(new, head + 1)
	do
		head += 1
	end
	local tail = 0
	while
		tail < #old - head
		and tail < #new - head
		and string.byte(old, #old - tail) == string.byte(new, #new - tail)
	do
		tail += 1
	end
	while head > 0 and continuation_byte(old, head + 1) do
		head -= 1
	end
	while tail > 0 and continuation_byte(old, #old - tail + 1) do
		tail -= 1
	end
	return head, tail
end

-- Replaces the buffer's text with `formatted`, changing only what differs.
local function apply(buffer: greed.Buffer, formatted: string)
	local hunks = greed.diff(buffer:text(), formatted)
	if #hunks == 0 then
		return
	end
	buffer:edit(function(e)
		for _, hunk in hunks do
			-- Hunks are whole lines; replace just the part that differs.
			local new = hunk.text
			local head, tail = common_ends(buffer:slice(hunk.from, hunk.to), new)
			e:replace(hunk.from + head, hunk.to - tail, string.sub(new, head + 1, #new - tail))
		end
	end)
end

-- The formatter command for the buffer, with "{path}" filled in, if its
-- language has one and it's installed.
local function formatter(buffer: greed.Buffer): { string }?
	local language = buffer:language()
	local spec = language and languages.get(language)
	local command = spec and spec.formatter
	if command == nil or #command == 0 or greed.which(command[1]) == nil then
		return nil
	end
	local path = buffer:path() or ""
	local filled = {}
	for i, arg in command do
		filled[i] = (string.gsub(arg, "{path}", function()
			return path
		end))
	end
	return filled
end

-- Runs `command` on the buffer's text and puts the result in. Returns an
-- error to show, if it failed.
local function run_formatter(buffer: greed.Buffer, command: { string }): string?
	local path = buffer:path()
	local folder = path and string.match(path, "^(.*)/[^/]*$")
	local done, err = greed.process.run(command, { stdin = buffer:text(), cwd = folder })
	if done == nil then
		return `{command[1]}: {err}`
	elseif done.code ~= 0 then
		local first = string.match(done.stderr, "[^\n]+") or `exited with {done.code}`
		return `{command[1]}: {first}`
	end
	apply(buffer, done.stdout)
	return nil
end

-- Asks the language server to format the buffer. Returns false if there's
-- no server, or it can't.
local function server_format(buffer: greed.Buffer): boolean
	if buffer:path() == nil then
		return false
	end
	local indent = require("@core").indent.unit(buffer)
	local ok, edits = pcall(greed.lsp.request, buffer, "textDocument/formatting", {
		textDocument = { uri = greed.lsp.uri(buffer) },
		options = {
			tabSize = if indent == "\t" then 4 else #indent,
			insertSpaces = indent ~= "\t",
		},
	})
	if not ok or type(edits) ~= "table" then
		return false
	end
	local ranges = {}
	for _, edit in edits do
		table.insert(ranges, {
			from = greed.lsp.offset(buffer, edit.range.start),
			to = greed.lsp.offset(buffer, edit.range["end"]),
			text = edit.newText,
		})
	end
	buffer:edit(function(e)
		for _, range in ranges do
			e:replace(range.from, range.to, range.text)
		end
	end)
	return true
end

local M = {}

--- Formats `buffer` with its language's formatter, or its language server.
--- Returns false if neither could, and an error if the formatter failed.
function M.format(buffer: greed.Buffer): (boolean, string?)
	local command = formatter(buffer)
	if command then
		local err = run_formatter(buffer, command)
		return err == nil, err
	end
	return server_format(buffer), nil
end

greed.command({
	name = "format",
	doc = "Format the buffer with its language's formatter or language server",
	run = function(ctx)
		local formatted, err = M.format(ctx.buffer)
		if err then
			error(err, 0)
		elseif not formatted then
			greed.echo("nothing to format this with")
		end
	end,
})

core.file.before_save("format", function(buffer)
	if greed.option.get("format-on-save") == true then
		local _, err = M.format(buffer)
		if err then
			error(err, 0)
		end
	end
end)

-- Helix formats on =; this formats the whole buffer.
greed.keymap.bind("normal", { ["="] = "format" })

return M
