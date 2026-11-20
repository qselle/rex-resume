# rex-resume

Reopens your [vibe](https://github.com/mistralai/mistral-vibe) conversations in their [Rex](https://www.superlogical.com/rex) panes after the Rex server restarts: an upgrade, a reboot, or a crash.

Rex already brings back your sessions, tabs and splits, but as fresh shells. With rex-resume, each pane that was running vibe types `vibe --resume <its conversation>` by itself.

It is a [Rex Lua script](https://www.superlogical.com/rex/docs/automate/lua-scripts) that the Rex server starts and that follows Rex's [events](https://www.superlogical.com/rex/docs/reference/events). It needs no shell setup.

## Install

On the machine that runs the Rex server (macOS or Linux):

```sh
git clone https://github.com/qselle/rex-resume.git ~/.rex-resume
echo 'dofile(os.getenv("HOME") .. "/.rex-resume/init.lua")' >> ~/.config/rex/init.lua
rex config reload
```

Rex's configuration file is `$XDG_CONFIG_HOME/rex/init.lua` when that is set, or the file `REX_CONFIG` names. The vibe already running in your panes is picked up at once.

**Coming from the zsh plugin?** Remove its `source` line (or `rex-resume` from oh-my-zsh's `plugins`) first. Otherwise both reopen vibe.

Update: `git -C ~/.rex-resume pull && rex config reload`, which replaces the running watcher.
Uninstall: remove the `dofile` line, then run `pkill -f 'do --all .*rex-resume.lua'` and `rm -rf ~/.rex-resume ~/.local/state/rex-resume`.

## How it works

Each Rex pane has a permanent ID that survives restarts. The watcher keeps a record for each pane running vibe, and updates it as things happen, not at shutdown.

```
Rex server starts → init.lua → rex do --all rex-resume.lua   (the watcher, one per server)

1. While you work
┌─ Rex pane  ID = 7f3a ────────────────┐
│ $ vibe                               │  terminal.process_changed: vibe-rs in front
│   … /resume, /new …                  │  terminal.program_status_changed: vibe reports (OSC 7501)
└──────────────────────────────────────┘
   ↳ the watcher asks vibe which conversation it has open (the lock its app server holds)
   ↳ ~/.local/state/rex-resume/panes/<server>/7f3a.json
        { cwd: ~/src/app, session: d90dff3e, instance: <this server's instance> }

2a. You quit vibe                         → the pane's shell is back in front → record deleted
2b. The server stops, crashes, is killed  → no event; the watcher ends with it → record stays

3. Rex comes back: same layout, same pane IDs, fresh shells; init.lua starts a new watcher
┌─ pane 7f3a (new shell) ───────────────────────────────┐
│ record from another server instance, shell at prompt  │
│ $ cd ~/src/app && vibe --resume d90dff3e              │  ← typed for you
└───────────────────────────────────────────────────────┘
```

| Who | Does what |
|---|---|
| Rex | Restores the layout and the pane IDs, starts the watcher (`init.lua`), reports what each pane runs |
| vibe | Holds a lock on the conversation it has open, reports its status |
| rex-resume | Keeps the records, and reopens vibe in restored panes |

### Why not save at shutdown

Another way to do this is a hook that saves which pane runs which conversation when the server stops (an `ExecStop=` on `rex.service`), and a job that replays the list after it starts. rex-resume keeps its records current instead:

| | Save at shutdown | rex-resume |
|---|---|---|
| `systemctl stop` or `restart rex` | Saved | Already recorded |
| Crash, OOM kill, `kill -9`, power loss | Nothing saved: the server is gone by the time the hook runs, or nothing runs at all | Already recorded |
| `rex server stop`, or a restart from the Rex app | Nothing saved: the server exits first, and systemd runs the hook after | Already recorded |
| Where it lives | Two systemd units, Linux only | Rex's `init.lua`, macOS or Linux |

## Safety

The watcher runs as you, on the server's machine, and uses nothing but Rex's API (over the local socket) and local files. It makes no network calls. It reads vibe's session store, and writes only to `~/.local/state/rex-resume`. It never starts a Rex server (`--autostart=false`). The only processes it stops are older rex-resume watchers: CLI clients of your account, on this machine, labeled `rex-resume`.

Typing into a pane is the one thing it does to your work, and it is guarded:

- Only after a server restart (a record left by an earlier server instance), and only within 60 seconds of the server's start. A watcher that starts later doesn't type into panes you have been using since.
- Only once per pane, and only when the pane's own shell (zsh, bash, fish, sh, dash, ksh) is in the foreground at its prompt.
- The line is fixed: Ctrl-U (which clears anything already typed, so it can't run glued to ours), then ` cd '<folder>' && vibe --resume <id>`. The session ID must be letters, digits and dashes. A folder name holding control characters, which a line editor would read as keys, is left out. vibe then resumes wherever the shell starts.
- The same holds for a record someone edited: the worst it can type is a `cd` to an existing folder and `vibe --resume`.

What it can't rule out: if the shell itself reads input at that moment (a `read` in your rc file), that input gets the line.

## Limits

- It relies on vibe internals: the `vibe-rs` process name, and the session store under `~/.vibe/logs/session`. That store holds `active/<id>.lock.json`, the lock held by vibe's app server, and `unified/<id>/meta.json`. Tested with vibe 3.1.4. If an update changes them, panes reopen a new vibe rather than the conversation. A custom `session_logging.save_dir` isn't supported.
- It relies on Rex's preview API: `rex do --all`, plus the terminal's `process` and `write` methods and `process_changed` events. Tested with Rex 0.1.0-preview.22 (API revision 19).
- `rex` must be on the Rex server's `PATH`. The watcher reads `VIBE_HOME` and `XDG_STATE_HOME` from the server's environment, not from your shell's.
- While no watcher runs (it was killed), nothing is noted. The next watcher catches up on what it can see: vibe running now, and panes that closed.
- A pane that isn't at its shell's prompt within 10 seconds of the restore is left alone. So is a watcher that starts more than 60 seconds after the server.
- A pane started with a command (`rex run -- vibe`) comes back however Rex restores it.
- A reply vibe was writing when Rex stopped doesn't continue: re-prompt it.

## Troubleshooting

- `rex client ls` lists a client labeled `rex-resume`.
- `tail ~/.local/state/rex-resume/watcher.log` shows `watching server …`, then a `note` for each vibe, and `resume` or `forget` lines as panes come back or vibe quits.
- `ls ~/.local/state/rex-resume/panes/*/` holds one record per pane running vibe (one folder per Rex server).
- If no watcher runs after `rex config reload`, check that `rex` is on the server's `PATH`. With systemd, run `systemctl --user show-environment`.
