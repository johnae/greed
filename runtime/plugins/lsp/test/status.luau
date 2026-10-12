local test = require("@greed/test")
local greed = require("@greed")
local status = require("@lsp").status

test("progress a server reports shows until it ends, the oldest first", function()
	status.progress(
		"demo",
		{ token = 1, value = { kind = "begin", title = "Indexing", percentage = 0 } }
	)
	assert(status.work("demo") == "indexing 0%", status.work("demo"))
	status.progress(
		"demo",
		{ token = 1, value = { kind = "report", message = "3/10", percentage = 30.5 } }
	)
	assert(status.work("demo") == "indexing 3/10 30%", status.work("demo"))
	status.progress("demo", { token = "b", value = { kind = "begin", title = "Building" } })
	assert(
		status.work("demo") == "indexing 3/10 30%",
		"the oldest shows: " .. tostring(status.work("demo"))
	)
	status.progress("demo", { token = 1, value = { kind = "end" } })
	assert(status.work("demo") == "building", status.work("demo"))
	status.progress("demo", { token = "b", value = { kind = "end" } })
	assert(status.work("demo") == nil, status.work("demo"))
end)

test(
	"a language whose server isn't installed says so; one without a server shows nothing",
	function(t)
		greed.lsp.server({ language = "demo", command = { "greed-no-such-server" } })
		t:buffer("x|")
		local buffer = greed.view():buffer()
		buffer:set_language("demo")
		assert(status.text(buffer) == "greed-no-such-server not installed", status.text(buffer))
		greed.lsp.remove("demo")
		assert(status.text(buffer) == nil, status.text(buffer))
	end
)

test("a server held back in a project you haven't trusted says how to let it start", function(t)
	local dir = t:tempdir({ ["main.demo"] = "x\n" })
	greed.lsp.server({ language = "demo", command = { "sh" } })
	greed.lsp.trust({ t:tempdir() })
	greed.open(`{dir}/main.demo`)
	local buffer = greed.view():buffer()
	buffer:set_language("demo")
	assert(status.text(buffer) == "sh waits for :trust", status.text(buffer))
	greed.lsp.trust(nil)
	greed.lsp.remove("demo")
end)
