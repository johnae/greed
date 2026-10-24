# Plugins to install

Plugins written for Greed that don't come with it. Each one lives in a git
repository of its own, with its own docs, and installs with a line in your
`init.luau`. Once it's installed, `:docs` and `space h d` show its docs
beside this manual.

It's a short list for now. [Adding yours](#adding-yours) says how to get
on it.

## Themes

### Zenbones

Themes that tell code apart by contrast, bold and italic, ported from
[zenbones.nvim](https://github.com/zenbones-theme/zenbones.nvim). Twelve
variants, most of them in dark and light, and comments can get a font of
their own in the window.

![zenbones, dark](https://raw.githubusercontent.com/johnae/greed-zenbones/main/docs/zenbones.png)

```luau
require("@git-plugins").use("https://github.com/johnae/greed-zenbones")
require("@theme").use("zenbones")
```

It asks for nothing beyond the editor.
[Repository](https://github.com/johnae/greed-zenbones) ·
[Docs](https://github.com/johnae/greed-zenbones/tree/main/docs)

## Installing one

The `use` line records the plugin, and Greed fetches what's missing in the
background once it's up, so starting never waits on the network. A plugin
that wants more than the editor, like running programs or the network,
asks you first, naming what it wants. Each is pinned to a commit in
`plugins.lock` next to your config, and `:plugins-update` moves them on.
[Configuration](using.md#configuration) has the rest.

## Adding yours

Wrote a plugin others could use? Open a pull request adding it to this
page, with a few lines on what it does and its install line. A plugin on
the list:

- passes `greed check` on the current release, in its own CI;
- has a README and a license;
- works on its own, without a setup only you have.

[Sharing a plugin](plugins.md#sharing-a-plugin) has how to set one up, its
docs folder included.
