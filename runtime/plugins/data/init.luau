-- Data in documents: tables read from files and databases, shown live in
-- Markdown under the block that asks for them. The sources (sources.luau)
-- are `core.data`'s, so any plugin can add one and any plugin can read
-- one; documents draw them (document.luau).
--
--   space m n   the data block's next rows; space m p the ones before

local greed = require("@greed")
local sources = require("@self/sources")
local render = require("@self/render")
local document = require("@self/document")

local M = {}

M.sources = sources
M.render = render
M.document = document

--- The keys, by layer. Change them before this plugin loads, or rebind
--- and unbind from your config afterwards.
M.keys = {
	leader = {
		["m n"] = "data-page-next",
		["m p"] = "data-page-prev",
	},
}

greed.keymap.bind({ layer = "leader" }, M.keys.leader)

return M
