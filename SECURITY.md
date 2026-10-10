## Reporting a vulnerability

Please report security problems privately, through
[GitHub's private vulnerability reporting](https://github.com/johnae/greed/security/advisories/new),
rather than in an issue. Say what you found, how to reproduce it, and what
it lets someone do. You'll get an answer within a week.

Things that count, among others:

- a plugin doing more than its `plugin.toml` grants it, or more than you
  approved;
- code in a file running before you trusted the file or project, like a
  Markdown code block or a project's `.greed/init.luau`;
- an agent getting around proposals and approvals, or reading what it
  shouldn't, like your secrets;
- another user on the same machine reaching your sessions, or anyone
  reaching them over the network;
- `greed ssh` running something on either machine that you didn't ask for.

Greed is early, and only the latest release gets fixes.
