# Greed's shell integration for zsh, read because a Greed terminal pointed
# ZDOTDIR here. It puts ZDOTDIR back as it was, reads your own .zshenv, and
# once your .zshrc has run, adds the marks Greed reads: where each prompt,
# command and output starts and how the command ended (OSC 133), and the
# folder the shell is in (OSC 7). Nothing of yours is changed.

if [[ -n "${GREED_ZSH_ZDOTDIR+set}" ]]; then
	ZDOTDIR=$GREED_ZSH_ZDOTDIR
	unset GREED_ZSH_ZDOTDIR
else
	unset ZDOTDIR
fi

typeset -g _greed_integration=${${(%):-%x}:A:h}/greed.zsh
if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
	builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi
if [[ -o interactive && -f $_greed_integration ]]; then
	builtin source $_greed_integration
fi
unset _greed_integration
