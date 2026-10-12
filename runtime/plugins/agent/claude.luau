-- Claude Code in Greed: `claude` run in any Greed terminal connects to Greed
-- by itself, as it does in VS Code's terminal, and `space i C` opens it in
-- a pane beside your files (or goes to it, or brings it back). The acp
-- plugin starts it in a workspace of its own too (`space i W`).

local greed = require("@greed")
local terminal = require("@terminal")
local ide = require("./ide")

greed.option.define({
	name = "claude-command",
	needs = "proc",
	doc = 'How the Claude pane starts Claude Code, e.g. "claude --continue"',
	default = "claude",
})

-- With this set, Claude Code connects to the editor on that port at start,
-- without `/ide`.
if ide.port then
	terminal.set_env("CLAUDE_CODE_SSE_PORT", tostring(ide.port))
end

-- The buffer of the Claude pane's terminal, while it runs.
local claude: greed.Buffer? = nil

local function running(): greed.Buffer?
	local buffer = claude
	if buffer and terminal.terminal(buffer) then
		return buffer
	end
	claude = nil
	return nil
end

local M = {}

--- Starts Claude Code in a new pane on the right, as `claude-command` says
--- with `extra` arguments after it, in `cwd` (the project by default). A
--- folder outside the project, like an agent's workspace, is named to
--- Claude Code as open, so it finds Greed from there. Errors when it
--- can't start.
function M.open(cwd: string?, extra: { string }?): terminal.Term
	local command = {}
	for word in string.gmatch(greed.option.get("claude-command") :: string, "%S+") do
		table.insert(command, word)
	end
	if extra then
		table.move(extra, 1, #extra, #command + 1, command)
	end
	if cwd then
		ide.add_folder(cwd)
	end
	-- From a float, like the session list, beside the pane behind it.
	local from = if greed.view():is_pane() then nil else greed.tab.current().active
	return terminal.open(command, { split = "right", from = from, cwd = cwd })
end

--- Stops naming `folder`, given to `open`, to Claude Code as open.
M.forget_folder = ide.remove_folder

--- Goes to the Claude pane: focuses it if it's showing, brings it back
--- beside the focused view if not, or starts Claude Code there.
function M.toggle()
	local buffer = running()
	if buffer == nil then
		local ok, started = pcall(function()
			return M.open()
		end)
		if not ok then
			greed.echo(`can't start Claude Code: {started}`)
			return
		end
		claude = started.buffer
		return
	end
	local views = buffer:views()
	local view = if #views > 0 then views[1] else greed.view():split("right", buffer)
	view:focus()
	terminal.enter(view)
end

greed.command({
	name = "claude",
	doc = "Go to the Claude Code pane, or open one",
	run = M.toggle,
})

greed.keymap.bind({ layer = "leader" }, { ["i C"] = "claude" })

return M
