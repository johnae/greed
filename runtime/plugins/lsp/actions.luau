-- Changes the language server works out: renaming the thing under the
-- cursor everywhere it's used, and code actions (quick fixes, refactors)
-- for the cursor or the selection.

local kern = require("@kern")
local core = require("@core")
local picker = require("@picker")
local common = require("./common")
local edits = require("./edits")

-- Applies a workspace edit and says what changed.
local function apply(edit: any, what: string)
	local changed, err = edits.apply_workspace(edit)
	if changed == nil then
		kern.echo(`{what}: {err}`)
	elseif changed > 1 then
		kern.echo(`{what}: changed {changed} files`)
	end
end

-- The word at `pos`, for a name to start from when the server doesn't
-- give one.
local function word_at(buffer: kern.Buffer, pos: number): string?
	local line = buffer:line_of(pos)
	for _, found in buffer:find_all("\\w+", buffer:line_start(line), buffer:line_end(line)) or {} do
		if found.from <= pos and pos <= found.to then
			return buffer:slice(found.from, found.to)
		end
	end
	return nil
end

-- What the name under the cursor is now, as the server sees it: false if
-- the server says it can't be renamed.
local function current_name(buffer: kern.Buffer, pos: number): (boolean, string?)
	local capabilities = kern.lsp.capabilities(buffer)
	local provider = capabilities and capabilities.renameProvider
	if type(provider) ~= "table" or not provider.prepareProvider then
		return true, word_at(buffer, pos)
	end
	local ok, result = common.ask(buffer, "textDocument/prepareRename", pos)
	if not ok then
		return false, nil
	elseif result == nil then
		kern.echo("can't rename this")
		return false, nil
	elseif result.placeholder then
		return true, result.placeholder
	end
	local range = result.range or result
	if range.start then
		local from = kern.lsp.offset(buffer, range.start)
		return true, buffer:slice(from, kern.lsp.offset(buffer, range["end"]))
	end
	return true, word_at(buffer, pos)
end

kern.command({
	name = "rename",
	doc = "Rename the thing under the cursor everywhere it's used",
	run = function(ctx)
		local buffer, pos = ctx.buffer, common.head(ctx.view)
		local ok, name = current_name(buffer, pos)
		if not ok then
			return
		end
		core.prompt.open({
			title = "Rename to",
			text = name,
			on_submit = function(new_name)
				if new_name == "" or new_name == name then
					return
				end
				local answered, result, err = common.request(
					buffer,
					"textDocument/rename",
					function()
						local params = common.at(buffer, pos)
						params.newName = new_name
						return params
					end
				)
				if not answered then
					return
				elseif err then
					kern.echo(`rename: {err.message}`)
				elseif result == nil then
					kern.echo("nothing to rename")
				else
					apply(result, "rename")
				end
			end,
		})
	end,
})

-- The problems the server reported in `from`..`to`, as it sent them, so
-- it can offer fixes for them.
local function problems_in(buffer: kern.Buffer, from: number, to: number): { any }
	local list = {}
	for _, d in kern.lsp.diagnostics(buffer) do
		if d.from <= to and from <= d.to then
			table.insert(list, {
				range = {
					start = kern.lsp.position(buffer, d.from),
					["end"] = kern.lsp.position(buffer, d.to),
				},
				severity = d.severity,
				message = d.message,
				source = d.source,
			})
		end
	end
	return list
end

-- Does what a code action says: fetches its edit if the server left that
-- for later, applies it, then runs its command.
local function run_action(buffer: kern.Buffer, action: any)
	-- A bare command, the older kind of answer.
	if type(action.command) == "string" then
		action = { title = action.title, command = action }
	end
	if action.edit == nil and action.command == nil and action.data ~= nil then
		local ok, resolved = pcall(kern.lsp.request, buffer, "codeAction/resolve", action)
		if ok and resolved then
			action = resolved
		end
	end
	if action.edit then
		apply(action.edit, action.title)
	end
	if action.command then
		local _, err = kern.lsp.request(buffer, "workspace/executeCommand", {
			command = action.command.command,
			arguments = action.command.arguments,
		})
		if err then
			kern.echo(`{action.title}: {err.message}`)
		end
	end
end

kern.command({
	name = "code-action",
	doc = "Pick a fix or refactor for the cursor or the selection",
	run = function(ctx)
		local buffer = ctx.buffer
		local selection = ctx.view:selection()
		local range = selection.ranges[selection.primary]
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		local ok, result, err = common.request(buffer, "textDocument/codeAction", function()
			return {
				textDocument = { uri = kern.lsp.uri(buffer) },
				range = {
					start = kern.lsp.position(buffer, from),
					["end"] = kern.lsp.position(buffer, to),
				},
				context = { diagnostics = problems_in(buffer, from, to) },
			}
		end)
		if not ok then
			return
		elseif err then
			kern.echo(`code actions: {err.message}`)
			return
		end
		-- What the server prefers first, otherwise in its order.
		local items, others = {}, {}
		for _, action in result or {} do
			if not action.disabled then
				local item = { label = action.title, value = action }
				table.insert(if action.isPreferred then items else others, item)
			end
		end
		table.move(others, 1, #others, #items + 1, items)
		if #items == 0 then
			kern.echo("no code actions here")
			return
		end
		picker.pick("Code actions", items, function(item)
			run_action(buffer, item.value)
		end)
	end,
})

kern.keymap.bind("normal", {
	["space r"] = "rename",
	["space a"] = "code-action",
})

return {}
