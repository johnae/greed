-- The config the demos run with: a fresh Greed in Catppuccin Frappé with
-- pills on the status line, a little bigger to read in a video, and
-- nothing of the machine it's recorded on.
local greed = require("@greed")

require("@theme").use("catppuccin-frappe")
greed.option.set("statusline-pills", true)
greed.option.set("gui-font-size", 17)
require("@statusline").remove("host")

-- A scripted model for the agent demo, so it records the same every time
-- without a key or the network: it looks for why the worker crashes,
-- reads it, proposes a fix and says what it did. Each answer streams in
-- small pieces, as a model's does.
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

local SCRIPT: { any } = {
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

local step = 0
models.check = function(): string?
	return nil
end
models.turn = function(_role, request, on_text, _on_open, on_thinking)
	if string.find(request.system or "", "You summarise", 1, true) then
		return { text = "", calls = {}, stop = "done" }, nil
	end
	step += 1
	local turn = SCRIPT[step] or { text = "Done." }
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
