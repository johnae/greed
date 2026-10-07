-- Signature help: typing "(" or "," in a call shows what the function
-- takes, above the cursor, with the parameter being typed picked out. It
-- follows as you type, and closes when the call ends or typing stops.
-- The signature-help command asks for it, for a key in insert mode.

local greed = require("@greed")

-- The modes signature help works in: typing, and typing with the
-- completion menu open.
local function typing(mode: string): boolean
	return mode == "insert"
		or mode == "vim-insert"
		or mode == "edit"
		or string.match(mode, "^completion%-") ~= nil
end

type Open = { view: greed.View, list: greed.Buffer }

local open: Open? = nil
-- Goes up with each keystroke, so a slow answer for older text is dropped.
local generation = 0

local function close()
	if open then
		open.view:close()
		open = nil
	end
end

-- The characters that ask for signature help in `buffer`, and the ones
-- that ask again while it's showing.
local function triggers(buffer: greed.Buffer): ({ string }, { string })
	local capabilities = greed.lsp.capabilities(buffer)
	local provider = capabilities and capabilities.signatureHelpProvider
	if type(provider) ~= "table" then
		return {}, {}
	end
	return provider.triggerCharacters or {}, provider.retriggerCharacters or {}
end

-- The byte offset in `text` of UTF-16 offset `units`, as servers count
-- parameter offsets in labels.
local function byte_of(text: string, units: number): number
	local counted = 0
	for pos, code in utf8.codes(text) do
		if counted >= units then
			return pos - 1
		end
		counted += if code >= 0x10000 then 2 else 1
	end
	return #text
end

-- Where the active parameter is in `signature`'s label, as byte offsets.
local function parameter_range(signature: any, active: number): (number?, number?)
	local parameter = signature.parameters and signature.parameters[active + 1]
	if parameter == nil then
		return nil, nil
	end
	local label: string = signature.label
	if type(parameter.label) == "table" then
		return byte_of(label, parameter.label[1]), byte_of(label, parameter.label[2])
	end
	local from, to = string.find(label, parameter.label, 1, true)
	if from == nil then
		return nil, nil
	end
	return from - 1, to
end

-- Shows the active signature of a signature help answer.
local function show(help: any)
	local signatures = help.signatures or {}
	local signature = signatures[(help.activeSignature or 0) + 1] or signatures[1]
	if signature == nil then
		close()
		return
	end
	local label: string = signature.label
	local width = math.min((utf8.len(label) or #label) + 2, 80)
	local o: Open
	if open == nil then
		local list = greed.create_buffer("signature", label, { readonly = true })
		local view =
			greed.float(list, { anchor = "above-cursor", width = width, height = 3, focus = false })
		o = { view = view, list = list }
		open = o
	else
		o = open
		o.list:edit(function(e)
			e:replace(0, o.list:len(), label)
		end)
		o.view:configure({ width = width })
	end
	local from, to =
		parameter_range(signature, signature.activeParameter or help.activeParameter or 0)
	local marks: { greed.Mark } = {}
	if from and to then
		table.insert(marks, { from = from, to = to, style = "ui.signature.parameter" })
	end
	o.list:decorate("signature", marks)
end

-- Asks the server for signature help at the cursor of `view`, and shows
-- it, or closes it when there's none.
local function ask(view: greed.View, context: any)
	local buffer = view:buffer()
	if buffer:path() == nil then
		return
	end
	generation += 1
	local wanted = generation
	local ok, help = pcall(greed.lsp.request, buffer, "textDocument/signatureHelp", {
		textDocument = { uri = greed.lsp.uri(buffer) },
		position = greed.lsp.position(buffer, view:cursor()),
		context = context,
	})
	if wanted ~= generation or not typing(greed.mode.get()) then
		return
	end
	if ok and help then
		show(help)
	else
		close()
	end
end

greed.on("buffer.changed", function(event: greed.BufferChanged)
	local view = greed.view()
	local buffer = view:buffer()
	if event.buffer ~= buffer or not typing(greed.mode.get()) then
		return
	end
	local pos = view:cursor()
	local ch = if pos > 0 then buffer:char_at(buffer:prev_char(pos)) or "" else ""
	local trigger, retrigger = triggers(buffer)
	if table.find(trigger, ch) then
		ask(view, { triggerKind = 2, triggerCharacter = ch, isRetrigger = open ~= nil })
	elseif open then
		local again = if table.find(retrigger, ch) then 2 else 3
		ask(view, { triggerKind = again, triggerCharacter = ch, isRetrigger = true })
	end
end)

greed.on("mode.changed", function(event: greed.ModeChanged)
	if not typing(event.to) then
		close()
	end
end)

greed.command({
	name = "signature-help",
	doc = "While typing, show what the function being called takes",
	run = function(ctx)
		if not typing(greed.mode.get()) then
			greed.echo("signature help shows while typing")
			return
		end
		ask(ctx.view, { triggerKind = 1, isRetrigger = open ~= nil })
	end,
})

return {}
