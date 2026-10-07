-- Looking up the thing under the cursor: where it's defined (g d) and what
-- it is (space k). Plugins add a way to answer for what they know about,
-- like a note's [[link]] or a language server's symbols; the first that
-- answers wins, and fallbacks, like the language server, go after the rest.
--
--     core.lookup.add("definition", function(ctx)
--         local target = link_at(ctx.buffer, ctx.view:cursor())
--         if target then
--             core.file.open(target)
--         end
--         return target ~= nil
--     end)

local greed = require("@greed")
local registry = require("./registry")

local M = {}

export type Kind = "definition" | "hover"

--- Answers for the thing under the cursor, if it can, and says whether it
--- did.
export type Answer = (ctx: greed.Context) -> boolean

type Entry = { answer: Answer, fallback: boolean }

local answers: { [Kind]: { Entry } } = { definition = {}, hover = {} }

--- Adds `answer` for `kind`, after those added before it. A `fallback` is
--- asked only when nothing else answered. It goes when the plugin adding
--- it does.
function M.add(kind: Kind, answer: Answer, options: { fallback: boolean? }?)
	local entry = { answer = answer, fallback = options ~= nil and options.fallback == true }
	greed.plugin.tie(registry.put(answers[kind], entry))
end

-- Asks each answer for `kind` in turn, fallbacks last, until one answers.
local function look_up(kind: Kind, ctx: greed.Context, nothing: string)
	for _, fallback in { false, true } do
		for _, entry in table.clone(answers[kind]) do
			if entry.fallback == fallback and entry.answer(ctx) then
				return
			end
		end
	end
	greed.echo(nothing)
end

greed.command({
	name = "goto-definition",
	doc = "Go to where the thing under the cursor is defined",
	run = function(ctx)
		look_up("definition", ctx, "no definition found")
	end,
})

greed.command({
	name = "hover",
	doc = "Show what's under the cursor, and any problems there",
	run = function(ctx)
		look_up("hover", ctx, "nothing to show here")
	end,
})

greed.keymap.bind({ role = "command" }, { ["g d"] = "goto-definition" })
greed.keymap.bind({ layer = "leader" }, { k = "hover" })

return M
