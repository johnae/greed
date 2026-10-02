-- Grammars Kern doesn't have built in, downloaded the first time a file in
-- their language opens and kept in the cache folder after that. Each is a
-- WebAssembly file from the grammar's own releases, checked against the
-- checksum below, with the queries from the same version of its
-- repository, their capture names changed to Kern's.
--
-- Turn downloading off with `kern.option.set("grammar-download", false)`;
-- grammars already downloaded still load. `:grammar-fetch NAME` downloads
-- one ahead of time.

local kern = require("@kern")

kern.option.define({
	name = "grammar-download",
	doc = "Download the grammar for a language Kern has none for when a file in it opens",
	default = true,
})

export type Source = {
	--- The GitHub repository, e.g. "tree-sitter/tree-sitter-ruby".
	repo: string,
	--- The release tag the grammar and its queries come from.
	version: string,
	sha256: string,
	--- The grammar's own name, when it isn't the language's with "-" as "_".
	symbol: string?,
	--- Languages whose queries come first, like C's for C++.
	inherits: { string }?,
	--- Where the WebAssembly file is, instead of the release.
	url: string?,
	--- Where the queries are, with "{kind}" for "highlights" or
	--- "injections", instead of the repository.
	queries: string?,
}

local M = {}

local function tree_sitter(name: string, version: string, sha256: string): Source
	return { repo = `tree-sitter/tree-sitter-{name}`, version = version, sha256 = sha256 }
end

--- The grammars Kern knows where to get, by language.
M.sources = {
	cpp = tree_sitter(
		"cpp",
		"v0.23.4",
		"174eb0deb75b2ec7881bcacda9f995648d8e683956e5c2267e69ab6dc503fcbf"
	),
	css = tree_sitter(
		"css",
		"v0.25.0",
		"8a23977fe271357cce6f254ef88c9bebf3854602d8046605aef6a45c02135c59"
	),
	html = tree_sitter(
		"html",
		"v0.23.2",
		"c48fcd82c7ea8bf943180088ba7f28c48b2bb5287874179168bf9d31e394cf85"
	),
	java = tree_sitter(
		"java",
		"v0.23.5",
		"4fdeac4ca6ca089f06c6f7e562abcac1733cd465728cc7031ebb73c2019122c4"
	),
	ruby = tree_sitter(
		"ruby",
		"v0.23.1",
		"09a96427d7c72f0613ed470cd9812223fc4a91d6a9c025c0235cc6bd59ff96f4"
	),
	haskell = tree_sitter(
		"haskell",
		"v0.24.1",
		"ea89cb1199b1ca2102e273b27239e795baff17248128a9bcd3c3825ac17d8cc0"
	),
	["c-sharp"] = tree_sitter(
		"c-sharp",
		"v0.23.5",
		"6f69e1cae44e1c32c1eccc170dc5a9778fb94ff716f71113fe1f8c4299aa2f40"
	),
	scala = tree_sitter(
		"scala",
		"v0.26.2",
		"37d7fe5a91ca98941dc05493b0c05a0df0f36df5035890fa00b02497c68aaac3"
	),
	regex = tree_sitter(
		"regex",
		"v0.25.0",
		"e63c28e3a023614e14f2086b0d818e190239ebe5b2fcce7e64a9940091d83a79"
	),
	jsdoc = tree_sitter(
		"jsdoc",
		"v0.25.0",
		"5530e630fd42424b1c026ec4b2b260ff1b73b78b7040239ac33d4be22a9b2271"
	),
	julia = tree_sitter(
		"julia",
		"v0.25.0",
		"b20da9dc7d7334e2cae034ca4974dd09c94be8c0a524df1fc194b545bc2f49f5"
	),
	ocaml = tree_sitter(
		"ocaml",
		"v0.26.0",
		"bfa3eef92b9d3cc1117aa486d46ecb06c98a3a28c1747660aaa5851df5e4530c"
	),
} :: { [string]: Source }
M.sources.cpp.inherits = { "c" }

-- Capture names other editors use, as Kern's (see docs/highlighting.md).
local NAMES: { [string]: string? } = {
	number = "constant.numeric",
	float = "constant.numeric.float",
	boolean = "constant.builtin.boolean",
	character = "constant.character",
	escape = "constant.character.escape",
	["string.escape"] = "constant.character.escape",
	property = "variable.other.member",
	field = "variable.other.member",
	["variable.member"] = "variable.other.member",
	parameter = "variable.parameter",
	method = "function.method",
	["function.call"] = "function",
	["function.method.call"] = "function.method",
	conditional = "keyword.control.conditional",
	["repeat"] = "keyword.control.repeat",
	include = "keyword.control.import",
	exception = "keyword.control.exception",
	["keyword.conditional"] = "keyword.control.conditional",
	["keyword.repeat"] = "keyword.control.repeat",
	["keyword.return"] = "keyword.control.return",
	["keyword.import"] = "keyword.control.import",
	["keyword.exception"] = "keyword.control.exception",
	module = "namespace",
	delimiter = "punctuation.delimiter",
	["tag.attribute"] = "attribute",
	["type.definition"] = "type",
	["string.special.uri"] = "string.special.url",
	["text.title"] = "markup.heading",
	["text.emphasis"] = "markup.italic",
	["text.strong"] = "markup.bold",
	["text.literal"] = "markup.raw",
	["text.uri"] = "markup.link.url",
	["text.reference"] = "markup.link.text",
}

-- Captures that are only for other editors' own features.
local DROPPED = { embedded = true, spell = true, nospell = true, none = true }

-- A pattern that names any node of a kind, like `(identifier) @variable`.
-- With the first pattern to match some text winning, these go last.
local CATCH_ALL = "^%(([%w_]+)%)%s+@[%w._]+$"

--- `source`, a query written for another editor, with Kern's capture names
--- and its catch-all patterns moved to the end.
function M.adapt(source: string): string
	local renamed = string.gsub(source, "@([%w._]+)", function(name: string): string
		if DROPPED[name] then
			return ""
		end
		return "@" .. (NAMES[name] or name)
	end)
	-- `(pattern/wildcard)`, a node by its supertype, needs the supertypes
	-- in the grammar, which not every build of one has; the node alone
	-- matches the same text.
	renamed = string.gsub(renamed, "%(([%w_]+)/([%w_]+)", "(%2")
	-- Kern doesn't track which names are local variables, so a pattern
	-- for those that aren't is a catch-all, kept after the others.
	renamed =
		string.gsub(renamed, "%(%(([%w_]+)%)%s+(@[%w._]+)%s*%(#is%-not%? local%)%s*%)", "(%1) %2")
	local lines, last = {}, {}
	for line in string.gmatch(renamed .. "\n", "(.-)\n") do
		table.insert(if string.match(line, CATCH_ALL) then last else lines, line)
	end
	for _, line in last do
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

--- How files are fetched: `url` saved at `path`. Tests swap it out.
function M.fetch(url: string, path: string)
	local result, err = kern.process.run({
		"curl",
		"--fail",
		"--silent",
		"--show-error",
		"--location",
		"--max-time",
		"120",
		"--create-dirs",
		"--output",
		path,
		url,
	})
	if result == nil then
		error(`can't run curl to download grammars: {err}`, 0)
	elseif result.code ~= 0 then
		error(`downloading {url}: {result.stderr}`, 0)
	end
end

local KINDS = { "highlights", "injections" }

local function sha256(path: string): string?
	local result = kern.process.run({ "sha256sum", path })
	return result and string.match(result.stdout, "^(%x+)")
end

-- Where `name`'s files go.
local function folder(name: string, source: Source): string
	local cache = kern.fs.dirs().cache or (kern.fs.cwd() .. "/.kern-cache")
	return `{cache}/grammars/{name}/{source.version}`
end

local function wasm_url(source: Source): string
	if source.url then
		return source.url
	end
	local repo = string.match(source.repo, "/(.+)$") or source.repo
	local file = string.gsub(repo, "-", "_")
	file = string.gsub(file, "^tree_sitter_", "tree-sitter-")
	return `https://github.com/{source.repo}/releases/download/{source.version}/{file}.wasm`
end

local function queries_url(source: Source, kind: string): string
	if source.queries then
		return (string.gsub(source.queries, "{kind}", kind))
	end
	return `https://raw.githubusercontent.com/{source.repo}/{source.version}/queries/{kind}.scm`
end

-- The grammar's files, downloaded if they aren't yet. Returns the
-- WebAssembly file, or nil if it isn't there and can't be downloaded now.
local function files(name: string, source: Source): string?
	local dir = folder(name, source)
	local wasm = `{dir}/grammar.wasm`
	if kern.fs.stat(wasm) then
		return wasm
	end
	if kern.option.get("grammar-download") ~= true then
		return nil
	end
	kern.echo(`downloading the {name} grammar`)
	local part = wasm .. ".part"
	M.fetch(wasm_url(source), part)
	local got = sha256(part)
	if got ~= source.sha256 then
		kern.process.run({ "rm", "-f", part })
		error(`the {name} grammar downloaded doesn't match its checksum ({got or "unknown"})`, 0)
	end
	for _, kind in KINDS do
		-- Not every grammar has every kind; those that don't are left out.
		pcall(M.fetch, queries_url(source, kind), `{dir}/{kind}.scm`)
	end
	kern.process.run({ "mv", part, wasm })
	return wasm
end

-- Languages being set up, so a second file opening doesn't start again.
local busy: { [string]: boolean } = {}

--- Sets up the grammar for `name` if Kern knows where to get one:
--- downloads it the first time, loads it and sets its queries, leaving
--- alone any a plugin or your config set from query files (`provided`
--- says which). Returns whether `name` has a grammar now.
function M.ensure(name: string, provided: (language: string, kind: string) -> boolean): boolean
	if table.find(kern.grammars(), name) then
		return true
	end
	local source = M.sources[name]
	if source == nil or busy[name] then
		return false
	end
	busy[name] = true
	local ok, result = pcall(function(): boolean
		local wasm = files(name, source)
		if wasm == nil then
			return false
		end
		kern.syntax.load_grammar(name, wasm, source.symbol)
		local dir = folder(name, source)
		for _, kind in KINDS do
			local own = kern.fs.read(`{dir}/{kind}.scm`)
			if own and not provided(name, kind) then
				local parts = {}
				for _, parent in source.inherits or {} do
					table.insert(parts, kern.syntax.query(parent, kind) or "")
				end
				table.insert(parts, own)
				kern.syntax.set_query(name, kind, M.adapt(table.concat(parts, "\n")))
			end
		end
		return true
	end)
	busy[name] = nil
	if not ok then
		error(result, 0)
	end
	return result
end

return M
