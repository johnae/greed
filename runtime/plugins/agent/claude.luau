-- Claude Code in Kern: `claude` run in any Kern terminal connects to Kern
-- by itself, as it does in VS Code's terminal, and `space o c` opens it in
-- a pane beside your files (or goes to it, or brings it back).

local kern = require("@kern")
local terminal = require("@terminal")
local ide = require("./ide")

kern.option.define({
	name = "claude-command",
	doc = 'How the Claude pane starts Claude Code, e.g. "claude --continue"',
	default = "claude",
})

-- With this set, Claude Code connects to the editor on that port at start,
-- without `/ide`.
if ide.port then
	terminal.env.CLAUDE_CODE_SSE_PORT = tostring(ide.port)
end

-- The buffer of the Claude pane's terminal, while it runs.
local claude: kern.Buffer? = nil

local function running(): kern.Buffer?
	local buffer = claude
	if buffer and terminal.terminal(buffer) then
		return buffer
	end
	claude = nil
	return nil
end

local M = {}

--- Goes to the Claude pane: focuses it if it's showing, brings it back
--- beside the focused view if not, or starts Claude Code there.
function M.toggle()
	local buffer = running()
	if buffer == nil then
		local command = {}
		for word in string.gmatch(kern.option.get("claude-command") :: string, "%S+") do
			table.insert(command, word)
		end
		local ok, started = pcall(function()
			return terminal.open(command, { split = "right" })
		end)
		if not ok then
			kern.echo(`can't start Claude Code: {started}`)
			return
		end
		claude = started.buffer
		return
	end
	local views = buffer:views()
	local view = if #views > 0 then views[1] else kern.view():split("right", buffer)
	view:focus()
	terminal.enter(view)
end

kern.command({
	name = "claude",
	doc = "Go to the Claude Code pane, or open one",
	run = M.toggle,
})

kern.keymap.bind("normal", { ["space o c"] = "claude" })

return M
