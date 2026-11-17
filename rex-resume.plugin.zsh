# rex-resume: reopen vibe conversations in the panes Rex restores after its
# server restarts (upgrade, reboot). https://github.com/qselle/rex-resume
#
# Rex restores sessions, tabs and splits under the same pane IDs ($REX_BLOCK),
# as fresh shells. vibe remembers "this terminal's last session in this folder"
# (what `vibe -c` continues), keyed by VIBE_TERMINAL_KEY. Keying it by pane
# makes that memory survive the restart. The pane's shell also leaves a note
# while vibe runs; the restored shell finds it and types `vibe --resume <id>`.

# Every shell in a Rex pane, bash included: `vibe -c` continues the pane's own
# session even without the rest.
[ -n "$REX_BLOCK" ] && export VIBE_TERMINAL_KEY="$REX_BLOCK"
[ -n "$ZSH_VERSION" ] || return 0

# The rest runs in the pane's own interactive shell only: the first one in the
# pane, or one that replaced it with `exec`. Shells nested in the pane inherit
# REX_BLOCK and the marker, with another PID.
if [[ -n $REX_BLOCK && -o interactive && -z $ZSH_EXECUTION_STRING ]] &&
  [[ -z $_REX_RESUME_SHELL || ${_REX_RESUME_SHELL%:*} != $REX_BLOCK || ${_REX_RESUME_SHELL##*:} == $$ ]]; then
  export _REX_RESUME_SHELL=$REX_BLOCK:$$
  typeset -g _rex_resume_note=${XDG_STATE_HOME:-$HOME/.local/state}/rex-resume/${REX_BLOCK#block:}
  typeset -g _rex_resume_line=

  # vibe's record of the pane's last session in a folder, or nothing.
  _rex_resume_session() {
    local dir=$1 key sum ptr id
    for key in $dir ${dir:A}; do
      if (( $+commands[sha256sum] )); then
        sum=$(printf '%s\0%s' $REX_BLOCK $key | sha256sum)
      else
        sum=$(printf '%s\0%s' $REX_BLOCK $key | shasum -a 256)
      fi
      ptr=${VIBE_HOME:-$HOME/.vibe}/logs/session/continue-pointers/${sum%% *}
      [[ -r $ptr ]] || continue
      id=${$(<$ptr)//[[:space:]]/}
      [[ -n $id && $id != *[^[:xdigit:]-]* ]] && { print -r -- $id; return; }
    done
    return 1
  }

  # A note left by vibe cut off by the server stop. It stays until the
  # reopened vibe replaces it or returns: if the pane dies first (a restore
  # during shutdown), the next restore tries again.
  if [[ -f $_rex_resume_note ]]; then
    () {
      local -a note=("${(@f)$(<$_rex_resume_note)}")
      local id
      if [[ $note[1] == vibe && -d $note[2] ]] && id=$(_rex_resume_session $note[2]); then
        cd -- $note[2] && _rex_resume_line="vibe --resume $id"
      fi
      [[ -n $_rex_resume_line ]] || command rm -f -- $_rex_resume_note
    }
  fi
  # Notes of panes closed while vibe ran.
  command rm -f -- ${_rex_resume_note:h}/*(N.m+30)

  # Typed and run at the first prompt, as if by hand.
  _rex_resume_run() {
    [[ -n $_rex_resume_line ]] || return
    BUFFER=$_rex_resume_line
    _rex_resume_line=
    zle accept-line
  }
  # Interactive vibe runs typed at the prompt.
  _rex_resume_preexec() {
    local -a words=(${(z)3})
    [[ ${words[1]:t} == vibe && $words[2] != (mcp|config|help) ]] || return
    local w
    for w in $words[2,-1]; do
      [[ $w == (-p|--prompt*|--prompt-file*|-v|--version|-h|--help|--setup|--workdir*|--worktree*) ]] && return
    done
    mkdir -p ${_rex_resume_note:h} &&
      (umask 077 && print -r -- $'vibe\n'$PWD >| $_rex_resume_note)
  }
  # vibe returned on its own: not killed by a signal, and the pane's terminal
  # is still there (both fail when the Rex server stops).
  _rex_resume_forget() {
    local ret=$?
    [[ -z $_rex_resume_line && -e $_rex_resume_note ]] && (( ret < 128 )) &&
      { : >/dev/tty } 2>/dev/null && command rm -f -- $_rex_resume_note
    return ret
  }

  autoload -Uz add-zsh-hook add-zle-hook-widget
  add-zle-hook-widget line-init _rex_resume_run
  add-zsh-hook preexec _rex_resume_preexec
  # First, to see vibe's exit status before other prompt hooks change it.
  precmd_functions=(_rex_resume_forget ${precmd_functions:#_rex_resume_forget})
fi
