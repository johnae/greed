# Greed's shell integration for fish, found because a Greed terminal put
# this folder first in XDG_DATA_DIRS. It takes the folder out again, so
# programs started from here don't find it. fish 4 sends the marks Greed
# reads itself; before 4, this adds them: the folder it's in (OSC 7) and the
# marks around each prompt, command and output (OSC 133). Nothing of yours
# is changed.

if set -q GREED_SHELL_INTEGRATION_XDG_DIR
    set -l kept
    for dir in (string split : -- "$XDG_DATA_DIRS")
        test "$dir" = "$GREED_SHELL_INTEGRATION_XDG_DIR"; or set -a kept $dir
    end
    if set -q GREED_XDG_DATA_DIRS_UNSET
        set -e XDG_DATA_DIRS
    else
        set -gx XDG_DATA_DIRS (string join : -- $kept)
    end
    set -e GREED_SHELL_INTEGRATION_XDG_DIR
    set -e GREED_XDG_DATA_DIRS_UNSET
end

if status is-interactive; and test (string split . -- $version)[1] -lt 4; and not set -q GREED_SHELL_INTEGRATION
    set -g GREED_SHELL_INTEGRATION 1

    function __greed_folder --on-variable PWD
        printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url -- $PWD)
    end
    __greed_folder

    function __greed_prompt --on-event fish_prompt
        set -l code $status
        set -q __greed_ran; and printf '\e]133;D;%s\a' $code
        set -e __greed_ran
        printf '\e]133;A\a'
    end

    function __greed_preexec --on-event fish_preexec
        set -g __greed_ran 1
        printf '\e]133;C\a'
    end
end
