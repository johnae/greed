-- kubectl's config, read without running kubectl: the files it would
-- read, and the context and namespace they make current.

local greed = require("@greed")
local shell = require("@shell")

type Shell = shell.Shell

local M = {}

--- The kubeconfig files kubectl would read for `sh`: those KUBECONFIG
--- names, else `~/.kube/config`. KUBECONFIG from the editor counts only
--- when Greed's home is the editor's, so a test's own home never reads
--- yours.
function M.files(sh: Shell): { string }
	local home = greed.fs.dirs().home
	local own = sh.env.KUBECONFIG
	local inherited = shell.editor_environment()
	local list = if type(own) == "string"
		then own
		elseif own == nil and home == inherited.HOME then inherited.KUBECONFIG
		else nil
	local files: { string } = {}
	if list and list ~= "" then
		for path in string.gmatch(list, "[^:]+") do
			table.insert(files, path)
		end
	elseif home then
		table.insert(files, `{home}/.kube/config`)
	end
	return files
end

-- A YAML scalar without the quotes around it.
local function scalar(text: string): string
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return string.match(trimmed, '^"(.*)"$') or string.match(trimmed, "^'(.*)'$") or trimmed
end

--- The context `yaml`, a kubeconfig, says is current, and its namespace
--- (nil when it sets none).
function M.read(yaml: string): (string?, string?)
	local lines = string.split(string.gsub(yaml, "\r", ""), "\n")
	local current: string? = nil
	for _, line in lines do
		local value = string.match(line, "^current%-context:(.*)$")
		if value then
			current = scalar(value)
		end
	end
	if current == nil or current == "" then
		return nil, nil
	end
	-- The contexts: a list of items each with a name and a context map,
	-- under the top-level `contexts:`.
	local inside = false
	local name: string?, namespace: string? = nil, nil
	local found: string? = nil
	local function close()
		if name == current then
			found = namespace
		end
		name, namespace = nil, nil
	end
	for _, line in lines do
		-- A top-level key; a list's items may start at the line's start too.
		if string.match(line, "^[^%s%-]") then
			if inside then
				close()
			end
			inside = string.match(line, "^contexts:") ~= nil
		elseif inside then
			if string.match(line, "^%s*%- ") then
				close()
			end
			local item = string.gsub(line, "^(%s*)%- ", "%1  ")
			local key, value = string.match(item, "^%s*([%w_-]+):(.*)$")
			if key == "name" and value then
				name = scalar(value)
			elseif key == "namespace" and value then
				namespace = scalar(value)
			end
		end
	end
	if inside then
		close()
	end
	local ns = found
	return current, if ns and ns ~= "" then ns else nil
end

--- The context and namespace kubectl's config makes current for `sh`.
function M.current(sh: Shell): (string?, string?)
	for _, path in M.files(sh) do
		local context, namespace = M.read(greed.fs.read(path) or "")
		if context then
			return context, namespace
		end
	end
	return nil, nil
end

return M
