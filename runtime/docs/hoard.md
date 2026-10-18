# Hoard: notes and todos

Hoard is where your notes, todos and today's plans live. It opens on a
home page with what's due, what you wrote today and a search over
everything, and you don't need to know an editor to use it.

```bash
greed notes          # in this terminal
greed --gui notes    # in a window
```

Running it again comes back to the same Hoard, with everything as you
left it.

From Greed itself, `:hoard` (`space n h`) takes the window you're in to
Hoard, starting it if needed, and `space B` brings you back.
`:hoard-window` (`space n H`) opens Hoard in a window of its own instead,
leaving this one as it is.

Hoard has no modes, so `:` types; `ctrl-g` opens the command line and
`ctrl-shift-p` the list of commands.

```text
Hoard  Sunday 18 October

╭─ Agenda ─────────────────────────────────────╮
│ Overdue                                      │
│ ☐ fix the fence  10 Oct                      │
│ Today                                        │
│ ☐ buy seeds                                  │
╰──────────────────────────────────────────────╯

 Inbox: 2 todos    All todos

Recent notes
  Garden plans  garden

╭─ Today ──────────────────────────────────────╮
│ met Anna about the garden                    │
│  Open today's note                           │
╰──────────────────────────────────────────────╯

╭─ Write a thought, or search ─────────────────╮
│ [] call the bank tomorrow 18:00              │
│ the shed needs paint before winter           │
╰─ [] makes a todo ── Add to today, alt-enter ─╯
```

## On the home page

The box at the bottom is where you write; the cursor is in it when Hoard
opens. Write as much as you like (`enter` starts a new line), then
`alt-enter` or `ctrl-enter` (or a click on **Add to today**) adds it to
today's note:

- A line starting `[]` becomes a todo, and understands plain words for
  when (below): `[] call the bank tomorrow 18:00`.
- Anything else goes in as you wrote it; a single line becomes a list item.
- `/` and `[[` work as they do in notes (below).

While what you write is one line, notes matching it show above the box:
by their title, the headings in them and open todos. Above that:

- **Agenda** lists what's overdue, due today and due in the next week.
  Today's part also has the todos you wrote today without a date. The
  box ticks a todo off; the words open its note; **when** (or `alt-d` on
  the line) moves it to today, tomorrow, the weekend, next week or no
  date, or to a day you type in plain words, like `friday` or `in 3 days`.
- **Inbox** opens the note todos are captured to from elsewhere, and
  **All todos** lists every open todo, soonest first.
- **Recent notes** are the ones changed last.
- **Today** shows what you wrote in today's note, its todos being in the
  agenda. Each day gets a note of its own, made the first time you write
  in it.

To move about with the keyboard, `up` from the top of the box goes to the
nearest thing above it, the best match while you search. `up` and `down`
(or `tab` and `shift-tab`) then go from one thing to the next, the one
you're on lit up, and `enter` opens or presses it. `down` past the last
one, or `esc`, comes back to the box, and typing goes to the box from
anywhere. With the mouse, click what you want.

From a note, `esc` goes back to the home (when something is selected,
the first `esc` lets go of it). The status line at the bottom starts
with `‹ Hoard`, which does the same when clicked. `alt-left` goes back to
where you were before, as in a browser, and `alt-right` forward again.

## Writing notes

A note is a page of text. A line starting with `#` is a heading, `- ` makes
a list, and `- [ ]` a todo:

```markdown
# Garden plans

- [ ] buy seeds due:2026-10-20
- [ ] fix the fence remind:2026-10-19 18:00
- the shed needs paint
```

- `due:` gives a todo a date, for the agenda, and `every:monday` makes it
  repeat: ticking it off brings it back for the next Monday (`day`,
  `weekday`, `week`, `month` and `year` work too).
- `remind:` gives anything a reminder, with a time or for the morning. It
  shows in Greed and on your desktop when it's due.
- `[[Garden plans]]` links to another note; `F12` on it opens it, making
  it if it's new (`g d` with Vim's or Helix's keys). Each note lists the
  notes that link to it at its end.
- `#garden` tags a note, and a todo or line in it.
- `/` at the start of a word opens a menu of these: todo, today's or
  tomorrow's date, due, remind, every, link, heading, table and tag. Pick
  one and fill in its places, `tab` going from one to the next.

Hoard types as you'd expect: keys type, notes save on their own a moment
after you stop typing, and `ctrl-z` undoes. That holds even if you use
Vim's or Helix's keys in the rest of Greed; to have them in Hoard too:

```luau
greed.option.set("hoard-editing-style", "same")
```

Notes have no line numbers, and Markdown's language servers don't run on
them: harper-ls, for one, checks spelling and grammar as English, whatever
language you write in. `greed.option.set("hoard-language-servers", true)`
turns them on.

## Links, embeds and Obsidian

Links can go to a place in a note as well as the note itself:

```markdown
See [[Garden plans#Seeds]] for the list, and [[Garden plans#^fence|the fence]].

![[Garden plans#Seeds]]
```

- `[[note#Heading]]` goes to a heading, and `[[note#^id]]` to a line
  ending in `^id`. `[[#Heading]]` is a heading in the same note.
- `[[note|other words]]` shows the other words in its place.
- `![[note]]` shows the note right there, under the line, and keeps it
  current as the note changes. `![[note#Heading]]` shows that section and
  `![[note#^id]]` that line, with what's under it in a list. Long ones are
  cut short.
- Typing `[[` lists your notes, and their other names, as you type, and
  the closing `]]` comes along. After a note's name, `#` lists its
  headings and `#^` its list items and lines. You don't write ids: a line
  you link to gets one at its end, like `^3fa2c1`, when you pick it.
- `ctrl-space n k` (`space n k` with Vim's or Helix's keys) does the same
  from all your notes at once: pick a heading, a list item or a line and
  the link goes where you are.
- Renaming a note, or moving a folder of them (`:file-rename`, or from the
  file list), changes the links to them in your other notes.

A folder Obsidian writes works as it is: `aliases:` in a note's front
matter (`aliases: [w42, this week]`) are other names links can use, in
any case; `#tags`, `key:: value` fields and the Tasks plugin's dates
(`📅 2026-10-20` is a due date) are read too. Canvas files aren't.

## Saying when in plain words

A todo you add on the home page or with `space n c` can say when in plain
words, and Greed writes the date for you:

| You type | It's |
|---|---|
| `call the bank tomorrow 18:00` | due tomorrow, with a reminder at 18:00 |
| `dentist on friday at 9` | due Friday, reminder at 09:00 |
| `renew passport in 3 weeks` | due in three weeks |
| `party 31 dec`, `trip jan 5`, `report 2026-11-02` | due that day |
| `plan the trip next week` | due next Monday |
| `movie tonight` | due today, reminder at 20:00 |
| `water plants every monday` | due Monday, and every Monday after |
| `pay rent every month on the 1st` | due on the 1st, every month |

Times can be `18:00`, `6pm` or `at 6`; a time alone is today's, or
tomorrow's once it has gone by. The words are English for now.

## Adding from anywhere

From any shell, without opening anything:

```bash
greed capture call the bank tomorrow 18:00
greed capture --note the plumber comes at noon
```

The first adds a todo to today's note, read as above; `--note` adds a
line that isn't a todo.

## Today's note from a template

Each day's note starts as `templates/daily.md` in your notes folder says,
when there is one. `{{date}}` becomes the date (`2026-10-18`) and
`{{day}}` the day in words (`Sunday 18 October`):

```markdown
# {{day}}

## Plans

## Notes
```

## Where your notes are

Your notes are plain text files (Markdown) in a folder, `~/notes` unless
you set another:

```luau
greed.option.set("notes-folder", "~/Documents/notes")
```

Nothing is kept anywhere else, so the folder works with git, Syncthing or
any other program, and stays readable without Greed. Notes changed by
other programs show up within a few seconds.

The [notes section](using.md#notes) of Using Greed has the rest: keys for
notes in the editor, reminders, notes in projects and agents working with
your notes.
