# Hoard: notes and todos

Hoard is where your notes, todos and today's plans live. It opens on a
home page with what's due, what you wrote today and a search over
everything, and you don't need to know an editor to use it.

[![Hoard's home page with the agenda and today's note, a todo written in plain words added for tomorrow, the notes searched as words are typed, then a question about when the plumber comes answered by the agent with links to the notes it read](https://github.com/johnae/greed/releases/download/media/hoard.png)](https://github.com/johnae/greed/releases/download/media/hoard.mp4)

```bash
greed notes          # in this terminal
greed --gui notes    # in a window
```

Running it again comes back to the same Hoard, with everything as you
left it. The first time, the home starts with where your notes are kept
and how to add to them, until you press `Got it`.

Your notes are plain Markdown files in a folder, `~/notes` unless you
set another in your config (`~/.config/greed/init.luau`). An Obsidian
vault works as it is: its links, tags, front matter, daily notes and
templates are read the way Obsidian reads them.

```luau
greed.option.set("notes-folder", "~/Documents/My vault")
```

This page starts with the everyday parts: the home page, writing notes,
saying when things are due and repeats. Further down are links and
Obsidian, queries, templates and having Greed's agent help.

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
- Starting with `?` asks your notes a question instead (see "Having the
  agent help" below).

While what you write is one line, what matches it shows above the box:
notes with those words anywhere in them, headings and todos, the last
word matching as you type it. It takes a query too, like `is:overdue` or
`tag:garden is:todo` (see "Lists that keep themselves" below). Above
that:

- **Agenda** lists what's overdue, due today and due in the next week.
  Today's part also has the todos you wrote today without a date. The
  box ticks a todo off; the words open its note; **when** (or `alt-d` on
  the line) moves it to today, tomorrow, the weekend, next week or no
  date, or to a day you type in plain words, like `friday` or `in 3 days`.
- **From before** brings back what you'd otherwise forget (see "Looking
  back" below).
- **Inbox** opens the note todos are captured to from elsewhere,
  **Agenda note** opens a note of queries for what's due (made the first
  time, then yours to change; see "Lists that keep themselves" below), and
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
  repeat (below).
- `remind:` gives anything a reminder, with a time or for the morning, as
  many as you like. It shows in Greed and on your desktop when it's due.
- `[[Garden plans]]` links to another note; `F12` on it opens it, making
  it if it's new (`g d` with Vim's or Helix's keys). Each note lists the
  notes that link to it at its end.
- You don't have to link while you write. When a line names another note
  (its name, title or another name it goes by), like "talked to Anna
  about the garden plans" with a note called Garden plans, the line says
  so at its end: `↗ Garden plans`. `ctrl-.` (`space a` with Vim's or
  Helix's keys), or a click on it, makes those words a link, kept as you
  wrote them. Each note also lists the notes mentioning it without a
  link, under "Mentioned in".
- `#garden` tags a note, and a todo or line in it. `#garden/seeds` is a
  tag under it. `:notes-tag-rename garden yard` renames a tag in every
  note, the tags under it and front matter's `tags:` too.
- `/` at the start of a word opens a menu of these: todo, today's or
  tomorrow's date, due, remind, every, link, heading, table and tag. Pick
  one and fill in its places, `tab` going from one to the next.

### Lists and sections as an outline

A list item takes the items under it along, and a heading its section:

- `tab` on an item's first line puts it under the item before, and
  `shift-tab` takes it back out, with what's under it.
- `alt-up` and `alt-down` move the item past the one beside it, or a
  section past the one beside it, keeping the blank lines between.
- `ctrl-space z` zooms in to the item or section the cursor is in and
  shows only it, following it as you add to it; `ctrl-space Z` or `esc`
  zooms out again. (`space z` and `space Z` with Vim's or Helix's keys.)
- `ctrl-k ctrl-l` folds an item or a section under its first line, or
  unfolds it (`tab` or `z a` with Vim's or Helix's keys).

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
- `![[beach.png]]` shows the picture in the window (and in terminals that
  show pictures), found as Obsidian finds it: beside the note, in
  Obsidian's attachments folder or anywhere in your notes by its name.
  `![[beach.png|300]]` makes it 300 pixels wide at most.
- Typing `[[` lists your notes, and their other names, as you type, and
  the closing `]]` comes along. After a note's name, `#` lists its
  headings and `#^` its list items and lines. You don't write ids: a line
  you link to gets one at its end, like `^3fa2c1`, when you pick it.
- `ctrl-space n k` (`space n k` with Vim's or Helix's keys) does the same
  from all your notes at once: pick a heading, a list item or a line and
  the link goes where you are.
- Renaming a note, or moving a folder of them (`:file-rename`, or from the
  file list), changes the links to them in your other notes.
- `[mail](mail:ID)`, which `T` in [mail](mail.md) writes in a todo, opens
  that message's thread in Greed.

[![A note from an Obsidian vault with its properties, a callout, links shown as their words, a section of another note embedded, and a notes block of the garden's open todos that gains a row as a todo is written](https://github.com/johnae/greed/releases/download/media/obsidian.png)](https://github.com/johnae/greed/releases/download/media/obsidian.mp4)

A folder Obsidian writes works as it is. Links find notes as Obsidian
finds them: `[[Cards view]]` goes to `Bases/Cards view.md` wherever it
is, in any case and with or without `.md`, and `[[Layouts/Cards view]]`
the note whose path ends that way; when several notes have that name, the
one in the linking note's folder wins, then the one nearest the top. In a
table, `[[note\|words]]` is a link with other words. Links in
front matter (`categories: ["[[Movies]]"]`) count as links too.
`aliases:` in a note's front matter (`aliases: [w42, this week]`) are
other names links can use, in any case; `#tags`, `key:: value` fields and
the Tasks plugin's dates (`📅 2026-10-20` is a due date) are read too.
Canvas and Bases files aren't. Today's note goes where Obsidian's daily
notes are set to keep it (their folder, name and template, in
`.obsidian/daily-notes.json`), and its templates folder is the one
Obsidian uses.

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
| `water plants every monday and thursday at 18` | each Monday and Thursday, reminder at 18:00 |
| `pay rent every month on the 1st` | due on the 1st, every month |
| `backup every 2 weeks until december` | every other week, until the end of December |
| `vitamins every day! at 8 and 20` | a habit: every day, reminders at 08:00 and 20:00 |
| `stretch every weekday! at 10:30 from nov 2` | a habit on weekdays, from 2 November |

Times can be `18:00`, `6pm` or `at 6`, several with `and`; a time alone
is today's, or tomorrow's once it has gone by. The words are English for
now.

## Repeats, habits and reminders

A todo repeats with `every:` and how often: `day`, `weekday`, `week`,
`month`, `year`, weekdays (`monday` or several, `mon,thu`), or a count
(`2weeks`, `3days`). `from:` and `until:` say when it starts and stops;
without them it repeats until you change the line.

```markdown
- [ ] pay rent every:month due:2026-11-01 remind:09:00 until:2027-06-30
- [ ] vitamins every:day! remind:08:00 remind:20:00
- stretch every:weekday remind:10:30 remind:15:00 from:2026-11-01
```

- A repeating todo is one thing to do at a time. Ticking it off brings the
  next one back under it, due on its next date after the one it was due
  on, so a missed one stays overdue until you catch up.
- A habit, `every:` with a `!` after it, comes up on each of its days
  whatever happened the day before. Ticking it says it's done for today
  (`done:2026-10-18` on the line); the box stays, for its next day. A
  habit is on the agenda each of its days until it's done.
- A reminder with a time alone, `remind:10:30`, goes off on the line's
  own days: a todo's due date, each day the line repeats on, or every day
  on a line that says neither. Give a line as many as you like.
- Notes from Obsidian's Tasks plugin repeat too: `🔁 every week on Monday`
  is `every:monday`, and `🛫 2026-11-01` is `from:`.

## Looking back

Notes are only worth keeping if they come back. The home's **From
before** shows:

- what you wrote a week, a month and a year ago, from those days' notes;
- **Remember this?**: a note you haven't changed in a month or more, a
  different one each day;
- **Waiting a while**: todos without a date in notes untouched for three
  weeks or more, with their box and **when**, to do, date or drop.

**Review the week** (`ctrl-space n w`, `space n w` with Vim's or Helix's
keys) writes a note for the week, `reviews/2026-W42`, and opens it: what
you ticked off, what's overdue, what's coming in the next week, what has
waited, the inbox, and the notes you wrote. It's written once a week, so
what you add to it, under **Thoughts** or anywhere, stays.

Ticking a todo off writes the day on it, `done:2026-10-18`, which is how
the review knows; unticking takes it away.

## Lists that keep themselves: queries

A `notes` block in any note lists what its query finds, and keeps it
current as your notes change:

````markdown
```notes
is:todo is:open due:..+7d sort:due
```
````

The query is the one Greed searches with everywhere: words, `field:value`,
`-` for not, `OR` for either, and `( )` to group.

| You write | It finds |
|---|---|
| `is:todo is:open due:..+7d sort:due` | what's due in the next week, soonest first |
| `is:overdue OR is:waiting` | what's late, and what has waited a long time |
| `is:todo in:(tag:garden) -is:done` | open todos in notes tagged garden |
| `is:note tag:meeting date:2w..` | meetings in the last two weeks |
| `is:note has:(is:todo is:open)` | notes with something still to do |
| `is:habit` | your habits |
| `done:this-week` | what you ticked off this week |

- What: `is:note`, `is:todo`, `is:heading`.
- Todos: `is:open`, `is:done`, `is:overdue`, `is:today` (as the agenda's
  Today has it), `is:due-today`, `is:habit`, `is:recurring`, `is:waiting`.
- Fields: `title`, `note`, `tag` (a todo has its note's tags too), `due`,
  `done`, `starts`, `until`, `every`, `date` (front matter's `date:`, a
  day's note's day, or when a note last changed), `modified`, and your own
  `key:: value` fields and front matter. A list in front matter matches
  each of its values, and a link by its note's name: `genre:sci-fi` finds
  `genre: ["[[Sci-fi]]", Noir]`. A field whose values are all dates is a
  date (`read:<2023`), as is one Obsidian's property types call a date.
- Where: `in:NAME` or `in:(query)` for what's in a note, `has:(query)` for
  notes holding something.
- `sort:due`, `sort:-date` (newest first) and `limit:20` say how to list
  them.

To tick a todo the block lists, open its table (`enter` on its top
border, or `:data-open` on the block) and `enter` on the todo: `Tick or
untick` ticks it in its note, and `Open` goes to it.

A query with a mistake says what's wrong where its results would be. The
agent can ask the same questions (`notes_query`), so "what's overdue in my
garden notes?" gets the same answer.

## Adding from anywhere

From any shell, without opening anything:

```bash
greed capture call the bank tomorrow 18:00
greed capture --note the plumber comes at noon
```

The first adds a todo to today's note, read as above; `--note` adds a
line that isn't a todo.

## Templates

Each day's note starts as `templates/daily.md` in your notes folder says,
when there is one. `{{date}}` becomes the date (`2026-10-18`), `{{day}}`
the day in words (`Sunday 18 October`), `{{title}}` the note's name and
`{{time}}` the time:

```markdown
# {{day}}

## Plans

## Notes
```

Each note in the templates folder is a kind of note you can start from,
named without its "Template". With `templates/Meeting Template.md` holding

```markdown
---
categories:
  - "[[Meetings]]"
date: {{date}}
people: []
---
## Agenda
```

`:notes-new` (`ctrl-space n n`, `space n n` with Vim's or Helix's keys)
asks which kind (`Meeting`), then the name, and opens the new note filled
in. `:notes-type` (`ctrl-space n y`) in a note you have gives it the kind's
fields it's missing, with the template's values, and leaves the ones it
has alone. Tagging a note with a kind's name (`#meeting`, or `meeting` in
its `tags:`) does the same through a hint on that line: `⊕ Meeting:
ctrl-. adds date, people` (`space a` with Vim's or Helix's keys).

In front matter, typing a key at the start of a line lists the keys your
notes use, and after `key: ` (or `- ` under a key) the values they give
it, most used first.

## Having the agent help

Write `?` and a question in the box on the home page and press
`alt-enter`: Greed's agent answers from your notes and links where each
part of the answer came from.

```text
? when is the plumber coming
```

`:notes-agent` (`ctrl-space n j`, `space n j` with Vim's or Helix's
keys) picks other jobs for it:

| Job | What it does |
|---|---|
| `connect` | Links the inbox (or the note you're in) to your other notes, adds tags and context (`ctrl-space n l`) |
| `todos` | Pulls the todos out of the note you're in, a meeting's say, under `## Todos` |
| `ask` | Answers a question from your notes (`:notes-ask QUESTION`) |
| `week` | Sums up the week from what you wrote, in the week's review |

The agent's transcript opens beside you. Whatever it changes in a note
you have comes to you as a proposed edit to accept or reject; it doesn't
delete anything.

`connect` and `week` can also run on their own, when you set a schedule
in your config:

```luau
greed.option.set("notes-agent-schedule", "week friday 16:00, connect weekdays 08:00")
```

The day is `daily`, `weekdays` or a weekday's name. A run Greed was
closed for happens when it next starts that day, and a run with nothing
new to work on (an inbox unchanged since the last one) is skipped, so
the model isn't asked for nothing. With several Greed sessions open, one
of them runs the schedule. What a scheduled run changes waits for your
review like any other.

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
