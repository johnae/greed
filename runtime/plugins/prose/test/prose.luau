local test = require("@kern/test")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("sentences", function(t)
	check(t, "One. Tw|o here. Three.", "m i s", "One. ^Two here.| Three.")
	check(t, "One. Tw|o here. Three.", "m a s", "One. ^Two here. |Three.")
	check(t, "Mr. Smith left. He| came back.", "m i s", "Mr. Smith left. ^He came back.|")
	check(t, "One. Tw|o. Three.", "] s", "One. Two. |Three.")
	check(t, "One. Tw|o. Three.", "[ s", "One. |Two. Three.")
	check(t, "One. |Two. Three.", "[ s", "|One. Two. Three.")
end)

test("sentences stop at blank lines", function(t)
	check(t, "A line\n\nNe|xt one", "m i s", "A line\n\n^Next one|")
end)

test("paragraphs", function(t)
	local text = "First para\nstill first\n\n\nSec|ond para\n\nThird"
	check(t, text, "m i p", "First para\nstill first\n\n\n^Second para|\n\nThird")
	check(t, text, "m a p", "First para\nstill first\n\n\n^Second para\n\n|Third")
	check(t, "Fi|rst\n\nSecond\n\nThird", "] p", "First\n\n|Second\n\nThird")
	check(t, "First\n\nSec|ond\n\nThird", "[ p", "First\n\n|Second\n\nThird")
	check(t, "First\n\n|Second\n\nThird", "[ p", "|First\n\nSecond\n\nThird")
end)

test("markdown sections", function(t)
	local text = "# Top\nintro\n## A\na te|xt\n## B\nb text\n"
	check(t, text, "m i h", "# Top\nintro\n## A\n^a text\n|## B\nb text\n")
	check(t, text, "m a h", "# Top\nintro\n^## A\na text\n|## B\nb text\n")
	check(t, "# Top\nin|tro\n## A\n", "m a h", "^# Top\nintro\n## A\n|")
end)
