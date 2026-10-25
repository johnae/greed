# Plugins to install

Plugins for Greed that don't come with it. Each one lives in a git
repository of its own, with its own docs, and installs with a line in your
`init.luau`. Once it's in, `:docs` and `space h d` show its docs right
beside this manual.

It's a really short list for now - one plugin, and it's mine. I'm hoping
yours ends up here too, [Adding yours](#adding-yours) says how.

## Themes

### Zenbones

Themes that tell code apart by contrast, bold and italic instead of a lot
of colors. It's a port of Michael Chris Lopez's lovely
[zenbones.nvim](https://github.com/zenbones-theme/zenbones.nvim): twelve
variants, most of them dark and light, and in the window comments can go
in a font of their own.

![zenbones, dark](https://raw.githubusercontent.com/johnae/greed-zenbones/main/docs/zenbones.png)

Like this:

```luau
require("@git-plugins").use("https://github.com/johnae/greed-zenbones")
require("@theme").use("zenbones")
```

It asks for nothing beyond the editor.
[Repository](https://github.com/johnae/greed-zenbones) ·
[Docs](https://github.com/johnae/greed-zenbones/tree/main/docs)

## Installing one

The `use` line just records the plugin. Greed fetches what's missing in
the background once it's up, so starting never waits on the network.

A plugin that wants more than the editor (running programs, say, or the
network) asks you first and names what it wants. Each one is pinned to a
commit in `plugins.lock` next to your config, and `:plugins-update` moves
them on. [Configuration](using.md#configuration) has the rest.

## Adding yours

Wrote a plugin others could use? Open a pull request that adds it here,
with a few lines on what it does and its install line. What I'd ask of
one on the list:

- `greed check` passes on the current release, in its own CI;
- it has a README and a license;
- it works on its own, without a setup only you have.

[Sharing a plugin](plugins.md#sharing-a-plugin) has how to set one up,
docs folder and all.
