local greed = require("@greed")
local core = require("@core")
local languages = require("@languages")

type Replacement = { from: number, to: number, text: string }
type Snapshot = {
	version: number,
	path: string?,
	language: string?,
	text: string,
	command: { string }?,
	by: string?,
}

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

-- Prepare against the immutable input, never against newer live text.
local function replacements(source: string, formatted: string): { Replacement }
	local edits = {}
	for _, hunk in greed.diff(source, formatted) do
		local head, tail = common_ends(string.sub(source, hunk.from + 1, hunk.to), hunk.text)
		table.insert(edits, {
			from = hunk.from + head,
			to = hunk.to - tail,
			text = string.sub(hunk.text, head + 1, #hunk.text - tail),
		})
	end
	return edits
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

local M = {}

--- Formats a snapshot; a late result never replaces newer edits.
--- Stale formatting is reported and saving retains its write-current-text policy.
function M.format(buffer: greed.Buffer): (boolean, string?)
	local snapshot: Snapshot? = core.atomic(function(): Snapshot?
		if not buffer:valid() or buffer:readonly() then
			return nil
		end
		return {
			version = buffer:version(),
			path = buffer:path(),
			language = buffer:language(),
			text = buffer:text(),
			command = formatter(buffer),
			by = languages.set_by(buffer:language() or "", "formatter"),
		}
	end)
	if snapshot == nil then
		return false, "cannot format a closed or readonly buffer"
	end
	local edits: { Replacement } = {}
	local lsp_edits
	if snapshot.command then
		local command = snapshot.command
		local folder = snapshot.path and string.match(snapshot.path, "^(.*)/[^/]*$")
		local options: greed.RunOptions = { stdin = snapshot.text, cwd = folder }
		local ok, done, err =
			pcall(greed.plugin.within, snapshot.by, greed.process.run, command, options)
		if not ok then
			return false, tostring(done)
		elseif done == nil then
			return false, `{command[1]}: {err}`
		elseif done.code ~= 0 then
			local first = string.match(done.stderr, "[^\n]+") or `exited with {done.code}`
			return false, `{command[1]}: {first}`
		end
		edits = replacements(snapshot.text, done.stdout)
	else
		if snapshot.path == nil then
			return false, nil
		end
		local indent = core.indent.unit(buffer)
		local ok, result, request_error =
			pcall(greed.lsp.request, buffer, "textDocument/formatting", {
				textDocument = { uri = greed.lsp.uri(buffer) },
				options = {
					tabSize = if indent == "\t" then 4 else #indent,
					insertSpaces = indent ~= "\t",
				},
			})
		if not ok then
			return false, nil
		elseif request_error then
			return false, request_error.message
		elseif type(result) ~= "table" then
			return false, nil
		end
		lsp_edits = result
	end
	return core.atomic(function()
		if
			not buffer:valid()
			or buffer:readonly()
			or buffer:version() ~= snapshot.version
			or buffer:path() ~= snapshot.path
			or buffer:language() ~= snapshot.language
		then
			return false, "format skipped: buffer changed while formatting"
		end
		if lsp_edits then
			edits = {}
			for _, edit in lsp_edits do
				table.insert(edits, {
					from = greed.lsp.offset(buffer, edit.range.start),
					to = greed.lsp.offset(buffer, edit.range["end"]),
					text = edit.newText,
				})
			end
		end
		if #edits > 0 then
			buffer:edit(function(e)
				for _, edit in edits do
					e:replace(edit.from, edit.to, edit.text)
				end
			end)
		end
		return true, nil
	end)
end

return M
