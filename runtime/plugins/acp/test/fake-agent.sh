#!/bin/sh
# An ACP agent for tests: it answers initialize and session/new, and acts on
# a prompt by its first word.
#
#   hello        says "Hello there" in two pieces
#   usage        says how much of its context it has used
#   edit FILE    asks to edit FILE in its folder, and writes "edited" if allowed
#   read FILE    reads FILE through the editor and says what it holds
#   run          runs `echo from a terminal` and says what it printed
#   wait         says nothing until it's cancelled
#   busy         runs a tool call until it's cancelled
#   plan         reports a plan and a tool call that fails
#   context      says whether editor context came with the prompt
#   servers      says what MCP servers it was given
#   markdown     says something in Markdown: bold, code and a list
#   code         says to run two shell blocks, one of them risky
#   pictures     says whether an image came with the prompt, and its file
#   twice        asks two questions, one after the other
#   mcp          reports two MCP tool calls, as Claude Code names them
#   widen        writes a plugin.toml asking for "proc", and says if it could
#   script       asks to run a tool whose title has two lines
#   stars        runs a tool whose output has Markdown-looking stars and backticks
#   quit         exits

cwd=""

# Its models: as `models` by default, or as a config option when started
# with "config".
models='"models":{"currentModelId":"small","availableModels":[{"modelId":"small","name":"Small"},{"modelId":"berget/big","name":"Big","description":"The big one"}]}'
if [ "$1" = config ]; then
	models='"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"small","options":[{"value":"small","name":"Small"},{"value":"berget/big","name":"Big"}]}]'
fi

send() { printf '%s\n' "$1"; }

update() {
	send "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":$1}}"
}

say() { update "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$1\"}}"; }

# Reads lines until the answer to request $1 comes, and keeps it in $reply.
await() {
	while IFS= read -r reply; do
		case "$reply" in
		*"\"id\":$1,"* | *"\"id\":$1}"*) return ;;
		esac
	done
	exit 0
}

field() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"; }

turn_done() { send "{\"jsonrpc\":\"2.0\",\"id\":$1,\"result\":{\"stopReason\":\"$2\"}}"; }

while IFS= read -r line; do
	id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
	case "$line" in
	*'"method":"initialize"'*)
		images=""
		if [ "$1" = images ]; then images=",\"promptCapabilities\":{\"image\":true}"; fi
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":true,\"sessionCapabilities\":{\"fork\":{}}$images},\"authMethods\":[]}}"
		;;
	*'"method":"session/new"'*)
		cwd=$(field "$line" cwd)
		servers=$(printf "%s" "$line" | sed -n "s/.*\"mcpServers\":\(\[[^]]*\]\).*/\1/p")
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"s1\",\"modes\":{\"currentModeId\":\"default\",\"availableModes\":[{\"id\":\"default\",\"name\":\"Manual\"},{\"id\":\"plan\",\"name\":\"Plan\",\"description\":\"Plan before doing\"}]},$models}}"
		;;
	*'"method":"session/load"'*)
		cwd=$(field "$line" cwd)
		update '{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"an earlier question"}}'
		update '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"an earlier answer"}}'
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
		;;
	*'"method":"session/fork"'*)
		cwd=$(field "$line" cwd)
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"s2\"}}"
		;;
	*'"method":"session/set_mode"'* | *'"method":"session/set_model"'*)
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{}}"
		;;
	*'"method":"session/set_config_option"'*)
		value=$(field "$line" value)
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"configOptions\":[{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":\"$value\",\"options\":[{\"value\":\"small\",\"name\":\"Small\"},{\"value\":\"berget/big\",\"name\":\"Big\"}]}]}}"
		;;
	*'"method":"session/prompt"'*)
		text=$(field "$line" text)
		case "$text" in
		usage*)
			update '{"sessionUpdate":"usage_update","used":14200,"size":200000}'
			say "Counted."
			turn_done "$id" end_turn
			;;
		hello*)
			say "Hello"
			say " there"
			turn_done "$id" end_turn
			;;
		edit*)
			file=${text#edit }
			update "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"Edit $file\",\"kind\":\"edit\",\"status\":\"pending\",\"locations\":[{\"path\":\"$cwd/$file\",\"line\":1}]}"
			send "{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"s1\",\"toolCall\":{\"toolCallId\":\"t1\"},\"options\":[{\"optionId\":\"yes\",\"name\":\"Allow once\",\"kind\":\"allow_once\"},{\"optionId\":\"no\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}"
			await 900
			case "$reply" in
			*'"optionId":"yes"'*)
				send "{\"jsonrpc\":\"2.0\",\"id\":901,\"method\":\"fs/write_text_file\",\"params\":{\"sessionId\":\"s1\",\"path\":\"$cwd/$file\",\"content\":\"edited\\n\"}}"
				await 901
				update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"completed\",\"content\":[{\"type\":\"diff\",\"path\":\"$file\",\"oldText\":\"a\\n\",\"newText\":\"edited\\n\"}]}"
				say "Edited it."
				;;
			*'"cancelled"'*)
				turn_done "$id" cancelled
				continue
				;;
			*)
				update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"t1\",\"status\":\"failed\"}"
				say "Left it alone."
				;;
			esac
			turn_done "$id" end_turn
			;;
		read*)
			file=${text#read }
			send "{\"jsonrpc\":\"2.0\",\"id\":902,\"method\":\"fs/read_text_file\",\"params\":{\"sessionId\":\"s1\",\"path\":\"$cwd/$file\"}}"
			await 902
			say "It says $(field "$reply" content)"
			turn_done "$id" end_turn
			;;
		run*)
			send "{\"jsonrpc\":\"2.0\",\"id\":903,\"method\":\"terminal/create\",\"params\":{\"sessionId\":\"s1\",\"command\":\"echo\",\"args\":[\"from a terminal\"]}}"
			await 903
			term=$(field "$reply" terminalId)
			send "{\"jsonrpc\":\"2.0\",\"id\":904,\"method\":\"terminal/wait_for_exit\",\"params\":{\"sessionId\":\"s1\",\"terminalId\":\"$term\"}}"
			await 904
			send "{\"jsonrpc\":\"2.0\",\"id\":905,\"method\":\"terminal/output\",\"params\":{\"sessionId\":\"s1\",\"terminalId\":\"$term\"}}"
			await 905
			out=$(field "$reply" output | sed 's/\\n$//')
			say "It printed: $out"
			turn_done "$id" end_turn
			;;
		busy*)
			update '{"sessionUpdate":"tool_call","toolCallId":"t3","title":"Run tests","kind":"execute","status":"in_progress"}'
			while IFS= read -r next; do
				case "$next" in
				*'"session/cancel"'*) break ;;
				esac
			done
			turn_done "$id" cancelled
			;;
		wait*)
			while IFS= read -r next; do
				case "$next" in
				*'"session/cancel"'*) break ;;
				esac
			done
			turn_done "$id" cancelled
			;;
		plan*)
			update '{"sessionUpdate":"plan","entries":[{"content":"look around","priority":"high","status":"completed"},{"content":"fix it","priority":"high","status":"in_progress"}]}'
			update '{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Run tests","kind":"execute","status":"in_progress"}'
			update '{"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"failed","content":[{"type":"content","content":{"type":"text","text":"```\n1 test failed\nat pager.rs:3\nexpected 2\n```"}}]}'
			turn_done "$id" end_turn
			;;
		pictures*)
			seen=no
			case "$line" in *'"type":"image"'*) seen=yes ;; esac
			file=no
			case "$line" in *'saved at '*) file=yes ;; esac
			say "image $seen, file $file"
			turn_done "$id" end_turn
			;;
		code*)
			say 'Run this:\n\n```sh\necho from the chat\n```\n\nor this:\n\n```console\n$ kill 999999\n```'
			turn_done "$id" end_turn
			;;
		markdown*)
			say 'Some **bold** and `code`, then:\n\n- one\n- two'
			turn_done "$id" end_turn
			;;
		twice*)
			for n in 1 2; do
				update "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"q$n\",\"title\":\"Step $n\",\"kind\":\"execute\",\"status\":\"pending\"}"
				send "{\"jsonrpc\":\"2.0\",\"id\":91$n,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"s1\",\"toolCall\":{\"toolCallId\":\"q$n\"},\"options\":[{\"optionId\":\"yes\",\"name\":\"Allow once\",\"kind\":\"allow_once\"},{\"optionId\":\"no\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}"
				await 91$n
				update "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"q$n\",\"status\":\"completed\"}"
			done
			say "Both done."
			turn_done "$id" end_turn
			;;
			mcp*)
				update '{"sessionUpdate":"tool_call","toolCallId":"m1","title":"mcp__greed__describe","kind":"read","status":"completed"}'
				update '{"sessionUpdate":"tool_call","toolCallId":"m2","title":"mcp__github__list_issues","kind":"read","status":"completed"}'
				turn_done "$id" end_turn
				;;
			widen*)
				send "{\"jsonrpc\":\"2.0\",\"id\":907,\"method\":\"fs/write_text_file\",\"params\":{\"sessionId\":\"s1\",\"path\":\"$cwd/plugin.toml\",\"content\":\"name = \\\"tiny\\\"\\ncapabilities = [\\\"proc\\\"]\\n\"}}"
				await 907
				case "$reply" in
				*'"error"'*) say "Not written." ;;
				*) say "Written." ;;
				esac
				turn_done "$id" end_turn
				;;
			script*)
				update '{"sessionUpdate":"tool_call","toolCallId":"t5","title":"Run echo one\necho **two**","kind":"execute","status":"pending"}'
				send "{\"jsonrpc\":\"2.0\",\"id\":906,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"s1\",\"toolCall\":{\"toolCallId\":\"t5\"},\"options\":[{\"optionId\":\"yes\",\"name\":\"Allow once\",\"kind\":\"allow_once\"},{\"optionId\":\"no\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}"
				await 906
				update '{"sessionUpdate":"tool_call_update","toolCallId":"t5","status":"completed"}'
				turn_done "$id" end_turn
				;;
		stars*)
			update '{"sessionUpdate":"tool_call","toolCallId":"t4","title":"Run python","kind":"execute","status":"in_progress"}'
			update '{"sessionUpdate":"tool_call_update","toolCallId":"t4","status":"completed","content":[{"type":"content","content":{"type":"text","text":"def f(**kwargs):\n    return *ptr, `x`\n- not a list"}}]}'
			turn_done "$id" end_turn
			;;
		context*)
			case "$line" in
			*'<editor-context>'*'File: '*) say "with context" ;;
			*) say "without context" ;;
			esac
			turn_done "$id" end_turn
			;;
		servers*)
			count=$(printf '%s' "$servers" | grep -o '"command"' | wc -l | tr -d ' ')
			say "servers: $count"
			turn_done "$id" end_turn
			;;
		quit*)
			echo "bye from the fake agent" >&2
			exit 0
			;;
		esac
		;;
	esac
done
