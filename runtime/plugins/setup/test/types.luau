local test = require("@greed/test")
local greed = require("@greed")
local setup = require("@setup")

-- Puts a config in the config folder; returns the folder above it.
local function config(): string
	local dir = assert(greed.fs.dirs().config)
	greed.fs.write(`{dir}/init.luau`, "-- mine\n")
	return assert(string.match(dir, "^(.*)/[^/]+$"))
end

test("a .luaurc beside the config knows @greed and the plugins", function(t)
	local parent = config()
	assert(setup.types.update(), "wrote it")
	local luaurc = greed.fs.read(`{parent}/.luaurc`) or ""
	local runtime = assert(setup.types.runtime())
	assert(string.find(luaurc, `"greed": "{runtime}/types/greed"`, 1, true), luaurc)
	assert(string.find(luaurc, `"theme": "{runtime}/plugins/theme"`, 1, true), luaurc)
	assert(setup.types.update() == nil, "nothing to do the second time")
end)

test("Greed writes over its own .luaurc but never yours", function(t)
	local parent = config()
	setup.types.update()
	-- An older Greed's file, as Greed wrote it, is brought up to date.
	local data = assert(greed.fs.dirs().data)
	greed.fs.write(`{parent}/.luaurc`, "{}\n")
	greed.fs.write(`{data}/config-luaurc`, "{}\n")
	assert(setup.types.update(), "updated")
	-- One you changed stays as it is.
	greed.fs.write(`{parent}/.luaurc`, '{ "languageMode": "strict" }\n')
	assert(setup.types.update() == nil, "nothing written")
	assert(greed.fs.read(`{parent}/.luaurc`) == '{ "languageMode": "strict" }\n', "untouched")
end)

test("a .luaurc that was there first is yours", function(t)
	local parent = config()
	greed.fs.write(`{parent}/.luaurc`, "{}\n")
	assert(setup.types.update() == nil, "nothing written")
	assert(greed.fs.read(`{parent}/.luaurc`) == "{}\n", "untouched")
end)

test("without a config folder there's nothing to do", function(t)
	assert(setup.types.update() == nil)
end)
