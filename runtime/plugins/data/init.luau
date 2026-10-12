-- Data in documents: tables read from files and databases, shown live in
-- Markdown under the block that asks for them. The sources (sources.luau)
-- are `core.data`'s, so any plugin can add one and any plugin can read
-- one; documents draw them (document.luau).
--
--   space m n   the data block's next rows; space m p the ones before
--   space m o   its table in a float, as text (enter on the table too)

local greed = require("@greed")
local sources = require("@self/sources")
local document = require("@self/document")
local open = require("@self/open")

local M = {}

M.sources = sources
M.document = document
M.open = open

--- The keys, by layer. Change them before this plugin loads, or rebind
--- and unbind from your config afterwards.
M.keys = {
	leader = {
		["m n"] = "data-page-next",
		["m p"] = "data-page-prev",
		["m o"] = "data-open",
	},
}

greed.keymap.bind({ layer = "leader" }, M.keys.leader)

return M
