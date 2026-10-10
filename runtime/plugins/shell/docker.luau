-- `docker ps`'s rows as containers, in the docker context the command
-- ran against when it named one.

local greed = require("@greed")
local state = require("./state")
local parse = require("./parse")
local kinds = require("./kinds")

type Block = state.Block

-- The flags that take a value: docker's own before its command, and those
-- of the commands acting on a container.
local VALUED: { [string]: boolean } = {
	["-H"] = true,
	["--host"] = true,
	["--config"] = true,
	["-l"] = true,
	["--log-level"] = true,
	["-n"] = true,
	["--tail"] = true,
	["--since"] = true,
	["--until"] = true,
	["-u"] = true,
	["--user"] = true,
	["-w"] = true,
	["--workdir"] = true,
	["-e"] = true,
	["--env"] = true,
}

-- The commands whose next word is a container.
local CONTAINER_COMMANDS: { [string]: boolean } = {
	logs = true,
	exec = true,
	stop = true,
	start = true,
	restart = true,
	inspect = true,
	rm = true,
	kill = true,
	attach = true,
	top = true,
	port = true,
	stats = true,
	pause = true,
	unpause = true,
}

-- `words`, a docker command line from its second word: the words that
-- aren't flags, and the context it names, if it does.
local function read_line(words: { string }): ({ string }, string?)
	local context: string? = nil
	local rest: { string } = {}
	local i = 2
	while i <= #words do
		local word = words[i]
		local named = string.match(word, "^%-%-context=(.*)$")
		if word == "--context" or word == "-c" then
			i += 1
			context = words[i]
		elseif named then
			context = named
		elseif VALUED[word] then
			i += 1
		elseif string.sub(word, 1, 1) ~= "-" then
			table.insert(rest, word)
		end
		i += 1
	end
	return rest, context
end

-- Whether `words` is a `docker ps` or `docker container ls` command line,
-- and the docker context it names, if it does.
local function listing(words: { string }): (boolean, string?)
	local rest, context = read_line(words)
	local lists = rest[1] == "ps"
		or (rest[1] == "container" and (rest[2] == "ls" or rest[2] == "ps"))
	return lists, context
end

-- `docker` with `args`, in the context `value` came from.
local function docker(args: string, value: any): string
	local context = if value.context then " --context " .. parse.quote(value.context) else ""
	return `docker{context} {args}`
end

-- The docker object `name` of `kind`, in `context`, as a thing.
local function thing_of(kind: string, name: string, context: string?): kinds.Thing
	return {
		kind = kind,
		label = name,
		value = { name = name, context = context },
		key = if context then `{context}/{name}` else name,
	}
end

kinds.kind({
	name = "docker",
	match = "docker",
	capture = function(block: Block): any
		local words = parse.words(kinds.command_line(block), greed.fs.dirs().home)
		if words == nil then
			return nil
		end
		local lists, context = listing(words)
		return if lists then { context = context } else nil
	end,
	row = function(row: { [string]: string }, captured: any): kinds.Thing?
		local name = row.NAMES or row.Names
		local id = row["CONTAINER ID"] or row.ID
		local which = if name and name ~= "" then name else id
		if which == nil or which == "" then
			return nil
		end
		local thing = thing_of("container", which, captured.context)
		-- The image it runs is an object of its own.
		local image_column = if row.IMAGE then "IMAGE" else "Image"
		local image = row[image_column]
		if image and image ~= "" then
			thing.cells = { [image_column] = thing_of("image", image, captured.context) }
		end
		return thing
	end,
	called = function(): (string, string)
		return "container", "containers"
	end,
	complete = {
		docker = function(words: { string }, _shell: state.Shell): ((value: any) -> string?)?
			if string.sub(words[#words] or "", 1, 1) == "-" then
				return nil
			end
			local rest, context = read_line(table.move(words, 1, #words - 1, 1, {}))
			if not CONTAINER_COMMANDS[rest[1]] or #rest ~= 1 then
				return nil
			end
			return function(value: any): string?
				return if value.context == context then value.name else nil
			end
		end,
	},
})

kinds.object_kind("container", "A docker container, by its name and docker context")

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

kinds.object_kind("image", "A docker image, by its name and docker context")

kinds.command("image", "inspect", function(value: any): string
	return docker(`image inspect {parse.quote(value.name)}`, value)
end, { doc = "Everything docker knows about it, as JSON", default = true })
kinds.command("image", "history", function(value: any): string
	return docker(`image history {parse.quote(value.name)}`, value)
end, { doc = "The layers it's made of" })
kinds.command("image", "pull", function(value: any): string
	return docker(`pull {parse.quote(value.name)}`, value)
end, { doc = "Fetch it again, for what's newest under its name" })

return {}
