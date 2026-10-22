# Changelog

What changed in each release of Greed. The commits behind each line are in
the repository's history.

## Unreleased

- core: optional file-pane column rulers with `greed.option.set("rulers", {80, 100})`, empty by default and drawn beneath text backgrounds in terminals and windows; guides stay aligned to one-based text columns through horizontal scrolling, scaled text and offscreen columns. Options also support sorted, unique positive integer lists.

## 0.3.0 - 2026-10-22

### Highlights

- Hoard (`greed notes`): your notes and todos on a home page with today, the agenda and a search over everything; todos in plain words (`call the bank tomorrow 18:00`), repeats, habits and reminders.
- An Obsidian vault works as it is: links, aliases, embeds and pictures, callouts, front matter, daily notes, templates and the Tasks plugin's dates.
- Mail (`greed mail`): your IMAP accounts (Gmail, and Proton through Bridge) in a local copy, searched as you type, offline too; threads, HTML laid out with nothing loaded, writing in Markdown, invites, rules and undo.
- One query language for notes, mail and the shell's filters (`is:todo due:..+7d`, `in:inbox from:anna`), checked as you type, and notes blocks that keep a list of what a query finds.
- Agents in both: ask your notes a question, pull the todos out of a meeting, sum up the week, ask which mail needs an answer; jobs can run on a schedule, and what they change waits for your review.
- A mail becomes a todo in your notes, linking back to its thread.
- The shell reads more commands as tables (free, ss, ip, mount, uptime, ping, test runs, git's branches and stashes), and `parse` turns any text into a table with a sikt program.
- A session that crashed or was upgraded comes back as it was; one you quit starts clean.

### New

- core: greed.sikt reads rows out of text with sikt programs, on other threads for many texts
- core: a sikt program's rows can hold each capture as the text it matched
- shell: parse reads text as a table with a sikt program, and a parser can be one
- shell: free, ss, ip, mount, uptime, ping, test runs, who, env and git's branches, remotes and stashes read as tables
- core: :w! makes a folder that isn't there, as :wa!, :wq! and :wqa! do
- core: reading dates in plain words moves to core, for notes, queries and the rest
- core: one query language: a query parsed into a tree, with its mistakes, and printed back
- core: a date in a query read as the days it covers: today, 2w, eow, monday, last week, 2026-10
- core: a query checked against its source and run over items: fields, flags, dates, places, sorting
- index: queries run over rows in Rust, with maybe for what only Luau can tell
- index: an index on SQLite: items in items, fields and flags, words in FTS5, searched with the same rules
- index: greed.index: indexes Luau reads and writes, on another thread
- core: a search box for queries: colours, the live *, mistakes, counts, tab and history
- index: words and values match without minding accents: cafe finds Café
- core: in: naming nothing says so, with the name likely meant; tab completes names
- query: an item can be in several places, as a mail in its labels, and in: finds it there
- core: greed.fs.scan lists a folder's files with sizes and times, and reads them, in the background
- core: core.file.on_changed hears what Greed writes, moves and removes
- notes: an index of every note, kept current: titles, outline, todos, tags, links, fields, reminders
- hoard: greed notes opens Hoard, a home for your notes: search, today, the agenda, adding todos
- notes: todos say when in plain words, like tomorrow 18:00 or every monday, and repeating todos come back
- hoard: greed capture adds to today's note from any shell, and today's note starts from a template
- lsp: a completion source can ask to be asked first
- hoard: / in a note offers a todo, dates, a reminder, a repeat, a link, a heading, a table or a tag
- notes: links go to headings, blocks and aliases as Obsidian writes them, and the Tasks plugin's due dates count
- notes: embeds show the note, section or block in place
- notes: :notes-link links to a heading, list item or block, giving it an id
- notes: renaming a note or folder changes the links to it
- hoard: [[ completes notes, their headings and blocks as you type
- hoard: modeless and without line numbers or spelling servers, unless set otherwise
- hoard: the status line and going back lead home from a note
- hoard: the home is a box to write in, adding to today and searching as you type
- hoard: :hoard goes to Hoard's session from anywhere, :hoard-window in a window of its own
- hoard: the arrows move about the home, and the widget you're on lights up
- hoard: esc in a note goes back to the home
- hoard: todos written today are on the agenda, and the box fits its width
- hoard: a todo on the agenda moves to another day with its when button or alt-d
- notes: repeats on several days or every few, habits, from and until, and reminders at a time alone
- core: quick-fix asks plugins first, then the language server
- notes: a line names the notes it mentions, the quick fix links them, and notes list where they're mentioned
- hoard: the home brings back old notes and waiting todos, and the week gets a review
- markdown: list items and sections move, indent and zoom with what's under them
- notes: notes, todos and headings answer queries, and agents can ask them
- notes: a notes block in a note lists what its query finds, as the notes change
- hoard: the home's search reads an index of everything the notes say, and takes queries
- core: greed.fs.write can write in the background, so a slow disk doesn't hold the editor
- hoard: the first time, the home says where notes are and how to add to them
- notes: a todo a notes block lists is ticked from its row, as a data source's row offers what can be done with it
- hoard: the agenda as a note of queries, made the first time and then yours to change
- markdown: Obsidian's callouts show their sign and title, their bar in their kind's colour
- notes: front matter's lists and links are fields queries read, and its date is the note's
- notes: in an Obsidian vault, today's note goes where its daily notes settings say, from their template
- notes: note kinds from templates, and front matter completion
- notes: agent jobs: pull out todos, ask your notes, sum up the week
- notes: rename a tag in every note
- notes: picture embeds, found as Obsidian finds attachments
- notes: a tag naming a note kind offers its missing fields
- notes: agent jobs on a schedule, skipped when there's nothing new
- restore: a session that was quit starts clean, one that crashed or was upgraded comes back
- mail: greed-mail: accounts, logging in over TLS, what a server can do, its mailboxes
- mail: the store and the first sync: headers newest first, by UID range, a batch at a time
- mail: flags and labels kept up to date, messages gone from the server go, Bridge's labels as places
- mail: bodies: each message's text, its HTML packed and what's attached, unread first
- mail: threads: replies join what they reply to, in whichever order they come
- mail: the index: messages and threads by words, places, fields and flags, kept up with the store
- mail: greed-mail serve: syncs in the background, answers search results and threads over JSON-RPC
- mail: :mail searches your mail as you type and reads its threads, from greed-mail
- mail: new mail comes at once through IDLE; a failing account is tried again, later each time
- mail: greed mail opens mail in a session of its own on a full page; a quick look elsewhere
- mail: mark read, flag, archive and trash; changes show at once and go to the server each round
- mail: write, reply and send mail over SMTP; a copy in Sent, the original marked answered
- mail: tags: keywords on plain IMAP, shown in the list, t to set or take off; Proton and Gmail wait
- mail: HTML mail laid out as styled text in Greed, its links opened from it; h for its text, b for a browser that loads nothing
- mail: attachments open from a thread or save where you say, fetched whole the first time
- mail: a list shows a thread once, its changes made to the messages found
- mail: saved searches over the list, their unread counted as mail comes; g 1 to g 9
- mail: rules for new mail: a query and what to do with what it finds, in Luau
- mail: T makes a todo of a message, linking back; mail: links open its thread
- mail: invites read as a card; accept, maybe or decline answers the organizer
- mail: the quick look elsewhere changes mail through the mail session
- mail: z undoes the last change or takes back mail just sent; deleting for good asks
- mail: a thread opens on what's new, older messages and long quotes folded; o shows all
- mail: writing mail: From by who it went to, aliases, addresses completed from your mail, attachments
- mail: tags set as Gmail labels, and Proton labels once an account turns them on
- mail: aliases are you: is:mine, invites to them, and never offered as contacts
- mail: the list says what greed-mail is busy with: a bar while indexing, how much is in while syncing
- mail: what's written is kept as a draft as you go; :mail-drafts writes one again, z reopens mail taken back
- mail: space . acts on the mail at the cursor, and on the draft being written
- core: files open by type: in Greed, outside it as open_with says, never a program
- mail: what's attached shows in the list and under each message, with how it opens
- mail: space . on what's attached: open, open outside, save, save all, copy its path
- mail: search what's attached by its name and kind: file:invoice type:pdf
- mail: what's attached to recent and flagged mail is fetched ahead, so it opens at once
- mail: g s picks any saved search by name, however many there are
- mail: tab and shift-tab go through the saved searches, alt-1 to alt-9 to one
- mail: identities: a signature, Reply-To and Bcc to yourself for each address you send from
- mail: mail is written in Markdown and goes as its text and the HTML it makes
- mail: a default From for new mail, and :mail-from picks who it's from with that identity's signature
- mail: greed-mail and the plugin say which protocol they speak, and a mismatch says what to rebuild
- mail: rules can be tried on the mail you have, then run over it; and a rule can be kept for mail of an age
- mail: ctrl-enter or alt-enter sends the mail being written
- agent: what you're in says what it is: mail and its search, a shell, Hoard, a terminal
- mail: agents search and read your mail, show a thread, and mark or archive it, with mail tools
- mail: a mail: link opens its thread at that message, unfolded

### Fixed

- core: greed.sikt.compile gives nil and why, as assert takes them, and check lists a program's mistakes and warnings
- notes: a [[link]] in Markdown outside the notes opens the file beside it
- session: greed FILE opens a file not there yet, also with another version's session
- index: taking an item out finds its field words by rowid, without reading them all
- ui: a list leaves a span its own press, like a box to tick
- render: text after a line's end reaches the last column and stays put under the cursor
- core: numbers come back from greed.json as they went, to the last bit
- data: a table without rows says so, rather than drawing an empty one
- notes: links find notes as Obsidian does, by file name in any folder and any case, front matter's too
- mail: the index searches only a message's text fields by word
- mail: an index made again gets every message again; a search finding nothing lists nothing
- mail: is:mine is mail from your address, not one that ends like it
- mail: flagged mail shows a flag in the list
- mail: an index from an older greed-mail says what makes it again
- mail: a list of threads copies greed-mail's tags, a JSON array, without cloning it
- rpc: sending to a program never waits on it reading: a writer thread per connection
- cmdline: fewer matches than before all show, none left scrolled out of sight
- mail: mail with nothing attached sends: an empty table from Luau is an empty list
- mail: mail due goes out between batches of a long index catch-up, not after it
- mail: \Recent isn't kept as a flag, so Bridge's mail isn't indexed again every round
- mail: changes and fetched bodies index only themselves, never waiting on a long catch-up
- mail: a message cut short only in what's attached doesn't say its text goes on
- mail: b opens the message in the browser, not as its HTML in Greed
- mail: new mail shows in all its places at once, the inbox too, before a round's slow part
- agent: mail being read reaches an agent marked as from outside
- agent: an agent sending mail asks you first, every time
- agent: an agent sees the mail, shell or list you're in, and reads a buffer by its id
- test: waiting lets time pass when a timer woke the test, so timers started meanwhile fire
- hoard: question-only job prompts, no templates in recent, links as words
- mail: search and todo prompts end in a space, rows cut in a narrow pane

### Faster

- index: candidates load a thousand at a time, a limit stops early, and numbers narrow in SQL
- index: statements are prepared once, and only text fields get word rows
- index: a search sorted by date walks it in order and stops at a page; text only read for words
- notes: the notes' index is written in slices and batches, searches reuse what they worked out, and budgets measure both
- notes: what the notes' indexes worked out is saved, so a new session reads only notes that changed
- notes: the index's rows read each note's days once, labels reuse the parsed text, and today is read once a second
- notes: notes' lines are read with sikt, and lines with anything rarer with syntax as before
- markdown: empty lines and lines starting with a mark no block starts with read as prose at once, and table cells are found a bar at a time
- mail: a thread's subject found by an index, the index written 2000 at a time, dates in UTC
- mail: saved searches count their unread from the index alone, asking greed-mail nothing

### Documentation

- sessions, machines and the hub
- shell: filters mind neither case nor accents
- hoard: where notes are and Obsidian vaults up front; README says what Hoard does
- mail: setting it up, several accounts, the mail session and the quick look, mail.toml for Gmail and Proton
- mail: a guide to mail in Greed: setting up, keys, Hoard, agents, what's there and not
- charts: an example namespace that's nobody's
- site: code in one font everywhere, so boxes and bars line up on every device
- site: Hoard and Mail on the front page and their docs, with recorded demos

## 0.2.1 - 2026-10-18

### Highlights

- Snippets in VS Code's format: copy in VS Code snippet files or sets like friendly-snippets, with places, choices, variables and transforms.
- Brackets and quotes typed in pairs, in the Helix and VS Code styles, and completion from words in open files and from paths as you type.
- Undo lasts across restarts, kept with each save.
- `space -` shows a folder as text: rename, make, move and delete files by editing it. Deletes go to the trash.
- Plugins from git, named in your config and pinned to commits in a lock file next to it.
- Indent guides, color swatches and TODO comments picked out.
- Trusting a project is asked in a box that stays until you answer, and the status line says when a language server waits for `:trust`.

### New

- core: brackets and quotes typed in pairs, in the helix and vscode styles
- lsp: words from open files and paths complete as you type
- core: snippets with places to fill in, tab going from one to the next
- snippets: your own snippets, in VS Code's format, a file per language
- indent guides, color swatches and TODO comments picked out
- undo lasts across restarts, kept with each save
- folders: edit a folder as text to rename, make, move and delete files; deleting goes to the trash
- git-plugins: plugins from git, fetched in the background and pinned in a lock file
- record: demos can show the keys they press and a caption
- core: greed.text.matches finds a regex's matches and groups in a string
- snippets: choices offered in the menu, and VS Code's transforms
- git-plugins: a plugin taken out of the config is removed by :plugins-sync

### Fixed

- core: the question whether to trust a project was cut off on narrow screens, and outside a repository it asked about the file's folder instead of the one the language server runs in, so rust-analyzer kept waiting after a yes (#3); it's now a box that stays until you answer
- lsp: a server held back in an untrusted project says it waits for :trust
- notes: reminders go off in one session when several are running
- projects: space P says what enter does, and alt-o opens a project here

### Documentation

- 0.2.0's highlights as the release page shows them, one line each
- site: plain text and a recording of Greed in place of the generated picture
- plain wording, tables and examples in place of long prose, on every page
- provider-neutral examples, agents by protocol, a shorter front page
- site: a short hero and a tour of recent additions
- show-keys and caption in recording scripts

## 0.2.0 - 2026-10-17

### Highlights

![A Markdown page working out a budget: fields, formulas, a table's worked-out columns and a bar chart](https://raw.githubusercontent.com/johnae/greed/v0.2.0/site/media/changelog/0.2.0-live-markdown.png)

- Live Markdown: fields, `{{ formulas }}`, worked-out table columns and charts under tables, recomputed as you type. Data blocks read tables live from CSV, SQLite and PostgreSQL.
- Agents across machines: one session follows the others and the hubs on machines you reached with `greed ssh`. `space space` lists every session and agent, and you can answer or stop an agent from anywhere, Claude Code's questions included.
- Auto mode for agents: commands that only look, build or test run by themselves, and a decision model you pick judges the rest or asks you. `:decision-check` tries a model before you rely on it.
- Untrusted projects run none of their own code until you trust them: config, language servers that run the project's code, and formatting on save. Greed asks once.
- `core.ui`, a way for plugins to draw interfaces as text: lists, grids, inputs and buttons. The picker, completion and the command line use it.
- Some 330 more languages from Helix's list, Terraform, OpenTofu and HCL among them.
- In the window, views scroll smoothly, buttons light up under the mouse and input methods compose at the cursor. `:s///c` asks about each match.
- Install on macOS and Linux with Homebrew: `brew install johnae/greed/greed`, or `brew install --cask johnae/greed/greed-app` for Greed.app.

### New

- languages: Terraform, OpenTofu and HCL: HCL's grammar downloaded with Helix's queries, terraform-ls or tofu-ls
- languages: some 330 more languages from Helix's list: files, comments, indent and language servers
- sessions: space B goes back to the session you were in, on whichever machine, and home comes back from another machine
- agent: agent-max-tokens stops Greed's own agent once a session has read and written that many tokens
- agent: a status tool, greed ctl status: what needs you and the agents at work, with a schema version
- terminal: agents in terminals say through their hooks when they work, wait for you or idle; greed ctl KEY=@- reads stdin
- agent: Greed's own sessions fork too, going on from what was said with the same model and tool groups
- agent: agents in workspaces of their own hear when another changes the same files
- core: objects.changed nudges whoever follows an object to look again now; terminals keep their agent's state per source, trusted or not, reconciled when the program ends
- agent: the Claude Code Greed starts tells Greed through its hooks when it works or waits, with nothing to set up; the status line counts agents in terminals too
- agent: agents running in terminals show in the session list, where enter goes to their terminal and x closes it
- ssh: greed ssh notices a dropped connection, through a heartbeat both ends keep, and comes back to the same session by itself
- cli: greed ls says how each session's agents are doing, asking it as an ordinary client; greed.session.status
- agent: greed ctl watch follows a session's status: all of it at once, again on each change and every 15 seconds
- hub: one session on the machine follows the others, so each says what waits elsewhere (space i A goes there)
- agent: the status says which machine it's on, by an id made once, for hubs to tell machines apart
- hub: the hub tells each machine once when an agent anywhere waits for you
- hub: hubs follow other machines' hubs over ssh, so you see and hear of agents there
- hub: follow the machines you reached with greed ssh lately, no config needed
- hub: a session over greed ssh shows what's on your machine, asked through your client
- picker: space space lists your sessions and agents on every machine, from plugins' places
- agent: answer or stop an agent from anywhere: its actions in space space, here or on other machines
- agent: Claude Code's questions wait in Greed while you're elsewhere, answered from anywhere
- agent: questions Greed's agent asks are answered from anywhere; greed ctl acting as you asks an agent every time
- agent: Claude Code's multiple-choice questions are asked on a page while you're elsewhere
- blocks: what runs by itself runs only as you last let it; changes from outside wait
- core: formulas, Luau's expressions worked out without running code
- markdown: live values, {{ formulas }}, lets and fields, worked out as you edit
- markdown: formula columns in tables, worked out row by row
- blocks: command buttons in Markdown, values quoted as one argument each
- chart: charts under Markdown tables, drawn again as the table changes
- chart: charts under tables drawn as vectors where the client can
- blocks: code blocks get the page's values, fields, lets and tables
- markdown: edit tables as drawn from normal mode
- markdown: markup opens as written when the cursor steps inside
- markdown: a hidden part says when it shows, and opens with the cursor on it
- notes: a todo can have several reminders, each going off on its own
- core: tables of data in one shape, and the sources they come from
- data: data blocks in Markdown, tables read live from csv, sqlite and psql
- chart: a chart line under a data block charts the table it read
- core: core.ui, interfaces drawn as text and marks from a view's state
- data: a data block's table opens in a float as text; tables drawn by core.ui
- core: core.ui grids, values under the cursor, items kept as lines move, button rows
- data: data SOURCE in the shell, so boards and shell blocks read databases
- core: core.ui keyed parts drawn again only when they change, and soon for bursts
- gui: scrolled views glide to their place, unless gui-smooth-scroll is off
- core: core.ui inputs under a view, marks of a span's own, and its namespace and width
- core: core.ui finds lines by value, picks out fuzzy matches, and mounts before it draws
- core: a core.ui view can draw under an input line, as a picker's list under its query
- core: a core.ui view over an input can have no lines, leaving only the input
- acp: images sent while the agent works go with the message, to Greed's agent at its next step
- core: a core.ui list marks its current row; picker, completion and the command line use it
- core: value_at gives the value of the span at a position
- gui: hover lights up buttons, fields and choices; input methods compose at the cursor
- core: risk.safe tells command lines that only look, build or test
- acp: auto mode answers agents' questions where it safely can
- acp: auto mode's decision model judges commands by what you asked, risky ones too
- models: decide asks yes-or-no questions of a System One decision model or any chat model
- acp: auto mode asks the decision model how likely a command is harmful and asked for
- acp: up and down bring back what you sent; auto or manual shown in colour and remembered
- acp: auto mode asks whether a command is safe and asked for, as clef-flash answers best
- acp: :decision-check tries the decision model on commands it should and shouldn't let run
- core: greed.fs.dirs gives the system's folder for temporary files
- acp: auto mode judges scratch files in /tmp, tells ACP agents why, and stops after twenty blocks
- core: language servers start only in folders Luau trusts, held back until then
- core: an untrusted project runs none of its own code until you trust it, asked once
- cmdline: :s///c asks about each match, vim's y/n/a/l/q
- core: greed.fs takes relative paths from the shown project's root
- site: recordings get the room on wide screens and open larger on a click

### Fixed

- ssh: greed ssh relays an agent that answers, falling back to IdentityAgent, and says on the status line why one doesn't
- ssh: a session puts its own greed on its programs' PATH when none is there, so greed FILE works on machines greed ssh set up
- hub: ask a client attaching from elsewhere about its machine at once
- agent: a tool call without its path tells the model; a crash ends the turn instead of hanging it
- agent: an answer a question doesn't offer is ignored, not taken as a no
- hub: the status line counts agents from what the hub heard, not by listing sessions each frame
- markdown: a table's last row no longer drawn in the border's dim style
- markdown: a command button's values are left for its command
- blocks: a command button's output shows in a float as it runs
- markdown: fill out table rows typed short of cells
- chart: a Markdown chart's comment line stays in sight above it
- blocks: command buttons run in sh, the same for anyone
- shell: values in lines for your shell are quoted for it, nu and fish too
- acp: a long command in the box's bottom line is cut to fit, its time still shown
- acp: an image sent while the agent works says it goes with the next message
- gui: only a view that scrolled glides, never rows moved by its text or a pane with fixed parts or pictures
- board: i, a, c and o open a card's file in typing mode too
- acp: typing in the box keeps the status animated rather than drawing it still for a moment
- core: a cursor kept by core.ui lands on a whole character
- board: updates drawn together, charts run again once a resize settles
- models: decide reads the provider's key as models, whoever asks
- acp: the decision model sees your newest message apart, and a new one asks it again
- acp: auto mode asks the decision model one plain question, whether a command is safe to run
- core: servers that only read files start untrusted, and tests trust every project
- core: a key other than y or n at the trust question does what it would have
- markdown: a search into a table, or typing that changed nothing, leaves it as written

### Faster

- keys are drawn before background work; slow status line pieces move aside
- delta: rows a scrolled view still shows move on the client and aren't sent again
- markdown: an edit reads only the lines it changed, and questions and charts look only where they can be
- core: a view resizing is drawn once per burst, parts that wrap kept as they are
- acp: folded thoughts are the same at any width, so a resize edits only the box

### Documentation

- agents and models beyond Claude: any MCP client, ACP agents and Greed's own with any provider; setup adds Greed to every agent installed
- site: a text environment for you and your agents
- decision models are a judgment call; test yours before relying on auto mode
- a changelog from the commits with highlights, shown on the release page
- a guide to building interfaces with core.ui, auto mode setup, Homebrew, and what 0.2.0 left out
- site: live Markdown on the front page, Homebrew, demos that trust their projects

## 0.1.8 - 2026-10-14

### New

- render: wrapped rows start at their line's indent, a transcript's bar on each

### Fixed

- shell: the rows of $3 | where ... are what block 3's were, pods still pods

### Documentation

- the kubectl demo charts block 1 with $1, and the site says what $1 does

## 0.1.7 - 2026-10-14

### New

- agent: Greed's own agent can work in a workspace of its own, and knows how its work gets back to you
- agent: space i W starts Claude Code in a workspace of its own, listed with the sessions to review and bring in
- gui: going to another session keeps the window, and alt-w in space P opens a project in another window
- terminal: esc waits a moment in programs on the normal screen, so esc esc leaves Claude Code without stopping it
- gui: ctrl-shift-n, or cmd-n on macOS, opens another window on the session, laid out on its own
- agent: agents are told the tool groups as they connect, so your todos are found in your notes
- kubernetes: a pod's shell opens in a floating terminal, bash if it has one, picking the container

### Fixed

- shell: rows a table stage kept are still what the command listed, so filtered pods stay pods
- panes: closing a terminal's float or panel ends its program, as closing its pane does
- core: :project takes ~ and paths from the project, and opens the file it names

### Documentation

- plugins: what Luau is and why plugins are written in it
- media: the kubectl demo opens a filtered pod's logs, and demos run in ~/shop
- the kubectl video's caption says it opens the failing pod's logs
- site: a new lead, Luau explained and linked, and the Nix cache
- media: the panes demo goes to a second project and back with space P
- an agent demo with a scripted model, on the site and in the agent docs; the sample projects are repositories

## 0.1.6 - 2026-10-14

### New

- models: :login vibe signs in through Mistral's console as Vibe does, so requests count against the plan's allowance
- gui: a watchdog notices when the window stops showing frames, makes its surface again and asks for a whole frame
- agent: the system prompt names the model answering, so it doesn't guess or take on another's name
- agent: Greed's agent reads what an answer depends on first, and with agent-care thorough surveys with helpers and says what it checked
- agent: the chat's rows can be reached while it streams: it stays where you moved, alt-up/alt-down pick rows from the box, enter or a click opens them, and a helper's float closes with esc or q

### Fixed

- client: frames are numbered and a client whose deltas stop fitting asks for a whole frame, one client's bad draw doesn't stop the others, and a lost window surface is made again
- shell: esc in a shell where nothing has run yet leaves typing for normal mode
- markdown: an indented list's first item and indented headings get their bullet and markers where the markup is, however the text was read
- agent: a transcript is drawn in one go, so no frame shows it half drawn while an agent streams; core.atomic runs code without a pause
- gui: the window's events keep a frame boxed, as macOS's menu events made the sizes too far apart for clippy

### Documentation

- what attaches to a session is a client, in a terminal or a window

## 0.1.5 - 2026-10-13

### New

- docker: docker ps shows NAMES first, so a narrow pane cuts the other columns
- models: Mistral as a provider, and :login asks for the key of one that only takes a key
- models: pick a model from the provider's own list, in :models and in Greed's agent chat
- models: Greed's agent names its conversation for providers that only cache with a key, Mistral by default
- acp: OpenCode among the agents to start
- agent: the transcript is read-only above the box; typing or pasting there goes into the box
- shell: everything above the prompt is read-only; typing or pasting there goes to the prompt
- agent: Greed's agent hands work to helpers it can watch: offered from the start, read-only by default, live rows while they run
- effects: edits you didn't type light up and fade, big jumps flash their line, inactive panes can dim, floats cast shadows by default
- agent: an effort per role and /effort mid-chat, thoughts shown folded, and / commands in the chat box
- models: Mistral's reasoning models get their thinking back with what they said
- shell: shell.project() for plugins that run programs in the project's environment; the plugin guide shows how, and plugin_try doesn't urge installing
- models: the per-request debug line says how long until the first bytes, the whole, and the pace
- agent: thoughts show their tail and size while they stream, the status says waiting, thinking or writing, and outside text is tagged rather than wrapped in warnings
- models: a model that goes quiet is given up on and asked once more, as are dropped connections and busy servers
- models: GLM 5.3 on Mistral: its window, efforts per model with a max level, thinking always on
- agent: keep thoughts short, and a thought past agent-max-thought is stopped and the model asked for smaller steps
- agent: tab after /effort, /model and /mode lists what the model takes, how each effort is sent
- agent: no turn limit unless agent-max-turns says, with a note every 200 steps

### Fixed

- shell: ctrl-c just after enter stops the line instead of being lost
- models: a message after a turn stopped at tool results follows a word from the model
- agent: run_command and act work in your view, never the agent's chat; views and buffers close by id
- agent: the eval review page opens read-only in normal mode, without its fences; big headings in floats take their rows
- agent: ctrl-c stops the agent at once, esc rejects a question with what you typed, messages sent while it works are queued
- models: Mistral's reasoning models keep the first word of their answer
- agent: a rejection means stop and ask, and the turn ends after two; tools say what they acted on, focus gives ids and the real mode, eval points at describe
- core: backspace and vim's paste step back by characters, not bytes, after ❯ and the like
- core: setting a mode that doesn't exist is an error naming the modes there are
- api: greed.view(id) and greed.buffer(id) find one by id, functions given arguments they don't take say so, and eval's sandbox asks before closing, switching tabs or changing the mode
- lsp: an accepted completion is your edit, not the plugin's
- agent: plugin_try says so when file paths start from the project instead of the plugin's folder
- gui: text beside a float stays where it is without the float, and floats over panels cast their shadow on them
- models: Mistral gets ten minutes of quiet, since it sends a tool call whole once it's written
- agent: one draw of a transcript at a time, so a long one redrawn twice at once keeps one box
- agent: redacting secrets takes time in step with the text, so a large selection no longer takes seconds
- agent: esc in insert mode leaves it before rejecting, a rejected edit doesn't stop the tests, local and Berget models get ten minutes of quiet, empty answers aren't sent, and a long loop saves the session every few seconds

## 0.1.4 - 2026-10-13

### New

- greed --fresh starts a session without restoring what it had open
- debug topics, :debug and :debug-log, greed.debug and a debug_log tool
- chart: a line for each name over time, same names in a watch add up, --why is text alone
- macos: holding Shift as the app opens starts it fresh
- shell: blocks mode: move between commands and rows, act with a key, run again in place and compare with the run before
- shell: up and down in blocks mode go through every row too, J and K between commands
- gui: dropping a file on the window pastes its path, copied to the session's machine first over greed ssh
- over greed ssh, a paste of paths to files on your machine sends the files
- shell: drill down: what an action on a row runs shows where you are, esc goes back up
- shell: filters of a view's own, panes beside, and drilled-down commands stop when you go back
- shell: JSON lines shown readably, filters by field and section, tab folds sections
- shell: tab completes a filter's sections, fields and columns
- shell: a filter's fields show values they have, as readable logs hide their names
- shell: logfmt reads readably too, log times show as the time here
- shell: a filter's prompt says how much it keeps as it's typed
- shell: a column not found by name says the dotted path that has it
- a line that doesn't wrap marks what's out of sight at its edges
- shell: a slow command says it hasn't printed anything yet
- filters compare: level>=warn in levels' order, took>500, level!=debug
- shell: up in a filter brings back those used on the same kind of command
- shell: long JSON and YAML show their keys folded as they end
- kubernetes: an event's row is the object it's about
- one way to compare values, the same in a view's filter and a table's where
- process: run takes env, a timeout, a group and on_start, built on spawn; the shell's hand-made loops use it
- rpc: messages framed one a line, as agents send them
- test: a plugin's tests require its files as the plugin loaded them
- tab width per buffer, from the language or tab-width; API conventions written down, mode aliases gone
- actions: a kind's default action lives in core.actions and comes first
- kubernetes: find a pod or any object by its id, asking kubectl when no block shows it
- agent: risky commands ask every time, saying why; core.risk knows which
- agent: secrets in output are hidden before a model reads it
- agent: Greed's agent runs its commands as blocks of the project's shell
- kubernetes: a deployment relates to its pods, a pod to what owns it
- kubernetes: a deployment's logs, all its pods merged, each line's pod a field
- acp: agent sessions are objects, to inspect, show, stop and close
- shell: a shell is an object, with its blocks
- board: boards and their cards are objects
- notes: notes and todos are objects, to open and tick
- restore: a session reopens the project's tabs, panes and terminals; saved layouts go from the project's root
- ssh agent forwarding through Greed: one socket per session, following you across reconnects, asking before a key signs
- core: ssh-agent-confirm per machine, with ssh-agent-confirm-hosts
- typed command arguments, checked before a command runs and completed from their type
- agent: agents find commands and run them with checked arguments; commands on one object are its actions
- agent: agent-compact-at compacts Greed's agent at a fixed size
- agent: agent-new takes the agent and a first message, so ctl and scripts can start one

### Fixed

- gui: Command with a character no longer types the plain character
- prometheus: prom asks with its own network access, waits 30 s, and says when nothing matched
- shell: blocks mode stays out of floats, and steps only through rows to act on
- shell: blocks mode stands in for normal mode, : and ? and shift-tab work, keys that type nothing stay
- shell: blocks mode reaches the running commands on the strip, and the leader works in it
- shell: a block whose draw failed as its program exited still ends
- shell: what real kubectl, ps and logs turned up
- shell: events' warnings colored, a followed log's newest line stays readable
- shell: a selected command's status reads on its usual ground
- shell: ctrl-c before a command's program starts stops it once it does
- lines break only at \n, \r\n and \r, as compilers and language servers count them
- http: a redirect never drops from https to http; URLs read as browsers read them
- shell: a failing listener can't leave a block running, and listeners go with their plugin
- a plugin's Claude Code connection, menus and HTTP streams go with it
- process: unread output waits, programs nobody holds are let go, a gone group isn't signalled
- shell: a program that caught ctrl-c and exited isn't 'killed'; where splits at the first operator
- shell: ctrl-c reaches a program the moment it starts, not only once it owns the terminal
- shell: a followed block doesn't pull back a cursor just moved off its last line
- shell: ctrl-c stops a waiting builtin; each client drills down on its own
- fs: every greed.fs function takes ~ as home; mkdir can't block Greed's own files
- plugins: capability gating fails closed, and a test names any function left ungated
- programs Greed starts can be stopped with ctrl-c even when Greed was started ignoring it
- shell: a block drawn again keeps the lines that read the same, and a cursor on them stays
- lsp: completion in a buffer without a server says nothing
- luau: a program's end reaches a coroutine between slices; a failed caller's jobs end
- agent: a proposed change isn't accepted over your edit of its text
- core: acting for another client gives back the one before, so the server acts for it again
- picker: a command needing an argument opens the command line with its name
- shell: a block whose shell closed while it ran still ends
- shell: a block's time is its program's, the wait for the environment shown apart
- picker: long items stay on one row, cut at the edge; several targets say how many
- statusline: a buffer named after its kind shows the kind once
- shell: a block that can't start ends failed with why; the shell's own housekeeping isn't charged to the plugin asking it to run
- secrets: a keyring that can't be reached says so, and a secret saved to the file says why
- agent: changes outside the project always ask, questions name their files, agent options need eval, eval's session allowance stays with that session

### Documentation

- an events reference with each event's type and fields
- a charts guide: kinds, lines per thing, PromQL, dashboards, Linux and macOS boards
- greed --record, shot with commands that take arguments, the Mac's Greed menu, --session in usage
- agents: debug_log among the tools
- what runs where with greed ssh, config both ways, the ssh agent today
- a run through the docs against the code: fixes, and what was missing
- plugins: shell.run's options and capabilities; t:run, t:tempdir and fake programs in tests
- permissions and sandboxing, one page: who asks what, policies, what always asks, plugins and the sandbox, setting up

## 0.1.3 - 2026-10-11

### Fixed

- macos: the app asks what to do about an older session, says why it stops, draws its window on launch, and Option, Quit and finding files at home work as on a Mac

### Documentation

- download links that always get the latest release, and releases carry names without the version

## 0.1.2 - 2026-10-11

### New

- kubernetes: switch the context and namespace, everywhere or in one shell
- keymap: say when a plugin's keys hide another's, and show it in space h k
- shell: change a block in place; kubectl get blocks switch resource and namespace
- board: boards of live shell commands, saved as markdown
- board: cards side by side as the board is wide enough, moved with < and >
- chart: | chart draws a table as a chart, in characters every terminal shows
- scene: scenes in the render model, drawn as images under the text in kitty terminals
- chart: numbers keep their unit, and scene-drawing keeps charts in characters
- gui: the window draws scenes under its text, as kitty terminals do
- chart: --why says how each column was read and why the chart
- docs: the manual comes with the editor, searchable; the website builds from the same pages
- gui: braille and eighth blocks are drawn as shapes, whatever the font
- board: typing on a card opens the board's file at it
- board: a card's chart shows coloured, and as an image where it can be, as big as the card
- board: front matter sets a board's columns, for the same layout in any window
- prometheus: prom asks Prometheus, and a plugin's builtin feeds table stages
- shell: kubectl and docker are read from their JSON when stages follow
- blocks: shell blocks run in the Greed shell, with charts and every=N live
- gui: greed --record plays a demo script and draws each frame, for videos
- board: cards are shell blocks, and shell blocks take input=
- site: demos of notes, boards, kubectl and panes, in Catppuccin Frappé
- gui: greed shot saves the editor as the window shows it, after a few steps
- test: t:frame gives the screen as the window draws it, to check how it looks

### Fixed

- scene: a scene is drawn only while every line of its characters shows
- shell: the strip cuts a line by characters, and says a chart is one
- chart: ids aren't charted unasked, a TIME of hours isn't time, and the greatest rows show
- board: a card cut narrower than its chart shows it without an error
- board: one load of a board at a time, and a load that fails says why
- scene: charts under a shell block draw as images, in the window's colours
- gui: big text takes rows only in its own pane, so panes beside it keep theirs
- blocks: only the run button looks like one, so a block's fence stays readable
- shell: macOS ps stays a table when a long user name moves a row along
- markdown: big pages open with less drawing, and unoptimised builds get more time per call
- shell: a watch's next run is timed from when the last one ended
- dist: notarizing asks again through a dropped connection, for up to three hours
- shell: a watch told to stop just as its command ends stops

### Documentation

- Greed as a text environment, with videos of the shell, notes, boards and panes

## 0.1.1 - 2026-10-10

### New

- panes: click a float's border arrows, names or dots to go to that float
- core: objects: kinds, ids, state, relations and actions, for the editor's own things
- terminals, shell blocks, language servers and proposals are objects
- describe: space h i inspects objects: state, related objects to go to, actions to run
- languages: :language NAME sets a buffer's language, :setf as in Vim
- agent: objects, inspect and act: agents find, read and act on the editor's objects
- shell: table rows are objects: a pod, process or container by what it is, other rows by their block
- shell: kinds match rows by their columns, whatever printed them
- shell: nu's tables come back as data, their rows things like any table's
- shell: cells can be objects too: a pod's node, a container's image
- shell: git status, git log, jj st and jj log rows are changed files, commits and revisions
- shell: cells and plain rows have actions: copy, filter by this, as JSON
- context: pin any object for agents; its state goes with every prompt
- jumps: back and forward per view, from whatever showed another buffer
- view: narrow a view to some lines; a block's float shows only the block
- actions: the row's thing first, actions every kind has last, kubectl's names
- shell: follow logs in a float on the last line; an action already running opens its block
- picker: space space switches to anything open; @kind narrows it
- actions: rename, delete, diff and reveal files; grep and new shell in folders; more for processes
- actions: a selection over several rows acts on each of them
- inspect: forward as well as back, on ctrl-o and ctrl-i
- view: lines that don't wrap scroll sideways; a table's rows stay rows in a narrow pane
- objects: watch anything for changes, with a notification saying how
- actions: keep what was done to each thing; history and the inspector show it
- shell: keep several block floats open, one for each block, laid out as the tab's floats
- sessions: a build id; attaching to another build says so, greed --new starts one beside it, greed ssh brings this build
- actions: destroying actions ask in one place; several, or an agent's, are reviewed together
- shell: drawn tables show sizes, dates and nested JSON as people read them
- shell: a table's header and the cells saying how things are doing are colored
- shell: map and filter say what's wrong with a column; fractions show to two places
- sessions: greed --shell shows the project's greed shell, as --terminal shows a terminal

### Fixed

- agent: only you decide on proposed changes, never code an agent or plugin started
- shell: stages after a nu line work on the table nu gave back
- shell: sort, last, uniq, sum and split after a program are the stages when given an argument; a block float's cursor stays on whole characters

### Documentation

- Get, Reflect, Eval, Edit, Delegate; an execution environment with a good editor built in

## 0.1.0 - 2026-10-10

The first release.
