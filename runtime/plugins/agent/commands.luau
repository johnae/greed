-- Commands for agents: find the ones that do what's needed, with how
-- they're typed, and run one with its arguments, checked as the command
-- line checks them. This is the way to do what a command does; `eval` is
-- for what no command does.

local greed = require("@greed")
local core = require("@core")
local registry = require("./registry")
local context = require("./context")

local object = registry.schema.object

-- How many commands `commands` lists at most.
local LISTED = 40

-- Words in a command's name that say it closes, deletes or stops
-- something: such a run asks the user every time.
local CLOSING = { "quit", "close", "delete", "remove", "kill", "detach", "forget", "discard" }

-- An argument as `commands` shows it: its name, then its type and whether
-- it can be left out, when it says.
local function shown_arg(arg: greed.ArgSpec): string
	local parts = { arg.name }
	if arg.type then
		table.insert(parts, arg.type)
	end
	if arg.choices then
		table.insert(parts, `one of {table.concat(arg.choices, "/")}`)
	end
	if arg.kind then
		table.insert(parts, `a {arg.kind}`)
	end
	if arg.optional then
		table.insert(parts, "optional")
	end
	return table.concat(parts, " ")
end

registry.tool({
	name = "commands",
	description = "Find the editor's commands by words in their name or doc, with how each is typed "
		.. "and what its arguments are (their type: a number, a file, one of some choices, an object "
		.. "like a pod or a note by its id or name). Run one with run_command",
	input = object({
		query = { type = "string", description = "Words to look for, e.g. 'layout' or 'save'" },
	}, { "query" }),
	run = function(args)
		local query = string.lower(tostring(args.query))
		local out: { any } = {}
		for _, command in greed.commands() do
			if #out == LISTED then
				break
			end
			local text = string.lower(`{command.name} {command.doc}`)
			if string.find(text, query, 1, true) then
				local described = {}
				for _, arg in command.args do
					table.insert(described, shown_arg(arg))
				end
				table.insert(out, {
					name = command.name,
					usage = command.usage,
					doc = command.doc,
					args = greed.json.array(described),
				})
			end
		end
		if #out == 0 then
			return `no command has "{args.query}" in its name or doc`
		end
		return greed.json.array(out)
	end,
})

registry.tool({
	name = "run_command",
	kind = "execute",
	description = "Run one of the editor's commands (find them with commands) with its arguments, "
		.. "as typing it on the command line would, checked first: a wrong or missing argument "
		.. "gives back the command's usage and what was wrong, and nothing runs. Use it rather "
		.. "than eval for anything a command does. It acts on the user's view (the file "
		.. "they're in, never your chat), or the one in `view`; close a view with act",
	input = object({
		name = { type = "string", description = "The command, e.g. layout-save" },
		args = {
			type = "array",
			items = { type = "string" },
			description = "Its arguments in order, each a word as typed",
		},
		view = { type = "string", description = "A view's id to run it in, e.g. view:12" },
	}, { "name" }),
	danger = function(args)
		local name = tostring(args.name)
		for _, word in CLOSING do
			if string.find(name, word, 1, true) then
				return `{name} may close, delete or stop something`
			end
		end
		return nil
	end,
	run = function(args)
		local name = tostring(args.name)
		local words: { string } = {}
		if type(args.args) == "table" then
			for _, word in args.args do
				table.insert(words, tostring(word))
			end
		end
		local view: greed.View? = nil
		if args.view ~= nil then
			local found = core.objects.get(tostring(args.view))
			if found == nil or found.kind ~= "view" then
				error(`{args.view} isn't a view; objects with kind view lists them`, 0)
			end
			view = found.value
		end
		context.within(function()
			greed.run(name, { args = words, wait = true })
		end, view)
		return `ran {name}`
	end,
})

return {}
