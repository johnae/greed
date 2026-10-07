local test = require("@greed/test")
local greed = require("@greed")

-- A plugin answering `kind` by saying `name`: always, or only on the word
-- "here" if `picky`.
local function answering(t: test.TestContext, name: string, kind: string, options: string)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = `name = "{name}"\n`,
		["init.luau"] = string.format(
			[[
local core = require("@core")
local greed = require("@greed")
local options = %s
core.lookup.add("%s", function(ctx)
	local line = ctx.buffer:line_text(ctx.buffer:line_of(ctx.view:cursor()))
	if options.picky and not string.find(line, "here", 1, true) then
		return false
	end
	greed.echo("%s")
	return true
end, options)
]],
			options,
			kind,
			name
		),
	}))
end

local function said(t: test.TestContext): string
	local messages = t:messages()
	return messages[#messages] or ""
end

test("g d asks each plugin in turn, fallbacks last, whatever order they load in", function(t)
	t:buffer("|here\nnot so\n")
	greed.plugin.unload("lsp")
	answering(t, "wide", "definition", "{ fallback = true }")
	answering(t, "narrow", "definition", "{ picky = true }")
	t:keys("g d")
	assert(said(t) == "narrow", said(t))
	t:keys("j g d")
	assert(said(t) == "wide", "the fallback answers the rest: " .. said(t))
	greed.plugin.unload("narrow")
	t:keys("k g d")
	assert(said(t) == "wide", "what a plugin added goes with it: " .. said(t))
end)

test("space k asks for hover, and with nobody to answer says so", function(t)
	t:buffer("|here\n")
	greed.plugin.unload("lsp")
	t:keys("space k")
	assert(said(t) == "nothing to show here", said(t))
	answering(t, "mine", "hover", "{}")
	t:keys("space k")
	assert(said(t) == "mine", said(t))
end)
