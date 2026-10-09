-- Programs a shell runs open files in Greed. The shell sets $EDITOR and
-- the like to `greed edit --wait` (state.luau), which asks the session
-- through the shell_edit tool to show the files where the block ran, and
-- returns once each is done with: `:q` or `:wq` in it, or `:cq` to stop the
-- program with an error (core.file.wait). The shell shows there again
-- after.

local greed = require("@greed")
local core = require("@core")
local state = require("./state")

type Shell = state.Shell
type Block = state.Block

local M = {}

export type Options = {
	--- The block whose program asks (`$GREED_BLOCK`): the files show in the
	--- view it ran from, and the shell comes back there after.
	block: number?,
	--- Wait until every file is done with.
	wait: boolean?,
}

-- Where the files show: the view `block` ran from while it's still there,
-- else one showing its shell, else the focused one.
local function view_for(shell: Shell?, block: Block?): greed.View
	local from = if block then state.views[block.uid] else nil
	if from and from:valid() then
		return from
	end
	return if shell then shell.buffer:views()[1] or greed.view() else greed.view()
end

-- Shows `buffer` in `view`, focused, in the style's mode for reading and
-- moving around rather than the shell's typing.
local function show(view: greed.View, buffer: greed.Buffer)
	view:show(buffer)
	view:focus()
	if greed.view() == view then
		greed.mode.set(core.style.home_for(view))
	end
end

--- Shows the files at `paths` (absolute) in the view of `opts.block`, and
--- with `opts.wait` one after another until each is done with: "done", or
--- "aborted" when `:cq` stopped one, which leaves the rest. Then the shell
--- shows there again, and files that weren't open before close.
function M.open(paths: { string }, opts: Options): "done" | "aborted"
	local shell, block = state.find(opts.block)
	local view = view_for(shell, block)
	local buffers: { greed.Buffer } = {}
	local fresh: { [greed.Buffer]: boolean } = {}
	for _, path in paths do
		local buffer = core.file.buffer(path)
		if buffer == nil then
			local loaded = greed.load(path)
			fresh[loaded] = true
			table.insert(buffers, loaded)
		else
			table.insert(buffers, buffer)
		end
	end
	if not opts.wait then
		if buffers[1] then
			show(view, buffers[1])
		end
		return "done"
	end
	local outcome: "done" | "aborted" = "done"
	for _, buffer in buffers do
		if buffer:valid() then
			show(view, buffer)
			if core.file.wait(buffer) == "aborted" then
				outcome = "aborted"
				break
			end
		end
	end
	for buffer in fresh do
		if buffer:valid() then
			core.file.close(buffer, true)
		end
	end
	if shell and shell.buffer:valid() and view:valid() then
		view:show(shell.buffer)
		view:set_cursor(shell.buffer:len())
		if greed.view() == view then
			greed.mode.set(core.style.typing_mode())
		end
	end
	return outcome
end

return M
