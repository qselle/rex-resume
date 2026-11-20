-- rex-resume: the Rex server starts the watcher (rex-resume.lua) each time it
-- loads its configuration: at startup and on `rex config reload` (the new
-- watcher replaces the old one). Load this file from Rex's init.lua:
--   dofile(os.getenv("HOME") .. "/.rex-resume/init.lua")
-- The watcher logs to ~/.local/state/rex-resume/watcher.log.

-- This file's folder: Rex names a chunk by its path, without Lua's usual "@".
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local state = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/rex-resume"

rex.exec.start({ "sh", "-c", [[
# `rex config check` runs this file too: start only under the server.
case "$(ps -o args= -p "$PPID")" in *" server "* | *" server") ;; *) exit 0 ;; esac
mkdir -p "$2" || exit
log=$2/watcher.log
[ "$(wc -c <"$log" 2>/dev/null || echo 0)" -lt 1000000 ] || mv -f "$log" "$log.1"
# The server may load its configuration before it accepts connections. Never
# autostart: a watcher must not start a server of its own.
i=0
until rex --autostart=false whoami >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 40 ] || exit 1; sleep 0.5
done
exec rex --autostart=false do --all "$1" >>"$log" 2>&1
]], "rex-resume", dir .. "/rex-resume.lua", state }, { detach = true })
