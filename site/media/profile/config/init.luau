-- The config the demos run with: a fresh Greed in Catppuccin Frappé with
-- pills on the status line, a little bigger to read in a video, and
-- nothing of the machine it's recorded on.
local greed = require("@greed")

require("@theme").use("catppuccin-frappe")
greed.option.set("statusline-pills", true)
greed.option.set("gui-font-size", 17)
require("@statusline").remove("host")
