local test = require("@kern/test")
local kern = require("@kern")

test("g w labels the words, closest first, and a label selects its word", function(t)
	t:buffer("one |two three")
	local buffer = kern.view():buffer()
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
	assert(#kern.view():buffer():decorations("jump") == 0)
end)

test("the alphabet can be changed", function(t)
	kern.option.set("jump-label-alphabet", "jk")
	t:buffer("|aa bb cc dd ee")
	t:keys("g w k j")
	t:expect("aa bb ^cc| dd ee")
	kern.option.set("jump-label-alphabet", "abcdefghijklmnopqrstuvwxyz")
end)
