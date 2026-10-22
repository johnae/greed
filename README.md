Greed is a modal text editor. It's sort of Helix and Vim and VS Code in one - you
pick the keys - with a shell, terminals and agents built in, and it runs in a
terminal or a window, locally or over ssh.

I wanted an editor I could bend as far as Emacs, without it ever freezing on me
while a plugin thinks. This is that editor.

[![A Rust file with the file tree beside it and a terminal below running kubectl get pods](https://github.com/johnae/greed/releases/download/media/hero.png)](https://github.com/johnae/greed/releases/download/media/hero.mp4)

Something like this:

```text
$ greed src/main.rs          # edit; the session keeps running if you detach
:detach                      # leave it running in the background
$ greed ls
myapp                /home/you/myapp
$ greed attach               # come back to it, here or in a window (--gui)
$ greed ctl focus            # ask the running editor what you're looking at
{ "path": "/home/you/myapp/src/main.rs", "mode": "normal", "style": "vim", "selections": [ ... ], ... }
```

## Why

Because most of what an editor does doesn't need to be in its core. The core is a
small Rust program, and keys, modes, commands, pickers, themes and the agent
support are Luau plugins - you can read them, change them or swap them out while
it runs. And, of course, because it's fun.

## Pick your keys

The first time Greed starts it asks how you like to edit, and `:style` switches
later. Each style follows the editor it comes from, down to text objects,
registers, macros and counts:

- Vim: say what to do, then where. `d w`, `c i w`, `.` to repeat.
- Helix: select first, then act. `x` selects a line, `s` every regex match in it,
  and typing edits all of them at once.
- VS Code: no modes. Typing inserts, shift and the arrows select, `ctrl-d` adds
  the next match as another cursor.

Everything that isn't editing sits under the leader:

| | Vim, Helix | VS Code style |
| --- | --- | --- |
| Leader | `space` | `ctrl-space` |
| Find files | `space f` | `ctrl-space f` or `ctrl-p` |
| Search the project as you type | `space /` | `ctrl-space /` |
| Run a command | `:` | `ctrl-P` picks one, `alt-x` opens the command line |

Language servers just start when they're installed - `:health` says which ones it
found. [Editing styles](runtime/docs/editing-styles.md) has all the keys.

## What else is in there

Quite a bit, actually:

- Panes, tabs and floating views on zellij's `alt` keys, and terminals.
- A shell (`:shell`) where each command becomes a block you keep, search and run
  again.
- `greed ssh HOST` for an editor running on another machine, and several terminals
  and windows on one session.
- Markdown that computes as you type: fields, formulas, charts under tables, and
  tables read live from CSV, SQLite or PostgreSQL.
- Snippets in VS Code's format, so friendly-snippets and the like just work.
- Hoard (`greed notes`): notes and todos as plain Markdown, with a home page,
  today's note and an agenda. An Obsidian vault works as it is, and the agent can
  file your inbox or pull todos out of a meeting.
- Mail (`greed mail`): your IMAP accounts in one fast, searchable list, with HTML
  laid out without loading anything.

## Plugins in Luau

A plugin is a folder with an `init.luau`. This one upper-cases the selections and
puts it on the leader's `U`:

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

Drop it in `~/.config/greed/plugins/upper/` with a `plugin.toml` saying
`name = "upper"`, or run `greed new upper` there to get one with a test. The API is
typed, so `luau-analyze` and `luau-lsp` check your plugin, and `greed test upper`
runs its tests in a headless editor. Plugins can draw their own interfaces too -
[Building interfaces](runtime/docs/ui.md) shows how.

## Agents

Agents are just clients of the editor, like the terminal is. They see what you have
open (unsaved changes too), your selections and diagnostics, and propose edits you
accept or reject in the buffer.

Like so:

```bash
claude mcp add greed -- greed mcp     # Greed's tools in Claude Code
codex mcp add greed -- greed mcp      # or Codex, or any MCP client
```

Inside Greed:

| Keys | |
| --- | --- |
| `space i n` | Start an agent: Greed's own, with any model you set up, or Claude Code, Codex, Gemini CLI or opencode over ACP, in the project or in a workspace of its own |
| `space i C` | Claude Code in a pane, connected to Greed as it is to VS Code; its edits arrive as proposals |
| `space i W` | Claude Code in a pane, in a workspace of its own |

In auto mode, commands that only look, build or test just run, and a model you pick
judges the rest or asks you. Agents can write plugins too - Greed type checks and
tests them, and you read the code before it loads.

## Install

Each system gets one file with a single `greed` binary in it. The links fetch the
latest [release](https://github.com/johnae/greed/releases/latest):

| System | Download | |
| --- | --- | --- |
| Linux, x86_64 | [greed-linux-x86_64.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-linux-x86_64.tar.gz) | terminal and window; any distribution with glibc 2.28 or newer |
| Linux, arm64 | [greed-linux-aarch64.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-linux-aarch64.tar.gz) | the same, for arm64 |
| Linux, terminal only | [x86_64](https://github.com/johnae/greed/releases/latest/download/greed-linux-x86_64-tui-only-static.tar.gz), [arm64](https://github.com/johnae/greed/releases/latest/download/greed-linux-aarch64-tui-only-static.tar.gz) | one static binary for any Linux, servers and NixOS too; no `--gui` |
| macOS, Apple silicon or Intel | [greed-macos.zip](https://github.com/johnae/greed/releases/latest/download/greed-macos.zip) | Greed.app, which opens the window |
| macOS, for the terminal | [greed-macos-universal.tar.gz](https://github.com/johnae/greed/releases/latest/download/greed-macos-universal.tar.gz) | the same binary on its own |

The Linux tarballs are laid out like `/usr/local`, so it should be as
straightforward as:

```bash
tar -xzf greed-*-linux-x86_64.tar.gz -C ~/.local --strip-components=1
greed README.md        # in the terminal
greed --gui README.md  # in a window
```

The first start asks how you like to edit and which theme you want, and `:tutor`
then walks you through that style's keys. The macOS builds are signed and notarized,
so Greed.app opens like any other app.

With [Homebrew](https://brew.sh), on macOS or Linux:

```bash
brew install johnae/greed/greed             # the greed command
brew install --cask johnae/greed/greed-app  # Greed.app, on macOS
```

If you happen to be on NixOS (or using Nix), you can just use the flake:
`nix run github:johnae/greed`, or `.#static` for the terminal-only static binary.
Every release and main are built for x86_64 and arm64 Linux and Apple silicon, and
kept in a binary cache so they download instead of building. To always use it:

```nix
nix.settings = {
  substituters = [ "https://greed.cachix.org" ];
  trusted-public-keys = [
    "greed.cachix.org-1:3KCJ/GtSbnfcfrCNZAe+3vcK8YPc4FZ/2JaYTjAqmnc="
  ];
};
```

Then, with the flake as an input (`inputs.greed.url = "github:johnae/greed";`):

```nix
environment.systemPackages = [ inputs.greed.packages.${pkgs.system}.default ];
# or home.packages, or nixpkgs.overlays = [ inputs.greed.overlays.default ]
# and then pkgs.greed
```

Of note is that the cache has the builds against the flake's own nixpkgs, so leave
out `inputs.greed.inputs.nixpkgs.follows`, or Nix builds Greed against yours.

Building it yourself needs a recent stable Rust and cmake (for the WebAssembly
runtime that loads downloaded grammars):

```bash
cargo build --release
./target/release/greed README.md
```

The default plugins are built into the binary, so it runs from anywhere. Point
`GREED_RUNTIME` at a folder shaped like `runtime/` to use your own copy of them.

## Documentation

- [Using Greed](runtime/docs/using.md): editing, searching, files, sessions, configuration.
- [Editing styles](runtime/docs/editing-styles.md) and [Keys](runtime/docs/keys.md): the three styles, and binding your own keys.
- [Several clients](runtime/docs/clients.md): terminals and windows on one session.
- [The shell](runtime/docs/shell.md): commands as blocks you keep, search and run again.
- [Boards](runtime/docs/boards.md) and [Charts](runtime/docs/charts.md): live shell commands as a page of cards, and any table as a chart.
- [Highlighting](runtime/docs/highlighting.md): how code is highlighted and themed.
- [Writing plugins](runtime/docs/plugins.md): commands, keys, decorations, panels, tests and types.
- [Agents](runtime/docs/agents.md): `greed ctl`, MCP, proposals, `/ide`, and plugins written by agents.
- [Permissions and sandboxing](runtime/docs/permissions.md): what agents and plugins may do, and what asks you.
- [How Greed is built](runtime/docs/design.md): what lives in Rust, what lives in Luau, and why.

Go explore.

## Honestly

It's really early days, so expect some rough edges and things that change between
releases. That said, I use it daily - for code, notes and mail. If something
breaks, create an issue or a pull request ([CONTRIBUTING.md](CONTRIBUTING.md) says
how I like them). Thanks!

Thanks to Helix, (Neo)vim, Emacs and org-mode, zellij, Obsidian and Logseq, which
much of this borrows from. Greed is licensed under the
[Mozilla Public License 2.0](LICENSE); parts from other projects keep their own
licenses, listed in [THIRD-PARTY.md](THIRD-PARTY.md).
