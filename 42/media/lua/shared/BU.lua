-- BU.lua (shared) - Backup mod core v0.5.0, Java premise (bu-agent javaagent)
-- Spec (fixed):
--   * Backup: hotkey only -> pause (speed 0 + Core NoSave attempt) ->
--     guard&lock (isBackingUp + sync freeze) -> retry on transient
--     (ERR_RETRY) up to MAX_ATTEMPTS, then fail (permanent errors finish)
--     -> unlock + notify.
--     External root (%USERPROFILE%/Zomboid/BU/<mode>__<name>/). No generations.
--   * Best-effort autosave suppression during copy (speed 0 + Core NoSave),
--     detection + retry on transient (ERR_RETRY) up to MAX_ATTEMPTS,
--     sync run + running indicator (Halo + log).
--   * MP guard: client-only disabled (SP+host enabled).
--   * Title-screen restore: list slots -> select -> 2-step confirm -> overwrite.
-- Debug: BU.doBackup(true) / BU.doRestore("<mode>__<name>")
-- English-only UI: see BU.STR. Sandbox option labels live in
-- Translate/EN/Sandbox.json because the game's options screen reads them.
if BU == nil then BU = {} end

BU.version = "0.5.0"
BU.modId = "BU"
BU.isBackingUp = false
BU.backupCount = 0
BU.restoreCount = 0
BU.menuMode = true -- true on title (no world); client flips on GameStart/MenuEnter
-- UI strings are plain English constants, not getText lookups: this mod is
-- English-only by design. The old getText keys are kept as table keys so the
-- call sites read unchanged and a later translation pass stays mechanical.
BU.STR = {
    UI_BU_Running          = "running...",
    UI_BU_BackupStart      = "Backing up...",
    UI_BU_BackupDone       = "Backup done.",
    UI_BU_BackupFailed     = "Backup FAILED:",
    UI_BU_RestoreStart     = "Restoring...",
    UI_BU_RestoreDone      = "Restore done.",
    UI_BU_RestoreFailed    = "Restore FAILED:",
    UI_BU_Retrying         = "Retrying:",
    UI_BU_MPBlocked        = "Disabled in MP client (SP/host only).",
    UI_BU_NoBackups        = "no backups",
    UI_BU_ListTitle        = "BU Restore (title only)",
    UI_BU_ConfirmRestore   = "RESTORE? press again:",
    UI_BU_Prev             = "< Prev",
    UI_BU_Next             = "Next >",
    UI_BU_Close            = "Close",
}

-- Never let a missing key surface as a raw key name.
function BU.s(key)
    local v = BU.STR[key]
    if v ~= nil then return v end
    return "BU"
end

BU.RETRY_DELAY_MS = 3000 -- transient (ERR_RETRY) retries until success
-- Shared retry cap: backup (tick-driven) and restore (sync sleep on the
-- title screen) both give up here (~3 min). Data stays intact on failure.
BU.MAX_ATTEMPTS = 60

-- retry/deferred-run state machine (driven by client OnTick pump)
BU._pending = nil -- {kind="runBackup"/"retryBackup", attempts=N, atMs=T}

-- ---------- Sandbox ----------
function BU.isNotifyEnabled()
    if SandboxVars and SandboxVars.BU and SandboxVars.BU.EnableNotify ~= nil then
        return SandboxVars.BU.EnableNotify
    end
    return true
end

function BU.isManualKeyEnabled()
    if SandboxVars and SandboxVars.BU and SandboxVars.BU.BackupOnManualKey ~= nil then
        return SandboxVars.BU.BackupOnManualKey
    end
    return true
end

-- ---------- MP guard: true only for remote-client (no local save) ----------
function BU.isClientOnly()
    local c, s = false, false
    if type(isClient) == "function" then
        local ok, v = pcall(isClient)
        if ok and v then c = true end
    end
    if type(isServer) == "function" then
        local ok, v = pcall(isServer)
        if ok and v then s = true end
    end
    return c and not s
end

function BU.restoreAllowed()
    return not BU.isBackingUp and not BU.isClientOnly() and BU.menuMode
end

-- ---------- Java bridge ----------
function BU.bridge()
    local b = rawget(_G, "BUControl")
    if b ~= nil then return b end
    -- ZombieBuddy edition publishes under the package path (bu.BUControl);
    -- it carries no top-level alias, so self-install one here once. Later
    -- lookups take the fast path. The javaagent edition (main branch)
    -- provides the alias itself, so this keeps one Lua for both editions.
    local ns = rawget(_G, "bu")
    if type(ns) == "table" then
        local c = rawget(ns, "BUControl")
        if c ~= nil then
            pcall(rawset, _G, "BUControl", c)
            return c
        end
    end
    return nil
end

local _unpack = (table and table.unpack) or unpack

function BU.jcall(name, ...)
    local b = BU.bridge()
    if b == nil then return nil, "no bridge (bu-agent?)" end
    local f = b[name]
    if type(f) ~= "function" then return nil, "no method " .. tostring(name) end
    local args = { ... }
    local n = select("#", ...)
    local ok, r = pcall(function()
        if _unpack then return f(_unpack(args)) end
        if n == 0 then return f()
        elseif n == 1 then return f(args[1])
        elseif n == 2 then return f(args[1], args[2])
        else return f(args[1], args[2], args[3]) end
    end)
    if not ok then return nil, tostring(r) end
    return r, nil
end

function BU.getRoot()
    local r, err = BU.jcall("defaultRoot")
    if r == nil or r == "" then return nil, err or "no root" end
    if string.sub(tostring(r), 1, 4) == "ERR_" then return nil, tostring(r) end
    return tostring(r), nil
end

function BU.getSlot(root, mode, name)
    local r, err = BU.jcall("slotFor", root, mode, name)
    if r == nil or r == "" then return nil, err or "no slot" end
    if string.sub(tostring(r), 1, 4) == "ERR_" then return nil, tostring(r) end
    return tostring(r), nil
end

-- ---------- Save info ----------
function BU.getSaveInfo()
    if type(getLatestSave) ~= "function" then return nil, nil end
    local ok, tbl = pcall(getLatestSave)
    if not ok or not tbl then return nil, nil end
    local name, mode = nil, nil
    pcall(function() name = tbl[1] end)
    pcall(function() mode = tbl[2] end)
    if name and mode then return tostring(mode), tostring(name) end
    if tbl.get then
        pcall(function() name = tbl:get(0); mode = tbl:get(1) end)
        if name and mode then return tostring(mode), tostring(name) end
    end
    if tbl[0] then
        name = tbl[0]; mode = tbl[1]
        if name and mode then return tostring(mode), tostring(name) end
    end
    return nil, nil
end

function BU.getAbsoluteSavePath(rel)
    if not rel or rel == "" then return nil end
    if type(getAbsoluteSaveFolderName) ~= "function" then return nil end
    local ok, abs = pcall(getAbsoluteSaveFolderName, rel)
    if ok and abs and abs ~= "" then return tostring(abs) end
    return nil
end

-- slot "<mode>__<name>" -> mode, name (split at FIRST "__"; mode is a fixed token)
function BU.splitSlot(slot)
    if not slot or slot == "" then return nil, nil end
    local i, j = string.find(slot, "__", 1, true)
    if not i then return nil, nil end
    local mode = string.sub(slot, 1, i - 1)
    local name = string.sub(slot, j + 1)
    if mode == "" or name == "" then return nil, nil end
    return mode, name
end

-- ---------- Notification (player may be nil on title) ----------
function BU.notify(haloKey, detail)
    local msg = BU.s(haloKey)
    if detail and detail ~= "" then msg = msg .. " " .. detail end
    print("[BU] " .. msg)
    if not BU.isNotifyEnabled() then return end
    if type(getSpecificPlayer) == "function" then
        local ok, p = pcall(getSpecificPlayer, 0)
        if ok and p and type(p.setHaloNote) == "function" then
            pcall(function() p:setHaloNote(msg, 0, 255, 0, 300) end)
        end
    end
end

-- ---------- Pause / autosave-suppression envelope (best effort, logged) ----------
BU._env = nil

function BU.pushEnv()
    local env = { speed = nil, noSave = nil }
    if type(getGameSpeed) == "function" and type(setGameSpeed) == "function" then
        local ok, v = pcall(getGameSpeed)
        if ok and type(v) == "number" then
            env.speed = v
            pcall(setGameSpeed, 0)
        end
    end
    if type(getCore) == "function" then
        local ok, core = pcall(getCore)
        if ok and core and type(core.setNoSave) == "function" and type(core.isNoSave) == "function" then
            local ok2, v2 = pcall(function() return core:isNoSave() end)
            if ok2 then env.noSave = v2 end
            local ok3, err3 = pcall(function() core:setNoSave(true) end)
            if not ok3 then print("[BU] setNoSave(true) failed: " .. tostring(err3)) end
        end
    end
    BU._env = env
end

function BU.popEnv()
    local env = BU._env
    BU._env = nil
    if not env then return end
    if env.speed ~= nil and type(setGameSpeed) == "function" then
        pcall(setGameSpeed, env.speed)
    end
    if env.noSave ~= nil and type(getCore) == "function" then
        local ok, core = pcall(getCore)
        if ok and core and type(core.setNoSave) == "function" then
            pcall(function() core:setNoSave(env.noSave) end)
        end
    end
end

-- ---------- Result classification ----------
function BU.classify(res)
    if not res then return "ERR", "nil result" end
    local s = tostring(res)
    if string.sub(s, 1, 3) == "OK|" then return "OK", s end
    if string.sub(s, 1, 10) == "ERR_RETRY|" then return "RETRY", s end
    return "ERR", s
end

function BU.nowMs()
    if type(getTimestampMs) == "function" then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- ---------- One backup attempt (sync). Returns kind, detail ----------
function BU.attemptBackupOnce()
    local mode, name = BU.getSaveInfo()
    if not mode or not name then return "ERR", "ERR_NOSRC|no save info" end
    local root, rerr = BU.getRoot()
    if not root then return "ERR", "root: " .. tostring(rerr) end
    local slot, serr = BU.getSlot(root, mode, name)
    if not slot then return "ERR", "slot: " .. tostring(serr) end
    local saveOk = false
    if type(saveGame) ~= "function" then return "ERR", "ERR_SAVE|no saveGame" end
    local ok, err = pcall(saveGame)
    if ok then saveOk = true else print("[BU] saveGame failed: " .. tostring(err)) end
    if not saveOk and type(save) == "function" then
        local ok2 = pcall(save, true)
        if ok2 then saveOk = true end
    end
    if not saveOk then return "ERR", "ERR_SAVE|saveGame failed" end
    local src = BU.getAbsoluteSavePath(mode .. "/" .. name)
    if not src then return "ERR", "ERR_NOSRC|no abs path" end
    local res = BU.jcall("backupTo", src, slot)
    local kind, detail = BU.classify(res)
    if kind == "OK" then
        BU.backupCount = BU.backupCount + 1
    end
    return kind, (detail or "") .. " slot=" .. slot
end

-- ---------- Public backup entry (deferred to tick for running indicator) ----------
function BU.doBackup(isManual)
    if BU.isClientOnly() then
        print("[BU] blocked: MP client")
        BU.notify("UI_BU_MPBlocked", "")
        return
    end
    if BU.menuMode then
        print("[BU] blocked: backup needs a loaded world (use title Restore on menu)")
        return
    end
    if BU.isBackingUp then
        print("[BU] already backing up, skip")
        return
    end
    BU.isBackingUp = true
    BU.notify("UI_BU_BackupStart", "")
    BU._pending = { kind = "runBackup", manual = isManual, attempts = 0 }
    if BU.onRunningChanged then pcall(BU.onRunningChanged, true) end
end

function BU.finishBackup(kind, detail)
    BU.popEnv()
    BU.isBackingUp = false
    BU._pending = nil
    if BU.onRunningChanged then pcall(BU.onRunningChanged, false) end
    if kind == "OK" then
        BU.notify("UI_BU_BackupDone", tostring(detail))
    else
        BU.notify("UI_BU_BackupFailed", tostring(detail))
    end
    print("[BU] Backup end " .. tostring(kind) .. " " .. tostring(detail))
end

-- ---------- Restore ----------
function BU.listSlots()
    local root, rerr = BU.getRoot()
    if not root then return nil, "root: " .. tostring(rerr) end
    local res = BU.jcall("listBackups", root)
    if res == nil then return nil, "no result" end
    local s = tostring(res)
    if s == "EMPTY" then return {}, nil end
    if string.sub(s, 1, 4) == "ERR_" then return nil, s end
    local out = {}
    for line in string.gmatch(s, "[^\n]+") do
        local parts = {}
        for p in string.gmatch(line, "[^|]+") do table.insert(parts, p) end
        if parts[1] then
            table.insert(out, { slot = parts[1], mtime = tonumber(parts[2]) or 0,
                files = tonumber(parts[3]) or 0, bytes = tonumber(parts[4]) or 0 })
        end
    end
    return out, nil
end

function BU.doRestore(slot)
    -- Synchronous: title screen has no OnTick pump, so the deferred path
    -- would never run. UI freezes during copy = lock (same as backup run).
    if BU.isClientOnly() then
        BU.notify("UI_BU_MPBlocked", "")
        return
    end
    if not BU.menuMode then
        print("[BU] blocked: restore only on title screen")
        BU.notify("UI_BU_RestoreFailed", "not on title")
        return
    end
    if BU.isBackingUp then
        print("[BU] busy, skip restore")
        return
    end
    local mode, name = BU.splitSlot(slot)
    if not mode or not name then
        BU.notify("UI_BU_RestoreFailed", "bad slot")
        return
    end
    BU.isBackingUp = true
    BU.notify("UI_BU_RestoreStart", slot)
    if BU.onRunningChanged then pcall(BU.onRunningChanged, true) end
    local n = 0
    while true do
        n = n + 1
        local ok, kind, detail = pcall(BU.attemptRestoreOnce, mode, name, slot)
        if not ok then
            BU.finishRestore("ERR", "lua error: " .. tostring(kind), slot)
            return
        end
        if kind == "OK" then
            BU.finishRestore(kind, detail, slot)
            return
        elseif kind == "RETRY" and n < BU.MAX_ATTEMPTS then
            print("[BU] restore transient fail, sync retry #" .. tostring(n) .. " : " .. tostring(detail))
            BU.notify("UI_BU_Retrying", tostring(n) .. "/" .. tostring(BU.MAX_ATTEMPTS))
            BU.jcall("sleepMs", BU.RETRY_DELAY_MS)
        else
            if kind == "RETRY" then
                detail = tostring(detail) .. " (gave up after " .. tostring(n) .. " tries)"
            end
            BU.finishRestore(kind, detail, slot)
            return
        end
    end
end

function BU.attemptRestoreOnce(mode, name, slot)
    local root, rerr = BU.getRoot()
    if not root then return "ERR", "root: " .. tostring(rerr) end
    local backupAbs, err = BU.getSlot(root, mode, name)
    if not backupAbs then
        return "ERR", "slot: " .. tostring(err)
    end
    -- sanity: slot arg must match
    local wantTail = mode .. "__" .. name
    if string.sub(backupAbs, -string.len(wantTail)) ~= wantTail then
        return "ERR", "ERR_SLOT|mismatch"
    end
    local saveAbs = BU.getAbsoluteSavePath(mode .. "/" .. name)
    if not saveAbs then return "ERR", "ERR_NOSRC|no live save path (mode/name unknown?)" end
    local res = BU.jcall("restoreBackup", backupAbs, saveAbs)
    local kind, detail = BU.classify(res)
    if kind == "OK" then BU.restoreCount = BU.restoreCount + 1 end
    return kind, (detail or "")
end

function BU.finishRestore(kind, detail, slot)
    BU.isBackingUp = false
    BU._pending = nil
    if BU.onRunningChanged then pcall(BU.onRunningChanged, false) end
    if kind == "OK" then
        BU.notify("UI_BU_RestoreDone", tostring(slot))
    else
        BU.notify("UI_BU_RestoreFailed", tostring(detail))
    end
    print("[BU] Restore end " .. tostring(kind) .. " slot=" .. tostring(slot) .. " " .. tostring(detail))
end

-- ---------- Tick pump: runs deferred backup work + retries (client OnTick) ----------
-- Restore is NOT pumped: BU.doRestore is synchronous (title screen), so the
-- only pending kinds here are runBackup / retryBackup.
function BU.pump()
    local p = BU._pending
    if not p then return end
    if p.kind ~= "runBackup" and p.kind ~= "retryBackup" then return end
    local now = BU.nowMs()
    local firstRun = (p.kind == "runBackup")
    if not firstRun then
        -- wait out RETRY_DELAY_MS (now==0 means no clock: run immediately)
        if p.atMs and p.atMs ~= 0 and now ~= 0 and now < p.atMs then return end
    end
    BU._pending = nil
    if BU.menuMode then
        BU.finishBackup("ERR", firstRun and "world closed before run" or "world closed before retry")
        return
    end
    -- Envelope (pause + NoSave) is pushed once per backup, popped by
    -- finishBackup; retries keep it in place.
    if firstRun then BU.pushEnv() end
    local ok, kind, detail = pcall(BU.attemptBackupOnce)
    if not ok then
        BU.finishBackup("ERR", "lua error: " .. tostring(kind))
        return
    end
    if kind == "OK" then
        BU.finishBackup(kind, detail)
    elseif kind == "RETRY" then
        -- transient only: retry until success (permanent errors finish)
        local n = (p.attempts or 0) + 1
        if n >= BU.MAX_ATTEMPTS then
            BU.finishBackup("ERR", tostring(detail) .. " (gave up after " .. tostring(n) .. " tries)")
            return
        end
        print("[BU] backup transient fail, attempt #" .. tostring(n) .. " : " .. tostring(detail))
        BU.notify("UI_BU_Retrying", tostring(n) .. "/" .. tostring(BU.MAX_ATTEMPTS))
        BU._pending = { kind = "retryBackup", attempts = n, atMs = now + BU.RETRY_DELAY_MS }
    else
        BU.finishBackup(kind, detail)
    end
end

print("[BU] core loaded v" .. BU.version)

-- ---------- Diagnostics: run BU.Debug() in Lua console / check log ----------
function BU.Debug()
    print("[BU-Debug] version=" .. tostring(BU.version)
        .. " menuMode=" .. tostring(BU.menuMode)
        .. " isBackingUp=" .. tostring(BU.isBackingUp)
        .. " clientOnly=" .. tostring(BU.isClientOnly()))
    local b = BU.bridge()
    print("[BU-Debug] bridge=" .. tostring(b ~= nil))
    if b and type(b.version) == "function" then
        local ok, v = pcall(function() return b.version() end)
        print("[BU-Debug] java=" .. tostring(v) .. " ok=" .. tostring(ok))
    end
    local root, rerr = BU.getRoot()
    print("[BU-Debug] root=" .. tostring(root) .. " err=" .. tostring(rerr))
    if root then
        local slots, serr = BU.listSlots()
        if slots then
            print("[BU-Debug] slots=" .. tostring(#slots))
            for i = 1, math.min(#slots, 10) do
                print("[BU-Debug]   " .. tostring(slots[i].slot))
            end
        else
            print("[BU-Debug] list err=" .. tostring(serr))
        end
    end
    local mode, name = BU.getSaveInfo()
    print("[BU-Debug] save=" .. tostring(mode) .. "/" .. tostring(name))
    if BU.client then
        print("[BU-Debug] listOpen=" .. tostring(BU.client.listWin ~= nil)
            .. " page=" .. tostring(BU.client.listPage))
    end
end

-- Force-clear a stuck run (e.g. BU.Abort() from console). No file writes.
function BU.Abort()
    BU._pending = nil
    BU.popEnv()
    BU.isBackingUp = false
    if BU.onRunningChanged then pcall(BU.onRunningChanged, false) end
    print("[BU] aborted by user")
end

-- Force the restore list to rebuild (e.g. BU.Reopen() from console if the
-- list is missing after a UI swap)
function BU.Reopen()
    if BU.client and BU.client.openList then
        BU.client.openList()
        print("[BU] reopen listOpen=" .. tostring(BU.client.listWin ~= nil))
    else
        print("[BU] reopen unavailable (client not loaded)")
    end
end

-- Restore-list window dump: run BU.WinState() on the title screen
function BU.WinState()
    print("[BU-Win] menuMode=" .. tostring(BU.menuMode)
        .. " listOpen=" .. tostring(BU.client and BU.client.listWin ~= nil))
    local w = BU.client and BU.client.listWin
    if w then
        local r = {}
        if type(w.isVisible) == "function" then
            local ok1, v1 = pcall(function() return w:isVisible() end)
            if ok1 then r.isVisible = v1 end
        end
        r.field = w.visible
        local s = ""
        for k, v in pairs(r) do s = s .. k .. "=" .. tostring(v) .. " " end
        print("[BU-Win] list " .. s)
        if type(w.getX) == "function" and type(w.getY) == "function" then
            local okX, x = pcall(function() return w:getX() end)
            local okY, y = pcall(function() return w:getY() end)
            if okX and okY then print("[BU-Win] x=" .. tostring(x) .. " y=" .. tostring(y)) end
        end
    else
        print("[BU-Win] no list window")
    end
    if type(ISPauseMenu) == "table" then
        local ok, v = pcall(function()
            if ISPauseMenu.instance and type(ISPauseMenu.instance.isVisible) == "function" then
                return ISPauseMenu.instance:isVisible()
            end
            return "no instance/method"
        end)
        print("[BU-Win] ISPauseMenu visible=" .. tostring(v) .. " ok=" .. tostring(ok))
    else
        print("[BU-Win] ISPauseMenu absent")
    end
end

-- Scan global names only (no value calls) to find B42 pause/menu classes.
-- Run BU.FindMenu() with ESC menu open.
function BU.FindMenu()
    local pats = { "pause", "menu", "esc", "option", "resume", "quit" }
    local hits = {}
    local n = 0
    for k, _ in pairs(_G) do
        if type(k) == "string" then
            local lk = string.lower(k)
            for _, p in ipairs(pats) do
                if string.find(lk, p, 1, true) then
                    n = n + 1
                    if #hits < 60 then table.insert(hits, k) end
                    break
                end
            end
        end
        if n > 400 then break end
    end
    table.sort(hits)
    print("[BU-Find] globals=" .. tostring(n))
    for _, h in ipairs(hits) do print("[BU-Find]   " .. h) end
end
