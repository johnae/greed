-- Data between the editor and commands: what `$3`, `buf:NAME`, `@sel` and
-- `@file` read, and the buffers `> buf:NAME` writes to.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")
local run = require("./run")
local parse = require("./parse")
local tables = require("./tables")

type Shell = state.Shell
type Into = parse.Into

local M = {}

-- Buffers `> buf:NAME` made, by name.
local made: { [string]: greed.Buffer } = {}

--- The buffer `name` names: one a `> buf:NAME` made, else an open file at
--- that path (from `cwd`), else the first open file of that name.
function M.buffer(name: string, cwd: string?): greed.Buffer?
	local found = made[name]
	if found and found:valid() then
		return found
	end
	local at_path = core.file.buffer(name, cwd)
	if at_path then
		return at_path
	end
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path and core.project.basename(path) == name then
			return buffer
		end
	end
	return nil
end

--- The names of the buffers `> buf:NAME` made that are still open.
function M.names(): { string }
	local names: { string } = {}
	for name, buffer in made do
		if buffer:valid() then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

--- What `source` (`$3`, `buf:NAME`, `@sel` or `@file`) holds for a command
--- in `shell`, and for a block whose output was JSON, that value; nil and
--- why when there's nothing there. `buf:` paths are taken from `cwd`.
function M.read(shell: Shell, source: string, cwd: string): (string?, any?, string?)
	local number = tonumber(string.match(source, "^%$(%d+)$"))
	if number then
		local block = state.block(shell, number)
		if block == nil then
			return nil, nil, `there's no block {number} in this shell`
		end
		run.fill(block)
		return block.stdout, block.value, nil
	end
	local name = string.match(source, "^buf:(.+)$")
	if name then
		local buffer = M.buffer(name, cwd)
		if buffer == nil then
			return nil, nil, `no buffer is called {name}`
		end
		return buffer:text(), nil, nil
	end
	local view = core.file.view()
	if view == nil then
		return nil, nil, `{source}: no file is showing`
	end
	local buffer = view:buffer()
	if source == "@file" then
		return buffer:text(), nil, nil
	end
	local parts: { string } = {}
	for _, range in view:selection().ranges do
		local from, to = core.text.span(range)
		table.insert(parts, buffer:slice(from, to))
	end
	return table.concat(parts, "\n"), nil, nil
end

--- The table in what `source` holds (`text`, and `value` when it was JSON):
--- block `$N`'s table, or one read from a buffer or the selection.
function M.table(shell: Shell, source: string, text: string?, value: any?): tables.Table?
	local number = tonumber(string.match(source, "^%$(%d+)$"))
	if number then
		local block = state.block(shell, number)
		return block and block.table
	end
	if text == nil then
		return nil
	end
	local decoded = if string.match(text, "^%s*%[") then greed.json.decode(text) else value
	return tables.from_value(decoded) or tables.detect(text, nil)
end

--- The buffer `into` names, for a command's output: made (and kept open)
--- if there's none, and emptied first unless it's added to.
function M.target(into: Into, cwd: string): greed.Buffer
	local buffer = M.buffer(into.name, cwd)
	if buffer == nil then
		local new = greed.create_buffer("file", "")
		new:set_kept(true)
		made[into.name] = new
		return new
	end
	if not into.append and buffer:len() > 0 then
		buffer:edit(function(e)
			e:delete(0, buffer:len())
		end)
	end
	return buffer
end

return M
