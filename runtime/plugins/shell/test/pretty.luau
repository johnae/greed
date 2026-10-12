local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())
type Block = typeof(assert(shell.run(shell.open(), "true")))

local LOG = table.concat({
	'{"level":"info","ts":"2026-10-12T11:57:46.269Z","msg":"in sync","name":"vikunja"}',
	'{"level":"error","ts":1760270266,"msg":"db down","release":{"name":"linstor"}}',
	"not json",
}, "\n") .. "\n"

local function open(t: test.TestContext): Shell
	greed.option.set("shell-blocks", false)
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({
		["log.json"] = LOG,
		["plain"] = "a\nb\n",
		["pod.yaml"] = "status:\n  phase: Running\n  conditions:\n  - type: Ready\nspec:\n  nodeName: n1\n",
	})
	return sh
end

local function run(t: test.TestContext, sh: Shell, line: string): Block
	local block = assert(shell.run(sh, line, { view = greed.view() }), line)
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block
end

-- What shows in place of each line, the pieces joined.
local function readable(sh: Shell, block: Block): { string }
	local lines: { [number]: { string } } = {}
	for _, mark in sh.buffer:decorations(`shell.pretty.{block.uid}`) do
		local line = sh.buffer:line_of(mark.from)
		lines[line] = lines[line] or {}
		table.insert(lines[line], mark.text or "")
	end
	local out: { string } = {}
	local numbers: { number } = {}
	for line in lines do
		table.insert(numbers, line)
	end
	table.sort(numbers)
	for _, line in numbers do
		table.insert(out, table.concat(lines[line]))
	end
	return out
end

test("JSON lines show their time, level and message first, the rest after", function(t)
	local sh = open(t)
	local block = run(t, sh, "cat log.json")
	assert(block.pretty == true, "readable")
	local shown = readable(sh, block)
	assert(#shown == 2, `the line that isn't JSON shows as it came: {#shown}`)
	local here = os.date("%H:%M:%S", 1760270266)
	assert(shown[1] == `{here} info  in sync  name=vikunja`, shown[1])
	assert(shown[2] == `{here} error db down  release.name=linstor`, shown[2])
	-- The buffer keeps the JSON.
	assert(string.find(sh.buffer:text(), '"msg":"db down"', 1, true) ~= nil)
end)

test("shell-pretty shows them as they came and back; other output isn't touched", function(t)
	local sh = open(t)
	local block = run(t, sh, "cat log.json")
	greed.view():set_cursor(assert((shell.log.output_range(sh, block))))
	t:run("shell-pretty")
	assert(block.pretty == false and #readable(sh, block) == 0, "as it came")
	t:run("shell-pretty")
	assert((block.pretty :: boolean?) == true and #readable(sh, block) == 2, "readable again")
	local plain = run(t, sh, "cat plain")
	assert(plain.pretty == false and #readable(sh, plain) == 0)
end)

test("with shell-json-lines raw, they show as they came", function(t)
	local sh = open(t)
	greed.option.set("shell-json-lines", "raw")
	local block = run(t, sh, "cat log.json")
	assert(block.pretty == false and #readable(sh, block) == 0)
end)

test("tab in what a command printed folds the section indented under the line", function(t)
	local sh = open(t)
	local block = run(t, sh, "cat pod.yaml")
	local first = sh.buffer:line_of(assert((shell.log.output_range(sh, block))))
	local view = greed.view()
	view:set_cursor(sh.buffer:line_start(first))
	t:run("fold-toggle")
	local hidden = view:hidden_lines()
	assert(#hidden == 1, `one fold: {#hidden}`)
	assert(
		hidden[1].from == first + 1 and hidden[1].to == first + 3,
		`{hidden[1].from} {hidden[1].to}`
	)
end)

test("tab in a filter completes sections and fields from what the block printed", function(t)
	local sh = open(t)
	local yaml = run(t, sh, "cat pod.yaml")
	local main = greed.view()
	main:set_cursor(assert((shell.log.output_range(sh, yaml))))
	t:run("shell-filter")
	t:keys(". c o n tab tab")
	local typed = greed.view():buffer():text()
	assert(typed == ".status.conditions", typed)
	t:keys("esc")
	local logs = run(t, sh, "cat log.json")
	main:focus()
	main:set_cursor(assert((shell.log.output_range(sh, logs))))
	t:run("shell-filter")
	t:keys("l e v tab")
	local field = greed.view():buffer():text()
	assert(field == "level=", field)
end)

test(
	"a filter's fields come with values they have, as a readable line hides their names",
	function(t)
		local sh = open(t)
		local logs = run(t, sh, "cat log.json")
		local level: string? = nil
		for _, word in shell.filtering.words(logs) do
			if word.word == "level=" then
				level = word.what
			end
		end
		assert(level == "info, error", tostring(level))
		local main = greed.view()
		main:set_cursor(assert((shell.log.output_range(sh, logs))))
		t:run("shell-filter")
		local spec = assert(greed.view():float_spec())
		assert(string.find(tostring(spec.title), "tab lists fields", 1, true), tostring(spec.title))
	end
)

test("logfmt lines show readably too, and times show as the time here", function(t)
	local sh = open(t)
	sh.cwd = t:tempdir({
		["fmt.log"] = 'ts=2025-10-12T11:57:46Z level=warn msg="disk is filling" path=/var used=91%\n',
	})
	local block = run(t, sh, "cat fmt.log")
	local shown = readable(sh, block)
	local here = os.date("%H:%M:%S", 1760270266)
	assert(shown[1] == `{here} warn  disk is filling  path=/var used=91%`, shown[1])
end)
