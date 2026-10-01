# Agents

Agents use Kern the way you do, as clients of the running editor. They can
read buffers with your unsaved changes, see what you have selected and what
the language servers report, open files for you, and propose edits that
you review in the buffer. Every tool is also a shell command, for scripts
and agents that prefer a CLI.

## From the shell: `kern ctl`

```bash
kern ctl tools                       # what the editor offers
kern ctl focus                       # the current file, selections, visible lines
kern ctl read path=src/main.rs from_line=10 to_line=20
kern ctl diagnostics
kern ctl eval code='return require("@kern").mode.get()'
```

Arguments are `key=value` pairs (values that parse as JSON are JSON) or one
JSON object. `kern ctl` talks to the running session: the one named by
`$KERN_SESSION`, or the only one running. Each session's socket is readable
only by you and needs a token from a file only you can read.

## Claude Code and other MCP clients

```bash
claude mcp add kern -- kern mcp
```

`kern mcp` connects an MCP client to the running editor. The tools:

| Tool | What it does |
|---|---|
| `focus` | The current file, your selections with their text, the lines on screen |
| `buffers` | Open files and which have unsaved changes |
| `read` | A file as the editor has it, unsaved changes included |
| `diagnostics` | Errors and warnings from language servers |
| `open` | Open a file for you, at a line |
| `propose` | Propose edits for you to review |
| `project` | The project's root folder |
| `eval` | Run Luau inside the editor |
| `plugin_guide`, `plugin_try`, `plugin_install` | Write a plugin (below) |

`eval` can do anything a plugin can. Leave it out of an agent's allowed
tools if you don't want that.

## Reviewing proposed edits

`propose` takes a file and a list of edits, each replacing some exact text
with new text. The old text is struck through in the buffer and the new
text shows after it. Nothing changes until you decide:

| Keys | |
|---|---|
| `] o` `[ o` | Next and previous proposed change |
| `space o a` `space o r` | Accept or reject the changes your selections touch |
| `space o A` `space o R` | Accept or reject every change in the file |
| `space o o` | Pick from every pending change |

Changes follow the edits you make while they wait. The agent waits too, and
then hears which changes went in. Accepted changes are ordinary edits you
can undo.

## Claude Code's `/ide`

Start Kern in a project, start `claude` in the same project, and `/ide`
lists Kern next to any other editors. Once connected:

- Claude Code sees your selection as you move, and `space o m` mentions the
  selected lines to it.
- Its edits arrive as proposed changes, reviewed with the keys above. If
  you accept some of them, Claude Code learns which.
- It can read diagnostics, open files and check for unsaved changes.

Kern writes a lock file to `~/.claude/ide` so Claude Code can find it, and
removes it when the session ends.

## Plugins written by agents

An agent can extend Kern while you work:

1. `plugin_guide` gives it the plugin conventions and the full typed API.
2. `plugin_try` writes a plugin to a staging folder and checks it: strict
   types against the API, then the plugin's own tests in a headless editor.
   The agent gets back what failed and tries again.
3. `plugin_install` asks you. A panel shows the code and the check results;
   `a` installs it into `~/.config/kern/plugins` and loads it right away,
   `r` rejects it.

Ask for something like "a command that jumps from a `use` line to the
crate's entry in Cargo.toml" and the agent goes through these steps. You
only see it once its checks pass.

## Writing your own tools

Any plugin can offer tools; see [Writing plugins](plugins.md#agents).
