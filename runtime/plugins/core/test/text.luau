local test = require("@greed/test")
local text = require("@core").text

test("text width counts cells as drawn: wide characters two, tabs to their stop", function()
	assert(text.width("abc") == 3)
	assert(text.width("‹ ›") == 3)
	assert(text.width("\255\254") == 2, "a byte each when it isn't UTF-8")
	assert(text.width("日本") == 4, tostring(text.width("日本")))
	assert(text.width("a\tb") == 5, "a tab reaches the next stop")
	assert(text.width("a\tb", 8) == 9)
end)

test("clipped text ends in an ellipsis only when it was longer", function()
	assert(text.clip("‹ 2/5 ›", 3) == "‹ …")
	assert(text.clip("short", 5) == "short")
	assert(text.clip("shorter", 5) == "shor…")
	assert(text.clip("日本語です", 5) == "日本…", "cut by cells, whole characters")
end)

test("two texts' shared start counts whole lines only", function()
	local same = text.same_lines
	assert(same("a\nb\nc\n", "a\nb\nd\n") == 4)
	assert(same("a\nbc\n", "a\nbd\n") == 2, "not into a line that differs")
	assert(same("a\nb\n", "a\nb\nc\n") == 4)
	assert(same("", "x\n") == 0)
	assert(same("a\nb", "a\nb") == 2, "a last line without its break isn't whole")
end)

test("text splits into lines, trims and loses its quotes the same everywhere", function()
	local lines = text.split_lines("a\r\nb\nc\n")
	assert(table.concat(lines, "|") == "a|b|c", table.concat(lines, "|"))
	assert(table.concat(text.split_lines("a\n\nb"), "|") == "a||b")
	assert(#text.split_lines("") == 0, "no text, no lines")
	assert(text.trim("  a b \n") == "a b")
	assert(text.unquote('"a b"') == "a b" and text.unquote("'x'") == "x")
	assert(text.unquote('"half') == '"half', "only quotes around it")
end)

test(
	"relines reads only the lines a change touched, the rest moved, as a fresh split has them",
	function(t)
		local greed = require("@greed")
		t:buffer("|one\ntwo\r\nthree\n\nfive")
		local buffer = greed.view():buffer()
		local lines, starts = text.buffer_lines(buffer:text())
		local edits: { { from: number, to: number, put: string } } = {
			{ from = 0, to = 0, put = "x" },
			{ from = 4, to = 4, put = "new\nlines\n" },
			{ from = 0, to = 9, put = "" },
			{ from = 999, to = 999, put = "\nend" },
		}
		for i, edit in edits do
			local from = math.min(edit.from, buffer:len())
			local to = math.min(edit.to, buffer:len())
			local changed: { number }? = nil
			local function hear(event: greed.BufferChanged)
				changed = { event.from_line or 0, event.to_line or 0 }
			end
			greed.on("buffer.changed", hear)
			buffer:edit(function(e)
				e:replace(from, to, edit.put)
			end)
			greed.off("buffer.changed", hear)
			local span = assert(changed, "it said what changed")
			local now, at = text.relines(buffer, lines, starts, span[1], span[2])
			local want, want_at = text.buffer_lines(buffer:text())
			assert(now and at, `edit {i}: read again`)
			assert(
				table.concat(now, "|") == table.concat(want, "|"),
				`edit {i}: {table.concat(now, "|")}`
			)
			assert(
				table.concat(at, ",") == table.concat(want_at, ","),
				`edit {i}: {table.concat(at, ",")}`
			)
			lines, starts = now, at
		end
	end
)

test("percent-encoding keeps what URLs keep, and what you ask it to", function()
	assert(text.percent_encode("a b/c~d") == "a%20b%2Fc~d", text.percent_encode("a b/c~d"))
	assert(text.percent_encode("a b/c", "/") == "a%20b/c")
	assert(text.percent_encode("x]@%", "]@") == "x]@%25", text.percent_encode("x]@%", "]@"))
	assert(text.percent_decode("a%20b%2fc%zz") == "a b/c%zz")
	assert(text.percent_decode(text.percent_encode("åäö (1)")) == "åäö (1)")
end)

test("a count reads with its thousands apart", function()
	assert(text.count(0) == "0")
	assert(text.count(999) == "999")
	assert(text.count(1000) == "1,000")
	assert(text.count(143691) == "143,691", text.count(143691))
	assert(text.count(1234567) == "1,234,567")
	assert(text.count(-4200) == "-4,200")
end)
