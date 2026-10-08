-- `:set`, `:toggle` and `:get`. `:set NAME VALUE` (or `NAME=VALUE`) sets an
-- option. A yes-or-no option also takes Vim's forms: `:set NAME` turns it
-- on, `:set noNAME` off, `:set NAME!` (or `invNAME`) flips it, and
-- `:set NAME?` shows any option's value. Vim's `number` (`nu`),
-- `relativenumber` (`rnu`) and `textwidth` (`tw`) work too.

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
local vim_names: { [string]: string } = { tw = "text-width", textwidth = "text-width" }

local function option_name(name: string): string
	return vim_names[name] or name
end

-- The value typed for an option, as the type it takes.
local function value_of(text: string): greed.OptionValue
	return if text == "true" then true elseif text == "false" then false else tonumber(text) or text
end

-- One word after `:set`: NAME, noNAME, invNAME, NAME!, NAME? or NAME=VALUE.
local function set_word(word: string)
	local name, value = string.match(word, "^([^=]+)=(.*)$")
	if name and value then
		greed.option.set(option_name(name), value_of(value))
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
		error(`no option called {base}`, 0)
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
		error("set needs an option, e.g. :set tab-width 2 or :set auto-save", 0)
	end
	-- NAME VALUE, where text values can have spaces.
	local option = option_name(args[1])
	if #args >= 2 and not string.find(args[1], "=", 1, true) and exists(option) then
		greed.option.set(option, value_of(table.concat(args, " ", 2)))
		return
	end
	for _, word in args do
		set_word(word)
	end
end

local option_arg: greed.ArgSpec = { name = "option", doc = "The option", complete = "option" }

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
		local name = ctx.args[1]
		if name == nil then
			error("toggle-option needs an option, e.g. :toggle auto-save", 0)
		end
		set_word(name .. "!")
	end,
})

greed.command({
	name = "get-option",
	doc = "Show an option's value",
	args = { option_arg },
	run = function(ctx)
		local name = ctx.args[1]
		if name == nil then
			error("get-option needs an option, e.g. :get tab-width", 0)
		end
		set_word(name .. "?")
	end,
})

return M
