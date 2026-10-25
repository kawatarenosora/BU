-- BU_client.lua v0.5.0 - Java premise
-- One key (F8 by default, changeable in mod options) does both jobs,
-- split by screen so the two can never collide:
--   in-game          -> backup: pause (speed 0 + NoSave attempt) ->
--                      guard&lock -> retry on transient -> unlock.
--   title screen     -> toggle the restore list (2-step confirm per slot).
-- No persistent panel: the list window exists only while it is open.
-- No vanilla menu patching (version-proof): own window + key + debug console.
--
-- Kahlua rule (proven by tick crash): NEVER call obj:method() unless
-- type(obj.method)=="function" was verified first. Missing-method dispatch
-- escapes pcall. All object calls go through jobj().
require "BU"

local KEY_F8 = 66 -- LWJGL keycode; F6=64 clashes with vanilla fast-forward

BU.client = BU.client or {}
local client = BU.client
client.THROTTLE = 20
client.tick = 0
client.armedSlot = nil
client.armedAt = 0
client.listPage = 1

local _unpack = (table and table.unpack) or unpack

-- Safe object call: existence pre-check, then pcall. Returns nil on any miss.
local function jobj(obj, method, ...)
    if obj == nil then return nil end
    local f = obj[method]
    if type(f) ~= "function" then return nil end
    local args = { ... }
    local n = select("#", ...)
    local ok, r = pcall(function()
        if _unpack then return f(obj, _unpack(args)) end
        if n == 0 then return f(obj)
        elseif n == 1 then return f(obj, args[1])
        elseif n == 2 then return f(obj, args[1], args[2])
        elseif n == 3 then return f(obj, args[1], args[2], args[3])
        elseif n == 4 then return f(obj, args[1], args[2], args[3], args[4])
        elseif n == 5 then return f(obj, args[1], args[2], args[3], args[4], args[5])
        elseif n == 6 then return f(obj, args[1], args[2], args[3], args[4], args[5], args[6])
        else return f(obj, args[1], args[2], args[3], args[4], args[5], args[6], args[7]) end
    end)
    if not ok then return nil end
    return r
end

-- Safe constructor: jobj(Class,"new",...) with sentinel (nil = failed)
local function joclass(classTable, ...)
    if type(classTable) ~= "table" then return nil end
    if type(classTable.new) ~= "function" then return nil end
    return jobj(classTable, "new", ...)
end

-- ---------- guards ----------
function BU.getManualKey()
    if type(getCore) == "function" then
        local okc, core = pcall(getCore)
        if okc and core and type(core.getKey) == "function" then
            local ok, v = pcall(function() return core:getKey("BU_Manual") end)
            if ok and v and v ~= 0 then return v end
        end
    end
    return KEY_F8
end

function BU.requestManual()
    if not BU.isManualKeyEnabled() then
        print("[BU] manual key disabled in sandbox")
        return
    end
    if BU.isClientOnly() then
        print("[BU] blocked: MP client")
        BU.notify("UI_BU_MPBlocked", "")
        return
    end
    if BU.menuMode then
        -- Title screen: the same key toggles the restore list. Restore is
        -- title-only and backup is in-game-only, so the two never collide.
        if BU.restoreAllowed() then
            client.toggleList()
        elseif BU.isClientOnly() then
            BU.notify("UI_BU_MPBlocked", "")
        end
        return
    end
    local now = BU.nowMs()
    if client.lastManualMs and now ~= 0 and (now - client.lastManualMs) < 2000 then return end
    client.lastManualMs = now
    print("[BU] manual backup requested (open ESC menu = paused = safest)")
    BU.doBackup(true)
end

-- ---------- UI ----------
-- English-only (see BU.STR in the shared core): no getText lookup, so the
-- label is identical in every game language and never shows a raw key.
local function txt(key)
    return BU.s(key)
end

-- No panel any more, so the running indicator rides on the list window's
-- title when one is open; otherwise it is the log/halo only.
function client.setStatus(s)
    if client.listWin then
        jobj(client.listWin, "setTitle", "BU " .. tostring(s or ""))
    end
end

BU.onRunningChanged = function(running)
    if running then
        client.setStatus("- " .. txt("UI_BU_Running"))
    else
        client.setStatus("")
    end
end

function client.fmtDate(ms)
    if not ms or ms == 0 then return "-" end
    if type(os) == "table" and type(os.date) == "function" then
        local ok, v = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(ms / 1000))
        if ok and v then return tostring(v) end
    end
    return tostring(ms)
end

function client.closeList()
    if client.listWin then
        jobj(client.listWin, "setVisible", false)
        jobj(client.listWin, "removeFromUIManager")
        client.listWin = nil
    end
    client.armedSlot = nil
    client.listPage = 1
end

-- One page of rows. No scrolling: paging keeps the list at a fixed
-- height, so it never grows off-screen and needs no scroll container.
client.PAGE_SIZE = 8

-- Hotkey on the title screen: open the list, or close it if already open.
-- Rebuilds from disk on open, so a backup taken since is picked up.
function client.toggleList()
    if client.listWin ~= nil then
        print("[BU] restore list closed by key")
        client.closeList()
        return
    end
    local now = BU.nowMs()
    if client.lastToggleMs and now ~= 0 and (now - client.lastToggleMs) < 400 then return end
    client.lastToggleMs = now
    print("[BU] restore list opened by key")
    client.openList()
end

function client.openList(page)
    client.closeList()
    local slots, err = BU.listSlots()
    if slots == nil then
        BU.notify("UI_BU_RestoreFailed", tostring(err))
        return
    end
    -- newest first (mtime desc), then slot name as a stable tiebreak
    table.sort(slots, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return tostring(a.slot) < tostring(b.slot)
    end)
    local total = #slots
    local pages = math.max(1, math.ceil(total / client.PAGE_SIZE))
    local cur = page or 1
    if cur < 1 then cur = 1 end
    if cur > pages then cur = pages end
    local win = joclass(ISCollapsableWindow, 220, 10, 330, 120)
    if win == nil then
        print("[BU] list window failed")
        return
    end
    jobj(win, "setTitle", txt("UI_BU_ListTitle"))
    jobj(win, "initialise")
    jobj(win, "addToUIManager")
    jobj(win, "setVisible", true)
    jobj(win, "bringToTop")
    client.listWin = win
    local y = 30
    if total == 0 and type(ISLabel) == "table" and UIFont and UIFont.Small then
        local lbl = joclass(ISLabel, 12, y, 20, txt("UI_BU_NoBackups"), 1, 1, 1, 1, UIFont.Small)
        if lbl ~= nil then jobj(win, "addChild", lbl) end
        y = y + 26
    end
    client.listPage = cur
    local from = (cur - 1) * client.PAGE_SIZE + 1
    local to = math.min(from + client.PAGE_SIZE - 1, total)
    for i = from, to do
        local e = slots[i]
        local title = e.slot .. "  " .. client.fmtDate(e.mtime)
            .. "  " .. tostring(e.files) .. "f/" .. tostring(math.floor((e.bytes or 0) / 1024)) .. "KB"
        local b = joclass(ISButton, 10, y, 310, 24, title, client, client.onEntryClick)
        if b ~= nil then
            b.buSlot = e.slot
            jobj(win, "addChild", b)
            y = y + 28
        end
    end
    -- Pager row (only when there is more than one page)
    if pages > 1 then
        local pb = joclass(ISButton, 10, y, 100, 24, txt("UI_BU_Prev"), client, client.onPrevPage)
        if pb ~= nil then jobj(win, "addChild", pb) end
        if type(ISLabel) == "table" and UIFont and UIFont.Small then
            local pl = joclass(ISLabel, 118, y + 5, 100, 20,
                tostring(cur) .. "/" .. tostring(pages), 1, 1, 1, 1, UIFont.Small)
            if pl ~= nil then jobj(win, "addChild", pl) end
        end
        local nb = joclass(ISButton, 220, y, 100, 24, txt("UI_BU_Next"), client, client.onNextPage)
        if nb ~= nil then jobj(win, "addChild", nb) end
        y = y + 28
    end
    local cb = joclass(ISButton, 10, y + 4, 310, 24, txt("UI_BU_Close"), client, client.onCloseList)
    if cb ~= nil then jobj(win, "addChild", cb) end
    jobj(win, "setHeight", y + 40)
end

function client:onEntryClick(btn)
    if not btn or not btn.buSlot then return end
    if not BU.restoreAllowed() then
        BU.notify("UI_BU_RestoreFailed", "not on title")
        return
    end
    local slot = btn.buSlot
    local now = BU.nowMs()
    local dt = (now ~= 0 and client.armedAt ~= 0) and (now - client.armedAt) or nil
    if client.armedSlot == slot and (dt == nil or (dt >= 0 and dt < 8000)) then
        client.armedSlot = nil
        print("[BU] restore confirmed slot=" .. slot)
        client.closeList()
        BU.doRestore(slot)
        return
    end
    client.armedSlot = slot
    client.armedAt = now
    jobj(btn, "setTitle", txt("UI_BU_ConfirmRestore") .. " " .. slot)
    print("[BU] restore armed slot=" .. slot .. " (press again within 8s to confirm)")
end

function client:onCloseList(btn)
    client.closeList()
end

-- Paging rebuilds the window, which also drops any half-armed confirm.
function client:onPrevPage(btn)
    client.openList((client.listPage or 1) - 1)
end

function client:onNextPage(btn)
    client.openList((client.listPage or 1) + 1)
end

-- ---------- events ----------
local function onKeyPressed(key)
    if not BU.isManualKeyEnabled() then return end
    if key == BU.getManualKey() then
        BU.requestManual()
    end
end

local function onGameBoot()
    BU.menuMode = true
    if type(keyBinding) == "table" then
        local exists = false
        for _, v in ipairs(keyBinding) do
            if v.value == "BU_Manual" then exists = true; break end
        end
        if not exists then
            table.insert(keyBinding, { value = "[BU]" })
            table.insert(keyBinding, { value = "BU_Manual", key = KEY_F8 })
            print("[BU] keyBinding registered F8")
        end
    end
end

local function onGameStart()
    BU.menuMode = false
    client.closeList()
    print("[BU] OnGameStart (F8 backup in-game, F8 restore list on title)")
end

local function onMainMenuEnter()
    BU.menuMode = true
    client.closeList()
    print("[BU] OnMainMenuEnter")
end

local function onTick()
    client.tick = client.tick + 1
    if (client.tick % client.THROTTLE) == 0 then
        -- Restore is title-only: leaving the world detaches the list.
        if not BU.menuMode and client.listWin then client.closeList() end
        -- Main-menu UI is rebuilt on top of ours; keep the list clickable.
        if BU.menuMode and client.listWin then jobj(client.listWin, "bringToTop") end
    end
    BU.pump()
end

local function initKeyBinding()
    onGameBoot()
end

Events.OnGameBoot.Add(initKeyBinding)
Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnTick.Add(onTick)
if Events.OnMainMenuEnter then
    Events.OnMainMenuEnter.Add(onMainMenuEnter)
end

print("[BU] client v" .. BU.version .. " loaded - F8: backup in-game / toggle restore list on title")
