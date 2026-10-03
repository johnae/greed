-- Pipe each selection through something and put back what comes out:
--
--   |               ask what to pipe through
--   :pipe TARGET    the same, from the command line
--
-- The target says what it is:
--
--   sort -u                        a shell command, given the selection as input
--   luau: snake_case               a Luau function (see pipe.define)
--   model: use the new client API  a language model, in the pipe-model role
--
-- Every selection gets its own result, and they all go in as one change, so
-- one undo takes them back. A model's changes are an operation too, to
-- review with space u o; marks keep each result in its place if you edit
-- while the model works.

local kern = require("@kern")
local core = require("@core")
local models = require("@models")
local operations = require("@operations")

kern.option.define({
	name = "pipe-model-role",
	doc = "The model role `| model: ...` asks; see :models",
	default = "fast",
})

--- Turns a selection's text into new text, or fails with why.
export type Filter = (text: string) -> string

local M = {}

-- Words of `text`, split at spaces, dashes, underscores and case changes.
local function words(text: string): { string }
	local spaced = string.gsub(text, "(%l)(%u)", "%1 %2")
	local out = {}
	for word in string.gmatch(spaced, "[%w]+") do
		table.insert(out, string.lower(word))
	end
	return out
end

local function joined(
	text: string,
	separator: string,
	capital: (i: number, word: string) -> string
): string
	local out = {}
	for i, word in words(text) do
		out[i] = capital(i, word)
	end
	return table.concat(out, separator)
end

local function unchanged(_: number, word: string): string
	return word
end

local function capitalized(word: string): string
	return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
end

-- The lines of `text`, and whether it ended with a line break.
local function lines(text: string): ({ string }, boolean)
	local ends = string.sub(text, -1) == "\n"
	local list = string.split(if ends then string.sub(text, 1, -2) else text, "\n")
	return list, ends
end

--- The Luau filters, by name. Add your own with `pipe.define`.
M.filters = {
	upper = string.upper,
	lower = string.lower,
	trim = function(text: string): string
		return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
	end,
	snake_case = function(text: string): string
		return joined(text, "_", unchanged)
	end,
	kebab_case = function(text: string): string
		return joined(text, "-", unchanged)
	end,
	camel_case = function(text: string): string
		return joined(text, "", function(i, word)
			return if i == 1 then word else capitalized(word)
		end)
	end,
	pascal_case = function(text: string): string
		return joined(text, "", function(_, word)
			return capitalized(word)
		end)
	end,
	sort = function(text: string): string
		local list, ends = lines(text)
		table.sort(list)
		return table.concat(list, "\n") .. (if ends then "\n" else "")
	end,
	reverse = function(text: string): string
		local list, ends = lines(text)
		local out = {}
		for i = #list, 1, -1 do
			table.insert(out, list[i])
		end
		return table.concat(out, "\n") .. (if ends then "\n" else "")
	end,
} :: { [string]: Filter }

--- Adds a Luau filter called `name`, for `| luau: name`.
function M.define(name: string, filter: Filter)
	M.filters[name] = filter
end

-- Output for a selection that didn't end with a line break loses the one
-- most programs add.
local function fit(selected: string, output: string): string
	if string.sub(selected, -1) ~= "\n" and string.sub(output, -1) == "\n" then
		return string.sub(output, 1, -2)
	end
	return output
end

local function shell(command: string): Filter
	return function(text)
		local done, err = kern.process.run({ "sh", "-c", command }, { stdin = text })
		if done == nil then
			error(err, 0)
		elseif done.code ~= 0 then
			error(`{command} failed: {done.stderr}`, 0)
		end
		return fit(text, done.stdout)
	end
end

-- What models are told, so they answer with nothing but the new text.
local SYSTEM = "You rewrite text as instructed. Reply with only the rewritten text: "
	.. "no explanations, no quotes, no code fences. Keep the original's indentation and "
	.. "line breaks unless told otherwise."

-- A model's answer without the code fence it may wrap around it anyway.
local function unfenced(answer: string): string
	local inside = string.match(answer, "^%s*```[%w_-]*\n(.-)\n?```%s*$")
	return inside or answer
end

local function model(instruction: string): Filter
	return function(text)
		local role = kern.option.get("pipe-model-role") :: string
		local answer, err = models.ask(role, {
			system = SYSTEM,
			messages = { { role = "user", content = `{instruction}\n\n{text}` } },
		})
		if answer == nil then
			error(err, 0)
		end
		return fit(text, unfenced(answer))
	end
end

--- The filter `target` names and whether it's a model's, or nil and why
--- not.
function M.parse(target: string): (Filter?, boolean, string?)
	local kind, rest = string.match(target, "^%s*(%a+):%s*(.-)%s*$")
	if kind == "luau" then
		local filter = M.filters[rest :: string]
		if filter == nil then
			return nil, false, `there's no Luau filter called {rest}`
		end
		return filter, false, nil
	elseif kind == "model" then
		if rest == "" then
			return nil, false, "say what the model should do, e.g. model: translate to French"
		end
		return model(rest :: string), true, nil
	elseif kind == "rule" then
		return nil, false, "rules aren't there yet"
	end
	if string.match(target, "^%s*$") then
		return nil, false, "nothing to pipe through"
	end
	return shell(target), false, nil
end

-- Pipes each selection in `view` through `filter`, keeping marks over them so
-- the results land in place even if the text moves while it works. Returns
-- what puts every result in with one edit, or why it can't.
local function gather(view: kern.View, filter: Filter): ((() -> ())?, string?)
	local buffer = view:buffer()
	local ns = "pipe"
	local marks: { kern.Mark } = {}
	for _, range in view:selection().ranges do
		local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
		table.insert(marks, { from = from, to = to, style = "pipe" })
	end
	buffer:decorate(ns, marks)
	local results: { string } = {}
	for i, mark in marks do
		local ok, out = pcall(filter, buffer:slice(mark.from, mark.to))
		if not ok then
			buffer:decorate(ns, {})
			return nil, tostring(out)
		end
		results[i] = out
	end
	-- Where the selections are now, in the order given.
	local now = buffer:decorations(ns)
	buffer:decorate(ns, {})
	if #now ~= #results then
		return nil, "the text changed too much while it worked"
	end
	return function()
		buffer:edit(function(e)
			for i, mark in now do
				e:replace(mark.from, mark.to, results[i])
			end
		end)
	end,
		nil
end

--- Pipes `view`'s selections through `target`. Waits for programs and
--- models; works in commands and kern.spawn. Returns false and why when it
--- can't.
function M.pipe(view: kern.View, target: string): (boolean, string?)
	local filter, from_model, why = M.parse(target)
	if filter == nil then
		return false, why
	end
	if from_model then
		kern.echo("asking the model...")
	end
	local apply, err = gather(view, filter)
	if apply == nil then
		return false, err
	end
	-- Only the edit is the operation, so what you type while the model
	-- works stays yours.
	if from_model then
		operations.run(target, function()
			apply()
		end, "model")
	else
		apply()
	end
	return true, nil
end

kern.command({
	name = "pipe",
	doc = "Pipe each selection through a shell command, a Luau filter (luau: name) or a model (model: what to do)",
	args = { { name = "target", doc = "e.g. sort -u, luau: snake_case, model: add doc comments" } },
	run = function(ctx)
		local target = if #ctx.args > 0
			then table.concat(ctx.args, " ")
			else core.prompt.ask("Pipe through")
		if target == nil or target == "" then
			return
		end
		local ok, err = M.pipe(ctx.view, target)
		if ok then
			kern.echo("")
		else
			kern.echo(err :: string)
		end
	end,
})

kern.keymap.bind("normal", { ["|"] = "pipe" })

return M
