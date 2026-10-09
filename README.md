Greed, a General Runtime for Editing, Extending and Delegating, is an editor
for the terminal and the environment around it: a small Rust core, and
everything else in Luau. Keys, modes, commands, pickers, themes and the
agent integration are plugins you can read, change or replace while it runs.

```text
$ greed src/main.rs          # edit; the session keeps running if you detach
:detach                      # leave it running in the background
$ greed ls
48211
$ greed attach               # come back to it, here or in a window (--gui)
$ greed ctl focus            # ask the running editor what you're looking at
{ "path": "src/main.rs", "mode": "vim", "selections": [ ... ], ... }
```

Edit the way you already like to. The first time Greed starts it asks
which style you want, and `:style` switches while it runs. The three
styles are equals: each follows the editor it comes from closely, down to
text objects, registers, macros and counts, so your habits carry over.

- Vim: say what to do, then where: `d w`, `c i w`, `.` to repeat.
- Helix: select first, then act. `x` selects a line, `s` every regex match
  inside the selection, and typing edits all of them at once.
- VS Code: no modes, VS Code's keys. Typing inserts, shift and the arrows
  select, `ctrl-d` adds the next match as another cursor.

Everything that isn't editing lives in the leader, which every style
opens: `space` in Vim and Helix, `ctrl-space` in the VS Code style. So
`space f` finds files (`ctrl-space f` or `ctrl-p` in the VS Code style)
and `space /` searches the project as you type. `:` runs any command in Vim and Helix;
in the VS Code style `ctrl-P` picks one and `alt-x` opens the same command
line. Language servers start on their own when they're installed;
`:health` shows which ones were found. [Editing styles](docs/editing-styles.md)
has the keys for each.

Greed also has panes, tabs and floating views with zellij's `alt` keys,
terminals, and a shell (`:shell`) whose commands become blocks you keep,
search and run again. `greed ssh HOST` shows an editor running on another
machine, and several terminals and windows can show one session at once.

## Plugins in Luau

A plugin is a folder with an `init.luau`. This one adds a command and puts
it on the leader's `U` (`space U`, or `ctrl-space U` in the VS Code style):

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

greed.keymap.bind({ layer = "leader" }, { U = "upper" })
```

Put it in `~/.config/greed/plugins/upper/` with a `plugin.toml` saying
`name = "upper"`, or run `greed new upper` in `~/.config/greed/plugins/` to
get one with a test. The API is typed, so `luau-analyze` and `luau-lsp`
check plugins against it, and `greed test upper` runs a plugin's tests in a
headless editor.

## Agents

Agents are clients of the editor, like the terminal is. They read what you
have open (unsaved changes included), see your selections and diagnostics,
and propose edits that show up in the buffer for you to accept or reject.

```bash
claude mcp add greed -- greed mcp     # Greed's tools in Claude Code
```

`space i C` opens Claude Code in a pane, connected to Greed like it is to
VS Code (outside Greed, `/ide` finds it), and its edits arrive as
proposals. `space i n` starts other agents inside Greed over ACP (Gemini
CLI, Codex) or Greed's own agent, with any model you set up. Agents can
write new plugins too: Greed type checks and tests them, and you review the
code before it loads.

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
binary without the window client that runs on any Linux of the same CPU,
to copy to a server.

The default plugins are built into the binary, so it runs from anywhere.
To use your own copy of them, point `GREED_RUNTIME` at a folder shaped like
`runtime/`. `luau-analyze` is optional and used for type checking plugins.

## Documentation

- [Using Greed](docs/using.md): editing, searching, files, sessions,
  configuration.
- [Editing styles](docs/editing-styles.md) and [Keys](docs/keys.md): the
  Vim, Helix and VS Code styles, and binding your own keys.
- [Several clients](docs/clients.md): terminals and windows on one
  session, following each other or laid out on their own.
- [The shell](docs/shell.md): commands as blocks you keep, search and run
  again, sending output to buffers or the next command; agents use it too.
- [Writing plugins](docs/plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](docs/agents.md): `greed ctl`, MCP, proposals, `/ide`, agents
  inside Greed and plugins written by agents.
- [How Greed is built](docs/design.md): what lives in Rust, what lives in
  Luau, and why.

Greed is early and changes often.

Greed is licensed under the [Mozilla Public License 2.0](LICENSE); parts
from other projects keep their own licenses, listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
