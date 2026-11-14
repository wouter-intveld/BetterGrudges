local ADDON = ...
local TITLE = "|cffcda552Better|rGrudges"

local DEFAULTS = {
    quiet = false, -- don't print new entries to chat
    realms = {},   -- realm -> player name -> record (see Record)
}

-- Entry kinds. A grudge stays open until a matching win settles it.
local KIND = {
    killedMe = { grudge = true, settledBy = "killedThem", text = "killed you" },
    duelLost = { grudge = true, settledBy = "duelWon", text = "bested you in a duel" },
    killedThem = { text = "fell to you" },
    duelWon = { text = "lost a duel to you" },
    rez = { kind = true, text = "offered you a resurrection" },
    buff = { kind = true, text = "buffed you with %s" },
    note = { text = "%s" },
}

-- Combat log flags.
local TYPE_PLAYER, TYPE_NPC, HOSTILE = 0x400, 0x800, 0x40
local KILLER_WINDOW = 10 -- seconds: a player hit you this recently, so your death is theirs
local BUSY_WINDOW = 6    -- seconds: you were trading blows with a creature

local db
local me, myName -- player GUID and name, set at login
local lastAttacker, lastAttackerGUID, lastAttackTime = nil, nil, 0
local lastPveTime = 0
local lastRez = {} -- name -> time, so a recast isn't noted twice

local function Print(msg)
    print(TITLE .. ": " .. msg)
end

local function Notify(msg)
    if not db.quiet then Print(msg) end
end

local function Book()
    local realm = GetRealmName()
    db.realms[realm] = db.realms[realm] or {}
    return db.realms[realm]
end

-- The player's record, created on first meeting. name is "Name" on your own
-- realm and "Name-Realm" for others.
local function Record(name, guid)
    local book = Book()
    local p = book[name]
    if not p then
        p = { entries = {} }
        book[name] = p
    end
    if guid and not p.class then
        local _, class = GetPlayerInfoByGUID(guid)
        p.class = class
    end
    return p
end

local function Describe(e)
    local text = KIND[e.k].text:format(e.s or "")
    if e.busy then text = text .. " while you were fighting something else" end
    if e.z and e.z ~= "" then text = text .. " in " .. e.z end
    return text
end

local function Add(name, guid, kind, extra)
    name = Ambiguate(name, "none")
    local p = Record(name, guid)
    local e = { t = time(), k = kind, z = GetZoneText() }
    for key, value in pairs(extra or {}) do e[key] = value end
    p.entries[#p.entries + 1] = e
    p.seen = e.t

    -- A win settles the oldest open grudge of its kind.
    for _, old in ipairs(p.entries) do
        local def = KIND[old.k]
        if def.settledBy == kind and not old.done then
            old.done = e.t
            e.avenged = true
            break
        end
    end
    return p, e
end

local function Counts(p)
    local open, settled, kindness = 0, 0, 0
    for _, e in ipairs(p.entries) do
        local def = KIND[e.k]
        if def.grudge then
            if e.done then settled = settled + 1 else open = open + 1 end
        elseif def.kind then
            kindness = kindness + 1
        end
    end
    return open, settled, kindness
end

local function Summary(p)
    local open, settled, kindness = Counts(p)
    local parts = {}
    if open > 0 then parts[#parts + 1] = ("|cffff5050%d grudge%s|r"):format(open, open == 1 and "" or "s") end
    if settled > 0 then parts[#parts + 1] = ("|cff999999%d settled|r"):format(settled) end
    if kindness > 0 then parts[#parts + 1] = ("|cff50ff50%d kindness%s|r"):format(kindness, kindness == 1 and "" or "es") end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------
local function OnCombatLog()
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, _, spellName, _, auraType =
        CombatLogGetCurrentEventInfo()
    if srcGUID ~= me and dstGUID ~= me then return end -- most of the log: not about you

    local srcPlayer = bit.band(srcFlags, TYPE_PLAYER) > 0
    if dstGUID == me and srcGUID ~= me then
        if sub:sub(-7) == "_DAMAGE" then
            if srcPlayer and bit.band(srcFlags, HOSTILE) > 0 then
                lastAttacker, lastAttackerGUID, lastAttackTime = srcName, srcGUID, GetTime()
            elseif bit.band(srcFlags, TYPE_NPC) > 0 then
                lastPveTime = GetTime()
            end
        elseif sub == "SPELL_AURA_APPLIED" and auraType == "BUFF" and srcPlayer and srcName
            and bit.band(srcFlags, HOSTILE) == 0 and not IsInInstance() then
            -- Open world only, and once a day per player: cities would fill the book.
            local p = Record(Ambiguate(srcName, "none"), srcGUID)
            local today = date("%Y-%m-%d")
            if p.buffDay ~= today then
                p.buffDay = today
                Add(srcName, srcGUID, "buff", { s = spellName })
            end
        end
    elseif srcGUID == me then
        if sub == "PARTY_KILL" and dstName and bit.band(dstFlags, TYPE_PLAYER) > 0
            and bit.band(dstFlags, HOSTILE) > 0 then
            local _, e = Add(dstName, dstGUID, "killedThem")
            if e.avenged then Notify(dstName .. ": grudge avenged!") end
        elseif sub:sub(-7) == "_DAMAGE" and bit.band(dstFlags, TYPE_NPC) > 0 then
            lastPveTime = GetTime()
        end
    end
end

local function OnPlayerDead()
    if lastAttacker and GetTime() - lastAttackTime <= KILLER_WINDOW then
        local busy = lastPveTime >= lastAttackTime - BUSY_WINDOW or nil
        local p = Add(lastAttacker, lastAttackerGUID, "killedMe", { busy = busy })
        Notify(("%s killed you. Noted in the book (%s)."):format(lastAttacker, Summary(p)))
    end
    lastAttacker = nil
end

-- "%1$s has defeated %2$s in a duel" -> a pattern, and which argument each capture is.
local function GlobalPattern(fmt)
    local order = {}
    local pat = fmt:gsub("%%(%d)%$s", function(n)
        order[#order + 1] = tonumber(n)
        return "\0"
    end):gsub("%%s", function()
        order[#order + 1] = #order + 1
        return "\0"
    end)
    pat = pat:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%z", "(.+)")
    return "^" .. pat .. "$", order
end

local DUEL_PATTERNS = {}
for _, fmt in ipairs({ DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT }) do
    if fmt then
        local pat, order = GlobalPattern(fmt)
        DUEL_PATTERNS[#DUEL_PATTERNS + 1] = { pat = pat, order = order }
    end
end

local function OnSystemMessage(msg)
    for _, d in ipairs(DUEL_PATTERNS) do
        local caps = { msg:match(d.pat) }
        if caps[1] then
            local args = {}
            for i, n in ipairs(d.order) do args[n] = caps[i] end
            local winner, loser = args[1], args[2] -- both formats: %1 wins, %2 loses
            if winner == myName and loser then
                local _, e = Add(loser, nil, "duelWon")
                if e.avenged then Notify(loser .. ": duel grudge settled!") end
            elseif loser == myName and winner then
                Add(winner, nil, "duelLost")
                Notify(winner .. " bested you in a duel. Noted in the book.")
            end
            return
        end
    end
end

local function OnResurrectRequest(name)
    if not name or (lastRez[name] and GetTime() - lastRez[name] < 60) then return end
    lastRez[name] = GetTime()
    Add(name, nil, "rez")
    Notify(name .. " offered you a resurrection. You owe them one.")
end

---------------------------------------------------------------------------
-- Tooltip: one line on players in the book
---------------------------------------------------------------------------
local function OnUnitTooltip(tooltip)
    local _, unit = tooltip:GetUnit()
    if not (unit and UnitIsPlayer(unit)) or UnitIsUnit(unit, "player") then return end
    local p = Book()[Ambiguate(GetUnitName(unit, true), "none")]
    local summary = p and Summary(p)
    if summary then tooltip:AddLine("Grudges: " .. summary) end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
-- A name typed in any case, or "target", to the key it has in the book.
local function FindName(arg)
    if arg:lower() == "target" then
        if UnitIsPlayer("target") then return Ambiguate(GetUnitName("target", true), "none"), UnitGUID("target") end
        return nil
    end
    local lower = arg:lower()
    for name in pairs(Book()) do
        if name:lower() == lower then return name end
    end
    return arg:sub(1, 1):upper() .. arg:sub(2):lower()
end

local function PrintLedger(name)
    local p = Book()[name]
    if not p or #p.entries == 0 then
        Print(name .. " isn't in the book.")
        return
    end
    Print(("%s%s: %s"):format(name, p.class and (" (" .. p.class:lower() .. ")") or "", Summary(p) or "nothing to settle"))
    for _, e in ipairs(p.entries) do
        local line = date("%Y-%m-%d", e.t) .. "  " .. Describe(e)
        if e.done then line = "|cff999999" .. line .. " [settled]|r"
        elseif KIND[e.k].grudge then line = "|cffff5050" .. line .. "|r" end
        print("  " .. line)
    end
end

local function PrintOpen()
    local list = {}
    for name, p in pairs(Book()) do
        local open = Counts(p)
        if open > 0 then list[#list + 1] = { name = name, open = open } end
    end
    table.sort(list, function(a, b) return a.open > b.open end)
    if #list == 0 then
        Print("no open grudges. A peaceful life.")
    else
        Print("open grudges:")
        for _, g in ipairs(list) do print(("  %s: %d"):format(g.name, g.open)) end
    end
end

SLASH_BETTERGRUDGES1 = "/grudge"
SLASH_BETTERGRUDGES2 = "/grudges"
SlashCmdList.BETTERGRUDGES = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local first, rest = msg:match("^(%S*)%s*(.-)$")
    local cmd = first:lower()
    if cmd == "" then
        PrintOpen()
    elseif cmd == "help" then
        Print("commands:")
        print("  /grudge - players you hold open grudges against")
        print("  /grudge <name> - their page in the book (\"target\" works as a name)")
        print("  /grudge <name> <text> - write a note on their page")
        print("  /grudge forgive <name> - settle all their open grudges")
        print("  /grudge quiet - don't print new entries")
    elseif cmd == "quiet" then
        db.quiet = not db.quiet
        Print("new entries " .. (db.quiet and "muted" or "printed"))
    elseif cmd == "forgive" then
        local name = rest ~= "" and FindName(rest)
        local p = name and Book()[name]
        if not p then
            Print("usage: /grudge forgive <name>")
            return
        end
        local n = 0
        for _, e in ipairs(p.entries) do
            if KIND[e.k].grudge and not e.done then
                e.done, n = time(), n + 1
            end
        end
        Print(n > 0 and ("%s: %d grudge%s forgiven. Generous."):format(name, n, n == 1 and "" or "s")
            or (name .. " has no open grudges."))
    else
        local name, guid = FindName(first)
        if not name then
            Print("your target isn't a player.")
        elseif rest == "" then
            PrintLedger(name)
        else
            Add(name, guid, "note", { s = rest })
            Print("noted on " .. name .. "'s page.")
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local handlers = {
    COMBAT_LOG_EVENT_UNFILTERED = OnCombatLog,
    PLAYER_DEAD = OnPlayerDead,
    CHAT_MSG_SYSTEM = OnSystemMessage,
    RESURRECT_REQUEST = OnResurrectRequest,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        frame:UnregisterEvent("ADDON_LOADED")
        BetterGrudgesDB = BetterGrudgesDB or {}
        db = BetterGrudgesDB
        for key, value in pairs(DEFAULTS) do
            if db[key] == nil then db[key] = type(value) == "table" and CopyTable(value) or value end
        end
        me, myName = UnitGUID("player"), UnitName("player")
        for name in pairs(handlers) do frame:RegisterEvent(name) end
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        return
    end
    handlers[event](...)
end)
