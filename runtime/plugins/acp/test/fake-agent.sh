#!/bin/sh
# An ACP agent for tests: it answers initialize and session/new, and acts on
# a prompt by its first word.
#
#   hello        says "Hello there" in two pieces
#   edit FILE    asks to edit FILE in its folder, and writes "edited" if allowed
#   read FILE    reads FILE through the editor and says what it holds
#   run          runs `echo from a terminal` and says what it printed
#   wait         says nothing until it's cancelled
#   plan         reports a plan and a tool call that fails
#   servers      says what MCP servers it was given
#   quit         exits

cwd=""

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
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{},\"authMethods\":[]}}"
		;;
	*'"method":"session/new"'*)
		cwd=$(field "$line" cwd)
		servers=$(printf "%s" "$line" | sed -n "s/.*\"mcpServers\":\(\[[^]]*\]\).*/\1/p")
		send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"sessionId\":\"s1\"}}"
		;;
	*'"method":"session/prompt"'*)
		text=$(field "$line" text)
		case "$text" in
		hello*)
			say "Hello"
			say " there"
			turn_done "$id" end_turn
			;;
		edit*)
			file=${text#edit }
			update "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t1\",\"title\":\"Edit $file\",\"kind\":\"edit\",\"status\":\"pending\"}"
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
