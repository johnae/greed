local test = require("@greed/test")
local greed = require("@greed")
local lsp = require("@lsp")
local picker = require("@picker")
local marks = require("../marks")

local function install(t: test.TestContext, name: string, badge: string)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = `name = "{name}"\nrequires = ["lsp", "picker"]\n`,
		["init.luau"] = string.format(
			[[
local greed = require("@greed")
local lsp = require("@lsp")
local picker = require("@picker")
local remove_badge = lsp.completion.kind_badge(function(kind)
	assert(kind == 3)
	return %q
end)
local remove_icon = picker.file_icon(function(path)
	assert(path == "src/example.rs")
	return %q
end)
local remove_sign = lsp.set_diagnostic_sign_provider(function(severity)
	assert(severity == 4)
	return %q
end)
greed.command({ name = %q, run = function()
	remove_badge()
	remove_icon()
	remove_sign()
end })
]],
			badge,
			badge,
			badge,
			name .. "-remove"
		),
	}))
end

local function shown(t: test.TestContext): string
	return table.concat(t:floats(), "\n")
end

local function expect_presentations(t: test.TestContext, value: string)
	t:keys("i")
	t:run("completion-ask")
	assert(string.find(shown(t), value, 1, true), shown(t))
	t:keys("esc")
	picker.pick(
		"files",
		{ { label = "example.rs", value = "src/example.rs", kind = "file" } },
		function() end
	)
	assert(string.find(shown(t), value, 1, true), shown(t))
	t:keys("esc")
	local found = marks.diagnostic_marks(greed.view():buffer(), {
		{ from = 0, to = 0, severity = 4, message = "preserved hint\nmore" },
	}, true)
	assert(found[1].sign == value)
	assert(found[1].style == "diagnostic.sign.hint")
	assert(found[2].text == "preserved hint" and found[2].style == "diagnostic.message.hint")
end

test("presentation providers restore predecessors on removal and unload", function(t)
	t:buffer("|")
	local buffer = greed.view():buffer()
	-- Keep this consumer buffer shown throughout: t:buffer replaces and closes
	-- an unused scratch buffer, independently of provider plugin ownership.
	local diagnostics: { greed.Diagnostic } = {
		{ from = 0, to = 0, severity = 4, message = "unchanged hint" },
	}
	local baseline = marks.diagnostic_marks(buffer, diagnostics, true)
	lsp.completion.source(function()
		return { { label = "example", text = "example", kind = 3, badge = "SOURCE" } }
	end, { first = true })
	install(t, "presentation-first", "FIRST")
	install(t, "presentation-second", "SECOND")
	expect_presentations(t, "SECOND")
	t:run("presentation-second-remove")
	expect_presentations(t, "FIRST")
	-- Removing an already removed entry must not disturb its predecessor.
	greed.plugin.unload("presentation-second")
	expect_presentations(t, "FIRST")
	install(t, "presentation-third", "THIRD")
	greed.plugin.unload("presentation-first")
	expect_presentations(t, "THIRD")
	greed.plugin.unload("presentation-third")
	t:keys("i")
	t:run("completion-ask")
	assert(string.find(shown(t), "SOURCE", 1, true), shown(t))
	t:keys("esc")
	local restored = marks.diagnostic_marks(buffer, diagnostics, true)
	assert(restored[1].sign == baseline[1].sign)
	assert(restored[2].text == baseline[2].text)
end)
