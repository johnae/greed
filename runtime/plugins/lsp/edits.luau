-- Edits from language servers: text edits for one file, and workspace
-- edits across files, which rename and code actions send. Files that
-- aren't open are opened (without being shown) and left unsaved, so the
-- change can be looked over and undone before writing it.

local greed = require("@greed")
local core = require("@core")

local M = {}

--- Applies LSP text edits `server` sent to `buffer` as one change.
function M.apply(buffer: greed.Buffer, edits: { any }, server: number?)
	local ranges = {}
	for _, edit in edits do
		table.insert(ranges, {
			from = core.lsp.offset(buffer, edit.range.start, server),
			to = core.lsp.offset(buffer, edit.range["end"], server),
			text = edit.newText,
		})
	end
	buffer:edit(function(e)
		for _, range in ranges do
			e:replace(range.from, range.to, range.text)
		end
	end)
end

-- The open buffer for `uri`, or the file opened for it.
local function buffer_for(uri: string): (greed.Buffer?, string?)
	local path = greed.lsp.path(uri)
	if path == nil then
		return nil, `can't edit {uri}`
	end
	local ok, buffer = pcall(greed.load, path)
	if not ok then
		return nil, tostring(buffer)
	end
	return buffer, nil
end

--- Applies a workspace edit `server` sent. Returns how many files changed,
--- or nil and why it couldn't. Creating, renaming and deleting files isn't
--- supported, so an edit with those changes nothing.
function M.apply_workspace(edit: any, server: number?): (number?, string?)
	local per_file: { { uri: string, edits: { any } } } = {}
	if edit.documentChanges then
		for _, change in edit.documentChanges do
			if change.kind then
				return nil, `can't {change.kind} files`
			end
			table.insert(per_file, { uri = change.textDocument.uri, edits = change.edits })
		end
	elseif edit.changes then
		for uri, edits in edit.changes do
			table.insert(per_file, { uri = uri, edits = edits })
		end
	end
	-- Every file first, so a missing one changes nothing.
	local buffers = {}
	for i, file in per_file do
		local buffer, err = buffer_for(file.uri)
		if buffer == nil then
			return nil, err
		end
		buffers[i] = buffer
	end
	for i, file in per_file do
		M.apply(buffers[i], file.edits, server)
	end
	return #per_file, nil
end

-- Servers send edits this way too, e.g. after running a code action's
-- command.
greed.lsp.on_request("workspace/applyEdit", function(params, server)
	local changed, err = M.apply_workspace(params.edit, server)
	if changed == nil then
		return { applied = false, failureReason = err }
	end
	return { applied = true }
end)

return M
