local greed = require("@greed")
-- Luau covers .lua files too.
require("@languages").set("luau", { indent = 2 })
require("@theme").use("nord")
greed.option.set("line-numbers", "relative")
