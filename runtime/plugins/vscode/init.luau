-- The vscode style: no modes, VS Code's keys. Typing inserts text
-- (replacing any selection), arrows move, shift and the arrows select, and
-- the usual ctrl shortcuts do the usual things. The editing itself is
-- core's (core/modeless.luau), shared with any other style without modes;
-- this plugin gives it VS Code's keys.
--
-- Switch to it with `:style vscode`, or to use it all the time, put this in
-- ~/.config/greed/init.luau:
--
--     require("@greed").option.set("editing-style", "vscode")

local greed = require("@greed")
local core = require("@core")

greed.keymap.bind("vscode", {
	left = "move-left",
	right = "move-right",
	up = "move-up",
	down = "move-down",
	home = "smart-home",
	["end"] = "line-end",
	["ctrl-left"] = "move-word-left",
	["ctrl-right"] = "move-word-right",
	["ctrl-home"] = "goto-start",
	["ctrl-end"] = "goto-end",
	pagedown = "page-down",
	pageup = "page-up",
	["shift-left"] = "extend-left",
	["shift-right"] = "extend-right",
	["shift-up"] = "extend-up",
	["shift-down"] = "extend-down",
	["shift-home"] = "extend-smart-home",
	["shift-end"] = "extend-line-end",
	["ctrl-shift-left"] = "extend-word-left",
	["ctrl-shift-right"] = "extend-word-right",
	["ctrl-shift-home"] = "extend-start",
	["ctrl-shift-end"] = "extend-end",
	enter = "type-newline",
	tab = "type-tab",
	["shift-tab"] = "dedent",
	backspace = "erase-back",
	delete = "erase-forward",
	esc = "collapse",
	["ctrl-a"] = "select-all",
	["ctrl-c"] = "copy-or-line",
	["ctrl-x"] = "cut-or-line",
	["ctrl-v"] = "paste-over",
	["ctrl-z"] = "undo",
	["ctrl-y"] = "redo",
	["ctrl-Z"] = "redo",
	["ctrl-p"] = "pick-file",
	["ctrl-b"] = "pick-buffer",
	["ctrl-P"] = "command-palette",
	["ctrl-f"] = "find",
	f3 = "search-next",
	["shift-f3"] = "search-prev",
	["ctrl-h"] = "replace-in-file",
	["ctrl-g"] = "command-line",
	["ctrl-d"] = "select-next-match",
	["ctrl-L"] = "select-all-matches",
	["ctrl-l"] = "select-lines",
	["ctrl-K"] = "delete-lines-at-cursor",
	["alt-up"] = "move-lines-up",
	["alt-down"] = "move-lines-down",
	["alt-shift-up"] = "copy-lines-up",
	["alt-shift-down"] = "copy-lines-down",
	["ctrl-alt-up"] = "copy-selection-up",
	["ctrl-alt-down"] = "copy-selection-down",
	["ctrl-enter"] = "insert-line-below",
	["ctrl-shift-enter"] = "insert-line-above",
	["ctrl-/"] = "toggle-comment",
	["ctrl-_"] = "toggle-comment",
	["ctrl-]"] = "indent",
	["ctrl-backspace"] = "delete-word-back",
	["ctrl-delete"] = "delete-word-forward",
	["ctrl-w"] = "buffer-close",
	["ctrl-q"] = "quit-ask",
	f12 = "goto-definition",
	["shift-f12"] = "goto-references",
	f2 = "rename",
	f8 = "next-diagnostic",
	["shift-f8"] = "prev-diagnostic",
	["ctrl-."] = "code-action",
	["ctrl-O"] = "pick-outline",
	["ctrl-t"] = "pick-workspace-symbol",
	["ctrl-M"] = "pick-problem",
	["alt-left"] = "jump-back",
	["alt-right"] = "jump-forward",
	["ctrl-u"] = "selection-undo",
	["ctrl-U"] = "selection-redo",
	["ctrl-\\"] = "pane-split-right",
	-- ctrl-k starts VS Code's chords, so it never deletes to the line's end
	-- here as it does in other styles' typing modes.
	["ctrl-k ctrl-0"] = "fold-close-all",
	["ctrl-k ctrl-j"] = "fold-open-all",
	["ctrl-k ctrl-l"] = "fold-toggle",
	["ctrl-k ctrl-i"] = "hover",
	["ctrl-k ctrl-q"] = "goto-last-modification",
	["ctrl-k ctrl-t"] = "theme",
	["ctrl-k s"] = "save-all",
})

-- Without modes there's no ":" to find, so switching here says where
-- commands are.
greed.on("option.changed", function(event: greed.OptionChanged)
	if event.name == "editing-style" and event.value == "vscode" then
		greed.echo("ctrl-P runs any command, alt-x opens the command line, ctrl-space the leader")
	end
end)

core.modeless.define({ name = "vscode", doc = "No modes, VS Code's keys", leader = "ctrl-space" })

return {}
