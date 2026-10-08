# Editing styles

Greed comes with three ways to edit, and you can switch between them while
it runs. Each one follows the editor it comes from closely, so what your
hands know works here: Helix's selections and motions, Vim's operators,
text objects, registers, macros and visual modes, the usual shortcuts of
modeless editors. Where one still differs from the original, its section
below says so.

| Style | How it works | Like |
|---|---|---|
| `helix` (the default) | Select text, then say what to do with it | Helix, Kakoune |
| `vim` | Say what to do, then where: `d w`, `c i w`, `y y` | Vim |
| `vscode` | No modes, VS Code's keys: typing inserts, shift and the arrows select | VS Code, most editors |

```text
:style vim        switch now
:style            pick one from a list
```

The status line shows the style's name, dim, on the right; clicking it
opens the same list. The mode on the left reads the way the style's
editor says it: NORMAL, INSERT, SELECT in Helix's, VISUAL in Vim's.

The first time you start Greed it asks which you'd like (`:setup` asks
again). To start in a style every time, set it in `~/.config/greed/init.luau`:

```luau
require("@greed").option.set("editing-style", "vim")
```

The keys that aren't about editing live in the leader, which every style
opens its own way: `space` in Helix and Vim, `ctrl-space` in the vscode style,
where typing a letter inserts it. So `space f` finds files and `space /`
searches the project, and in the vscode style `ctrl-space f` and `ctrl-space /`
do the same; after the leader a hint lists what can follow. Helix and Vim
also share `:` for commands, `g d` to go to a definition and `] d` to the
next problem. Prompts and pickers work the same in all three.

## Keys in every style

Bind keys for the leader or for a role, and they work in whichever style
you use, styles added later included:

```luau
local greed = require("@greed")

greed.keymap.bind({ layer = "leader" }, { w = "save" })          -- space w, or ctrl-space w
greed.keymap.bind({ role = "typing" }, { ["ctrl-s"] = "save" })   -- insert mode, or vscode's mode
greed.keymap.bind({ style = "vim", role = "command" }, { ["g h"] = "line-start" })
```

The roles are `command` (Helix's and Vim's normal mode), `typing`
(insert mode, vscode's mode) and `selecting` (Helix's select mode, Vim's
visual mode). A binding for one style's role wins over the style's own
keys, and those win over a binding for every style's role. [Keys](keys.md#binding-keys)
has the whole order.

## Helix

Normal mode is for moving and selecting, and every movement selects: `w`
selects to the next word, `x` the line, `%` the whole file. Then a command
acts on what's selected: `d` deletes it, `c` changes it, `y` copies it.

```text
x d        select the line, delete it
x x d      select two lines, delete them
% s foo    select every "foo" in the file; typing now edits them all
```

The cursor sits on a character, as in Helix, and is part of what you
select: `v l l` selects three characters, `;` leaves the cursor on the
character it was on, and `d` on a bare cursor deletes that character.
`w`, `b` and `e` move exactly as Helix's do.

With `:set motion-hints true` (off by default), a word motion (`w` `b`
`e` and their WORD forms) numbers the next nine places doing it again
would take you, and typing a number goes there in one key: `w 3` instead
of `w w w w`. In select mode it extends the selection. Right after such a
motion a digit is then a number to jump to rather than the start of a
count; any other key drops the numbers. Vim's style has the same option
for `w b e W B E g e g E`, in normal and visual mode. The nearest three
numbers use the theme's `ui.motion.hint` style and the rest the quieter
`ui.motion.hint.far`; in the window both are drawn as badges, like key caps.
A number sits on the space beside its place when the place is a letter, so
it hides none of the text.

Why it's the default: you see what a command will act on before you run
it, and many selections are part of the model rather than a separate
feature. `s`, `S`, `C` and `alt-s` make selections, and every edit then
happens at each one, which covers most of what macros and
search-and-replace are used for. [Using Greed](using.md#editing) lists
the keys. The style is the `helix` plugin, and its modes are `helix`,
`helix-insert` and `helix-select`.

## Vim

Vim's normal mode works the other way round: an operator first, then a
motion saying how far. `d w` deletes to the next word, `c i w` changes the
word under the cursor, `3 j` moves three lines down. The cursor sits on a
character, and `v` starts a visual mode for selecting by hand.

| Keys | |
|---|---|
| `h j k l` `w b e` `W B E` `g e` `0 ^ $` `g _` `g g` `G` `%` | Move, with counts: `3 w`; `%` to the matching bracket, `50 %` halfway down |
| `{ }` `( )` `H M L` `- + _` `\|` | Paragraphs, sentences, the top, middle or bottom of the screen, lines, a column |
| `f t F T` + a character, `; ,` | To the next or previous character on the line; again, or back |
| `d c y` + a motion or text object | Delete, change or copy; doubled (`d d`) for whole lines |
| `i w` `a w` `i W` `i (` `a "` `i s` `i p` `i t` ... | Text objects: words, brackets (`b` `B` too), quotes, sentences, paragraphs, tags, and the rest of the objects Helix's `m i` takes (`i f` a function, `i d` a number, `i n (` the next parens...) |
| `>` `<` `g c` + a motion | Indent, dedent, comment; `> >` `< <` `g c c` for the line |
| `g ~` `g u` `g U` `g ?` + a motion | Switch case, lowercase, uppercase, rot13 (`~` `u` `U` in visual mode) |
| `g q` `g w` `=` `!` + a motion | Rewrap to the `text-width` option (`g w` keeps the cursor), reindent, pipe through a command |
| `x X D C s S` | The usual shortcuts for deleting and changing |
| `r` `~` `J` `g J` | Replace a character, switch case, join lines (`g J` without adding or removing spaces) |
| `ctrl-a` `ctrl-x` | Add to or subtract from the number at or after the cursor, with counts |
| `p P` | Paste after or before |
| `i a I A o O`, `g i` | Insert; with a count (`3 i`) what you type goes in that many times; `g i` where you last stopped typing |
| `u` `ctrl-r` `U` | Undo, redo, put back the last changed line |
| `g -` `g +` | Back or on through every state of the text, across undo branches (`space u t` shows them all) |
| `v` `V` `ctrl-v` | Visual mode, by character, line or block; `i`/`a` there select a text object |
| `o` `r` `J` `p` in visual mode | Go to the other end, replace every character, join the lines, paste over the selection |
| `g v` `g n` | Select the last visual selection again, or the next search match (`c g n` then `.` changes match after match) |
| `y s` + a motion or object + a character, `d s` `c s`, `S` in visual mode | Surround, as vim-surround does: `ysiw)` wraps the word in brackets (`(` with spaces inside), `ds"` takes the quotes away, `cs"'` changes them, `yss` wraps the line |
| `alt-o` `alt-i` | Select the syntax node around the cursor, growing it in visual mode, or shrink it back |
| `alt-shift-right` `alt-shift-left` | Move the selected syntax node past the next or previous one |
| `K`, `g r n` `g r a` `g r r` `g r i` `g r t`, `g O` | As in Neovim: hover, rename, code actions, references, implementations, type definition, symbols in the file |
| `g s` | Label the words on screen and jump to the one you type |
| `ctrl-n` | Select the word under the cursor, then add its next match each time, as vim-visual-multi does; `c` `d` `y` `i` `a` `I` `A` act on every selection, `ctrl-x` skips a match, `ctrl-p` drops the last, `esc` goes back to one cursor |
| `Z Z` `Z Q` | Save and close, close without saving; in a split, like `:wq` and `:q`, they close just that window |
| `ctrl-^` | The file you were in before, like `:b#` |
| `I` `A` in visual block mode | Type before or after the block on every line (`$` takes it to each line's end) |
| `*` `#` | Search for the word under the cursor, forward or back |
| `ctrl-f` `ctrl-b` `ctrl-d` `ctrl-u` `ctrl-e` `ctrl-y` | Page, half page and a line down and up |
| `z z` `z t` `z b`, `z a` `z c` `z o` `z R` `z M` `z f` `z j` `z k` `z d` `z E` | Center the view, cursor line to the top or bottom; folds |
| `R` | Type over the text; `backspace` puts back what it replaced |
| `g ;` `g ,` | Back and forward through the places you changed |
| `ctrl-o` `ctrl-t` `ctrl-d` `ctrl-n` `ctrl-p` in insert mode | One normal mode command, indent, dedent, complete from words in open files |
| `ctrl-o` `ctrl-i` | Back and forward through where you jumped from |
| `m` + a letter, `'` `` ` `` + a letter | Set a mark (`a`–`z` in the file, `A`–`Z` across files), go to its line or to it |
| `.` | Repeat the last change, with what it typed |
| `q` + a letter, `q` | Record a macro into that register, stop |
| `@` + a letter, `@ @` | Play a macro, play the last one again |
| `"` + a letter | Use that register for the next yank, delete or paste; an uppercase letter appends; `"0` holds the last yank, `"1`–`"9` the last line deletes, `"-` a small one |

Why it's here: Vim's keys are in a lot of people's hands, and switching
editors shouldn't mean relearning them. It also shows how far a plugin can
go: the Vim style is plain Luau against the same API any plugin uses, with
its own modes (`vim`, `vim-insert`, `vim-visual`, `vim-visual-line`,
`vim-visual-block`, `vim-replace`, `vim-multi`) beside Helix's.

The unnamed register is the system clipboard, so `p` pastes what you
copied in another program too; `"+` is the same and `"_` keeps nothing.
Text from another program pastes as it is, even when it ends in a line
break. Panels like the file tree and help keep their own keys.

Line commands with ranges (`:%s/a/b/g`, `:g/regex/d`, `:'<,'>norm A;`)
are on the command line; [Using Greed](using.md#the-command-line) lists
them. Some of Vim is still missing: a copied block pastes as plain
text (one piece per line), and Vim's own regex syntax (`\(`, `\<`) since
patterns are the same regexes search uses.

## VS Code

No modes, VS Code's keys. Typing inserts text, replacing a selection if
there is one, and the keys are the ones VS Code and most editors use.

| Keys | |
|---|---|
| arrows, `home` `end`, `ctrl-left` `ctrl-right` | Move; `home` goes to the first non-blank, then the line's start |
| `pageup` `pagedown`, `ctrl-home` `ctrl-end` | A screen up or down, the start or end of the file |
| `shift` + arrows, `home` `end`, `ctrl-left` `ctrl-right` | Select |
| `ctrl-a`, `ctrl-l` | Select all, select the line (again for the next one) |
| `ctrl-c` `ctrl-x` `ctrl-v` | Copy, cut, paste; with nothing selected, copy and cut take the line |
| `ctrl-z` `ctrl-y` | Undo, redo (`ctrl-shift-z` redoes too, where the terminal can tell it from `ctrl-z`) |
| `tab` `shift-tab`, `ctrl-]` | Indent or dedent the selected lines; `tab` alone types a level of indent |
| `ctrl-backspace` `ctrl-delete` | Delete a word back or forward |
| `alt-up` `alt-down`, `alt-shift-up` `alt-shift-down` | Move the line up or down, copy it up or down |
| `ctrl-shift-k`, `ctrl-enter` `ctrl-shift-enter` | Delete the line, start a new line below or above |
| `ctrl-d`, `ctrl-shift-l` | Select the word, then add its next match as another cursor; select every match |
| `ctrl-alt-up` `ctrl-alt-down`, `alt`-click | Add a cursor above or below, or where you click |
| `ctrl-/` | Comment or uncomment the lines |
| `ctrl-f`, `f3` `shift-f3`, `ctrl-h` | Find, the next or previous match, replace in the file (`:%s/`) |
| `ctrl-g` | Go to a line: type its number |
| `f12` `shift-f12` `f2` `ctrl-.` | Go to the definition, find references, rename, code actions |
| `f8` `shift-f8`, `ctrl-shift-m` | The next or previous problem, all problems |
| `ctrl-shift-o` `ctrl-t` | Go to a symbol in the file, in the project |
| `alt-left` `alt-right` | Back and forward through where you jumped from |
| `ctrl-u` `ctrl-shift-u` | Back to the cursors before the last command, and forward again |
| `ctrl-p` `ctrl-b`, `ctrl-w` | Find a file, switch to an open file, close the file |
| `ctrl-P` or `alt-x` | Run a command |
| `ctrl-space` | The leader: `ctrl-space f` finds a file, `ctrl-space /` searches the project, the rest as `space` in Helix and Vim |
| `ctrl-s`, `ctrl-q` | Save; quit, asking first whether to save unsaved files |

Keys with `ctrl-shift` need a terminal that reports them, such as one with
the kitty keyboard protocol (kitty, WezTerm, foot, Ghostty).

Why it's here: for people who don't want modes, or don't want them yet,
and for the odd edit where modes get in the way. Everything else in Greed
still works, through the leader, `ctrl-P` and the command line (`alt-x`).
Completion comes up as you type; `ctrl-space` is the leader here. The
style is the `vscode` plugin: VS Code's keys over core's editing without
modes, which another modeless keymap can use the same way (see below).

## Making your own

A style is a few modes with keys bound in them, registered with the
`core` plugin. It says which of its modes plays each role and which keys
open the leader, and everything bound for those comes with it, with no
plugin having to know the style exists:

```luau
local greed = require("@greed")

greed.keymap.bind("mine", { j = "move-down", k = "move-up", i = "insert-mode" })
greed.keymap.fallback("mine-insert", "insert-char")

require("@core").style.define({
	name = "mine",
	doc = "My own keys",
	mode = "mine",
	-- Which mode plays each role; insert-mode goes to the typing one.
	roles = { command = "mine", typing = "mine-insert" },
	-- What the status line shows for each mode.
	labels = { mine = "normal", ["mine-insert"] = "insert" },
	-- The keys that open the leader, where `space f` and the rest live.
	leader = "space",
})
```

That's enough for `:style mine` to switch to it and for it to show in the
`:style` list and the setup page. The leader opens with `space`, with the
same hint after it; keys plugins bind for the command role (`:`, `g d`,
`] d`) work in `mine`, and the typing keys every style shares (`enter`,
`backspace`, the arrows, `esc` back to `mine`) in `mine-insert`. The file
tree, pickers, help and other panels keep their keys in it. Completion,
signature help and Markdown shown as written while typing follow the
typing mode; a style without modes makes its own mode the typing one
(`roles = { typing = "mine" }`). `.` works in any style: it types the keys
of the last change again;
`require("@core").commands.tag("no-repeat", { "my-undo" })` leaves out
commands that shouldn't count as one. The Vim plugin in
`runtime/plugins/vim` is a full example.

A style without modes, like a JetBrains keymap, is shorter still: bind
its keys in its one mode, and core's editing without modes (the vscode
style's) does the typing, replacing the selection, and the rest:

```luau
local greed = require("@greed")

greed.keymap.bind("jetbrains", {
	["ctrl-c"] = "copy-or-line",
	["ctrl-v"] = "paste-over",
	["ctrl-d"] = "copy-lines-down",
	["ctrl-y"] = "delete-lines-at-cursor",
	["ctrl-shift-up"] = "move-lines-up",
})

require("@core").modeless.define({
	name = "jetbrains",
	doc = "No modes, JetBrains' keys",
	leader = "ctrl-space",
})
```

Roles decide where keys live, not what commands mean, so two styles still
differ in what `d` does. And Vim's operators read the motion after them
straight from the keyboard, so leader and role keys don't apply between
`d` and its motion.
