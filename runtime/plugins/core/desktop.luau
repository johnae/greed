-- Desktop notifications shown by the desktop itself, with notify-send or
-- osascript, for what should reach you with no client attached (reminders,
-- chat). `greed.client.notify` goes through an attached client instead.

local greed = require("@greed")

local M = {}

--- The program that shows a desktop notification here, if one is
--- installed: notify-send (Linux and the BSDs), or osascript (macOS).
function M.command(title: string, body: string): { string }?
	if greed.which("notify-send") then
		return { "notify-send", "--app-name=Greed", title, body }
	elseif greed.which("osascript") then
		return {
			"osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 2 of argv) with title (item 1 of argv)",
			"-e",
			"end run",
			title,
			body,
		}
	end
	return nil
end

--- Shows `title` and `body` on the desktop, where it can.
function M.notify(title: string, body: string)
	local command = M.command(title, body)
	if command then
		-- A desktop without notifications isn't worth an error.
		pcall(function()
			greed.process.run(command)
		end)
	end
end

return M
