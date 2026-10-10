# Welcome to Greed

A few questions to set Greed up. `tab` and `shift-tab` go from choice to
choice, `enter`, `space` or a click picks one, and `esc` closes the page. A
style or theme you pick switches now, so you can try it here; the rest waits
for Save. New to a style? `:tutor` afterwards teaches its keys.

## How do you like to edit? <!-- id=style -->

```luau output=choices
local greed, core = require("@greed"), require("@core")
local now = greed.option.get("editing-style")
local list = {}
for _, style in core.style.list() do
	local picked = if style.name == now then "(x) " else ""
	table.insert(list, `{picked}{style.name}: {style.doc}`)
end
return list
```

```luau when=style
require("@greed").option.set("editing-style", answer)
```

## Which theme? <!-- id=theme -->

```luau output=choices
local theme = require("@theme")
local list = {}
for _, name in theme.list() do
	table.insert(list, if name == theme.current() then `(x) {name}` else name)
end
return list
```

```luau when=theme
require("@greed").run("theme", { args = { answer } })
```

## Icons <!-- id=icons -->

```luau output=choices
return require("@setup").icon_choices()
```

## Do you use Claude Code? <!-- id=claude -->

- ( ) yes: add Greed's tools to it (`claude mcp add greed -- greed mcp`)
- (x) no: or not now

## Which language model should Greed use? <!-- id=provider -->

```luau output=choices
return require("@setup").provider_choices()
```

<!-- if provider!=none -->
```luau button="Set up the model…"
require("@setup").model(answers.provider)
```
<!-- end -->

---

```luau button="Save"
require("@setup").save(answers)
```

```luau button="Not now"
require("@setup").close()
```
