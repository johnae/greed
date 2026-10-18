Greed is a modal text editor with Helix, Vim and VS Code keys, a shell,
terminals and agent support. It runs in a terminal or a window, locally or
over ssh. The core is a small Rust program; keys, modes, commands,
pickers, themes and the agent support are Luau plugins you can read,
change or replace while it runs.

[![A Rust file with the file tree beside it and a terminal below running kubectl get pods](https://github.com/johnae/greed/releases/download/media/hero.png)](https://github.com/johnae/greed/releases/download/media/hero.mp4)

```text
$ greed src/main.rs          # edit; the session keeps running if you detach
:detach                      # leave it running in the background
$ greed ls
myapp                /home/you/myapp
$ greed attach               # come back to it, here or in a window (--gui)
$ greed ctl focus            # ask the running editor what you're looking at
{ "path": "/home/you/myapp/src/main.rs", "mode": "normal", "style": "vim", "selections": [ ... ], ... }
```

The first time Greed starts it asks which editing style you want;
`:style` switches while it runs. Each style follows the editor it comes
from, down to text objects, registers, macros and counts.

- Vim: say what to do, then where: `d w`, `c i w`, `.` to repeat.
- Helix: select first, then act. `x` selects a line, `s` every regex match
  inside the selection, and typing edits all of them at once.
- VS Code: no modes, VS Code's keys. Typing inserts, shift and the arrows
  select, `ctrl-d` adds the next match as another cursor.

Everything that isn't editing is under the leader key:

| | Vim, Helix | VS Code style |
| --- | --- | --- |
| Leader | `space` | `ctrl-space` |
| Find files | `space f` | `ctrl-space f` or `ctrl-p` |
| Search the project as you type | `space /` | `ctrl-space /` |
| Run a command | `:` | `ctrl-P` picks one, `alt-x` opens the command line |

Language servers start on their own when they're installed; `:health`
shows which ones were found. [Editing styles](runtime/docs/editing-styles.md)
has the keys for each style.

Also in Greed:

- Panes, tabs and floating views with zellij's `alt` keys, and terminals.
- A shell (`:shell`) whose commands become blocks you keep, search and run
  again.
- `greed ssh HOST` shows an editor running on another machine, and several
  terminals and windows can show one session at once.
- Markdown files that compute as you type: fields, formulas, charts under
  tables, and tables read live from CSV, SQLite or PostgreSQL.
- Snippets in VS Code's format: copy in VS Code snippet files, or sets like
  friendly-snippets, and they work as they are.
- Hoard (`greed notes`): your notes and todos as plain Markdown files, on
  a home page with search, today's note and an agenda, usable without
  knowing an editor.

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
headless editor. Plugins draw their own interfaces (lists, fields,
buttons) with `core.ui`, as text you can search and copy like any other;
[Building interfaces](runtime/docs/ui.md) shows how.

## Agents

Agents are clients of the editor, like the terminal is. They read what you
have open (unsaved changes included), see your selections and diagnostics,
and propose edits that show up in the buffer for you to accept or reject.

```bash
claude mcp add greed -- greed mcp     # Greed's tools in Claude Code
codex mcp add greed -- greed mcp      # or Codex, or any MCP client
```

Inside Greed:

| Keys | |
| --- | --- |
| `space i n` | Start an agent: Greed's own, with any model you set up, or Claude Code, Codex, Gemini CLI or opencode over ACP, in the project or in a workspace of its own to review and bring in when it's done |
| `space i C` | Claude Code in a pane, connected to Greed as it is to VS Code; its edits arrive as proposals |
| `space i W` | Claude Code in a pane, in a workspace of its own |

In auto mode, commands that only look, build or test run by themselves,
and a decision model you pick judges the rest or asks you. Agents can
write new plugins too: Greed type checks and tests them, and you review the
code before it loads.

## Install

Each system has one file to download, holding a single `greed` binary.
The links get the latest [release](https://github.com/johnae/greed/releases/latest).

| System | Download | |
| --- | --- | --- |
| Linux, x86_64 | [greed-linux-x86_64.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-linux-x86_64.tar.gz) | terminal and window; any distribution with glibc 2.28 or newer |
| Linux, arm64 | [greed-linux-aarch64.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-linux-aarch64.tar.gz) | the same, for arm64 |
| Linux, terminal only | [x86_64](https://github.com/johnae/greed/releases/latest/download/greed-linux-x86_64-tui-only-static.tar.gz), [arm64](https://github.com/johnae/greed/releases/latest/download/greed-linux-aarch64-tui-only-static.tar.gz) | one static binary for any Linux, servers and NixOS too; no `--gui` |
| macOS, Apple silicon or Intel | [greed-macos.zip](https://github.com/johnae/greed/releases/latest/download/greed-macos.zip) | Greed.app, which opens the window |
| macOS, for the terminal | [greed-macos-universal.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-macos-universal.tar.gz) | the same binary on its own |

The Linux tarballs are laid out like `/usr/local`, with a desktop entry and
an icon, so unpacking one into `~/.local` installs it:

```bash
tar -xzf greed-*-linux-x86_64.tar.gz -C ~/.local --strip-components=1
greed README.md        # in the terminal
greed --gui README.md  # in a window
```

The first start asks how you like to edit and which theme you want. Then
`:tutor` teaches that style's keys, with lines to practise on, and shows
you around Greed.

The macOS builds are signed and notarized by Apple, so Greed.app opens
from a download like any other app.

With [Homebrew](https://brew.sh), on macOS or Linux:

```bash
brew install johnae/greed/greed             # the greed command
brew install --cask johnae/greed/greed-app  # Greed.app, on macOS
```

`brew upgrade` brings each new release.

On NixOS, and anywhere with Nix, the flake has it with gui support:
`nix run github:johnae/greed`, or `.#static` for the static binary (only tui). Both
are built for every release and for main, for x86_64 and arm64 Linux and
Apple silicon macOS (the window build), and kept in a binary cache, so
they download instead of building. `nix run` asks once whether to use
the cache; to use it always, add it to your Nix settings:

```nix
nix.settings = {
  substituters = [ "https://greed.cachix.org" ];
  trusted-public-keys = [
    "greed.cachix.org-1:3KCJ/GtSbnfcfrCNZAe+3vcK8YPc4FZ/2JaYTjAqmnc="
  ];
};
```

Then in a NixOS or home-manager configuration, with the flake as an
input (`inputs.greed.url = "github:johnae/greed";`):

```nix
environment.systemPackages = [ inputs.greed.packages.${pkgs.system}.default ];
# or home.packages, or nixpkgs.overlays = [ inputs.greed.overlays.default ]
# and then pkgs.greed
```

The cache has the builds of the flake's own nixpkgs, so leave out
`inputs.greed.inputs.nixpkgs.follows`, or Nix builds Greed against yours.

To build it yourself you need a recent stable Rust and cmake (for the
WebAssembly runtime that loads downloaded grammars):

```bash
cargo build --release
./target/release/greed README.md
```

The default plugins are built into the binary, so it runs from anywhere.
To use your own copy of them, point `GREED_RUNTIME` at a folder shaped like
`runtime/`. `luau-analyze` is optional and used for type checking plugins.

## Documentation

- [Using Greed](runtime/docs/using.md): editing, searching, files, sessions,
  configuration.
- [Editing styles](runtime/docs/editing-styles.md) and [Keys](runtime/docs/keys.md): the
  Vim, Helix and VS Code styles, and binding your own keys.
- [Several clients](runtime/docs/clients.md): terminals and windows on one
  session, following each other or laid out on their own.
- [The shell](runtime/docs/shell.md): commands as blocks you keep, search and run
  again, sending output to buffers or the next command; agents use it too.
- [Boards](runtime/docs/boards.md) and [Charts](runtime/docs/charts.md): live shell
  commands saved as a page of cards, and any table drawn as a chart.
- [Highlighting](runtime/docs/highlighting.md): how code is highlighted and themed.
- [Writing plugins](runtime/docs/plugins.md): commands, keys, decorations, panels,
  tests and types.
- [Agents](runtime/docs/agents.md): `greed ctl`, MCP, proposals, `/ide`, agents
  inside Greed and plugins written by agents.
- [Permissions and sandboxing](runtime/docs/permissions.md): what agents and
  plugins may do, what asks you, and rules that answer for you.
- [How Greed is built](runtime/docs/design.md): what lives in Rust, what lives in
  Luau, and why.

Or maybe it's Glorified REPL, Editor Eventually Discovered. Either way,
it's early and changes often.

Greed is licensed under the [Mozilla Public License 2.0](LICENSE); parts
from other projects keep their own licenses, listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
