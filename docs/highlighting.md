# Highlighting

Greed highlights code with tree-sitter. A language's `highlights` query
gives pieces of the text names like `keyword.control.return` or
`markup.heading.1`, and the theme gives each name a look. The names are
the same in every language, so one theme entry styles keywords everywhere.
Files are parsed again in the background after each edit; until that's
done, the highlights from before move along with the text you typed.

A name falls back to its parent when the theme has no entry for it:
`keyword.control.return` uses `keyword.control`, then `keyword`. A theme
can be as short as the top-level names, or style any of the finer ones.

```luau
require("@greed").theme.set({
	keyword = { fg = "magenta" },
	["keyword.control.return"] = { fg = "red", bold = true },
	["markup.heading.1"] = { fg = "blue", bold = true, underline = true },
})
```

These are the names Greed's queries and themes use, and the ones to use in
queries you write. They're the names Helix uses, so its queries work as
they are. A theme entry can also be set for one kind of client only, with
`tui` and `gui` parts:

```luau
require("@greed").theme.set({
	comment = { fg = "bright-black", gui = { italic = true } },
})
```

## Code

| Name | For |
|---|---|
| `attribute` | `#[derive(Debug)]`, decorators |
| `comment` | Comments |
| `comment.line` | `// ...` |
| `comment.line.documentation` | `/// ...` |
| `comment.block` | `/* ... */` |
| `comment.block.documentation` | `/** ... */` |
| `constant` | Constants |
| `constant.builtin` | `nil`, `None`, `self` as a value |
| `constant.builtin.boolean` | `true`, `false` |
| `constant.character` | `'a'` |
| `constant.character.escape` | `\n` in a string |
| `constant.numeric` | Numbers |
| `constant.numeric.integer` | `42` |
| `constant.numeric.float` | `4.2` |
| `constructor` | `Some(...)`, `new Foo` |
| `function` | Functions |
| `function.builtin` | `print`, `len` |
| `function.method` | `x.len()` |
| `function.macro` | `println!` |
| `function.special` | Preprocessor functions and the like |
| `keyword` | Keywords |
| `keyword.control` | Keywords that change the flow |
| `keyword.control.conditional` | `if`, `else`, `match` |
| `keyword.control.repeat` | `for`, `while`, `loop` |
| `keyword.control.import` | `use`, `import`, `require` |
| `keyword.control.return` | `return`, `break`, `continue` |
| `keyword.control.exception` | `try`, `catch`, `throw` |
| `keyword.directive` | `#include`, `#!` |
| `keyword.function` | `fn`, `function`, `def` |
| `keyword.operator` | `and`, `or`, `in` |
| `keyword.storage` | `let`, `const`, `static` |
| `keyword.storage.type` | `struct`, `enum`, `class` |
| `keyword.storage.modifier` | `pub`, `mut`, `async` |
| `label` | `'outer:`, a code block's language |
| `namespace` | Modules and packages |
| `operator` | `+`, `=`, `->` |
| `punctuation` | Punctuation |
| `punctuation.bracket` | `( ) [ ] { }` |
| `punctuation.delimiter` | `, ; .` |
| `punctuation.special` | `${` in strings, Markdown's `>` |
| `special` | Anything else a query wants to stand out |
| `string` | Strings |
| `string.regexp` | Regular expressions |
| `string.special` | Dates, symbols and the like |
| `string.special.path` | Paths |
| `string.special.url` | URLs |
| `string.special.symbol` | `:symbol`, atoms |
| `tag` | HTML and XML tags |
| `tag.builtin` | HTML's own tags |
| `type` | Types |
| `type.builtin` | `u8`, `string`, `int` |
| `type.parameter` | `T` in `Vec<T>` |
| `type.enum.variant` | Enum variants |
| `variable` | Variables |
| `variable.builtin` | `self`, `this` |
| `variable.parameter` | Function parameters |
| `variable.other.member` | Fields, properties, keys |

## Prose

| Name | For |
|---|---|
| `markup.heading` | Headings |
| `markup.heading.marker` | The `#` of a heading |
| `markup.heading.1` | A level 1 heading, and so on to `markup.heading.6` |
| `markup.heading.2` | |
| `markup.heading.3` | |
| `markup.heading.4` | |
| `markup.heading.5` | |
| `markup.heading.6` | |
| `markup.list` | List markers |
| `markup.list.unnumbered` | `-`, `*` |
| `markup.list.numbered` | `1.` |
| `markup.list.checked` | `[x]` |
| `markup.list.unchecked` | `[ ]` |
| `markup.bold` | `**bold**` |
| `markup.italic` | `*italic*` |
| `markup.strikethrough` | `~~gone~~` |
| `markup.link` | Links |
| `markup.link.url` | A link's address |
| `markup.link.label` | `[label]` in a reference link |
| `markup.link.text` | A link's text |
| `markup.quote` | Block quotes |
| `markup.raw` | Code |
| `markup.raw.inline` | `` `code` `` |
| `markup.raw.block` | Code blocks |

## Writing queries

Queries are files named `queries/LANGUAGE/highlights.scm`, in a plugin or in
`~/.config/greed/queries`; see [Using Greed](using.md#highlighting-and-syntax-queries).
In `greed repl`, `tostring(require("@greed").view():buffer():tree())` shows
the current buffer's syntax tree, which is what a query matches against. A
capture whose name starts with `_` (like `@_name`) is only there for a
predicate and isn't drawn.
