# The marks Greed reads, for an interactive zsh in a Greed terminal. They're
# added at the first prompt, after your .zshrc, so a theme that sets the
# prompt there keeps them, and kept last among the hooks after that.

[[ -n $GREED_SHELL_INTEGRATION ]] && return
typeset -g GREED_SHELL_INTEGRATION=1

_greed_precmd() {
	local code=$?
	if [[ -n $_greed_ran ]]; then
		builtin print -n "\e]133;D;$code\a"
	fi
	unset _greed_ran
	builtin print -n "\e]133;A\a\e]7;file://$HOST${PWD// /%20}\a"
	# The command starts where the prompt ends, wherever the theme put it.
	[[ $PS1 == *$'\e]133;B'* ]] || PS1="$PS1%{"$'\e]133;B\a'"%}"
}

_greed_preexec() {
	typeset -g _greed_ran=1
	builtin print -n "\e]133;C\a"
}

_greed_start() {
	precmd_functions=(${precmd_functions:#_greed_start} _greed_precmd)
	preexec_functions+=(_greed_preexec)
	_greed_precmd
}

precmd_functions+=(_greed_start)
