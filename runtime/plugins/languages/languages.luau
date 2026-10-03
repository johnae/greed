-- The languages Greed knows: which files are in each, the language servers to
-- try (the first one installed runs), the files that mark a project's root,
-- and how comments and indentation look. Greed has syntax highlighting for
-- some of them; `:health` shows which.

export type Language = {
	extensions: { string }?,
	--- Whole file names, like "Makefile".
	names: { string }?,
	--- Files that mark a project's root, e.g. "Cargo.toml".
	roots: { string }?,
	--- Commands to start a language server, tried in order.
	servers: { { string } }?,
	--- What starts a line comment.
	comment: string?,
	--- Spaces per indent level; leave out to indent with tabs.
	indent: number?,
	--- Luau patterns for a line after which the next goes a level in,
	--- matched against the line without its trailing spaces, e.g.
	--- `{ "[%(%[{:]$" }`. Used without an indents query, and with one where
	--- the code doesn't parse yet (a `def` before its `end` is typed).
	indent_after: { string }?,
	--- Luau patterns for text that goes a level out when it starts a line,
	--- like `{ "^end%f[%W]" }`, matched without leading spaces. Used where
	--- `indent_after` is; closing brackets by default.
	outdent_before: { string }?,
	--- A program that formats the file: it gets the text on its input and
	--- prints it formatted. "{path}" in it stands for the file's path.
	--- Without one, the language server formats, as rust-analyzer does.
	formatter: { string }?,
}

local languages: { [string]: Language } = {
	bash = {
		formatter = { "shfmt" },
		extensions = { "sh", "bash" },
		names = { ".bashrc", ".bash_profile" },
		servers = { { "bash-language-server", "start" } },
		comment = "#",
		indent = 2,
	},
	c = {
		formatter = { "clang-format", "--assume-filename={path}" },
		extensions = { "c", "h" },
		roots = { "compile_commands.json", "CMakeLists.txt", "Makefile" },
		servers = { { "clangd" } },
		comment = "//",
		indent = 4,
	},
	["c-sharp"] = {
		extensions = { "cs" },
		servers = { { "csharp-ls" } },
		comment = "//",
		indent = 4,
	},
	cpp = {
		formatter = { "clang-format", "--assume-filename={path}" },
		extensions = { "cpp", "cc", "cxx", "hpp", "hh", "hxx" },
		roots = { "compile_commands.json", "CMakeLists.txt", "Makefile" },
		servers = { { "clangd" } },
		comment = "//",
		indent = 4,
	},
	css = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "css", "scss" },
		servers = { { "vscode-css-language-server", "--stdio" } },
		indent = 2,
	},
	go = {
		formatter = { "gofmt" },
		extensions = { "go" },
		roots = { "go.mod" },
		servers = { { "gopls" } },
		comment = "//",
	},
	haskell = {
		extensions = { "hs" },
		roots = { "stack.yaml", "cabal.project", "package.yaml" },
		servers = { { "haskell-language-server-wrapper", "--lsp" } },
		comment = "--",
		indent = 2,
	},
	html = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "html", "htm" },
		servers = { { "vscode-html-language-server", "--stdio" } },
		indent = 2,
	},
	java = {
		extensions = { "java" },
		roots = { "pom.xml", "build.gradle", "build.gradle.kts" },
		servers = { { "jdtls" } },
		comment = "//",
		indent = 4,
	},
	javascript = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "js", "mjs", "cjs", "jsx" },
		roots = { "package.json" },
		servers = { { "typescript-language-server", "--stdio" } },
		comment = "//",
		indent = 2,
	},
	julia = {
		extensions = { "jl" },
		roots = { "Project.toml" },
		comment = "#",
		indent = 4,
	},
	json = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "json" },
		servers = { { "vscode-json-language-server", "--stdio" } },
		indent = 2,
	},
	luau = {
		formatter = { "stylua", "-" },
		extensions = { "luau", "lua" },
		roots = { ".luaurc" },
		servers = { { "luau-lsp", "lsp" } },
		comment = "--",
	},
	make = {
		names = { "Makefile", "makefile", "GNUmakefile" },
		extensions = { "mk" },
		comment = "#",
	},
	markdown = {
		extensions = { "md", "markdown" },
		servers = { { "harper-ls", "--stdio" }, { "marksman", "server" } },
		indent = 2,
	},
	nix = {
		formatter = { "nixfmt" },
		extensions = { "nix" },
		roots = { "flake.nix" },
		servers = { { "nil" }, { "nixd" } },
		comment = "#",
		indent = 2,
	},
	ocaml = {
		formatter = { "ocamlformat", "--name={path}", "-" },
		extensions = { "ml" },
		roots = { "dune-project" },
		servers = { { "ocamllsp" } },
		indent = 2,
	},
	python = {
		indent_after = { "[%(%[{:]$" },
		formatter = { "ruff", "format", "-" },
		extensions = { "py", "pyi" },
		roots = { "pyproject.toml", "setup.py", "requirements.txt" },
		servers = {
			{ "basedpyright-langserver", "--stdio" },
			{ "pyright-langserver", "--stdio" },
			{ "pylsp" },
		},
		comment = "#",
		indent = 4,
	},
	ruby = {
		extensions = { "rb" },
		names = { "Gemfile", "Rakefile" },
		roots = { "Gemfile" },
		servers = { { "ruby-lsp" }, { "solargraph", "stdio" } },
		comment = "#",
		indent = 2,
		indent_after = {
			"^%s*def%s",
			"^%s*class%s",
			"^%s*module%s",
			"^%s*if%s",
			"^%s*unless%s",
			"^%s*while%s",
			"^%s*until%s",
			"^%s*for%s",
			"^%s*case%f[%W]",
			"^%s*when%s",
			"^%s*begin$",
			"^%s*else$",
			"^%s*elsif%s",
			"^%s*rescue%f[%W]",
			"^%s*ensure$",
			"%sdo$",
			"%sdo%s*|[^|]*|$",
			"{%s*|[^|]*|$",
			"[%(%[{]$",
		},
		outdent_before = {
			"^end%f[%W]",
			"^else%f[%W]",
			"^elsif%f[%W]",
			"^when%f[%W]",
			"^rescue%f[%W]",
			"^ensure%f[%W]",
			"^[%)%]}]",
		},
	},
	rust = {
		extensions = { "rs" },
		roots = { "Cargo.toml" },
		servers = { { "rust-analyzer" } },
		comment = "//",
		indent = 4,
	},
	scala = {
		formatter = { "scalafmt", "--stdin" },
		extensions = { "scala", "sc" },
		roots = { "build.sbt", "build.sc" },
		servers = { { "metals" } },
		comment = "//",
		indent = 2,
	},
	toml = {
		formatter = { "taplo", "format", "-" },
		extensions = { "toml" },
		names = { "Cargo.lock" },
		servers = { { "taplo", "lsp", "stdio" } },
		comment = "#",
		indent = 2,
	},
	typescript = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "ts", "mts", "cts" },
		roots = { "tsconfig.json", "package.json" },
		servers = { { "typescript-language-server", "--stdio" } },
		comment = "//",
		indent = 2,
	},
	tsx = {
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "tsx" },
		roots = { "tsconfig.json", "package.json" },
		servers = { { "typescript-language-server", "--stdio" } },
		comment = "//",
		indent = 2,
	},
	yaml = {
		indent_after = { "[%(%[{:]$" },
		formatter = { "prettier", "--stdin-filepath", "{path}" },
		extensions = { "yaml", "yml" },
		servers = { { "yaml-language-server", "--stdio" } },
		comment = "#",
		indent = 2,
	},
	zig = {
		formatter = { "zig", "fmt", "--stdin" },
		extensions = { "zig" },
		roots = { "build.zig" },
		servers = { { "zls" } },
		comment = "//",
		indent = 4,
	},
}

return languages
