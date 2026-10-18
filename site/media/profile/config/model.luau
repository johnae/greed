-- A scripted model for the demos, so they record the same every time
-- without a key or the network. Asked why the worker crashes, it reads the
-- project, proposes a fix and says what it did; asked for a command, it
-- writes a plugin, checks it and asks to install it. Each answer streams
-- in small pieces, as a model's does.
local greed = require("@greed")
local models = require("@models")

local function streamed(text: string, to: ((piece: string) -> ())?)
	if to == nil then
		return
	end
	for piece in string.gmatch(text, "%S+%s*") do
		to(piece)
		greed.sleep(35)
	end
end

local function call(id: string, name: string, input: any): any
	return { id = id, name = name, input = input }
end

local CRASH: { any } = {
	{
		thinking = "The pod's logs end with it giving up on postgres after a few tries. "
			.. "I'll find where the worker connects.",
		calls = { call("c1", "grep", { pattern = "postgres" }) },
	},
	{
		thinking = "src/worker.rs connects. Reading it.",
		calls = { call("c2", "read", { path = "src/worker.rs" }) },
	},
	{
		text = "It tries 3 times, 2 s apart, then exits; Postgres takes longer than that after a node restarts. ",
		calls = {
			call("c3", "edit_file", {
				path = "src/worker.rs",
				old_text = "const ATTEMPTS: u32 = 3;\nconst WAIT: Duration = Duration::from_secs(2);",
				new_text = "// Postgres can take a minute to come back after a node restarts.\n"
					.. "const ATTEMPTS: u32 = 10;\nconst WAIT: Duration = Duration::from_secs(6);",
			}),
		},
	},
	{
		text = "The worker crashed because it gave up on Postgres after 6 s. It now waits up to "
			.. "a minute, 10 tries 6 s apart, which covers a restarted node. "
			.. "Checked: `src/worker.rs`, the pod's logs.",
	},
}

local UPCASE_INIT = [[local greed = require("@greed")

greed.command({
	name = "upcase-line",
	doc = "Upper-case the line the cursor is on",
	run = function(ctx)
		local buffer = ctx.buffer
		local line = buffer:line_of(ctx.view:cursor())
		local from, to = buffer:line_start(line), buffer:line_end(line)
		buffer:edit(function(e)
			e:replace(from, to, string.upper(buffer:slice(from, to)))
		end)
	end,
})

greed.keymap.bind({ role = "typing" }, { ["alt-u"] = "upcase-line" })
]]

local UPCASE_TEST = [[local test = require("@greed/test")

test("upper-cases the cursor's line", function(t)
	t:buffer("let name = |\"api\";\nnext")
	t:run("upcase-line")
	t:expect("LET NAME = \"API\";|\nnext")
end)
]]

local UPCASE: { any } = {
	{
		thinking = "A command and a key for it: a plugin. Switching on the plugin tools.",
		calls = { call("u1", "tools", { group = "plugins" }) },
	},
	{
		thinking = "A command that upper-cases the cursor's line, alt-u while typing, and a test.",
		calls = {
			call("u2", "plugin_try", {
				name = "upcase",
				files = {
					["plugin.toml"] = 'name = "upcase"\n',
					["init.luau"] = UPCASE_INIT,
					["test/upcase.luau"] = UPCASE_TEST,
				},
			}),
		},
	},
	{
		text = "Its types and test pass. ",
		calls = { call("u3", "plugin_install", { name = "upcase" }) },
	},
	{
		text = "Installed and loaded: `alt-u` upper-cases the line you're on while typing.",
	},
}

-- How far along each script is; a conversation follows one by what was asked.
local steps: { [any]: number } = {}
models.check = function(): string?
	return nil
end
models.turn = function(_role, request, on_text, _on_open, on_thinking)
	if string.find(request.system or "", "You summarise", 1, true) then
		return { text = "", calls = {}, stop = "done" }, nil
	end
	local asked = ""
	for _, said in request.said do
		if said.role == "user" and said.text then
			asked ..= said.text
		end
	end
	local script = if string.find(asked, "upper", 1, true) then UPCASE else CRASH
	steps[script] = (steps[script] or 0) + 1
	local turn = script[steps[script]] or { text = "Done." }
	greed.sleep(400)
	if turn.thinking then
		streamed(turn.thinking, on_thinking)
	end
	if turn.text then
		streamed(turn.text, on_text)
	end
	local calls = turn.calls or {}
	return {
		text = turn.text or "",
		thinking = turn.thinking,
		calls = calls,
		stop = if #calls > 0 then "tools" else "done",
	},
		nil
end

-- No spelling or grammar notes from a Markdown language server on the
-- recording machine.
greed.lsp.remove("markdown")

-- The sample projects are the demo's own; nothing to ask about.
greed.option.set("project-trust", "off")

return {}
