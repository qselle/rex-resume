# rex-resume

Reopens your [vibe](https://github.com/mistralai/mistral-vibe) conversations in their [Rex](https://www.superlogical.com/rex) panes after the Rex server restarts (upgrade, reboot).

Rex already brings back your sessions, tabs and splits, but as fresh shells. With rex-resume, each pane that was running vibe types `vibe --resume <its session>` by itself.

## Install

zsh, on macOS or Linux, on the machine that runs the Rex server:

```sh
git clone git@github.com:qselle/rex-resume.git ~/.rex-resume
echo 'source ~/.rex-resume/rex-resume.plugin.zsh' >> ~/.zshrc
```

With oh-my-zsh, clone it into `$ZSH_CUSTOM/plugins/rex-resume` instead and add `rex-resume` to `plugins=(...)`.

Then open new panes (or run `exec zsh` in the existing ones) and start vibe there. Only vibe started after that comes back.

Update: `git -C ~/.rex-resume pull`. Uninstall: remove the `source` line and `~/.rex-resume`.

**Not on zsh?** Add this one line to your shell's startup file instead. After a restart, run `vibe -c` in each pane: each gets its own conversation back.

```sh
[ -n "$REX_BLOCK" ] && export VIBE_TERMINAL_KEY="$REX_BLOCK"
```

## How it works

Each Rex pane has a permanent ID (`$REX_BLOCK`) that survives restarts. vibe's memory and rex-resume's note are both filed under it.

```
1. While you work
┌─ Rex pane  ID = 7f3a ────────────────┐
│ $ vibe                               │
│   ↳ shell leaves a note: ────────────┼──▶ ~/.local/state/rex-resume/7f3a
│     "vibe, ~/src/app"                │      vibe
│                                      │      ~/src/app
│ vibe remembers its session: ─────────┼──▶ ~/.vibe/logs/session/continue-pointers/
│   "pane 7f3a + ~/src/app → d90dff3e" │     (VIBE_TERMINAL_KEY = pane ID)
└──────────────────────────────────────┘

2a. You quit vibe        → prompt returns → note deleted (nothing to reopen)
2b. Rex server stops     → vibe and shell killed → note stays

3. Rex comes back: same layout, same pane IDs, fresh shells
┌─ pane 7f3a (new shell) ─────────────────────────┐
│ note for 7f3a?            → vibe, ~/src/app     │
│ vibe's session for 7f3a?  → d90dff3e            │
│ $ cd ~/src/app && vibe --resume d90dff3e        │  ← typed for you
└─────────────────────────────────────────────────┘
```

| Who | Does what |
|---|---|
| Rex | Restores layout and pane IDs (built in) |
| vibe | Remembers each terminal's last session for `vibe -c` (built in; rex-resume sets the terminal key to the pane ID) |
| rex-resume | Leaves the note, reopens vibe |

## Limits

- Only `vibe` typed at the pane's prompt is noted: not `rex run -- vibe`, `cd x && vibe`, `--workdir` or `--worktree`, nor vibe in a shell nested in the pane.
- A reply vibe was writing when Rex stopped doesn't continue: re-prompt it.
- It relies on vibe's undocumented `VIBE_TERMINAL_KEY` and its `continue-pointers` layout (vibe 3.1). If a vibe update changes them, panes come back as plain shells. A custom `session_logging.save_dir` in vibe's config isn't supported.
- The reopen command goes into your shell history.
- Needs a Rex that restores sessions: server 0.1.0-preview.11+ on Linux, app 0.1.0-preview.23+ on macOS.

## Troubleshooting

- `echo $VIBE_TERMINAL_KEY` in a Rex pane should print the pane's `block:…` ID.
- `ls ~/.local/state/rex-resume` lists one note per pane running vibe.
- No note right after starting vibe: the pane's shell started before the install. Run `exec zsh`, then `vibe -c`.
