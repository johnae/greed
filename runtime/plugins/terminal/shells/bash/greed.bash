# Greed's shell integration for bash. A Greed terminal starts bash as
# `bash --posix` with ENV pointing here, the one way to run a file of
# Greed's before your own that works for login shells too. This turns POSIX
# mode off again, puts ENV and HISTFILE back, reads the files bash would
# have read (the profile files for a login shell, else ~/.bashrc), then adds
# the marks Greed reads: where each prompt, command and output starts and
# how the command ended (OSC 133), and the folder (OSC 7). Nothing of yours
# is changed.

builtin set +o posix

if [[ -n "${GREED_BASH_ENV+set}" ]]; then
	builtin export ENV="$GREED_BASH_ENV"
else
	builtin unset ENV
fi
builtin unset GREED_BASH_ENV

# POSIX mode uses ~/.sh_history; Greed set bash's own unless you had one.
if [[ -n "$GREED_BASH_UNEXPORT_HISTFILE" ]]; then
	builtin export -n HISTFILE
	builtin unset GREED_BASH_UNEXPORT_HISTFILE
fi

if [[ -n "$GREED_BASH_LOGIN" ]]; then
	builtin unset GREED_BASH_LOGIN
	[[ -r /etc/profile ]] && builtin source /etc/profile
	for __greed_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
		if [[ -r "$__greed_file" ]]; then
			builtin source "$__greed_file"
			break
		fi
	done
	builtin unset __greed_file
else
	[[ -r "$HOME/.bashrc" ]] && builtin source "$HOME/.bashrc"
fi

if [[ -z "$GREED_SHELL_INTEGRATION" && $- == *i* ]]; then
	GREED_SHELL_INTEGRATION=1

	__greed_prompt_start() {
		local code=$?
		if [[ -n "$__greed_prompted" ]]; then
			builtin printf '\e]133;D;%s\a' "$code"
		fi
		__greed_prompted=1
		builtin printf '\e]133;A\a\e]7;file://%s%s\a' "$HOSTNAME" "${PWD// /%20}"
		return $code
	}

	# The command starts where the prompt ends, after whatever set it.
	__greed_prompt_end() {
		[[ "$PS1" == *$'\e]133;B'* ]] || PS1="$PS1"'\[\e]133;B\a\]'
	}

	PROMPT_COMMAND="__greed_prompt_start${PROMPT_COMMAND:+;$PROMPT_COMMAND};__greed_prompt_end"
	PS0="${PS0}"$'\e]133;C\a'
fi
