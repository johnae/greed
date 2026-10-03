Greed, a General Runtime for Editing, Extending and Delegating, is a modal
editor for the terminal and the environment around it: a small Rust core,
and everything else in Luau. Keys, modes, commands, pickers, themes and the
agent integration are plugins you can read, change or replace while it runs.

```text
$ greed src/main.rs          # edit; the session keeps running if you detach
:detach                      # leave it running in the background
$ greed ls
48211
$ greed attach               # come back to it
$ greed ctl focus            # ask the running editor what you're looking at
{ "path": "src/main.rs", "mode": "normal", "selections": [ ... ], ... }
```

Editing works like Helix: select first, then act. `w` selects a word, `x` a
line, `s` selects every regex match inside the selection, and typing then
edits all of them at once. `space f` finds files, `space /` searches the
project as you type, `space e` opens a file tree and `:` runs any command.
Language servers start on their own when they're installed; `:health` shows
which ones were found.

## Plugins in Luau

A plugin is a folder with an `init.luau`. This one adds a command and binds
it to `g u`:

```luau
local greed = require("@greed")

greed.command({
	name = "upper",
	doc = "Upper-case the selections",
	run = function(ctx)
		ctx.buffer:edit(function(e)
			for _, range in ctx.view:selection().ranges do
				local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
				e:replace(from, to, string.upper(ctx.buffer:slice(from, to)))
			end
		end)
	end,
})

greed.keymap.bind("normal", { ["g u"] = "upper" })
```

Put it in `~/.config/greed/plugins/upper/` with a `plugin.toml` saying
`name = "upper"`, or run `greed new upper` in `~/.config/greed/plugins/` to get
one with a test. The API is typed, so `luau-analyze` and `luau-lsp` check
plugins against it, and `greed test upper` runs a plugin's tests in a headless
editor.

## Agents

Agents are clients of the editor, like the terminal is. They read what you
have open (unsaved changes included), see your selections and diagnostics,
and propose edits that show up in the buffer for you to accept or reject.

```bash
claude mcp add greed -- greed mcp     # Greed's tools in Claude Code
```

`space o c` opens Claude Code in a pane, connected to Greed like it is to VS
Code (outside Greed, `/ide` finds it), and its edits arrive as proposals. Agents can write new plugins too: Greed type checks and
tests them, and you review the code before it loads.

## Try it

Greed builds with a recent stable Rust and cmake (for the WebAssembly
runtime that loads downloaded grammars):

```bash
cargo build --release
./target/release/greed README.md
```

To install it, `cargo install --path crates/greed-editor`, or with Nix,
`nix-build` here or `pkgs.callPackage ./nix/package.nix { }` in your own
configuration. `nix-build -A static` builds a single statically linked
binary that runs on any Linux of the same CPU, to copy to a server. The default plugins are built into the binary, so it runs
from anywhere. To use your own copy of them, point `GREED_RUNTIME` at a
folder shaped like `runtime/`. `luau-analyze` is optional and used for type
checking plugins.

## Documentation

- [Using Greed](docs/using.md): editing, searching, files, sessions,
  configuration.
- [Writing plugins](docs/plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](docs/agents.md): `greed ctl`, MCP, proposals, `/ide` and plugins
  written by agents.
- [How Greed is built](docs/design.md): what lives in Rust, what lives in
  Luau, and why.

Greed is early and changes often.
