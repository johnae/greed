local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")
local filtering = require("../filtering")
local log = require("../log")
local rows = require("../rows")

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
	greed.view():set_cursor(assert((log.output_range(sh, block))))
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
	local first = sh.buffer:line_of(assert((log.output_range(sh, block))))
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
	main:set_cursor(assert((log.output_range(sh, yaml))))
	t:run("shell-filter")
	t:keys(". c o n tab tab")
	local typed = greed.view():buffer():text()
	assert(typed == ".status.conditions", typed)
	t:keys("esc")
	local logs = run(t, sh, "cat log.json")
	main:focus()
	main:set_cursor(assert((log.output_range(sh, logs))))
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
		for _, word in filtering.words(logs) do
			if word.word == "level=" then
				level = word.what
			end
		end
		assert(level == "info, error", tostring(level))
		local main = greed.view()
		main:set_cursor(assert((log.output_range(sh, logs))))
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

test("the filter's prompt says how much it keeps as it's typed", function(t)
	local sh = open(t)
	local logs = run(t, sh, "cat log.json")
	greed.view():set_cursor(assert((log.output_range(sh, logs))))
	t:run("shell-filter")
	local prompt = greed.view()
	local function title(): string
		return tostring(assert(prompt:float_spec()).title)
	end
	assert(not string.find(title(), " of ", 1, true), title())
	t:keys("d o w n")
	assert(string.find(title(), "1 of 3 lines", 1, true), title())
end)

test("a command that hasn't printed after a second says so where its output goes", function(t)
	local sh = open(t)
	local block = assert(shell.run(sh, "sleep 30", { view = greed.view() }))
	local function says(): boolean
		for _, mark in sh.buffer:decorations(`shell.block.{block.uid}`) do
			if mark.lines and tostring(mark.lines[1]) == "nothing printed yet" then
				return true
			end
		end
		return false
	end
	assert(not says(), "not at once")
	t:wait(1100)
	assert(says(), "after a second")
	shell.kill(block)
end)

test("a filter compares levels in their order", function(t)
	local sh = open(t)
	local logs = run(t, sh, "cat log.json")
	rows.set(sh, logs, "level>=warn")
	local shown = assert(logs.shown)
	assert(#shown.rows == 1 and shown.total == 3, `{#shown.rows} of {shown.total}`)
	rows.set(sh, logs, "level!=error")
	assert(#assert(logs.shown).rows == 2, "info, and the line without a level")
end)

test("up in a filter brings back filters used on this kind of command", function(t)
	local sh = open(t)
	local first = run(t, sh, "cat log.json")
	local main = greed.view()
	local function filter(block: Block, keys: string): string
		main:focus()
		main:set_cursor(assert((log.output_range(sh, block))))
		t:run("shell-filter")
		t:keys(keys)
		return greed.view():buffer():text()
	end
	filter(first, "e r r o r enter")
	filter(run(t, sh, "cat log.json"), "l e v e l > = w a r n enter")
	local again = run(t, sh, "cat log.json")
	assert(filter(again, "up") == "level>=warn", "the last one")
	assert(greed.view():buffer():text() == "level>=warn")
	t:keys("up")
	assert(greed.view():buffer():text() == "error", "the one before")
	t:keys("down down")
	assert(greed.view():buffer():text() == "", "back to what was typed")
	t:keys("esc")
	local other = run(t, sh, "cat pod.yaml")
	assert(filter(other, "up") == "", "another kind of command has its own")
end)

test("long JSON or YAML shows its keys folded as it ends, a long one's keys too", function(t)
	local sh = open(t)
	greed.option.set("shell-fold-structured", 4)
	local item =
		'    {\n      "metadata": {\n        "name": "NAME",\n        "labels": { "app": "NAME" }\n      },\n      "status": { "phase": "Running" }\n    }'
	local list = '{\n  "kind": "List",\n  "items": [\n'
		.. (string.gsub(item, "NAME", "api"))
		.. ",\n"
		.. (string.gsub(item, "NAME", "db"))
		.. "\n  ]\n}\n"
	sh.cwd = t:tempdir({ ["list.json"] = list })
	local block = run(t, sh, "cat list.json")
	local view = greed.view()
	local first = sh.buffer:line_of(assert((log.output_range(sh, block))))
	local shown: { string } = {}
	local hidden: { [number]: boolean } = {}
	for _, run in view:hidden_lines() do
		for line = run.from, run.to do
			hidden[line] = true
		end
	end
	for line = first, sh.buffer:line_count() - 1 do
		if not hidden[line] then
			table.insert(shown, (string.gsub(sh.buffer:line_text(line), "^%s+", "")))
		end
	end
	local text = table.concat(shown, "|")
	assert(string.find(text, '"items": [', 1, true), text)
	assert(not string.find(text, '"name"', 1, true), "the items' insides are folded: " .. text)
	assert(string.find(text, '"kind": "List"', 1, true), text)
end)
