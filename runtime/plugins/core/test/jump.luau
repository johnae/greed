local test = require("@greed/test")
local greed = require("@greed")

test("g w labels the words, closest first, and a label selects its word", function(t)
	t:buffer("one |two three")
	local buffer = greed.view():buffer()
	t:keys("g w")
	local labels = {}
	for _, mark in buffer:decorations("jump") do
		labels[mark.from] = mark.text
	end
	assert(
		labels[4] == "aa" and labels[0] == "ab" and labels[8] == "ac",
		"two is closest, then one"
	)
	t:keys("a")
	assert(#buffer:decorations("jump") == 3, "the labels starting with the typed letter stay")
	t:keys("c")
	t:expect("one two ^three|")
	assert(#buffer:decorations("jump") == 0, "the labels go")
end)

test("a key that isn't a label cancels", function(t)
	t:buffer("one |two three")
	t:keys("g w z z")
	t:expect("one |two three")
	assert(#greed.view():buffer():decorations("jump") == 0)
end)

test("the alphabet can be changed", function(t)
	greed.option.set("jump-label-alphabet", "jk")
	t:buffer("|aa bb cc dd ee")
	t:keys("g w k j")
	t:expect("aa bb ^cc| dd ee")
	greed.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
end)

test("labels can use letters of more than one byte", function(t)
	greed.option.set("jump-label-alphabet", "åö")
	t:buffer("|aa bb cc dd")
	t:keys("g w ö å")
	t:expect("aa bb ^cc| dd")
	greed.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
end)

test("with no words or no alphabet it says so instead of waiting", function(t)
	t:buffer("|")
	t:keys("g w")
	local messages = t:messages()
	assert(messages[#messages] == "no words to jump to", messages[#messages])
	assert(#greed.view():buffer():decorations("jump") == 0)
	greed.option.set("jump-label-alphabet", "")
	t:buffer("|aa bb")
	t:keys("g w")
	messages = t:messages()
	assert(messages[#messages] == "jump-label-alphabet is empty", messages[#messages])
	greed.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
end)
