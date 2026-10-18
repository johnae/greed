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

```text
Hoard  Sunday 18 October

Search: [      ]

Add a todo: [      ]          Jot down: [      ]

╭─ Today ──────────────────────────────────────╮
│ met Anna about the garden                    │
│  Open today's note                           │
╰──────────────────────────────────────────────╯

╭─ Agenda ─────────────────────────────────────╮
│ Overdue                                      │
│ ☐ fix the fence  10 Oct                      │
│ Today                                        │
│ ☐ buy seeds                                  │
╰──────────────────────────────────────────────╯

 Inbox: 2 todos    All todos

Recent notes
  Garden plans  garden
```

## On the home page

Move between the boxes and buttons with `tab` and `shift-tab`, and press
one with `enter` or a click.

- **Search** finds notes by their title, the headings in them and open
  todos. Pick one to open it there.
- **Add a todo** puts a todo in today's note, and understands plain words
  for when (below); **Jot down** adds a line to it, for anything that
  isn't a todo.
- **Today** shows today's note. Each day gets a note of its own, made the
  first time you write in it.
- **Agenda** lists what's overdue, due today and due in the next week. The
  box ticks a todo off; the words open its note.
- **Inbox** opens the note todos are captured to from elsewhere, and
  **All todos** lists every open todo, soonest first.
- **Recent notes** are the ones changed last.

`:hoard` shows the home again from anywhere (`ctrl-space n h`, or `space n h`
with Vim's or Helix's keys).

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
after you stop typing, and `ctrl-z` undoes. If you already use one of
Greed's editing styles, set it in your config and Hoard uses it too.

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
