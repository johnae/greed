-- Undo that lasts across restarts: each time a file is saved, its undo
-- history is kept in the cache folder, and when the file is opened again,
-- unchanged since, it comes back, so undo goes on past where it was
-- opened. A file something else changed in between starts afresh.
--
-- Undo keeps text you deleted, so it skips files the project ignores
-- (`.env`, build output) and files named like secrets (`.env*`, `*.pem`,
-- `*.key`, `id_*`). The kept files are readable only by you, go after 30
-- days without a save, and a history over 10 MB isn't kept. `:set
-- undo-files false` turns it off.

local greed = require("@greed")
local project = require("./project")

greed.option.define({
	name = "undo-files",
	doc = "Keep each saved file's undo history, so undo goes on after a restart",
	default = true,
})

local M = {}

-- How long a kept history lasts without a save, in seconds.
local LASTS = 30 * 24 * 3600
-- The most text, and the most history, kept for one file, in bytes.
local LIMIT = 10 * 1024 * 1024

--- Where the histories are kept, if there's a cache folder.
function M.folder(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/undo` else nil
end

-- The file `path`'s history is kept in.
local function record(folder: string, path: string): string
	return `{folder}/{greed.hash.sha256(path)}`
end

-- The kept histories, by file, read from the folder once, so opening a
-- file with none reads nothing.
local kept: { [string]: boolean }? = nil

local function kept_in(folder: string): { [string]: boolean }
	local known = kept
	if known == nil then
		local found: { [string]: boolean } = {}
		local entries = greed.fs.list(folder, { hidden = true, ignored = true })
		if entries then
			for _, entry in entries do
				found[`{folder}/{entry.name}`] = true
			end
		end
		kept = found
		return found
	end
	return known
end

--- Whether `path` is named like a file of secrets.
function M.secret(path: string): boolean
	local name = project.basename(path) or path
	return string.match(name, "^%.env") ~= nil
		or string.match(name, "%.pem$") ~= nil
		or string.match(name, "%.key$") ~= nil
		or string.match(name, "^id_") ~= nil
end

-- Whether the project ignores `path`: its folder's listing, which leaves
-- ignored files out, doesn't have it.
local function ignored(path: string): boolean
	local folder, name = string.match(path, "^(.*)/([^/]+)$")
	if folder == nil or name == nil then
		return false
	end
	local entries = greed.fs.list(folder, { hidden = true })
	if entries == nil then
		return false
	end
	for _, entry in entries do
		if entry.name == name then
			return false
		end
	end
	return true
end

-- The kept-history folder and `buffer`'s file, when its history may be
-- kept; whether the project ignores the file is for the caller to ask,
-- since that reads its folder.
local function kept_for(buffer: greed.Buffer): (string?, string?)
	local path = buffer:path()
	local folder = M.folder()
	if
		path == nil
		or folder == nil
		or buffer:kind() ~= "file"
		or greed.option.get("undo-files") ~= true
		or buffer:len() > LIMIT
		or M.secret(path)
	then
		return nil, nil
	end
	return folder, path
end

-- Keeps the history of a file just saved: the text's digest on the first
-- line, then the history. Both are taken as saved; reading the folder to
-- see whether it's ignored, and writing, wait until after the save.
greed.on("buffer.saved", function(event: greed.BufferChanged)
	local buffer = event.buffer
	local folder, path = kept_for(buffer)
	if folder == nil or path == nil then
		return
	end
	local history = buffer:undo_save()
	if history == nil or #history > LIMIT then
		return
	end
	local digest = greed.hash.sha256(buffer:text())
	greed.spawn(function()
		if ignored(path) then
			return
		end
		local file = record(folder, path)
		if greed.fs.write(file, `{digest}\n{history}`, { private = true }) then
			kept_in(folder)[file] = true
		end
	end)
end)

-- Brings back the history of a file opened as it was saved. Only a file
-- that wasn't ignored has one kept, so there's no folder to read first.
greed.on("buffer.opened", function(event: greed.BufferChanged)
	local buffer = event.buffer
	local folder, path = kept_for(buffer)
	if folder == nil or path == nil then
		return
	end
	local file = record(folder, path)
	if not kept_in(folder)[file] then
		return
	end
	local text = greed.fs.read(file)
	local digest, history = string.match(text or "", "^([^\n]*)\n(.*)$")
	if digest and history and digest == greed.hash.sha256(buffer:text()) then
		buffer:undo_restore(history)
	end
end)

-- Histories not saved again for a while go, once the editor has started.
greed.on("editor.started", function()
	local folder = M.folder()
	if folder == nil then
		return
	end
	local entries = greed.fs.list(folder, { hidden = true, ignored = true })
	if entries == nil then
		return
	end
	local now = os.time()
	for _, entry in entries do
		local path = `{folder}/{entry.name}`
		local info = greed.fs.stat(path)
		if info and info.modified and now - info.modified > LASTS then
			greed.fs.remove(path)
		end
	end
end)

return M
