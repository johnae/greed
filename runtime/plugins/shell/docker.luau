-- `docker ps`'s rows as containers, in the docker context the command
-- ran against when it named one.

local greed = require("@greed")
local state = require("./state")
local parse = require("./parse")
local kinds = require("./kinds")

type Block = state.Block

-- docker's own flags that take a value, before its command.
local VALUED: { [string]: boolean } =
	{ ["-H"] = true, ["--host"] = true, ["--config"] = true, ["-l"] = true, ["--log-level"] = true }

-- The docker context `words`, a `docker ps` or `docker container ls`
-- command line, named (false when none); nil for any other docker.
local function context_of(words: { string }): (string | false)?
	local context: string | false = false
	local rest: { string } = {}
	local i = 2
	while i <= #words do
		local word = words[i]
		local named = string.match(word, "^%-%-context=(.*)$")
		if word == "--context" or word == "-c" then
			i += 1
			context = words[i] or false
		elseif named then
			context = named
		elseif VALUED[word] then
			i += 1
		elseif string.sub(word, 1, 1) ~= "-" then
			table.insert(rest, word)
		end
		i += 1
	end
	local listing = rest[1] == "ps"
		or (rest[1] == "container" and (rest[2] == "ls" or rest[2] == "ps"))
	return if listing then context else nil
end

-- `docker` with `args`, in the context `value` came from.
local function docker(args: string, value: any): string
	local context = if value.context then " --context " .. parse.quote(value.context) else ""
	return `docker{context} {args}`
end

kinds.kind({
	name = "docker",
	match = "docker",
	capture = function(block: Block): any
		local words = parse.words(block.command, greed.fs.dirs().home)
		local context = if words then context_of(words) else nil
		if context == nil then
			return nil
		end
		return { context = context or nil }
	end,
	row = function(row: { [string]: string }, captured: any): kinds.Thing?
		local name = row.NAMES or row.Names
		local id = row["CONTAINER ID"] or row.ID
		local which = if name and name ~= "" then name else id
		if which == nil or which == "" then
			return nil
		end
		return {
			kind = "container",
			label = which,
			value = { name = which, context = captured.context },
		}
	end,
	called = function(): (string, string)
		return "container", "containers"
	end,
})

kinds.command("container", "logs", function(value: any): string
	return docker(`logs --tail 200 {parse.quote(value.name)}`, value)
end, { doc = "The end of what it logged", default = true })
kinds.command("container", "follow logs", function(value: any): string
	return docker(`logs -f --tail 50 {parse.quote(value.name)}`, value)
end, { doc = "What it logs, as it logs it" })
kinds.command("container", "shell", function(value: any): string
	return "!" .. docker(`exec -it {parse.quote(value.name)} sh`, value)
end, { doc = "A shell in it, in a terminal" })
kinds.command("container", "inspect", function(value: any): string
	return docker(`inspect {parse.quote(value.name)}`, value)
end, { doc = "Everything docker knows about it, as JSON" })
kinds.command("container", "restart", function(value: any): string
	return docker(`restart {parse.quote(value.name)}`, value)
end, { doc = "Stop it and start it again", danger = true })
kinds.command("container", "stop", function(value: any): string
	return docker(`stop {parse.quote(value.name)}`, value)
end, { doc = "Stop it", danger = true })

return {}
