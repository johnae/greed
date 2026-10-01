local test = require("@kern/test")
local kern = require("@kern")
local marks = require("../marks")

local function diagnostic(from: number, severity: number, message: string): kern.Diagnostic
	return { from = from, to = from + 1, severity = severity, message = message }
end

test("each line with problems gets a sign and its worst message", function(t)
	t:buffer("|let a = b;\nlet c = d;\nok")
	local buffer = kern.view():buffer()
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
	local found = marks.diagnostic_marks(kern.view():buffer(), { diagnostic(4, 1, "not found") }, false)
	assert(#found == 1 and found[1].sign == "E", "just the sign")
end)
