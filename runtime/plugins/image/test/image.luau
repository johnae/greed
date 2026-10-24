local test = require("@greed/test")
local greed = require("@greed")

-- A 1 by 1 PNG.
local PNG =
	"\137\80\78\71\13\10\26\10\0\0\0\13\73\72\68\82\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\13\73\68\65\84\120\218\99\252\207\192\80\15\0\4\133\1\128\132\169\140\33\0\0\0\0\73\69\78\68\174\66\96\130"

-- The image the buffer shows, as its mark has it.
local function shown(buffer: greed.Buffer): any
	for _, mark in buffer:decorations("image") do
		if mark.image then
			return mark.image
		end
	end
	return nil
end

test("an image file opens as the image, with its name and size above it", function(t)
	local dir = t:tempdir({ ["dot.png"] = PNG })
	greed.open(dir .. "/dot.png")
	local buffer = greed.view():buffer()
	assert(buffer:kind() == "image", buffer:kind())
	assert(string.match(buffer:text(), "^dot%.png  1×1  "), buffer:text())
	local image = shown(buffer)
	assert(image and image.cols >= 1 and image.rows >= 1, "it's drawn")
end)

test("+ and - zoom, and 0 draws it at its own size", function(t)
	local dir = t:tempdir({ ["dot.png"] = PNG })
	greed.open(dir .. "/dot.png")
	local buffer = greed.view():buffer()
	t:keys("0")
	assert(string.find(buffer:text(), "100%", 1, true), buffer:text())
	t:keys("+ +")
	assert(string.find(buffer:text(), "156%", 1, true), buffer:text())
	t:keys("-")
	assert(string.find(buffer:text(), "125%", 1, true), buffer:text())
end)

test("a file that isn't an image says why", function(t)
	local dir = t:tempdir({ ["broken.png"] = "not a png" })
	greed.open(dir .. "/broken.png")
	assert(greed.view():buffer():kind() ~= "image")
	local messages = t:messages()
	assert(#messages > 0, "it says something")
end)

test("the keys work in a style no plugin names", function(t)
	local dir = t:tempdir({ ["dot.png"] = PNG })
	greed.open(dir .. "/dot.png")
	local buffer = greed.view():buffer()
	require("@core").style.define({ name = "mine", doc = "Mine", mode = "mine" })
	require("@core").style.set("mine")
	t:expect_mode("mine")
	t:keys("0")
	assert(string.find(buffer:text(), "100%", 1, true), buffer:text())
end)

test("space . on a picture offers its zooms, which zoom it", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["dot.png"] = PNG })
	greed.open(dir .. "/dot.png")
	local buffer = greed.view():buffer()
	t:keys("0")
	local targets = core.actions.at(greed.view())
	local picture = targets[1]
	assert(picture and picture.kind == "image" and picture.label == "dot.png", "it's found")
	local names: { string } = {}
	for _, action in core.actions.for_kind("image", picture) do
		table.insert(names, action.name)
	end
	local listed = table.concat(names, ", ")
	assert(string.find(listed, "zoom in, zoom out, fit, actual size", 1, true), listed)
	for _, action in core.actions.for_kind("image", picture) do
		if action.name == "zoom in" then
			core.actions.run(action, picture)
		end
	end
	t:wait(50)
	assert(string.find(buffer:text(), "125%", 1, true), buffer:text())
end)
