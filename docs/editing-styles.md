# Editing styles

Greed comes with three ways to edit, and you can switch between them while
it runs:

| Style | How it works | Like |
|---|---|---|
| `helix` (the default) | Select text, then say what to do with it | Helix, Kakoune |
| `vim` | Say what to do, then where: `d w`, `c i w`, `y y` | Vim |
| `edit` | No modes: typing inserts, shift and the arrows select | VS Code, most editors |

```text
:style vim        switch now
:style            show the style in use and the others
```

To start in a style every time, set it in `~/.config/greed/init.luau`:

```luau
require("@greed").option.set("editing-style", "vim")
```

Helix and Vim share the keys that aren't about editing: `space f` finds
files, `space /` searches the project, `:` runs commands, `g d` goes to a
definition, `] d` to the next problem. Edit mode, where typing a letter
inserts it, reaches the same commands through `ctrl-P` and `alt-x`.
Prompts and pickers work the same in all three.

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
for `w b e W B E g e g E`, in normal and visual mode.

Why it's the default: you see what a command will act on before you run
it, and many selections are part of the model rather than a separate
feature. `s`, `S`, `C` and `alt-s` make selections, and every edit then
happens at each one, which covers most of what macros and
search-and-replace are used for. [Using Greed](using.md#editing) lists
the keys.

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
| `i w` `a w` `i W` `i (` `a "` `i s` `i p` `i t` ... | Text objects: words, brackets (`b` `B` too), quotes, sentences, paragraphs, tags |
| `>` `<` `g c` + a motion | Indent, dedent, comment; `> >` `< <` `g c c` for the line |
| `g ~` `g u` `g U` `g ?` + a motion | Switch case, lowercase, uppercase, rot13 (`~` `u` `U` in visual mode) |
| `g q` `g w` `=` `!` + a motion | Rewrap to the `text-width` option (`g w` keeps the cursor), reindent, pipe through a command |
| `x X D C s S` | The usual shortcuts for deleting and changing |
| `r` `~` `J` `g J` | Replace a character, switch case, join lines (`g J` without adding or removing spaces) |
| `ctrl-a` `ctrl-x` | Add to or subtract from the number at or after the cursor, with counts |
| `p P` | Paste after or before |
| `i a I A o O`, `g i` | Insert; with a count (`3 i`) what you type goes in that many times; `g i` where you last stopped typing |
| `u` `ctrl-r` `U` | Undo, redo, put back the last changed line |
| `v` `V` `ctrl-v` | Visual mode, by character, line or block; `i`/`a` there select a text object |
| `o` `r` `J` `p` in visual mode | Go to the other end, replace every character, join the lines, paste over the selection |
| `g v` `g n` | Select the last visual selection again, or the next search match (`c g n` then `.` changes match after match) |
| `y s` + a motion or object + a character, `d s` `c s`, `S` in visual mode | Surround, as vim-surround does: `ysiw)` wraps the word in brackets (`(` with spaces inside), `ds"` takes the quotes away, `cs"'` changes them, `yss` wraps the line |
| `alt-o` `alt-i` | Select the syntax node around the cursor, growing it in visual mode, or shrink it back |
| `alt-shift-right` `alt-shift-left` | Move the selected syntax node past the next or previous one |
| `K`, `g r n` `g r a` `g r r` `g r i` `g r t`, `g O` | As in Neovim: hover, rename, code actions, references, implementations, type definition, symbols in the file |
| `g s` | Label the words on screen and jump to the one you type |
| `ctrl-n` | Select the word under the cursor, then add its next match each time, as vim-visual-multi does; `c` `d` `y` `i` `a` `I` `A` act on every selection, `ctrl-x` skips a match, `ctrl-p` drops the last, `esc` goes back to one cursor |
| `Z Z` `Z Q` | Save and close, close without saving |
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
Panels like the file tree and help keep their own keys.

Line commands with ranges (`:%s/a/b/g`, `:g/regex/d`, `:'<,'>norm A;`)
are on the command line; [Using Greed](using.md#the-command-line) lists
them. Some of Vim is still missing: a copied block pastes as plain
text (one piece per line), and Vim's own regex syntax (`\(`, `\<`) since
patterns are the same regexes search uses.

## Edit

No modes. Typing inserts text, replacing a selection if there is one, and
the keys are the ones most editors use.

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
| `ctrl-s` | Save |

Keys with `ctrl-shift` need a terminal that reports them, such as one with
the kitty keyboard protocol (kitty, WezTerm, foot, Ghostty).

Why it's here: for people who don't want modes, or don't want them yet,
and for the odd edit where modes get in the way. Everything else in Greed
still works, through `ctrl-P` and the command line (`alt-x`).

## Making your own

A style is a mode with keys bound in it, registered with the `core`
plugin. Its keys can borrow from Helix's normal mode, so `space`, `:` and
the rest keep working:

```luau
local greed = require("@greed")

greed.keymap.bind("mine", { j = "move-down", k = "move-up", i = "insert-mode" })
greed.keymap.inherit("mine", "normal", { "space", ":" })
-- The file tree, help and other panels keep their keys.
greed.keymap.inherit_kinds("mine", "normal")

require("@core").style.define({
	name = "mine",
	doc = "My own keys",
	mode = "mine",
	plugin = "mine",
})
```

`esc` in insert mode comes back to the style's mode, and `:style mine`
switches to it. `.` works in any style: it types the keys of the last
change again; `require("@core").again.ignore({ "my-undo" })` leaves out
commands that shouldn't count as one. The Vim plugin in `runtime/plugins/vim` is a full example.
