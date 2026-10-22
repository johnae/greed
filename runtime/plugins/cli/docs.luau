-- Reference pages as Markdown, from the editor as it runs: every loaded
-- plugin with its commands, keys and options, every option, and the Luau
-- API and its events from the type definitions. `greed reference DIR`
-- writes them; the website builds its reference from them, and with your
-- own config loaded they describe your setup too.

local greed = require("@greed")

local M = {}

-- `text` fit for a Markdown table cell.
local function cell(text: string): string
	return (string.gsub(string.gsub(text, "\n", " "), "|", "\\|"))
end

-- An option's value as you'd write it in Luau.
local function literal(value: greed.OptionValue): string
	return if type(value) == "string"
		then string.format("%q", value)
		elseif type(value) == "table" then "{" .. table.concat(value, ", ") .. "}"
		else tostring(value)
end

-- A keymap layer's mode part in words: a mode ("vim"), a role in every
-- style ("role:command"), one style's role ("vim:command") or the leader.
-- nil for a buffer kind alone.
local function mode_words(name: string): string?
	local before, after = string.match(name, "^([^:]+):(.+)$")
	if name == "leader" then
		return "after the leader"
	elseif before == "role" then
		return `every style's {after} mode`
	elseif before == "kind" then
		return nil
	elseif before then
		return `{before}'s {after} mode`
	end
	return name
end

-- Where a key is bound, from the keymap layers it's in: each a mode, a
-- buffer kind ("kind:tree"), both, or "global". E.g. "helix, vim; in tree
-- buffers".
local function where(layers: { string }): string
	local modes: { string } = {}
	local kinds: { string } = {}
	for _, layer in layers do
		local first = string.match(layer, "^(%S+)")
		local mode = if first then mode_words(first) else nil
		local kind = string.match(layer, "kind:(%S+)")
		if mode and not table.find(modes, mode) then
			table.insert(modes, mode)
		end
		if kind and not table.find(kinds, kind) then
			table.insert(kinds, kind)
		end
	end
	local text = table.concat(modes, ", ")
	if #kinds > 0 then
		text ..= `{if text == "" then "" else "; "}in {table.concat(kinds, ", ")} buffers`
	end
	return text
end

-- The keys that run `command` and where, keys bound in the same places
-- together, e.g. "`ctrl-n`, `down` (insert, vim-insert)".
local function keys_for(command: string): string
	local order: { string } = {}
	local layers: { [string]: { string } } = {}
	for _, binding in greed.keymap.find(command) do
		if layers[binding.keys] == nil then
			layers[binding.keys] = {}
			table.insert(order, binding.keys)
		end
		table.insert(layers[binding.keys], binding.layer)
	end
	local places: { string } = {}
	local keys_in: { [string]: { string } } = {}
	for _, keys in order do
		local place = where(layers[keys])
		if keys_in[place] == nil then
			keys_in[place] = {}
			table.insert(places, place)
		end
		table.insert(keys_in[place], `\`{keys}\``)
	end
	local parts = {}
	for _, place in places do
		table.insert(parts, `{table.concat(keys_in[place], ", ")} ({place})`)
	end
	return table.concat(parts, ", ")
end

-- Lines as Markdown: runs of indented lines (key lists, code) become code
-- blocks, Luau when they look like it.
local function prose(lines: { string }): string
	local out = {}
	local i = 1
	while i <= #lines do
		if string.match(lines[i], "^  ") then
			local run = {}
			while
				i <= #lines
				and (
					string.match(lines[i], "^  ")
					or lines[i] == "" and string.match(lines[i + 1] or "", "^  ")
				)
			do
				table.insert(run, lines[i])
				i += 1
			end
			local code = table.concat(run, "\n")
			local luau = string.find(code, "require(", 1, true)
				or string.find(code, "greed.", 1, true)
			table.insert(out, `\`\`\`{if luau then "luau" else "text"}\n{code}\n\`\`\``)
		else
			table.insert(out, lines[i])
			i += 1
		end
	end
	return table.concat(out, "\n")
end

-- The comment at the top of a plugin's entry file, as Markdown.
local function header(dir: string): string?
	local source = greed.fs.read(`{dir}/init.luau`)
	if source == nil then
		return nil
	end
	local lines = {}
	for line in string.gmatch(source .. "\n", "(.-)\n") do
		local text = string.match(line, "^%-%- ?(.*)$")
		if text == nil then
			break
		end
		table.insert(lines, text)
	end
	return if #lines > 0 then prose(lines) else nil
end

-- The `requires` list in a plugin's plugin.toml.
local function requires(dir: string): { string }
	local manifest = greed.fs.read(`{dir}/plugin.toml`) or ""
	local list = string.match(manifest, "requires%s*=%s*(%b[])")
	local names = {}
	for name in string.gmatch(list or "", '"([^"]+)"') do
		table.insert(names, name)
	end
	return names
end

--- The page of loaded plugins: what each does, its commands and keys, and
--- its options.
function M.plugins(): string
	local commands: { [string]: { greed.CommandInfo } } = {}
	for _, command in greed.commands() do
		commands[command.owner] = commands[command.owner] or {}
		table.insert(commands[command.owner], command)
	end
	local options: { [string]: { greed.OptionInfo } } = {}
	for _, option in greed.option.list() do
		options[option.owner] = options[option.owner] or {}
		table.insert(options[option.owner], option)
	end
	local dirs = greed.plugin.dirs()
	local out = {
		"# Plugins",
		"",
		"Everything you see in Greed comes from these plugins, each a folder of Luau you can read, change or replace. Unload one with `greed.plugin.unload(name)` in your config.",
	}
	for _, name in greed.plugin.list() do
		local dir = dirs[name]
		if dir == nil then
			continue
		end
		table.insert(out, `\n## {name}\n`)
		local about = header(dir)
		if about then
			table.insert(out, about .. "\n")
		end
		local needs = requires(dir)
		if #needs > 0 then
			table.insert(out, `Uses: {table.concat(needs, ", ")}.\n`)
		end
		local mine: { greed.CommandInfo } = commands[name] or {}
		table.sort(mine, function(a: greed.CommandInfo, b: greed.CommandInfo)
			return a.name < b.name
		end)
		if #mine > 0 then
			table.insert(out, "| Command | Keys | What it does |\n|---|---|---|")
			for _, command in mine do
				table.insert(
					out,
					`| \`{command.name}\` | {cell(keys_for(command.name))} | {cell(command.doc)} |`
				)
			end
			table.insert(out, "")
		end
		if options[name] then
			table.insert(out, "| Option | Default | What it does |\n|---|---|---|")
			for _, option in options[name] do
				table.insert(
					out,
					`| \`{option.name}\` | \`{cell(literal(option.default))}\` | {cell(option.doc)} |`
				)
			end
			table.insert(out, "")
		end
	end
	return table.concat(out, "\n") .. "\n"
end

--- The page of every option, with its default and the plugin it's from.
function M.options(): string
	local out = {
		"# Options",
		"",
		'Set any of these in your `init.luau`, e.g. `require("@greed").option.set("motion-hints", true)`, or while the editor runs with `:set motion-hints true`.',
		"",
		"| Option | Default | Plugin | What it does |",
		"|---|---|---|---|",
	}
	for _, option in greed.option.list() do
		table.insert(
			out,
			`| \`{option.name}\` | \`{cell(literal(option.default))}\` | {option.owner} | {cell(
				option.doc
			)} |`
		)
	end
	return table.concat(out, "\n") .. "\n"
end

type Field = { text: string, doc: { string } }
type Type = { name: string, doc: { string }, fields: { Field }, text: string? }

-- The types in a Luau type definition file, in order, each with its doc
-- comment and its fields'.
local function parse_types(source: string): { Type }
	local types: { Type } = {}
	local doc: { string } = {}
	local current: Type? = nil
	local field: Field? = nil
	for line in string.gmatch(source .. "\n", "(.-)\n") do
		local block = current
		if block then
			if line == "}" then
				current, field = nil, nil
			elseif string.match(line, "^\t%-%-%-") then
				table.insert(doc, string.match(line, "^\t%-%-%- ?(.*)$") :: string)
			elseif string.match(line, "^\t[%w_%[]") then
				field = { text = string.sub(line, 2), doc = doc }
				table.insert(block.fields, field :: Field)
				doc = {}
			elseif field and string.match(line, "^\t[\t%)]") then
				field.text ..= "\n" .. string.sub(line, 2)
			end
			continue
		end
		local name = string.match(line, "^export type ([%w_]+)")
		if name then
			local new: Type = { name = name, doc = doc, fields = {} }
			if not string.match(line, "{$") then
				new.text = string.match(line, "^export type (.*)$")
			end
			table.insert(types, new)
			current, doc = if new.text then nil else new, {}
		elseif string.match(line, "^%-%-%-") then
			table.insert(doc, string.match(line, "^%-%-%- ?(.*)$") :: string)
		elseif line == "" then
			doc = {}
		end
	end
	return types
end

--- The page of the Luau API, `require("@greed")`, from its type
--- definitions in `source`: the module first, then every type it uses.
function M.api(source: string): string
	local types = parse_types(source)
	local known: { [string]: boolean } = {}
	for _, t in types do
		known[t.name] = true
	end
	for i, t in types do
		if t.name == "Greed" then
			table.insert(types, 1, table.remove(types, i) :: Type)
			break
		end
	end
	local out = {
		"# Luau API",
		"",
		'What plugins and your config get from `require("@greed")`: the module first, then the types it hands out. Positions are 0-based byte offsets and lines are 0-based, as language servers count them.',
	}
	for _, t in types do
		table.insert(out, `\n## \`{t.name}\`\n`)
		if #t.doc > 0 then
			table.insert(out, table.concat(t.doc, "\n") .. "\n")
		end
		if t.text then
			table.insert(out, `\`\`\`luau\n{t.text}\n\`\`\``)
		end
		for _, f in t.fields do
			local text = string.gsub(f.text, ",$", "")
			local name = string.match(text, "^([%w_]+)")
			table.insert(out, `\n### \`{name or text}\`\n\n\`\`\`luau\n{text}\n\`\`\``)
			if #f.doc > 0 then
				table.insert(out, "\n" .. table.concat(f.doc, "\n"))
			end
			local refers = string.match(text, ": (%u[%w_]*)%??$")
			if refers and known[refers] then
				table.insert(out, `\nSee [\`{refers}\`](#{string.lower(refers)}).`)
			end
		end
	end
	return table.concat(out, "\n") .. "\n"
end

--- The page of events, from the type definitions in `source`: each event
--- `greed.on` takes, with the type its handler gets and that type's fields.
function M.events(source: string): string
	local by_name: { [string]: Type } = {}
	for _, t in parse_types(source) do
		by_name[t.name] = t
	end
	local out = {
		"# Events",
		"",
		"What `greed.on(event, handler)` hands each handler. Give the handler's parameter the type named here, as in `function(event: greed.BufferChanged)`, and the type checker catches a misspelled field. When each event happens is in [Writing plugins](../plugins.md#events); `space h e` (`:describe-event`) shows the same in the editor.",
	}
	for line in string.gmatch(source, "[^\n]+") do
		local event, kind =
			string.match(line, '%(event: "([%w%._]+)", handler: %(event: ([%w_{}]+)%)')
		if event == nil or kind == nil then
			continue
		end
		local t = by_name[kind]
		if t == nil then
			table.insert(out, `\n## \`{event}\`\n\nIts handler gets nothing.`)
			continue
		end
		local about = if #t.doc > 0 then " " .. table.concat(t.doc, " ") else ""
		table.insert(out, `\n## \`{event}\`\n\nIts handler gets a \`greed.{kind}\`.{about}`)
		local fields = {}
		for _, f in t.fields do
			for _, doc in f.doc do
				table.insert(fields, `\t--- {doc}`)
			end
			table.insert(fields, "\t" .. (string.gsub(f.text, "\n", "\n\t")))
		end
		table.insert(out, `\n\`\`\`luau\n\{\n{table.concat(fields, "\n")}\n}\n\`\`\``)
	end
	return table.concat(out, "\n") .. "\n"
end

--- Writes the reference pages into `dir`, returning what it wrote.
function M.write(dir: string): { string }
	local core = greed.plugin.dirs().core
	local types = core
		and greed.fs.read((string.gsub(core, "plugins/core$", "types/greed/init.luau")))
	local pages: { [string]: string } =
		{ ["plugins.md"] = M.plugins(), ["options.md"] = M.options() }
	if types then
		pages["api.md"] = M.api(types)
		pages["events.md"] = M.events(types)
	end
	local written = {}
	for file, text in pages do
		local ok, err = greed.fs.write(`{dir}/{file}`, text)
		if not ok then
			error(`can't write {dir}/{file}: {err}`, 0)
		end
		table.insert(written, file)
	end
	table.sort(written)
	return written
end

return M
