-- rex-resume: reopen vibe conversations in the panes Rex restores after its
-- server restarts (upgrade, reboot, crash). https://github.com/qselle/rex-resume
--
-- The Rex server starts this script itself (init.lua, see the README):
--   rex --autostart=false do --all rex-resume.lua
-- It keeps one record per pane running vibe, written as things happen:
--   vibe starts, or switches conversation  → record: folder, session, server instance
--   vibe returns to the pane's shell       → record deleted
--   server stops, crashes or is killed     → no event: the record stays
-- Rex restores the panes under the same IDs, as fresh shells. A record left
-- by an earlier server instance types `cd <folder> && vibe --resume <id>`.

local TERMINAL = "com.superlogical.terminal"
local LABEL = "rex-resume"
local HOME = os.getenv("HOME")
local STATE = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/rex-resume"
-- vibe's session store: who holds each conversation, and what it is.
local VIBE = (os.getenv("VIBE_HOME") or HOME .. "/.vibe") .. "/logs/session"

-- Shells whose syntax the typed line uses: `cd '…' && vibe …`.
local SHELLS = { zsh = true, bash = true, fish = true, sh = true, dash = true, ksh = true, mksh = true }
-- A restored pane is resumed only this soon after the server started. A
-- watcher that starts later (it failed to start, then a reload) must not type
-- into panes that have been in use since.
local RESUME_WINDOW = 60

local instance -- this server's instance_id: a record from another one survived a restart
local started  -- when this server started, in seconds since the epoch
local panes    -- this server's records: STATE/panes/<host_id>, one folder per Rex server

-- Control characters (from a folder name) are written as "?": the log is read
-- in terminals.
local function log(...)
  io.write(os.date("%Y-%m-%dT%H:%M:%S "), (table.concat({ ... }, " "):gsub("%c", "?")), "\n")
  io.flush()
end

-- Files ----------------------------------------------------------------------

local function read_json(path)
  local f = io.open(path)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return rex.json.decode(text)
end

local function record_path(block)
  return panes .. "/" .. (block:gsub("^block:", "")) .. ".json"
end

local function load(block)
  return read_json(record_path(block))
end

local function save(block, rec)
  local path = record_path(block)
  local f = assert(io.open(path .. ".tmp", "w"))
  f:write(rex.json.encode(rec))
  f:close()
  assert(os.rename(path .. ".tmp", path))
end

local function forget(block, why)
  if os.remove(record_path(block)) then log("forget", block, why) end
end

local function list(dir)
  local names, r = {}, rex.exec { "ls", dir }
  if r and r.ok then
    for name in r.stdout:gmatch("[^\n]+") do names[#names + 1] = name end
  end
  return names
end

-- Processes ------------------------------------------------------------------

local function is_vibe(p)
  return p ~= nil and (p.name == "vibe-rs" or p.name == "vibe")
end

-- The vibe a pane runs: in the foreground, or above a tool it runs there.
-- Ancestors come first, from the pane's shell down: the outermost vibe wins.
local function find_vibe(fg, ancestors)
  for _, p in ipairs(ancestors or {}) do
    if is_vibe(p) then return p end
  end
  if is_vibe(fg) then return fg end
end

local function parent_pid(pid)
  local f = io.open("/proc/" .. pid .. "/stat") -- Linux; ps elsewhere
  if f then
    local stat = f:read("*a")
    f:close()
    return tonumber(stat:match(".*%) %S+ (%d+)"))
  end
  local r = rex.exec { "ps", "-o", "ppid=", "-p", tostring(pid) }
  return r and r.ok and tonumber(r.stdout:match("%d+")) or nil
end

-- The conversation a vibe process has open. Its app server (vibe-rs's child)
-- holds a lock on each session it runs: subagents' have a parent session, and
-- a conversation without a first message has no meta.json yet (nothing to
-- resume).
local function vibe_session(pid)
  local best
  for _, name in ipairs(list(VIBE .. "/active")) do
    local lock = name:match("%.lock%.json$") and read_json(VIBE .. "/active/" .. name)
    local id = lock and lock.session_id
    if id and id:match("^[%w-]+$") and lock.process_id
      and (lock.process_id == pid or parent_pid(lock.process_id) == pid) then
      local meta = read_json(VIBE .. "/unified/" .. id .. "/meta.json")
      if meta and meta.parent_session_id == nil
        and (best == nil or (lock.acquired_at or "") > best.acquired_at) then
        best = { id = id, acquired_at = lock.acquired_at or "" }
      end
    end
  end
  return best and best.id
end

local function process(session_id, block)
  return rex.block.call(TERMINAL, "process", { session_id = session_id, block_id = block })
end

-- The pane's own shell is in the foreground, at its prompt.
local function at_prompt(p)
  return p.child ~= nil and p.foreground ~= nil and p.foreground.pid == p.child.pid
end

-- Tracking -------------------------------------------------------------------

-- A resume just typed: the pane's shell runs it, then vibe starts.
local function resuming(rec)
  return rec.resuming ~= nil and os.time() - rec.resuming < 60
end

local function note(block, vibe, rec)
  local session = vibe_session(vibe.pid)
  if session == nil and rec and (rec.pid == vibe.pid or resuming(rec)) then
    session = rec.session -- not found this time (vibe still starting up): keep it
  end
  save(block, { pid = vibe.pid, cwd = vibe.cwd, session = session, instance = instance })
  if not rec or rec.session ~= session or rec.cwd ~= vibe.cwd then
    log("note", block, vibe.cwd or "?", session or "(no message yet)")
  end
end

-- What a pane runs now, asked of the server rather than taken from an event.
local function refresh(session_id, block, confirm)
  local p = process(session_id, block)
  if p == nil then return end -- pane closed, or the server is going away: keep the record
  local rec = load(block)
  local vibe = find_vibe(p.foreground, p.ancestors)
  if vibe then return note(block, vibe, rec) end
  if rec == nil or rec.instance ~= instance or resuming(rec) or not at_prompt(p) then return end
  -- vibe returned to the shell. When the server stops, vibe and its shell die
  -- with it: check again a moment later, which a server going away never does.
  if confirm then return forget(block, "vibe quit") end
  rex.after(3, function() refresh(session_id, block, true) end)
end

local pending = {}
local function poke(session_id, block)
  if pending[block] then pending[block]:cancel() end
  pending[block] = rex.after(0.5, function()
    pending[block] = nil
    refresh(session_id, block)
  end)
end

-- Resuming -------------------------------------------------------------------

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function is_dir(path)
  local r = path and rex.exec { "test", "-d", path }
  return r ~= nil and r.ok
end

local function resume(session_id, block, rec, tries)
  local p = process(session_id, block)
  if p == nil then return end
  if not (at_prompt(p) and SHELLS[p.child.name]) then
    -- The restored shell is still starting (its rc files run commands too):
    -- wait for its prompt, and give up if the pane runs something else by then.
    if (tries or 0) < 20 then
      rex.after(0.5, function() resume(session_id, block, rec, (tries or 0) + 1) end)
    else
      forget(block, "pane busy")
    end
    return
  end
  local cmd = "vibe"
  if rec.session and rec.session:match("^[%w-]+$") and read_json(VIBE .. "/unified/" .. rec.session .. "/meta.json") then
    cmd = "vibe --resume " .. rec.session
  end
  -- The line is typed, so the line editor reads every byte as a key: a folder
  -- name holding control characters (C0, DEL, C1) could type a command of its
  -- own. Such a folder is skipped, and vibe resumes wherever the shell is.
  local cd = ""
  if rec.cwd and not rec.cwd:find("%c") and not rec.cwd:find("\194[\128-\159]") and is_dir(rec.cwd) then
    cd = "cd " .. quote(rec.cwd) .. " && "
  end
  rec.instance, rec.resuming, rec.pid = instance, os.time(), nil
  save(block, rec)
  -- Typed as by hand: Ctrl-U first clears anything already typed at the
  -- prompt, so it can't run glued to ours. The leading space keeps the line
  -- out of a history that ignores such lines (zsh's hist_ignore_space, bash's
  -- ignorespace).
  local _, err = rex.block.call(TERMINAL, "write", {
    session_id = session_id, block_id = block, data = "\21 " .. cd .. cmd .. "\r",
  })
  log("resume", block, rec.cwd or "?", cmd, err or "")
end

-- Startup --------------------------------------------------------------------

-- One watcher per server: the newest, so `rex config reload` runs new code.
local function take_over()
  local who = rex.call("server.whoami", {}).principal
  local me = who.pid
  rex.call("client.set_label", { label = LABEL })
  local clients = (rex.call("client.list", {}) or {}).clients or {}
  local mine
  for _, c in ipairs(clients) do
    if c.principal and c.principal.pid == me then mine = c.client_id end
  end
  for _, c in ipairs(clients) do
    local pid = c.principal and c.principal.pid
    -- Only an older watcher: a CLI client of this account on this machine.
    if c.info and c.info.label == LABEL and c.info.kind == "cli" and c.principal.transport == "unix"
      and c.principal.uid == who.uid and pid and pid ~= me and mine and c.client_id < mine then
      rex.exec { "kill", tostring(pid) }
      log("replaced watcher", tostring(pid))
    end
  end
end

-- Every pane, as found now: vibe running, a pane to resume, a stale record.
local function reconcile()
  local live = {}
  for _, s in ipairs((rex.call("session.list", {}) or {}).sessions or {}) do
    local blocks = rex.session.list_blocks { session_id = s.session_id }
    for _, b in ipairs((blocks and blocks.blocks) or {}) do
      if b.creator_name == TERMINAL then
        live[b.block_id] = true
        local rec = load(b.block_id)
        local p = process(s.session_id, b.block_id)
        local vibe = p and find_vibe(p.foreground, p.ancestors)
        if vibe then
          note(b.block_id, vibe, rec)
        elseif rec and rec.instance ~= instance then
          if started and os.time() - started < RESUME_WINDOW then
            resume(s.session_id, b.block_id, rec)
          else
            forget(b.block_id, "server started too long ago to resume")
          end
        elseif rec and not resuming(rec) then
          forget(b.block_id, "vibe quit while unwatched")
        end
      end
    end
  end
  for _, name in ipairs(list(panes)) do
    local block = "block:" .. (name:match("^(.+)%.json$") or "")
    if not live[block] then forget(block, "pane gone") end
  end
end

-- The server's start time ("2026-11-20T18:38:36.32Z", UTC) in seconds since
-- the epoch, or nil. Plain arithmetic (days_from_civil): os.time would read the
-- fields as local time.
local function epoch(stamp)
  local y, mo, d, h, mi, s = (stamp or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%d.]*Z$")
  if not y then return nil end
  y, mo = tonumber(y), tonumber(mo)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((mo + 9) % 12) + 2) / 5) + tonumber(d) - 1
  local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

local status = assert(rex.call("server.status", {}))
instance = status.instance_id
started = epoch(status.started_at)
panes = STATE .. "/panes/" .. assert(status.host_id, "server has no host_id")
local made = rex.exec { "mkdir", "-p", panes }
if not (made and made.ok) then error("cannot create " .. panes, 0) end
rex.exec { "chmod", "700", STATE }

rex.on("terminal.process_changed", function(ctx, ev)
  if find_vibe(ev.foreground, ev.ancestors) or load(ctx.block_id) then
    poke(ctx.session_id, ctx.block_id)
  end
end)
-- vibe reports its state (OSC 7501) as it works and when it switches
-- conversation: the moment to look its session up again.
rex.on("terminal.program_status_changed", function(ctx, ev)
  if (ev.record and ev.record.app == "vibe") or load(ctx.block_id) then
    poke(ctx.session_id, ctx.block_id)
  end
end)
rex.on("block_closed", function(ctx, ev)
  forget(ev.block_id, "pane closed")
end)

-- Session calls work once the script listens, not at its top level.
rex.after(0, function()
  log("watching", "server " .. instance, started and "" or "(start time unknown: no resume)")
  take_over()
  reconcile()
end)
