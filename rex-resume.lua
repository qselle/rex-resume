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
local PANES = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/rex-resume/panes"
-- vibe's session store: who holds each conversation, and what it is.
local VIBE = (os.getenv("VIBE_HOME") or HOME .. "/.vibe") .. "/logs/session"

local instance -- this server's instance_id: a record from another one survived a restart

local function log(...)
  io.write(os.date("%Y-%m-%dT%H:%M:%S "), table.concat({ ... }, " "), "\n")
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
  return PANES .. "/" .. (block:gsub("^block:", "")) .. ".json"
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
  local new = { pid = vibe.pid, cwd = vibe.cwd, session = session, instance = instance }
  if rec and rec.pid == new.pid and rec.cwd == new.cwd and rec.session == new.session
    and rec.instance == new.instance and not rec.resuming then
    return
  end
  save(block, new)
  log("note", block, new.cwd or "?", new.session or "(no message yet)")
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

local function has_record(block)
  local f = io.open(record_path(block))
  if f then f:close() end
  return f ~= nil
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
  if not at_prompt(p) then
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
  local cd = is_dir(rec.cwd) and "cd " .. quote(rec.cwd) .. " && " or ""
  rec.instance, rec.resuming, rec.pid = instance, os.time(), nil
  save(block, rec)
  -- Typed as by hand; the leading space keeps it out of a history that ignores
  -- such lines (zsh's hist_ignore_space, bash's ignorespace).
  local _, err = rex.block.call(TERMINAL, "write", {
    session_id = session_id, block_id = block, data = " " .. cd .. cmd .. "\r",
  })
  log("resume", block, rec.cwd or "?", cmd, err or "")
end

-- Startup --------------------------------------------------------------------

-- One watcher per server: the newest, so `rex config reload` runs new code.
local function take_over()
  local me = rex.call("server.whoami", {}).principal.pid
  rex.call("client.set_label", { label = LABEL })
  local clients = (rex.call("client.list", {}) or {}).clients or {}
  local mine
  for _, c in ipairs(clients) do
    if c.principal and c.principal.pid == me then mine = c.client_id end
  end
  for _, c in ipairs(clients) do
    local pid = c.principal and c.principal.pid
    if c.info and c.info.label == LABEL and pid and pid ~= me and mine and c.client_id < mine then
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
          resume(s.session_id, b.block_id, rec)
        elseif rec and not resuming(rec) then
          forget(b.block_id, "vibe quit while unwatched")
        end
      end
    end
  end
  for _, name in ipairs(list(PANES)) do
    local block = "block:" .. (name:match("^(.+)%.json$") or "")
    if not live[block] then forget(block, "pane gone") end
  end
end

local status = assert(rex.call("server.status", {}))
instance = status.instance_id
local made = rex.exec { "mkdir", "-p", "-m", "700", PANES }
if not (made and made.ok) then error("cannot create " .. PANES, 0) end

rex.on("terminal.process_changed", function(ctx, ev)
  if find_vibe(ev.foreground, ev.ancestors) or has_record(ctx.block_id) then
    poke(ctx.session_id, ctx.block_id)
  end
end)
-- vibe reports its state (OSC 7501) as it works and when it switches
-- conversation: the moment to look its session up again.
rex.on("terminal.program_status_changed", function(ctx, ev)
  if (ev.record and ev.record.app == "vibe") or has_record(ctx.block_id) then
    poke(ctx.session_id, ctx.block_id)
  end
end)
rex.on("block_closed", function(ctx, ev)
  forget(ev.block_id, "pane closed")
end)

-- Session calls work once the script listens, not at its top level.
rex.after(0, function()
  log("watching", "server " .. instance)
  take_over()
  reconcile()
end)
