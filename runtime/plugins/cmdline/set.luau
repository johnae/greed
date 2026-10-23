-- `:set`, `:toggle` and `:get`. `:set NAME VALUE` (or `NAME=VALUE`) sets an
-- option. A yes-or-no option also takes Vim's forms: `:set NAME` turns it
-- on, `:set noNAME` off, `:set NAME!` (or `invNAME`) flips it, and
-- `:set NAME?` shows any option's value. Vim's `number` (`nu`),
-- `relativenumber` (`rnu`), `textwidth` (`tw`), `ignorecase` (`ic`) and
-- `smartcase` (`scs`) work too; its indent ones say how indent goes here.

local greed = require("@greed")

local M = {}

local function exists(name: string): boolean
	for _, option in greed.option.list() do
		if option.name == name then
			return true
		end
	end
	return false
end

local function show(name: string)
	greed.echo(`{name} is {tostring(greed.option.get(name))}`)
end

-- What a word means for a yes-or-no thing: on, off, flip or show.
type Change = "on" | "off" | "flip" | "show"

-- Vim's line number settings, as Greed's: `number` shows the numbers in
-- this buffer, `relativenumber` counts from the cursor's line, and both
-- together are the "hybrid" line-numbers.
local function numbers(relative: boolean, change: Change)
	local buffer = greed.view():buffer()
	local style = greed.option.get("line-numbers")
	local shown = buffer:line_numbers()
	local number_on = shown and style ~= "relative"
	local relative_on = shown and style ~= "absolute"
	local was = if relative then relative_on else number_on
	if change == "show" then
		greed.echo(
			`{if relative then "relativenumber" else "number"} is {if was then "on" else "off"}`
		)
		return
	end
	local on = if change == "flip" then not was else change == "on"
	if relative then
		relative_on = on
	else
		number_on = on
	end
	buffer:set_line_numbers(number_on or relative_on)
	if number_on or relative_on then
		local new = if number_on and relative_on
			then "hybrid"
			elseif relative_on then "relative"
			else "absolute"
		if new ~= style then
			greed.option.set("line-numbers", new)
		end
	end
end

-- Vim's names for things Greed has: handled by hand, or another option.
local vim_flags: { [string]: (change: Change) -> () } = {
	number = function(change)
		numbers(false, change)
	end,
	relativenumber = function(change)
		numbers(true, change)
	end,
}
vim_flags.nu = vim_flags.number
vim_flags.rnu = vim_flags.relativenumber
-- Vim's case settings, as search-case: ignorecase is "ignore", smartcase
-- "smart" (Vim needs both on for that; here smartcase alone does).
local function case(on: string, off: string, name: string): (change: Change) -> ()
	return function(change)
		local now = greed.option.get("search-case")
		if change == "show" then
			greed.echo(`{name} is {if now == on then "on" else "off"} (search-case is {now})`)
			return
		end
		local turn_on = if change == "flip" then now ~= on else change == "on"
		greed.option.set("search-case", if turn_on then on else off)
	end
end
vim_flags.ignorecase = case("ignore", "match", "ignorecase")
vim_flags.ic = vim_flags.ignorecase
vim_flags.smartcase = case("smart", "ignore", "smartcase")
vim_flags.scs = vim_flags.smartcase
local vim_names: { [string]: string } = { tw = "text-width", textwidth = "text-width" }

-- Vim's indent settings, which Greed has per language instead.
local INDENT_HELP = "indent is per language here: "
	.. 'require("@languages").set("python", { indent = 4 }) in your config, '
	.. "or :set indent 4 for files in no language"
local vim_hints: { [string]: string } = {}
for _, name in { "shiftwidth", "sw", "tabstop", "ts", "softtabstop", "sts", "expandtab", "et" } do
	vim_hints[name] = INDENT_HELP
end

local function option_name(name: string): string
	return vim_names[name] or name
end

-- Fails saying how Greed does what Vim's `name` does, if it's one of those.
local function hint(name: string)
	local base = string.match(name, "^no(.+)$") or name
	local said = vim_hints[name] or vim_hints[base]
	if said then
		error(`{name}: {said}`, 0)
	end
end

-- The value typed for an option, as the type it takes: a number for
-- indent is that many spaces.
local function value_of(text: string, option: string?): greed.OptionValue
	-- A string option keeps a number as it was typed, like `rulers 80`.
	if option and option ~= "indent" and type(greed.option.get(option)) == "string" then
		return text
	end
	local value: greed.OptionValue = if text == "true"
		then true
		elseif text == "false" then false
		else tonumber(text) or text
	if option == "indent" and type(value) == "number" then
		return string.rep(" ", value)
	end
	return value
end

-- One word after `:set`: NAME, noNAME, invNAME, NAME!, NAME? or NAME=VALUE.
local function set_word(word: string)
	local name, value = string.match(word, "^([^=]+)=(.*)$")
	if name and value then
		hint(name)
		local option = option_name(name)
		greed.option.set(option, value_of(value, option))
		return
	end
	local change: Change = "on"
	name = word
	if string.sub(word, -1) == "?" then
		change, name = "show", string.sub(word, 1, -2)
	elseif string.sub(word, -1) == "!" then
		change, name = "flip", string.sub(word, 1, -2)
	end
	local base = name :: string
	local function known(option: string): boolean
		return vim_flags[option] ~= nil or exists(option_name(option))
	end
	if change == "on" and not known(base) then
		local off, flip = string.sub(base, 3), string.sub(base, 4)
		if string.sub(base, 1, 2) == "no" and known(off) then
			change, base = "off", off
		elseif string.sub(base, 1, 3) == "inv" and known(flip) then
			change, base = "flip", flip
		end
	end
	local flag = vim_flags[base]
	if flag then
		flag(change)
		return
	end
	local option = option_name(base)
	if not exists(option) then
		hint(base)
		-- The option module's own error names options like it.
		greed.option.set(option, true)
	end
	local current = greed.option.get(option)
	if change == "show" or (type(current) ~= "boolean" and change == "on") then
		show(option)
	elseif type(current) ~= "boolean" then
		error(`{option} isn't yes or no - :set {option} VALUE sets it`, 0)
	else
		greed.option.set(option, if change == "flip" then not current else change == "on")
	end
end

--- Runs `:set` with the words typed after it.
function M.set(args: { string })
	if #args == 0 then
		error(
			"set needs an option, e.g. :set text-width 100 or :set auto-save; space h o lists them",
			0
		)
	end
	-- NAME VALUE, where text values can have spaces.
	local option = option_name(args[1])
	if #args >= 2 and not string.find(args[1], "=", 1, true) and exists(option) then
		greed.option.set(option, value_of(table.concat(args, " ", 2), option))
		return
	end
	for _, word in args do
		set_word(word)
	end
end

local option_arg: greed.ArgSpec =
	{ name = "option", doc = "The option", complete = "option", type = "string" }

-- :set stays untyped: its words take Vim's forms (noNAME, NAME!, NAME=VALUE,
-- several at once), which it reads itself.
greed.command({
	name = "set",
	doc = "Set an option: NAME VALUE; for a yes-or-no one, NAME, noNAME or NAME! as in Vim; NAME? shows it",
	args = {
		{ name = "option", doc = "The option to set", complete = "option" },
		{ name = "value", doc = "true, false, a number or text", complete = "option-value" },
	},
	run = function(ctx)
		M.set(ctx.args)
	end,
})

greed.command({
	name = "toggle-option",
	doc = "Turn a yes-or-no option on or off",
	args = { option_arg },
	run = function(ctx)
		set_word(ctx.values.option .. "!")
	end,
})

greed.command({
	name = "get-option",
	doc = "Show an option's value",
	args = { option_arg },
	run = function(ctx)
		set_word(ctx.values.option .. "?")
	end,
})

return M
