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
    grudgeNote = { grudge = true, settledBy = "killedThem", text = "%s" },
    kindNote = { kind = true, text = "%s" },
}

local db
local myName -- set at login
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
-- Recording. This client keeps the combat log from addons, so everything
-- here comes from unit state, your own buffs and chat messages.
---------------------------------------------------------------------------

-- Units that can be checked by name: what you're looking at, and every nameplate.
local function EachUnit(fn)
    for _, unit in ipairs({ "target", "focus", "mouseover" }) do fn(unit) end
    for i = 1, 40 do fn("nameplate" .. i) end
end

-- Your killer is the hostile player who had you targeted when you died; a
-- creature with you targeted too means you were busy with it.
local function OnPlayerDead()
    local killers, seen, busy = {}, {}, nil
    EachUnit(function(unit)
        if not (UnitExists(unit) and UnitIsUnit(unit .. "target", "player") and UnitCanAttack("player", unit)) then return end
        if UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and not seen[guid] then
                seen[guid] = true
                killers[#killers + 1] = { name = GetUnitName(unit, true), guid = guid }
            end
        else
            busy = true
        end
    end)
    for _, k in ipairs(killers) do
        local p = Add(k.name, k.guid, "killedMe", { busy = busy })
        Notify(("%s killed you. Noted in the book (%s)."):format(k.name, Summary(p)))
    end
end

-- Buffs other players put on you, in the open world only and once a day per
-- player: cities and dungeons would fill the book.
local function OnPlayerAura(_, info)
    if not (info and info.addedAuras) or IsInInstance() then return end
    for _, aura in ipairs(info.addedAuras) do
        local src = aura.sourceUnit
        if aura.isHelpful and src and UnitIsPlayer(src) and not UnitIsUnit(src, "player")
            and not UnitCanAttack("player", src) then
            local name, guid = Ambiguate(GetUnitName(src, true), "none"), UnitGUID(src)
            local p = Record(name, guid)
            local today = date("%Y-%m-%d")
            if p.buffDay ~= today then
                p.buffDay = today
                Add(name, guid, "buff", { s = aura.name })
            end
        end
    end
end

-- "%1$s has defeated %2$s in a duel" -> a pattern, and which argument each capture is.
local function GlobalPattern(fmt)
    local order = {}
    local pat = fmt:gsub("%%(%d*)%$?[sd]", function(n)
        order[#order + 1] = n ~= "" and tonumber(n) or #order + 1
        return "\0"
    end)
    pat = pat:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%z", "(.+)")
    return "^" .. pat .. "$", order
end

-- "Name dies, honorable kill Rank: ...": a player you or your group killed.
local HONOR_PATTERNS = {}
for _, fmt in ipairs({ COMBATLOG_HONORGAIN, COMBATLOG_HONORGAIN_NO_RANK }) do
    if fmt then HONOR_PATTERNS[#HONOR_PATTERNS + 1] = { GlobalPattern(fmt) } end
end

local function OnHonorGain(msg)
    for _, h in ipairs(HONOR_PATTERNS) do
        local caps = { msg:match(h[1]) }
        if caps[1] then
            local args = {}
            for i, n in ipairs(h[2]) do args[n] = caps[i] end
            local victim = args[1]
            local _, e = Add(victim, nil, "killedThem")
            if e.avenged then Notify(victim .. ": grudge avenged!") end
            return
        end
    end
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
        elseif KIND[e.k].grudge then line = "|cffff5050" .. line .. "|r"
        elseif KIND[e.k].kind then line = "|cff50ff50" .. line .. "|r" end
        print("  " .. line)
    end
end

-- Everyone in the book: open grudges first, then the most recently met.
local function PrintBook()
    local list = {}
    for name, p in pairs(Book()) do
        local summary = Summary(p)
        if summary or #p.entries > 0 then
            list[#list + 1] = { name = name, open = (Counts(p)), seen = p.seen or 0, summary = summary or "notes" }
        end
    end
    table.sort(list, function(a, b)
        if a.open ~= b.open then return a.open > b.open end
        return a.seen > b.seen
    end)
    if #list == 0 then
        Print("the book is empty. A peaceful life.")
        return
    end
    Print("the book (/grudge <name> for a page):")
    for _, g in ipairs(list) do print(("  %s: %s"):format(g.name, g.summary)) end
end

SLASH_BETTERGRUDGES1 = "/grudge"
SLASH_BETTERGRUDGES2 = "/grudges"
SlashCmdList.BETTERGRUDGES = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local first, rest = msg:match("^(%S*)%s*(.-)$")
    local cmd = first:lower()
    if cmd == "" then
        PrintBook()
    elseif cmd == "help" then
        Print("commands:")
        print("  /grudge - everyone in the book, open grudges first")
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
-- Right-click menu: "Add to the book" on a player asks for a note.
---------------------------------------------------------------------------
StaticPopupDialogs.BETTERGRUDGES_NOTE = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 200,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function(self, data)
        local text = (self.EditBox or self.editBox):GetText():match("^%s*(.-)%s*$")
        if text ~= "" then
            local p = Add(data.name, data.guid, data.kind, { s = text })
            Print(("noted on %s's page (%s)."):format(data.name, Summary(p) or "notes"))
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local popup = self:GetParent()
        StaticPopupDialogs.BETTERGRUDGES_NOTE.OnAccept(popup, popup.data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

local function AddMenuEntry(_, root, context)
    local unit = context and context.unit
    local name, guid
    if unit and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
        name, guid = GetUnitName(unit, true), UnitGUID(unit)
    elseif context and context.name and not unit then
        name = context.server and context.server ~= "" and (context.name .. "-" .. context.server) or context.name
    end
    if not name then return end
    root:CreateDivider()
    local book = root:CreateButton("Add to the book")
    local short = Ambiguate(name, "none")
    for _, choice in ipairs({
        { label = "|cffff5050Grudge|r", kind = "grudgeNote", prompt = "A grudge against %s:" },
        { label = "|cff50ff50Kindness|r", kind = "kindNote", prompt = "A kindness from %s:" },
        { label = "Note", kind = "note", prompt = "A note on %s:" },
    }) do
        book:CreateButton(choice.label, function()
            StaticPopup_Show("BETTERGRUDGES_NOTE", choice.prompt:format(short), nil,
                { name = name, guid = guid, kind = choice.kind })
        end)
    end
end

-- The player menus: unit frames, nameplates, party and raid, and names in chat.
if Menu and Menu.ModifyMenu then
    for _, tag in ipairs({ "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_PARTY",
        "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS" }) do
        Menu.ModifyMenu(tag, AddMenuEntry)
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local handlers = {
    UNIT_AURA = OnPlayerAura,
    CHAT_MSG_COMBAT_HONOR_GAIN = OnHonorGain,
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
        myName = UnitName("player")
        for name in pairs(handlers) do
            if name == "UNIT_AURA" then frame:RegisterUnitEvent(name, "player") else frame:RegisterEvent(name) end
        end
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        return
    end
    handlers[event](...)
end)
