local greed = require("@greed")
local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)
local folder = string.gsub(greed.option.get("notes-folder") :: string, "^~", greed.fs.dirs().home or "~")
greed.fs.write(`{folder}/todo.md`, `- [ ] Call the dentist due:{tomorrow} remind:{tomorrow} 09:30\n`)
