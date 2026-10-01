-- Key hints: after a key that starts longer sequences, like "space", show
-- what can come next and what each key does.

local kern = require("@kern")

local shown: kern.View? = nil

local function hide()
	if shown then
		shown:close()
		shown = nil
	end
end

local function describe(command: string?, docs: { [string]: string }): string
	if command == nil then
		return "more..."
	end
	local doc = docs[command]
	if doc == nil or doc == "" then
		return command
	end
	return doc
end

kern.on("keys.pending", function(event: kern.KeysPending)
	hide()
	if event.keys == "" then
		return
	end

	local docs = {}
	for _, command in kern.commands() do
		docs[command.name] = command.doc
	end
	local lines = {}
	for _, next in kern.keymap.next(event.keys) do
		table.insert(lines, string.format("%-8s %s", next.key, describe(next.command, docs)))
	end
	if #lines == 0 then
		return
	end

	local buffer = kern.create_buffer("hints", table.concat(lines, "\n"))
	shown = kern.float(buffer, {
		title = event.keys,
		width = "100%",
		height = #lines + 2,
		anchor = "bottom",
		focus = false,
	})
end)
