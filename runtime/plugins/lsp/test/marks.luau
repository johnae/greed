local test = require("@greed/test")
local greed = require("@greed")
local marks = require("../marks")
local lsp = require("@lsp")

local function diagnostic(from: number, severity: number, message: string): greed.Diagnostic
	return { from = from, to = from + 1, severity = severity, message = message }
end

test("each line with problems gets a sign and its worst message", function(t)
	t:buffer("|let a = b;\nlet c = d;\nok")
	local buffer = greed.view():buffer()
	local found = marks.diagnostic_marks(buffer, {
		diagnostic(8, 2, "unused"),
		diagnostic(4, 1, "not found\nmore detail"),
		diagnostic(19, 3, "consider this"),
	}, true)
	local shown = {}
	for _, m in found do
		table.insert(shown, `{m.from}:{m.sign or ""}:{m.text or ""}:{m.style}`)
	end
	assert(
		table.concat(shown, " | ")
			== "0:E::diagnostic.sign.error | 0::not found:diagnostic.message.error | 11:I::diagnostic.sign.info | 11::consider this:diagnostic.message.info",
		table.concat(shown, " | ")
	)
end)

test("messages can be left out", function(t)
	t:buffer("|let a = b;")
	local found =
		marks.diagnostic_marks(greed.view():buffer(), { diagnostic(4, 1, "not found") }, false)
	assert(#found == 1 and found[1].sign == "E", "just the sign")
end)

test("configured signs preserve all severity styles and messages", function(t)
	t:buffer("|error\nwarning\ninfo\nhint")
	local buffer = greed.view():buffer()
	local diagnostics = {
		diagnostic(0, 1, "error text\nmore detail"),
		diagnostic(6, 2, "warning text"),
		diagnostic(14, 3, "info text"),
		diagnostic(19, 4, "hint text"),
	}
	local saved = lsp.signs
	local names = { "error", "warning", "info", "hint" }
	local defaults = { "E", "W", "I", "H" }
	local custom = { "!", "?", "i", "." }
	local function expect(signs: { string }, messages: boolean)
		local found = marks.diagnostic_marks(buffer, diagnostics, messages, lsp.signs)
		assert(#found == (if messages then 8 else 4))
		for severity, name in names do
			local sign = found[if messages then severity * 2 - 1 else severity]
			assert(sign.sign == signs[severity], name)
			assert(sign.style == "diagnostic.sign." .. name, name)
			assert(sign.from == diagnostics[severity].from and sign.to == sign.from, name)
			if messages then
				local message = found[severity * 2]
				assert(message.text == name .. " text", name)
				assert(message.style == "diagnostic.message." .. name and message.eol == true, name)
			end
		end
	end
	local ok, err = pcall(function()
		expect(defaults, true)
		lsp.signs = { error = "!", warning = "?", info = "i", hint = "." }
		expect(custom, true)
		expect(custom, false)
		-- Ordinary table mutation works too; omitted severities retain defaults.
		lsp.signs = { warning = "?" }
		lsp.signs.hint = "."
		expect({ "E", "?", "I", "." }, true)
		lsp.signs = {}
		expect(defaults, true)
	end)
	lsp.signs = saved
	assert(ok, tostring(err))
end)
