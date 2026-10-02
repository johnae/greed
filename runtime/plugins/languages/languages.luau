-- The languages Kern knows: which files are in each, the language servers to
-- try (the first one installed runs), the files that mark a project's root,
-- and how comments and indentation look. Kern has syntax highlighting for
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
	python = {
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
	},
	rust = {
		extensions = { "rs" },
		roots = { "Cargo.toml" },
		servers = { { "rust-analyzer" } },
		comment = "//",
		indent = 4,
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
		extensions = { "ts", "mts", "cts", "tsx" },
		roots = { "tsconfig.json", "package.json" },
		servers = { { "typescript-language-server", "--stdio" } },
		comment = "//",
		indent = 2,
	},
	yaml = {
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
